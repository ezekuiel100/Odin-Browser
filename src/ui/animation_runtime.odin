package ui

import "core:math"
import dom "../dom"
import js "../js"

Animation_Event :: struct { kind: string, elapsed: f32 }
Animation_Player :: struct {
    anim: Anim,
    elapsed: f32,
    started, ended: bool,
    iteration: int,
    pending: [dynamic]Animation_Event,
}

// Sample independently of visibility/culling. Paused animations still enter
// their initial phase (including a negative delay), but do not advance time.
animation_step :: proc(p: ^Animation_Player, dt: f32) {
    a := &p.anim
    if !a.active do return
    if !a.paused do p.elapsed += max(dt, 0)
    active := p.elapsed - a.delay
    if active < 0 do return
    end := a.iter > 0 ? a.dur * a.iter : f32(3.4028235e38)
    if a.zero_iterations || a.dur == 0 do end = 0
    if !p.started {
        p.started = true
        append(&p.pending, Animation_Event{"animationstart", clamp(-a.delay, 0, end)})
        // A negative delay skips iterations without synthesizing their events.
        p.iteration = a.dur > 0 ? int(math.floor(min(max(-a.delay, 0), end) / a.dur)) : 0
    }
    cycles := a.dur > 0 ? int(math.floor(min(active, end) / a.dur)) : 0
    for i := p.iteration + 1; i <= cycles; i += 1 {
        if f32(i) * a.dur >= end do break
        append(&p.pending, Animation_Event{"animationiteration", f32(i) * a.dur})
    }
    p.iteration = max(p.iteration, cycles)
    if active >= end && !p.ended {
        p.ended = true
        append(&p.pending, Animation_Event{"animationend", end})
    }
}

animation_step_tree :: proc(b: ^Box, dt: f32) {
    if b == nil do return
    for &p in b.animations {
        clear(&p.pending) // at most one frame of events when no VM is attached
        animation_step(&p, dt)
    }
    for c in b.children do animation_step_tree(c, dt)
    for it in b.inlines do if it.box != nil do animation_step_tree(it.box, dt)
}

// Handlers run after recording/replaying paint; callers subsequently check the
// DOM fingerprint and rebuild if necessary.
animation_dispatch :: proc(b: ^Box, vm: ^js.Interp) -> bool {
    if b == nil || vm == nil do return false
    fired := false
    for &p in b.animations {
        for ev in p.pending {
            if b.node != nil {
                if js.dispatch_animation_event(vm, b.node, ev.kind, p.anim.name, f64(ev.elapsed)) do fired = true
            }
        }
        clear(&p.pending)
    }
    for c in b.children do if animation_dispatch(c, vm) do fired = true
    for it in b.inlines do if it.box != nil && animation_dispatch(it.box, vm) do fired = true
    return fired
}

animation_index :: proc(b: ^Box, index: ^map[^dom.Node]^Box) {
    if b == nil do return
    if len(b.animations) > 0 && b.node != nil do index[b.node] = b
    for c in b.children do animation_index(c, index)
    for it in b.inlines do if it.box != nil do animation_index(it.box, index)
}

animation_restore :: proc(b: ^Box, index: map[^dom.Node]^Box) {
    if b == nil do return
    if old, ok := index[b.node]; ok {
        used := make([]bool, len(old.animations), context.temp_allocator)
        // Match from right to left, consuming duplicate names once.
        for i := len(b.animations) - 1; i >= 0; i -= 1 {
            p := &b.animations[i]
            for j := len(old.animations) - 1; j >= 0; j -= 1 {
                prev := &old.animations[j]
                if used[j] || !p.anim.active || prev.anim.name != p.anim.name do continue
                used[j] = true
                p.elapsed = prev.elapsed; p.started = prev.started
                p.ended = prev.ended; p.iteration = prev.iteration
                p.pending = prev.pending; prev.pending = nil
                break
            }
        }
    }
    for c in b.children do animation_restore(c, index)
    for it in b.inlines do if it.box != nil do animation_restore(it.box, index)
}

animation_restore_tree :: proc(root, old: ^Box) {
    if old == nil do return
    index := make(map[^dom.Node]^Box, context.temp_allocator)
    animation_index(old, &index)
    animation_restore(root, index)
}
