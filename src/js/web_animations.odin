package js

// Web Animations: `element.animate(keyframes, options)` → Animation.
//
// Entrou pelo github.com: o fade-in das imagens da home faz
// `o.animate([{opacity:0},{opacity:1}],{duration:200,fill:"backwards"})` e chama
// pause/play/cancel. Sem `animate`, cada render lançava TypeError, os error
// boundaries do React remontavam a subárvore, e a remontagem em laço estourava
// o React error #185 ("Maximum update depth") — a home ficava em branco.
//
// ⚠️ DEGRADAÇÃO HONESTA: não interpolamos quadro a quadro (as transições/
// animações CSS do motor vivem na camada de layout, longe do JS). Uma animação
// em `running` TERMINA no próximo microtask, salvo se for pausada/cancelada
// antes — o que reproduz o ESTADO FINAL, que é o que uma página estática mostra:
//   • fill none/backwards: no fim o efeito some (estilo do elemento volta);
//   • fill forwards/both: o último keyframe (o primeiro, se reverse) vai para
//     o estilo inline — o equivalente visual do efeito retido.
// `finished` resolve com a própria Animation; `cancel()` rejeita o `finished`
// com AbortError e troca por uma nova (como a spec, sem log de rejeição).
// `getAnimations()` devolve [] (não rastreamos as ativas).

@(private = "file")
anim_of :: proc(vm: ^Interp) -> ^Object {
    o, _ := vm.native_bound.(^Object)
    return o
}

@(private = "file")
anim_method :: proc(vm: ^Interp, anim: ^Object, name: string, fn: Native_Fn) {
    f := mk_native(vm, fn)
    f.bound = anim
    anim.props[name] = f
    mark_non_enumerable(anim, name)
}

@(private = "file")
anim_set_state :: proc(vm: ^Interp, anim: ^Object, st: string) {
    anim.props["playState"] = own_str(vm, st)
}

@(private = "file")
anim_state :: proc(anim: ^Object) -> string {
    s, _ := anim.props["playState"].(string)
    return s
}

// Agenda o término para o próximo microtask. A "geração" invalida agendamentos
// antigos: pause/cancel/play entre o agendamento e o microtask não terminam.
@(private = "file")
anim_schedule :: proc(vm: ^Interp, anim: ^Object) {
    g := as_number(anim.props["#gen"]) + 1
    anim.props["#gen"] = g
    holder := new_object(vm)
    holder.props["a"] = anim
    holder.props["g"] = g
    f := mk_native(vm, anim_tick)
    f.bound = holder
    append(&vm.reaction_queue, Reaction_Job{microtask = f})
}

@(private = "file")
anim_tick :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    holder, _ := vm.native_bound.(^Object)
    if holder == nil do return nil
    anim, _ := holder.props["a"].(^Object)
    if anim == nil do return nil
    if as_number(anim.props["#gen"]) != as_number(holder.props["g"]) do return nil
    if anim_state(anim) != "running" do return nil
    anim_do_finish(vm, anim)
    return nil
}

// Último keyframe (ou o primeiro, se `reverse`) aplicado ao estilo inline.
@(private = "file")
anim_apply_end :: proc(vm: ^Interp, anim: ^Object) {
    el := anim.props["#el"]
    style, ok := get_member(vm, el, "style").(^Object)
    if !ok do return
    first := truthy(anim.props["#reversed"])
    put :: proc(vm: ^Interp, style: ^Object, k: string, v: Value) {
        if k == "offset" || k == "easing" || k == "composite" do return
        set_member(vm, style, k, v)
    }
    #partial switch kf in anim.props["#kf"] {
    case ^Array:
        if len(kf.items) == 0 do return
        frame, fok := kf.items[first ? 0 : len(kf.items) - 1].(^Object)
        if !fok do return
        ks := make([dynamic]string, context.temp_allocator)
        own_enum_keys(frame, &ks)
        for k in ks do put(vm, style, k, frame.props[k])
    case ^Object:
        ks := make([dynamic]string, context.temp_allocator)
        own_enum_keys(kf, &ks)
        for k in ks {
            v := kf.props[k]
            if arr, aok := v.(^Array); aok {
                if len(arr.items) == 0 do continue
                v = arr.items[first ? 0 : len(arr.items) - 1]
            }
            put(vm, style, k, v)
        }
    }
}

@(private = "file")
anim_do_finish :: proc(vm: ^Interp, anim: ^Object) {
    anim_set_state(vm, anim, "finished")
    anim.props["currentTime"] = anim.props["#end"]
    fill, _ := anim.props["#fill"].(string)
    if fill == "forwards" || fill == "both" do anim_apply_end(vm, anim)
    if p, ok := anim.props["finished"].(^Object); ok do promise_resolve_with(vm, p, anim)
    anim_fire(vm, anim, "finish")
}

@(private = "file")
anim_fire :: proc(vm: ^Interp, anim: ^Object, type: string) {
    ev := new_object(vm)
    oput(ev, "type", own_str(vm, type))
    oput(ev, "currentTime", anim.props["currentTime"])
    oput(ev, "timelineTime", JS_Null{})
    oput(ev, "target", anim)
    if h, ok := anim.props[strings_concat_on(type)].(^Function); ok {
        call_function(vm, h, anim, {ev})
        vm_clear_uncaught(vm)
    }
    if ls, ok := anim.props["#listeners"].(^Array); ok {
        for it in ls.items {
            pair, pok := it.(^Array)
            if !pok || len(pair.items) < 2 do continue
            t, _ := pair.items[0].(string)
            if t != type do continue
            if fn, fok := pair.items[1].(^Function); fok {
                call_function(vm, fn, anim, {ev})
                vm_clear_uncaught(vm)
            }
        }
    }
}

@(private = "file")
strings_concat_on :: proc(type: string) -> string {
    switch type {
    case "finish": return "onfinish"
    case "cancel": return "oncancel"
    case "remove": return "onremove"
    }
    return ""
}

@(private = "file")
anim_play :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    anim := anim_of(vm); if anim == nil do return nil
    st := anim_state(anim)
    if st == "running" do return nil
    if st == "finished" || st == "idle" {
        // nova rodada: `finished` novo (o antigo já assentou)
        anim.props["finished"] = promise_new(vm)
        anim.props["currentTime"] = f64(0)
    }
    anim_set_state(vm, anim, "running")
    anim_schedule(vm, anim)
    return nil
}

@(private = "file")
anim_pause :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    anim := anim_of(vm); if anim == nil do return nil
    if anim_state(anim) == "finished" do return nil
    anim.props["#gen"] = as_number(anim.props["#gen"]) + 1
    anim_set_state(vm, anim, "paused")
    return nil
}

@(private = "file")
anim_cancel :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    anim := anim_of(vm); if anim == nil do return nil
    if anim_state(anim) == "idle" do return nil
    anim.props["#gen"] = as_number(anim.props["#gen"]) + 1
    if p, ok := anim.props["finished"].(^Object); ok && as_number(p.props["_state"]) == PROMISE_PENDING {
        promise_settle(vm, p, PROMISE_REJECTED, mk_error(vm, "AbortError", "The user aborted a request."))
    }
    anim.props["finished"] = promise_new(vm)
    anim.props["currentTime"] = JS_Null{}
    anim_set_state(vm, anim, "idle")
    anim_fire(vm, anim, "cancel")
    return nil
}

@(private = "file")
anim_finish :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    anim := anim_of(vm); if anim == nil do return nil
    if anim_state(anim) == "finished" do return nil
    anim.props["#gen"] = as_number(anim.props["#gen"]) + 1
    anim_do_finish(vm, anim)
    return nil
}

@(private = "file")
anim_reverse :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    anim := anim_of(vm); if anim == nil do return nil
    anim.props["#reversed"] = !truthy(anim.props["#reversed"])
    anim.props["playbackRate"] = -as_number(anim.props["playbackRate"])
    return anim_play(vm, this, a)
}

@(private = "file")
anim_update_rate :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    anim := anim_of(vm); if anim == nil do return nil
    if r, ok := arg(a, 0).(f64); ok do anim.props["playbackRate"] = r
    return nil
}

@(private = "file")
anim_commit_styles :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    anim := anim_of(vm); if anim == nil do return nil
    if anim_state(anim) == "finished" do anim_apply_end(vm, anim)
    return nil
}

@(private = "file")
anim_noop :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return nil }

@(private = "file")
anim_add_listener :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    anim := anim_of(vm); if anim == nil do return nil
    t, tok := arg(a, 0).(string)
    fn, fok := arg(a, 1).(^Function)
    if !tok || !fok do return nil
    ls, ok := anim.props["#listeners"].(^Array)
    if !ok { ls = new_array(vm); anim.props["#listeners"] = ls }
    pair := new_array(vm)
    append(&pair.items, own_str(vm, t), fn)
    append(&ls.items, pair)
    return nil
}

@(private = "file")
anim_remove_listener :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    anim := anim_of(vm); if anim == nil do return nil
    t, _ := arg(a, 0).(string)
    fn, _ := arg(a, 1).(^Function)
    ls, ok := anim.props["#listeners"].(^Array)
    if !ok do return nil
    for i := len(ls.items) - 1; i >= 0; i -= 1 {
        pair, pok := ls.items[i].(^Array)
        if !pok || len(pair.items) < 2 do continue
        pt, _ := pair.items[0].(string)
        pf, _ := pair.items[1].(^Function)
        if pt == t && pf == fn { ordered_remove(&ls.items, i); break }
    }
    return nil
}

@(private = "file")
effect_get_keyframes :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    anim := anim_of(vm)
    if anim != nil do if kf, ok := anim.props["#kf"].(^Array); ok do return kf
    return new_array(vm)
}

@(private = "file")
effect_get_timing :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    anim := anim_of(vm)
    o := new_object(vm)
    if anim != nil {
        oput(o, "duration", anim.props["#dur"])
        oput(o, "delay", anim.props["#delay"])
        oput(o, "fill", anim.props["#fill"])
        oput(o, "iterations", anim.props["#iter"])
    }
    return o
}

// Element.prototype.animate(keyframes, options)
native_element_animate :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    anim := new_object(vm)
    anim.props["#class"] = "Animation"
    anim.props["#el"] = this
    anim.props["#kf"] = arg(a, 0)
    dur, delay, iter := 0.0, 0.0, 1.0
    fill := "auto"
    id := ""
    #partial switch o in arg(a, 1) {
    case f64:
        dur = o
    case ^Object:
        if d, ok := get_member(vm, o, "duration").(f64); ok do dur = d
        if d, ok := get_member(vm, o, "delay").(f64); ok do delay = d
        if d, ok := get_member(vm, o, "iterations").(f64); ok do iter = d
        if f, ok := get_member(vm, o, "fill").(string); ok do fill = f
        if s, ok := get_member(vm, o, "id").(string); ok do id = s
    }
    anim.props["#dur"] = dur
    anim.props["#delay"] = delay
    anim.props["#iter"] = iter
    anim.props["#fill"] = own_str(vm, fill)
    anim.props["#end"] = delay + dur * iter
    anim.props["#gen"] = f64(0)
    anim.props["id"] = own_str(vm, id)
    anim.props["playState"] = own_str(vm, "running")
    anim.props["pending"] = false
    anim.props["playbackRate"] = f64(1)
    anim.props["currentTime"] = f64(0)
    anim.props["startTime"] = JS_Null{}
    anim.props["timeline"] = JS_Null{}
    anim.props["onfinish"] = JS_Null{}
    anim.props["oncancel"] = JS_Null{}
    anim.props["onremove"] = JS_Null{}
    anim.props["replaceState"] = own_str(vm, "active")
    anim.props["finished"] = promise_new(vm)
    ready := promise_new(vm)
    promise_resolve_with(vm, ready, anim)
    anim.props["ready"] = ready
    effect := new_object(vm)
    effect.props["target"] = this
    eg := mk_native(vm, effect_get_keyframes); eg.bound = anim; effect.props["getKeyframes"] = eg
    et := mk_native(vm, effect_get_timing); et.bound = anim; effect.props["getTiming"] = et
    effect.props["getComputedTiming"] = et
    anim.props["effect"] = effect
    anim_method(vm, anim, "play", anim_play)
    anim_method(vm, anim, "pause", anim_pause)
    anim_method(vm, anim, "cancel", anim_cancel)
    anim_method(vm, anim, "finish", anim_finish)
    anim_method(vm, anim, "reverse", anim_reverse)
    anim_method(vm, anim, "updatePlaybackRate", anim_update_rate)
    anim_method(vm, anim, "commitStyles", anim_commit_styles)
    anim_method(vm, anim, "persist", anim_noop)
    anim_method(vm, anim, "addEventListener", anim_add_listener)
    anim_method(vm, anim, "removeEventListener", anim_remove_listener)
    anim_schedule(vm, anim)
    return anim
}

// Element.prototype.getAnimations() / document.getAnimations(): não rastreamos.
native_get_animations :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    return new_array(vm)
}
