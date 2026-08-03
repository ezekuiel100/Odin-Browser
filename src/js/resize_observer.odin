package js

// ── ResizeObserver REAL (M232) ──────────────────────────────────────────────
//
// O ÚLTIMO dos três observers que eram `observer_ctor`: observe/disconnect no-op
// e callback que nunca disparava. Mesmo mal dos irmãos — stub de valor neutro,
// que não lança e deixa a página errada em silêncio.
//
// É o irmão do [[intersection-observer]] em quase tudo: mesma AMOSTRAGEM por
// frame (não há evento de "o elemento mudou de tamanho"), mesma entrega dentro
// do passo com a pilha de JS vazia, mesmo funil `vm_frame_step`, e o estado mora
// no próprio objeto JS. As duas diferenças que importam:
//
//   1. **O que se compara é TAMANHO, não interseção** — e o gatilho é "difere do
//      último ENTREGUE", sem limiares.
//   2. **O tamanho inicial de referência é (0,0)** (spec). É isso que faz o alvo
//      visível receber uma entry logo no 1º passo (é o que a página espera de
//      `observe()`) e o alvo `display:none` (0×0) NÃO receber nada — o mesmo
//      "não é renderizado ⇒ pula" do navegador, de graça.
//
// A geometria vem do hook `g_element_box` (ui: `js_element_box`), a mesma fonte
// do getBoundingClientRect e do getComputedStyle. Ele devolve as DUAS caixas numa
// chamada só porque cada entry precisa das duas.

import dom "../dom"

@(private = "file") RO_CB      :: "#cb"
@(private = "file") RO_TARGETS :: "#targets"
@(private = "file") RO_QUEUE   :: "#queue"

// ── construtor e métodos ────────────────────────────────────────────────────

ro_ctor :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    cb, cok := arg(a, 0).(^Function)
    if !cok {
        throw_type_error(vm, "ResizeObserver constructor: callback must be a function")
        return nil
    }
    o := new_object(vm)
    o.props[RO_CB]      = cb
    o.props[RO_TARGETS] = new_array(vm)
    o.props[RO_QUEUE]   = new_array(vm)
    o.props["observe"]     = mk_bound_obj(vm, o, ro_observe)
    o.props["unobserve"]   = mk_bound_obj(vm, o, ro_unobserve)
    o.props["disconnect"]  = mk_bound_obj(vm, o, ro_disconnect)
    for k in ([?]string{RO_CB, RO_TARGETS, RO_QUEUE, "observe", "unobserve", "disconnect"}) {
        mark_non_enumerable(o, k)
    }
    return o
}

@(private = "file")
ro_self :: proc(vm: ^Interp, this: Value) -> ^Object {
    if o, ok := vm.native_bound.(^Object); ok && o.props[RO_TARGETS] != nil do return o
    if o, ok := this.(^Object); ok do return o
    return nil
}

@(private = "file")
ro_observe :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    obs := ro_self(vm, this)
    if obs == nil do return nil
    target, tok := arg(a, 0).(^Object)
    if !tok || target.host == nil {
        throw_type_error(vm, "ResizeObserver.observe: target must be an Element")
        return nil
    }
    targets, ok := obs.props[RO_TARGETS].(^Array)
    if !ok do return nil
    // `box` da spec: aceitamos e guardamos, mas medimos as DUAS caixas em toda
    // entry de qualquer jeito (é o que o navegador entrega). A opção só decidiria
    // QUAL delas dispara a notificação — ver degradação (b).
    for it in targets.items {
        if r, rok := it.(^Object); rok {
            if t, tk := r.props["n"].(^Object); tk && t.host == target.host {
                return nil // observar o mesmo alvo de novo: no-op
            }
        }
    }
    rec := new_object(vm)
    rec.props["n"] = target
    // Tamanho de referência inicial (0,0): alvo com caixa recebe entry no 1º
    // passo; alvo sem caixa (display:none) não recebe nada, como na spec.
    rec.props["w"] = f64(0)
    rec.props["h"] = f64(0)
    append(&targets.items, rec)
    vm.ro_observe_calls += 1 // uso real da API; sai no --diagnose
    ro_track(vm, obs)
    return nil
}

@(private = "file")
ro_unobserve :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    obs := ro_self(vm, this)
    if obs == nil do return nil
    target, tok := arg(a, 0).(^Object)
    if !tok || target.host == nil do return nil
    targets, ok := obs.props[RO_TARGETS].(^Array)
    if !ok do return nil
    for it, i in targets.items {
        r, rok := it.(^Object)
        if !rok do continue
        if t, tk := r.props["n"].(^Object); tk && t.host == target.host {
            ordered_remove(&targets.items, i)
            break
        }
    }
    if len(targets.items) == 0 do ro_untrack(vm, obs)
    return nil
}

@(private = "file")
ro_disconnect :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    obs := ro_self(vm, this)
    if obs == nil do return nil
    if t, ok := obs.props[RO_TARGETS].(^Array); ok do clear(&t.items)
    if q, ok := obs.props[RO_QUEUE].(^Array);   ok do clear(&q.items)
    ro_untrack(vm, obs)
    return nil
}

@(private = "file")
ro_track :: proc(vm: ^Interp, obs: ^Object) {
    for o in vm.size_observers do if o == obs do return
    append(&vm.size_observers, obs)
}

@(private = "file")
ro_untrack :: proc(vm: ^Interp, obs: ^Object) {
    for o, i in vm.size_observers {
        if o == obs {
            ordered_remove(&vm.size_observers, i)
            return
        }
    }
}

// ── o passo por frame ───────────────────────────────────────────────────────

ro_active :: proc(vm: ^Interp) -> bool {
    return vm != nil && len(vm.size_observers) > 0
}

// Uma rodada de "broadcast active observations". Devolve true se algum callback
// rodou (o hospedeiro re-estiliza antes de pintar, como faz com os timers).
ro_step :: proc(vm: ^Interp) -> bool {
    if !ro_active(vm) || vm.ro_stepping do return false
    vm.ro_stepping = true
    defer vm.ro_stepping = false

    delivered := false
    snap: [dynamic]^Object
    defer delete(snap)
    for o in vm.size_observers do append(&snap, o)

    for obs in snap {
        targets, tok := obs.props[RO_TARGETS].(^Array)
        if !tok || len(targets.items) == 0 do continue
        q, qok := obs.props[RO_QUEUE].(^Array)
        if !qok do continue

        for it in targets.items {
            rec, rk := it.(^Object)
            if !rk do continue
            tobj, ok2 := rec.props["n"].(^Object)
            if !ok2 || tobj.host == nil do continue

            cw, ch, bw, bh, px, py: f32
            if g_element_box != nil {
                c1, c2, b1, b2, p1, p2, ok3 := g_element_box(cast(^dom.Node) tobj.host)
                if ok3 { cw, ch, bw, bh, px, py = c1, c2, b1, b2, p1, p2 }
            }
            // O gatilho é a caixa de CONTEÚDO (o default da spec). Igual ⇒ nada:
            // o passo roda todo frame e não pode virar um setInterval.
            if f64(cw) == as_number(rec.props["w"]) && f64(ch) == as_number(rec.props["h"]) do continue
            rec.props["w"] = f64(cw)
            rec.props["h"] = f64(ch)

            e := new_object(vm)
            e.props["target"]      = tobj
            e.props["contentRect"] = make_dom_rect(vm, px, py, cw, ch)
            // As listas de tamanho da spec (arrays de 1 item: só há fragmento
            // múltiplo em multicol, que não fragmentamos).
            e.props["contentBoxSize"]           = ro_size_list(vm, cw, ch)
            e.props["borderBoxSize"]            = ro_size_list(vm, bw, bh)
            e.props["devicePixelContentBoxSize"] = ro_size_list(vm, cw, ch) // DPR = 1
            append(&q.items, e)
        }

        if len(q.items) == 0 do continue
        entries := new_array(vm)
        for e in q.items do append(&entries.items, e)
        clear(&q.items)
        vm.ro_entries_sent += len(entries.items)
        delivered = true

        cb, cok := obs.props[RO_CB].(^Function)
        if !cok do continue
        vm.steps = 0
        vm.call_depth = 0
        reset_task_clock(vm)
        mo_task_enter(vm)
        call_function(vm, cb, obs, []Value{entries, obs})
        vm_clear_uncaught(vm)
        mo_task_exit(vm)
    }
    return delivered
}

// [{inlineSize, blockSize}] — inline = eixo horizontal (modo de escrita
// horizontal, o único que layoutamos de verdade; ver degradação (c)).
@(private = "file")
ro_size_list :: proc(vm: ^Interp, w, h: f32) -> ^Array {
    s := new_object(vm)
    s.props["inlineSize"] = f64(w)
    s.props["blockSize"]  = f64(h)
    a := new_array(vm)
    append(&a.items, s)
    return a
}

// vm_destroy: só a lista (os objetos são rastreados pelo vm).
ro_free :: proc(vm: ^Interp) {
    delete(vm.size_observers)
    vm.size_observers = nil
}
