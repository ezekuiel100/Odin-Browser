package js

// Performance Timeline + PerformanceObserver (M152).
//
// Entrou pela mesma porta do Intl: com o M150 fazendo identificador livre lançar
// ReferenceError, `PerformanceObserver is not defined` apareceu NOMEADO em 3
// sites (wikipedia, vercel, wired). Antes era undefined silencioso.
//
// ── A LINHA QUE NÃO ATRAVESSEI ───────────────────────────────────────────────
// A razão pela qual os sites usam PerformanceObserver é web-vitals: LCP, CLS,
// FID/INP, paint, resource, longtask. Nós NÃO MEDIMOS nada disso — não há hook
// de paint, não instrumentamos o carregamento de recurso, não há observação de
// layout shift. Seria fácil inventar entradas com números plausíveis e fazer o
// site "funcionar"; seria também o pior resultado possível, porque um painel de
// métricas passaria a receber dados FALSOS sem ninguém perceber.
//
// Então: `supportedEntryTypes` lista SÓ `mark` e `measure` — os dois que a
// página mesma produz e que portanto sabemos de verdade. Observar
// 'largest-contentful-paint' é aceito em silêncio e nunca entrega nada, que é
// exatamente o que a spec manda fazer com tipo não suportado (avisar e sair, sem
// lançar) e o que um browser sem aquela métrica faria. O site não quebra, e
// ninguém recebe número inventado.
//
// O ganho concreto não é a métrica — é que `performance.mark`/`measure` DEIXARAM
// DE SER NO-OP. Eram stubs que engoliam tudo e `getEntries*` devolvia array
// vazio; agora a timeline existe, então o padrão
// `mark('a'); …; measure('t','a'); getEntriesByName('t')[0].duration` responde.

// ── timeline (guardada NO objeto performance, não no Interp) ─────────────────
//
// `#entries` e `#observers` são props privadas do próprio `performance` (mesma
// convenção do "#t" da Date: não enumeram, não vazam no JSON.stringify). Evita
// campo novo no Interp e mantém a posse junto do objeto que já é dono deles.

@(private = "file")
perf_of :: proc(vm: ^Interp, this: Value) -> ^Object {
    if o, ok := this.(^Object); ok && o.props != nil {
        if _, has := o.props["#entries"]; has do return o
    }
    if o, ok := vm.native_bound.(^Object); ok {
        if _, has := o.props["#entries"]; has do return o
        // método de OBSERVER: o perf viaja junto
        if p, pok := o.props["#perf"].(^Object); pok do return p
    }
    return nil
}

@(private = "file")
arr_of :: proc(o: ^Object, key: string) -> ^Array {
    if a, ok := o.props[key].(^Array); ok do return a
    return nil
}

@(private = "file")
entry_str :: proc(e: Value, key: string) -> string {
    if o, ok := e.(^Object); ok {
        if s, sok := o.props[key].(string); sok do return s
    }
    return ""
}

@(private = "file")
mk_entry :: proc(vm: ^Interp, name, kind: string, start, dur: f64) -> ^Object {
    e := new_object(vm)
    e.props["name"]      = own_str(vm, name)
    e.props["entryType"] = own_str(vm, kind)
    e.props["startTime"] = start
    e.props["duration"]  = dur
    return e
}

// ── entrega assíncrona aos observers ────────────────────────────────────────
//
// A spec entrega numa TAREFA, não em linha — um observer não pode rodar no meio
// do mark que o originou. Usamos um timer de 0ms (mesmo canal do setTimeout),
// com o observer viajando em fn.bound.

@(private = "file")
notify_observers :: proc(vm: ^Interp, perf: ^Object, entry: ^Object) {
    obs_list := arr_of(perf, "#observers")
    if obs_list == nil do return
    kind := entry_str(entry, "entryType")
    for ov in obs_list.items {
        obs, ok := ov.(^Object); if !ok do continue
        if active, aok := obs.props["#active"].(bool); !aok || !active do continue
        types := arr_of(obs, "#types"); if types == nil do continue
        matches := false
        for tv in types.items {
            if s, sok := tv.(string); sok && s == kind { matches = true; break }
        }
        if !matches do continue
        q := arr_of(obs, "#queue"); if q == nil do continue
        append(&q.items, entry)
        schedule_delivery(vm, obs)
    }
}

@(private = "file")
schedule_delivery :: proc(vm: ^Interp, obs: ^Object) {
    // uma entrega pendente por observer: várias marks seguidas viram UM callback
    // com a lista inteira, como no browser.
    if pend, ok := obs.props["#pending"].(bool); ok && pend do return
    obs.props["#pending"] = true
    f := mk_native(vm, po_deliver)
    f.bound = obs
    vm.next_timer_id += 1
    append(&vm.timers, Timer{id = vm.next_timer_id, fn = f, due = vm.clock_ms})
}

// Lista passada ao callback: NÃO é um array (a spec dá um
// PerformanceObserverEntryList), e código real chama `list.getEntries()`.
@(private = "file")
mk_entry_list :: proc(vm: ^Interp, entries: ^Array) -> ^Object {
    l := new_object(vm)
    l.props["#snap"] = entries
    l.props["getEntries"]        = mk_bound_obj(vm, l, list_get_entries)
    l.props["getEntriesByType"]  = mk_bound_obj(vm, l, list_get_by_type)
    l.props["getEntriesByName"]  = mk_bound_obj(vm, l, list_get_by_name)
    for k in ([?]string{"getEntries", "getEntriesByType", "getEntriesByName"}) do mark_non_enumerable(l, k)
    return l
}

// (não file-private: o MutationObserver usa o mesmo padrão de método ligado)
mk_bound_obj :: proc(vm: ^Interp, o: ^Object, fn: Native_Fn) -> ^Function {
    f := mk_native(vm, fn)
    f.bound = o
    return f
}

@(private = "file")
list_snap :: proc(vm: ^Interp, this: Value) -> ^Array {
    if o, ok := this.(^Object); ok do if a, aok := o.props["#snap"].(^Array); aok do return a
    if o, ok := vm.native_bound.(^Object); ok do if a, aok := o.props["#snap"].(^Array); aok do return a
    return nil
}

@(private = "file")
list_get_entries :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    out := new_array(vm)
    if s := list_snap(vm, this); s != nil do for e in s.items do append(&out.items, e)
    return out
}

@(private = "file")
list_get_by_type :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    want := key_string(vm, arg(a, 0))
    out := new_array(vm)
    if s := list_snap(vm, this); s != nil {
        for e in s.items do if entry_str(e, "entryType") == want do append(&out.items, e)
    }
    return out
}

@(private = "file")
list_get_by_name :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    want := key_string(vm, arg(a, 0))
    out := new_array(vm)
    if s := list_snap(vm, this); s != nil {
        for e in s.items do if entry_str(e, "name") == want do append(&out.items, e)
    }
    return out
}

@(private = "file")
po_deliver :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    obs, ok := vm.native_bound.(^Object); if !ok do return nil
    obs.props["#pending"] = false
    q := arr_of(obs, "#queue"); if q == nil || len(q.items) == 0 do return nil
    snap := new_array(vm)
    for e in q.items do append(&snap.items, e)
    clear(&q.items)
    cb, cok := obs.props["#cb"].(^Function); if !cok do return nil
    call_function(vm, cb, obs, []Value{mk_entry_list(vm, snap), obs})
    return nil
}

// ── PerformanceObserver ─────────────────────────────────────────────────────

@(private = "file")
po_observe :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    obs, ok := vm.native_bound.(^Object)
    if !ok do if o, ook := this.(^Object); ook do obs = o
    if obs == nil do return nil
    perf, pok := obs.props["#perf"].(^Object); if !pok do return nil

    types := arr_of(obs, "#types"); if types == nil do return nil
    clear(&types.items)
    supported := arr_of(perf, "#supported")

    is_supported :: proc(supported: ^Array, s: string) -> bool {
        if supported == nil do return false
        for v in supported.items do if sv, ok := v.(string); ok && sv == s do return true
        return false
    }

    opts, _ := arg(a, 0).(^Object)
    if opts != nil {
        if et, eok := opts.props["entryTypes"].(^Array); eok {
            for v in et.items {
                s := key_string(vm, v)
                if is_supported(supported, s) do append(&types.items, own_str(vm, s))
            }
        } else if t, tok := opts.props["type"].(string); tok {
            if is_supported(supported, t) do append(&types.items, own_str(vm, t))
        }
    }
    // ⚠️ Tipo NÃO suportado (LCP/CLS/paint/resource — a razão real pela qual os
    // sites usam esta API) sai em SILÊNCIO, sem lançar. É o que a spec manda
    // fazer e o que um browser sem aquela métrica faz. O site segue vivo e
    // ninguém recebe número inventado. Ver o cabeçalho do arquivo.
    if len(types.items) == 0 do return nil

    obs.props["#active"] = true
    obs_list := arr_of(perf, "#observers")
    if obs_list != nil {
        already := false
        for v in obs_list.items do if o, ook := v.(^Object); ook && o == obs { already = true; break }
        if !already do append(&obs_list.items, obs)
    }

    // buffered:true → entrega o que JÁ estava na timeline
    if opts != nil && truthy(opts.props["buffered"]) {
        if q, qok := obs.props["#queue"].(^Array); qok {
            if all := arr_of(perf, "#entries"); all != nil {
                for e in all.items {
                    kind := entry_str(e, "entryType")
                    for tv in types.items {
                        if s, sok := tv.(string); sok && s == kind { append(&q.items, e); break }
                    }
                }
            }
            if len(q.items) > 0 do schedule_delivery(vm, obs)
        }
    }
    return nil
}

@(private = "file")
po_disconnect :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    obs, ok := vm.native_bound.(^Object)
    if !ok do if o, ook := this.(^Object); ook do obs = o
    if obs == nil do return nil
    obs.props["#active"] = false
    if q := arr_of(obs, "#queue"); q != nil do clear(&q.items)
    if perf, pok := obs.props["#perf"].(^Object); pok {
        if l := arr_of(perf, "#observers"); l != nil {
            for v, i in l.items {
                if o, ook := v.(^Object); ook && o == obs { ordered_remove(&l.items, i); break }
            }
        }
    }
    return nil
}

@(private = "file")
po_take_records :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    obs, ok := vm.native_bound.(^Object)
    if !ok do if o, ook := this.(^Object); ook do obs = o
    out := new_array(vm)
    if obs == nil do return out
    if q := arr_of(obs, "#queue"); q != nil {
        for e in q.items do append(&out.items, e)
        clear(&q.items)
    }
    return out
}

@(private = "file")
po_ctor :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    // o `bound` do CONSTRUTOR carrega {perf, prototype} — ver install_performance
    holder, hok := vm.native_bound.(^Object)
    obs := new_object(vm)
    if hok {
        if p, pok := holder.props["#perf"].(^Object); pok do obs.props["#perf"] = p
        if pr, prok := holder.props["#proto"].(^Object); prok do obs.proto = pr
    }
    if cb, cok := arg(a, 0).(^Function); cok {
        obs.props["#cb"] = cb
    } else {
        throw_type_error(vm, "PerformanceObserver constructor: callback must be a function")
        return nil
    }
    obs.props["#types"]   = new_array(vm)
    obs.props["#queue"]   = new_array(vm)
    obs.props["#active"]  = false
    obs.props["#pending"] = false
    obs.props["observe"]      = mk_bound_obj(vm, obs, po_observe)
    obs.props["disconnect"]   = mk_bound_obj(vm, obs, po_disconnect)
    obs.props["takeRecords"]  = mk_bound_obj(vm, obs, po_take_records)
    for k in ([?]string{"observe", "disconnect", "takeRecords"}) do mark_non_enumerable(obs, k)
    return obs
}

// ── performance.mark / measure / getEntries* ────────────────────────────────

@(private = "file")
perf_mark :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    perf := perf_of(vm, this); if perf == nil do return nil
    name := key_string(vm, arg(a, 0))
    start := vm.clock_ms
    if opts, ok := arg(a, 1).(^Object); ok {
        if v, has := opts.props["startTime"]; has do start = to_number(vm, v)
    }
    e := mk_entry(vm, name, "mark", start, 0)
    if opts, ok := arg(a, 1).(^Object); ok {
        if d, has := opts.props["detail"]; has do e.props["detail"] = d
    }
    if all := arr_of(perf, "#entries"); all != nil do append(&all.items, e)
    notify_observers(vm, perf, e)
    return e // a spec devolve a PerformanceMark criada
}

// Acha o startTime de uma mark pelo nome (a MAIS RECENTE, como a spec).
@(private = "file")
mark_time :: proc(perf: ^Object, name: string) -> (f64, bool) {
    all := arr_of(perf, "#entries"); if all == nil do return 0, false
    #reverse for v in all.items {
        if o, ok := v.(^Object); ok {
            if entry_str(v, "name") == name {
                if t, tok := o.props["startTime"].(f64); tok do return t, true
            }
        }
    }
    return 0, false
}

@(private = "file")
perf_measure :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    perf := perf_of(vm, this); if perf == nil do return nil
    name := key_string(vm, arg(a, 0))
    start, end := f64(0), vm.clock_ms

    // 2ª forma: measure(name, {start, end, duration}) — ES2019+
    if opts, ok := arg(a, 1).(^Object); ok {
        got_start, got_end := false, false
        if v, has := opts.props["start"]; has {
            if s, sok := v.(string); sok {
                if t, tok := mark_time(perf, s); tok { start = t; got_start = true }
            } else { start = to_number(vm, v); got_start = true }
        }
        if v, has := opts.props["end"]; has {
            if s, sok := v.(string); sok {
                if t, tok := mark_time(perf, s); tok { end = t; got_end = true }
            } else { end = to_number(vm, v); got_end = true }
        }
        if v, has := opts.props["duration"]; has {
            d := to_number(vm, v)
            if got_start && !got_end do end = start + d
            else if got_end && !got_start do start = end - d
        }
    } else {
        // forma clássica: measure(name, startMark, endMark)
        if s, ok := arg(a, 1).(string); ok {
            if t, tok := mark_time(perf, s); tok do start = t
        }
        if s, ok := arg(a, 2).(string); ok {
            if t, tok := mark_time(perf, s); tok do end = t
        }
    }

    e := mk_entry(vm, name, "measure", start, end - start)
    if all := arr_of(perf, "#entries"); all != nil do append(&all.items, e)
    notify_observers(vm, perf, e)
    return e
}

@(private = "file")
perf_get_entries :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    out := new_array(vm)
    if perf := perf_of(vm, this); perf != nil {
        if all := arr_of(perf, "#entries"); all != nil do for e in all.items do append(&out.items, e)
    }
    return out
}

@(private = "file")
perf_get_by_type :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    want := key_string(vm, arg(a, 0))
    out := new_array(vm)
    if perf := perf_of(vm, this); perf != nil {
        if all := arr_of(perf, "#entries"); all != nil {
            for e in all.items do if entry_str(e, "entryType") == want do append(&out.items, e)
        }
    }
    return out
}

@(private = "file")
perf_get_by_name :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    want := key_string(vm, arg(a, 0))
    kind := arg(a, 1) != nil ? key_string(vm, arg(a, 1)) : ""
    out := new_array(vm)
    if perf := perf_of(vm, this); perf != nil {
        if all := arr_of(perf, "#entries"); all != nil {
            for e in all.items {
                if entry_str(e, "name") != want do continue
                if kind != "" && entry_str(e, "entryType") != kind do continue
                append(&out.items, e)
            }
        }
    }
    return out
}

// clearMarks()/clearMeasures() sem argumento limpam TODAS as do tipo; com nome,
// só as daquele nome.
@(private = "file")
perf_clear :: proc(vm: ^Interp, this: Value, a: []Value, kind: string) -> Value {
    perf := perf_of(vm, this); if perf == nil do return nil
    all := arr_of(perf, "#entries"); if all == nil do return nil
    name := arg(a, 0) != nil ? key_string(vm, arg(a, 0)) : ""
    keep := make([dynamic]Value, 0, len(all.items))
    for e in all.items {
        drop := entry_str(e, "entryType") == kind && (name == "" || entry_str(e, "name") == name)
        if !drop do append(&keep, e)
    }
    clear(&all.items)
    for e in keep do append(&all.items, e)
    delete(keep)
    return nil
}

@(private = "file")
perf_clear_marks :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    return perf_clear(vm, this, a, "mark")
}

@(private = "file")
perf_clear_measures :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    return perf_clear(vm, this, a, "measure")
}

// ── instalação ──────────────────────────────────────────────────────────────

// Chamado por install_dom depois que o objeto `performance` existe. Substitui os
// stubs no-op de mark/measure/getEntries* por implementações reais e instala
// PerformanceObserver + as interfaces de entrada.
install_performance :: proc(vm: ^Interp, perf: ^Object) {
    perf.props["#entries"]   = new_array(vm)
    perf.props["#observers"] = new_array(vm)

    // ⚠️ SÓ o que a página mesma produz. Não listamos paint/resource/
    // largest-contentful-paint/layout-shift porque NÃO MEDIMOS nada disso —
    // anunciar suporte faria um painel de métricas receber dado falso.
    sup := new_array(vm)
    append(&sup.items, own_str(vm, "mark"))
    append(&sup.items, own_str(vm, "measure"))
    perf.props["#supported"] = sup

    perf.props["mark"]             = mk_bound_obj(vm, perf, perf_mark)
    perf.props["measure"]          = mk_bound_obj(vm, perf, perf_measure)
    perf.props["clearMarks"]       = mk_bound_obj(vm, perf, perf_clear_marks)
    perf.props["clearMeasures"]    = mk_bound_obj(vm, perf, perf_clear_measures)
    perf.props["getEntries"]       = mk_bound_obj(vm, perf, perf_get_entries)
    perf.props["getEntriesByType"] = mk_bound_obj(vm, perf, perf_get_by_type)
    perf.props["getEntriesByName"] = mk_bound_obj(vm, perf, perf_get_by_name)

    ctor := mk_native(vm, po_ctor)
    ctor.name = "PerformanceObserver"
    ctor.props = make(map[string]Value)
    proto := new_object(vm)
    proto.proto = vm.object_proto
    proto.props["constructor"] = ctor
    mark_non_enumerable(proto, "constructor")
    ctor.props["prototype"] = proto
    // `PerformanceObserver.supportedEntryTypes` é o feature-detect canônico do
    // web-vitals: a lib pergunta ANTES de observar. Responder a verdade aqui é o
    // que faz ela pular as métricas que não temos em vez de tentar e falhar.
    ctor.props["supportedEntryTypes"] = sup

    holder := new_object(vm) // bound do construtor: leva perf + prototype
    holder.props["#perf"]  = perf
    holder.props["#proto"] = proto
    ctor.bound = holder
    env_define(vm.global, "PerformanceObserver", ctor)

    // cascas das interfaces de entrada (instanceof / polyfill que escreve no
    // .prototype) — mesmo motivo das órfãs do M150.
    for name in ([?]string{"PerformanceEntry", "PerformanceMark", "PerformanceMeasure",
                           "PerformanceObserverEntryList", "PerformanceResourceTiming",
                           "PerformanceNavigationTiming", "PerformancePaintTiming"}) {
        f := mk_native(vm, perf_iface_ctor)
        f.name = name
        f.props = make(map[string]Value)
        p := new_object(vm)
        p.proto = vm.object_proto
        p.props["constructor"] = f
        mark_non_enumerable(p, "constructor")
        f.props["prototype"] = p
        env_define(vm.global, name, f)
    }
}

@(private = "file")
perf_iface_ctor :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    // Estas interfaces NÃO são construíveis pela página (a spec marca todas como
    // [Exposed] sem constructor útil); existem p/ instanceof e feature-detect.
    throw_type_error(vm, "Illegal constructor")
    return nil
}
