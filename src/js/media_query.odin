package js

// ── window.matchMedia REAL (M232) ───────────────────────────────────────────
//
// Antes: `MediaQueryList` com `matches` FIXO em false. É o mesmo mal do resto do
// Tier 1 — valor neutro que não lança e leva a página à decisão errada em
// silêncio. Aqui o custo é específico e grande: `matchMedia` é COMO o JS de site
// pergunta "sou mobile?", "o usuário quer menos animação?", "o tema é escuro?".
// Com false fixo, todo ramo responsivo do JS caía no lado errado (e ainda por
// cima no lado "não" de perguntas cujo "não" é o default do desktop, o que faz o
// defeito passar despercebido em algumas páginas e explodir em outras).
//
// A avaliação NÃO é reimplementada aqui: vai pelo hook `g_media_match` para o
// mesmo `parse_media_query` + `media_eval` que a folha de estilo usa no `@media`
// (src/css/css.odin). Se o CSS e o JS da mesma página discordassem sobre a mesma
// query, o site quebraria de um jeito impossível de diagnosticar.
//
// ── `matches` é VIVO ────────────────────────────────────────────────────────
// A página guarda o MQL e o consulta muito depois (`if (mql.matches)` dentro de
// um handler). Como a janela pode ter mudado de tamanho no meio, `matches` é
// servido por um GET-HOOK que re-avalia na hora, em vez de ser um valor gravado
// na criação. Mesmo espírito do `window.innerWidth`.

// Hook de avaliação (o ui instala; ver a razão de ciclo em dom_bindings.odin).
// nil => sem motor de CSS (odin test src/js sem fake) => matches false.
Media_Match_Fn :: proc(query: string) -> bool
g_media_match: Media_Match_Fn

@(private = "file") MQ_QUERY :: "#q"
@(private = "file") MQ_LAST  :: "#last" // último valor ENTREGUE (p/ detectar a virada)
@(private = "file") MQ_LIST  :: "#lst"  // ouvintes de 'change'

// window.matchMedia(query) → MediaQueryList
native_match_media :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    q := ""
    if s, ok := arg(args, 0).(string); ok do q = s
    mql := new_object(vm)
    mql.props[MQ_QUERY] = own_str(vm, q)
    mql.props["media"]  = own_str(vm, q) // degradação: devolvemos a query COMO VEIO
                                         // (o navegador serializa normalizada)
    mql.props["onchange"] = JS_Null{}
    mql.props["addListener"]         = mk_bound_obj(vm, mql, mq_add_listener) // API legada (Safari<14)
    mql.props["removeListener"]      = mk_bound_obj(vm, mql, mq_remove_listener)
    mql.props["addEventListener"]    = mk_bound_obj(vm, mql, mq_add_listener)
    mql.props["removeEventListener"] = mk_bound_obj(vm, mql, mq_remove_listener)
    mql.props["dispatchEvent"]       = mk_bound_obj(vm, mql, native_bool_false_ret)
    mql.get = mq_get // `matches` VIVO
    mql.set = mq_set // `onchange =` liga o rastreio por frame
    for k in ([?]string{MQ_QUERY, "media", "addListener", "removeListener",
                        "addEventListener", "removeEventListener", "dispatchEvent"}) {
        mark_non_enumerable(mql, k)
    }
    return mql
}

// Avaliação corrente da query deste MQL.
@(private = "file")
mq_now :: proc(o: ^Object) -> bool {
    if g_media_match == nil do return false
    q, ok := o.props[MQ_QUERY].(string)
    if !ok do return false
    return g_media_match(q)
}

// get-hook: `matches` re-avalia a cada leitura; o resto sai das props.
@(private = "file")
mq_get :: proc(vm: ^Interp, o: ^Object, name: string) -> (Value, bool) {
    if name == "matches" do return mq_now(o), true
    if v, ok := o.props[name]; ok do return v, true
    return nil, false
}

@(private = "file")
mq_self :: proc(vm: ^Interp, this: Value) -> ^Object {
    if o, ok := vm.native_bound.(^Object); ok && o.props[MQ_QUERY] != nil do return o
    if o, ok := this.(^Object); ok do return o
    return nil
}

// addListener(fn) e addEventListener('change', fn) — a mesma proc: na forma nova o
// 1º argumento é o tipo, e só 'change' existe num MediaQueryList.
@(private = "file")
mq_add_listener :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    o := mq_self(vm, this)
    if o == nil do return nil
    fn, ok := arg(a, 0).(^Function)
    if !ok {
        if t, tok := arg(a, 0).(string); tok {
            if t != "change" do return nil
            fn, ok = arg(a, 1).(^Function)
        }
    }
    if !ok do return nil
    lst, lok := o.props[MQ_LIST].(^Array)
    if !lok {
        lst = new_array(vm)
        o.props[MQ_LIST] = lst
        mark_non_enumerable(o, MQ_LIST)
        // O valor de PARTIDA é o de agora: o 'change' só sai numa VIRADA depois
        // do registro (a spec não entrega evento inicial — ao contrário do
        // IntersectionObserver, e essa assimetria já me custou um teste).
        o.props[MQ_LAST] = mq_now(o)
        mark_non_enumerable(o, MQ_LAST)
        mq_track(vm, o)
    }
    for it in lst.items do if f, fk := it.(^Function); fk && f == fn do return nil // já registrado
    append(&lst.items, fn)
    return nil
}

@(private = "file")
mq_remove_listener :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    o := mq_self(vm, this)
    if o == nil do return nil
    fn, ok := arg(a, 0).(^Function)
    if !ok do fn, ok = arg(a, 1).(^Function) // forma removeEventListener('change', fn)
    if !ok do return nil
    lst, lok := o.props[MQ_LIST].(^Array)
    if !lok do return nil
    for it, i in lst.items {
        if f, fk := it.(^Function); fk && f == fn {
            ordered_remove(&lst.items, i)
            break
        }
    }
    if len(lst.items) == 0 {
        if _, has := o.props["onchange"].(^Function); !has do mq_untrack(vm, o)
    }
    return nil
}

@(private = "file")
mq_track :: proc(vm: ^Interp, o: ^Object) {
    for x in vm.media_lists do if x == o do return
    append(&vm.media_lists, o)
}

@(private = "file")
mq_untrack :: proc(vm: ^Interp, o: ^Object) {
    for x, i in vm.media_lists {
        if x == o {
            ordered_remove(&vm.media_lists, i)
            return
        }
    }
}

// ── o passo por frame ───────────────────────────────────────────────────────
// Só existe para o evento 'change' — `matches` já é vivo por leitura. Um MQL sem
// ouvinte NUNCA entra em vm.media_lists, então página que só lê `.matches` não
// paga nada por frame.
mql_step :: proc(vm: ^Interp) -> bool {
    if vm == nil || len(vm.media_lists) == 0 do return false
    fired := false
    snap: [dynamic]^Object
    defer delete(snap)
    for o in vm.media_lists do append(&snap, o)
    for o in snap {
        now := mq_now(o)
        if now == truthy(o.props[MQ_LAST]) do continue
        o.props[MQ_LAST] = now
        q, _ := o.props[MQ_QUERY].(string)
        ev := new_object(vm)
        ev.props["type"]    = "change"
        ev.props["matches"] = now
        ev.props["media"]   = own_str(vm, q)
        ev.props["target"]  = o
        // handlers: onchange primeiro, depois os registrados (ordem do navegador)
        cbs: [dynamic]^Function
        defer delete(cbs)
        if f, ok := o.props["onchange"].(^Function); ok do append(&cbs, f)
        if lst, ok := o.props[MQ_LIST].(^Array); ok {
            for it in lst.items do if f, fk := it.(^Function); fk do append(&cbs, f)
        }
        for f in cbs {
            fired = true
            vm.steps = 0
            vm.call_depth = 0
            reset_task_clock(vm)
            mo_task_enter(vm)
            call_function(vm, f, o, []Value{ev})
            vm_clear_uncaught(vm)
            mo_task_exit(vm)
        }
    }
    return fired
}

// vm_destroy: só a lista (os objetos são rastreados pelo vm).
mq_free :: proc(vm: ^Interp) {
    delete(vm.media_lists)
    vm.media_lists = nil
}

// set-hook: `mql.onchange = fn` (a forma legada, sem addListener nenhum) também
// tem de ligar o rastreio por frame — senão seria um handler que nunca dispara,
// que é o defeito que este arquivo existe para tirar.
@(private = "file")
mq_set :: proc(vm: ^Interp, o: ^Object, name: string, val: Value) -> bool {
    o.props[name] = val
    if name == "onchange" {
        if _, ok := val.(^Function); ok {
            if _, has := o.props[MQ_LAST]; !has {
                o.props[MQ_LAST] = mq_now(o) // parte do valor de AGORA (sem evento inicial)
                mark_non_enumerable(o, MQ_LAST)
            }
            mq_track(vm, o)
        } else if _, has := o.props[MQ_LIST].(^Array); !has {
            mq_untrack(vm, o)
        }
    }
    return true
}
