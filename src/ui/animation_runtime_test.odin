package ui

import "core:testing"
import "core:mem/virtual"
import css "../css"
import html "../html"
import dom "../dom"
import js "../js"

ANIM_TEST_KF :: "@keyframes Fade{from{opacity:0}to{opacity:1}}@keyframes Tint{from{background-color:black}to{background-color:white}}"

@(test)
animation_styles_survive_temp_arena :: proc(t: ^testing.T) {
    root := html.parse_render("<html><body><div class='x'>animated</div></body></html>")
    defer dom.free_tree(root)
    rules, kf := css.parse(".x{animation:Move 1s,Move 2s}@keyframes Move{from{transform:translateX(0)}to{transform:translateX(10px)}}")
    defer css.free_rules(&rules)
    defer css.free_keyframes(&kf)
    arena: virtual.Arena
    err := virtual.arena_init_growing(&arena)
    testing.expect(t, err == nil)
    if err != nil do return
    saved_temp := context.temp_allocator
    context.temp_allocator = virtual.arena_allocator(&arena)
    styles, _ := compute_styles(root, &rules, 1280, 900, kf[:])
    context.temp_allocator = saved_temp
    virtual.arena_destroy(&arena)
    // Simulate fetch_worker/frame teardown before the style map is released.
    c := styles[dom.find_first(root, "div")]
    testing.expect_value(t, c.anim.n, 2)
    testing.expect_value(t, len(c.anim_more), 1)
    testing.expect_value(t, c.anim.stops[1].pct, f32(1))
    testing.expect_value(t, c.anim_more[0].stops[1].pct, f32(1))
    free_styles(styles)
}

@(test)
animation_multiple_lists :: proc(t: ^testing.T) {
    c := test_compute_anim(".x{animation:Fade 2s linear -1s paused both,Tint 4s steps(4,end) -1s paused both}"+ANIM_TEST_KF, "div", "x")
    testing.expect_value(t, len(c.anim_more), 1)
    if len(c.anim_more) != 1 do return
    testing.expect_value(t, c.anim.name, "Fade")
    testing.expect_value(t, c.anim_more[0].name, "Tint")
    testing.expect(t, abs(test_eval_anim(&c.anim, 0).op - 0.5) < 0.001)
    testing.expect_value(t, test_eval_anim(&c.anim_more[0], 0).bg, u32(0x3f3f3f))
}

@(test)
animation_longhand_repetition_and_none :: proc(t: ^testing.T) {
    c := test_compute_anim(".x{animation-name:Fade,none,Tint;animation-duration:2s,4s;animation-delay:-1s;animation-play-state:paused;animation-timing-function:linear,steps(2,end)}"+ANIM_TEST_KF, "div", "x")
    testing.expect_value(t, len(c.anim_more), 2)
    if len(c.anim_more) != 2 do return
    testing.expect(t, !c.anim_more[0].active)
    testing.expect_value(t, c.anim_more[1].dur, f32(2))
    testing.expect_value(t, c.anim_more[1].delay, f32(-1))
    testing.expect(t, c.anim_more[1].paused)
    testing.expect_value(t, c.anim_more[1].timing.kind, Timing_Kind.Linear)
}

@(test)
animation_event_boundaries_pause_and_finish :: proc(t: ^testing.T) {
    c := test_compute_anim(".x{animation:Fade 1s 0.5s 2.5 linear}"+ANIM_TEST_KF, "div", "x")
    p := Animation_Player{anim = c.anim}; defer delete(p.pending)
    animation_step(&p, 0.25)
    testing.expect_value(t, len(p.pending), 0)
    animation_step(&p, 0.25)
    testing.expect_value(t, len(p.pending), 1)
    testing.expect_value(t, p.pending[0].kind, "animationstart")
    p.anim.paused = true
    animation_step(&p, 10)
    testing.expect_value(t, p.elapsed, f32(0.5))
    p.anim.paused = false
    animation_step(&p, 2.5)
    testing.expect_value(t, len(p.pending), 4)
    testing.expect_value(t, p.pending[1].elapsed, f32(1))
    testing.expect_value(t, p.pending[2].elapsed, f32(2))
    testing.expect_value(t, p.pending[3].kind, "animationend")
    testing.expect_value(t, p.pending[3].elapsed, f32(2.5))
    animation_step(&p, 10)
    testing.expect_value(t, len(p.pending), 4)
}

@(test)
animation_negative_delay_skips_past_iterations :: proc(t: ^testing.T) {
    c := test_compute_anim(".x{animation:Fade 1s -2.5s 4 linear paused}"+ANIM_TEST_KF, "div", "x")
    p := Animation_Player{anim=c.anim}; defer delete(p.pending)
    animation_step(&p, 0)
    testing.expect_value(t, len(p.pending), 1)
    testing.expect_value(t, p.pending[0].elapsed, f32(2.5))
    p.anim.paused = false
    animation_step(&p, 1.5)
    testing.expect_value(t, len(p.pending), 3)
    testing.expect_value(t, p.pending[1].elapsed, f32(3))
    testing.expect_value(t, p.pending[2].kind, "animationend")
}

@(test)
animation_restore_duplicate_names_from_right :: proc(t: ^testing.T) {
    n := dom.make_node(.Element); defer dom.free_tree(n)
    old := Box{node=n, animations=make([]Animation_Player, 1)}
    old.animations[0] = Animation_Player{anim=Anim{active=true,name="Fade"},elapsed=0.75,started=true}
    defer delete(old.animations)
    fresh := Box{node=n, animations=make([]Animation_Player, 2)}
    defer delete(fresh.animations)
    for &p in fresh.animations do p.anim = Anim{active=true,name="Fade"}
    animation_restore_tree(&fresh, &old)
    testing.expect_value(t, fresh.animations[0].elapsed, f32(0))
    testing.expect_value(t, fresh.animations[1].elapsed, f32(0.75))
    testing.expect(t, fresh.animations[1].started)
}

@(test)
animation_restyle_preserves_clock_and_dispatches_dom_event :: proc(t: ^testing.T) {
    doc := html.parse("<html><body><div class='x' id='x'></div></body></html>")
    defer dom.free_tree(doc)
    rules, kf := css.parse(".x{animation:Fade 1s linear 2}"+ANIM_TEST_KF)
    defer css.free_rules(&rules); defer css.free_keyframes(&kf)
    tab := Tab{dom=doc,rules=rules,kf=kf,rules_ready=true}
    tab.vm = js.vm_create_with_dom(doc); defer js.vm_free(tab.vm)
    defer { free_layout(tab.layout); free_styles(tab.styles) }
    js.vm_run(tab.vm, `
        var events = [];
        document.body.addEventListener('animationstart', function(e) {
            events.push(e.type + ':' + e.animationName + ':' + e.elapsedTime);
            e.preventDefault();
            document.getElementById('x').setAttribute('data-canceled', String(e.defaultPrevented));
        });
        document.body.addEventListener('animationend', function(e) { events.push(e.type); });
    `)
    restyle_tab(&tab, 400, 300)
    animation_step_tree(tab.layout, 0.75)
    testing.expect(t, animation_dispatch(tab.layout, tab.vm))
    n := dom.find_first(doc, "div")
    testing.expect_value(t, n.attrs["data-canceled"], "false")
    restyle_tab(&tab, 400, 300)
    index := make(map[^dom.Node]^Box, context.temp_allocator)
    animation_index(tab.layout, &index)
    testing.expect_value(t, index[n].animations[0].elapsed, f32(0.75))
    js_style_source_set(tab.styles, tab.layout, 400, 300)
    testing.expect_value(t, js_computed_style(n, "opacity"), "0.75")
    testing.expect_value(t, js_computed_style(n, "transform"), "matrix(1, 0, 0, 1, 0, 0)")
    animation_step_tree(tab.layout, 1.25)
    animation_dispatch(tab.layout, tab.vm)
    js.vm_run(tab.vm, "document.getElementById('x').setAttribute('data-events', events.join(','))")
    testing.expect_value(t, n.attrs["data-events"], "animationstart:Fade:0,animationend")
}

@(test)
animation_identity_transform_owns_channels :: proc(t: ^testing.T) {
    c := test_compute_anim(".x{animation:a 2s linear -1s paused}@keyframes a{from{transform:rotate(0deg) scale(1)}to{transform:rotate(0deg) scale(1)}}", "div", "x")
    ev := test_eval_anim(&c.anim, 0)
    testing.expect(t, ev.has_rot && ev.has_scale)
    testing.expect_value(t, ev.rot, f32(0))
    testing.expect_value(t, ev.sx, f32(1))
    testing.expect_value(t, ev.sy, f32(1))
}

@(test)
animation_zero_duration_and_iterations :: proc(t: ^testing.T) {
    c := test_compute_anim(".x{animation:Fade 0s linear both}"+ANIM_TEST_KF, "div", "x")
    testing.expect(t, c.anim.active)
    testing.expect_value(t, test_eval_anim(&c.anim, 0).op, f32(1))
    p := Animation_Player{anim=c.anim}; defer delete(p.pending)
    animation_step(&p, 0)
    testing.expect_value(t, len(p.pending), 2)
    testing.expect_value(t, p.pending[0].elapsed, f32(0))
    testing.expect_value(t, p.pending[1].kind, "animationend")
    z := test_compute_anim(".x{animation:Fade 2s linear 0 both}"+ANIM_TEST_KF, "div", "x")
    testing.expect_value(t, test_eval_anim(&z.anim, 1).op, f32(0))
    delayed := test_compute_anim(".x{animation:Fade 0s 2s linear both}"+ANIM_TEST_KF, "div", "x")
    testing.expect_value(t, test_eval_anim(&delayed.anim, 0).op, f32(0))
    testing.expect_value(t, test_eval_anim(&delayed.anim, 2).op, f32(1))
}
