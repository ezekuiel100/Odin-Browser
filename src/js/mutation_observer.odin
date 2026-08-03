package js

// ── MutationObserver REAL (M201) ────────────────────────────────────────────
//
// Terceiro item do Tier 1 da auditoria: antes era `observer_ctor`, um objeto com
// observe/disconnect no-op cujo callback NUNCA disparava. A página registrava,
// seguia em frente, e o que dependia da notificação simplesmente não acontecia —
// em silêncio, sem erro no console.
//
// ONDE O ESTADO MORA: no PRÓPRIO objeto JS do observador (props "#cb"/"#queue"/
// "#regs"), mesma convenção do PerformanceObserver em performance.odin. Assim
// tudo é rastreado pelo vm (all_objects/all_arrays) e não entra gestão de
// memória nova. O vm só guarda a LISTA de observadores vivos (`mut_observers`),
// necessária para iterar na entrega e para o atalho "ninguém observando".
//
// POR QUE OS RECORDS SÃO CONSTRUÍDOS NA HORA DA MUTAÇÃO (e não na entrega):
// além de ser o único momento em que os irmãos/valor antigo ainda existem, o
// `wrap_element` de um filho REMOVIDO é o que o mantém VIVO — o
// `detach_or_free_children` (textContent=/innerHTML=) libera na hora todo filho
// sem wrapper JS. Sem o wrapper, `record.removedNodes[0]` seria ponteiro para
// memória liberada. A retenção é, portanto, condicional a haver observador
// interessado: página sem MutationObserver não muda de comportamento nem paga
// nada. Ver [[dom-uaf-wikipedia]].
//
// Quem ALIMENTA isto é o funil de mutação em dom_bindings.odin — `detach`,
// `mo_insert` e `set_attr_str` recebem o `vm` exatamente para que o compilador
// aponte todo call-site novo que esqueça de notificar.

import dom "../dom"

// Chaves do estado no objeto JS (com `#` p/ não colidir com nada que a página escreva).
@(private = "file") MO_CB    :: "#cb"
@(private = "file") MO_QUEUE :: "#queue"
@(private = "file") MO_REGS  :: "#regs"

// Rodadas de entrega por checkpoint. A spec entrega UMA vez por microtask
// checkpoint, e o que o callback mutar só sai no checkpoint seguinte. Um punhado
// de rodadas faz observador-que-alimenta-observador convergir na mesma tarefa
// sem risco de laço infinito (callback que SEMPRE muta pararia aqui).
@(private = "file") MO_ROUNDS :: 4

// Teto de registros enfileirados por observador entre dois checkpoints, como
// rede de segurança de memória. A fila drena a cada tarefa, então isto só é
// atingido por um laço patológico numa tarefa só. Alto de propósito: um
// re-render de framework passa fácil de 10 mil mutações numa tarefa, e truncar
// aí deixaria o observador ERRADO EM SILÊNCIO — exatamente o defeito que este
// marco existe para tirar. Note que os NÓS criados por esse laço já são
// ilimitados e custam a mesma ordem de grandeza; o teto aqui não é o que
// segura a RAM, é só o que impede a fila de crescer sozinha sem fim.
@(private = "file") MO_QUEUE_MAX :: 65536

@(private = "file")
MO_Kind :: enum { Child, Attr, Char }

// ── atalho: alguém observando? ──────────────────────────────────────────────
// Chamado em TODA mutação do DOM. Com zero observadores (o caso de ~toda página)
// é uma leitura de `len` — o custo de ter esta feature é esse.
mo_active :: proc(vm: ^Interp) -> bool {
    return vm != nil && len(vm.mut_observers) > 0
}

// ── construtor e métodos ────────────────────────────────────────────────────

mo_ctor :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    cb := arg(a, 0)
    if _, ok := cb.(^Function); !ok {
        throw_type_error(vm, "MutationObserver constructor: callback must be a function")
        return nil
    }
    o := new_object(vm)
    o.props[MO_CB]    = cb
    o.props[MO_QUEUE] = new_array(vm)
    o.props[MO_REGS]  = new_array(vm)
    o.props["observe"]     = mk_bound_obj(vm, o, mo_observe)
    o.props["disconnect"]  = mk_bound_obj(vm, o, mo_disconnect)
    o.props["takeRecords"] = mk_bound_obj(vm, o, mo_take_records)
    for k in ([?]string{MO_CB, MO_QUEUE, MO_REGS, "observe", "disconnect", "takeRecords"}) {
        mark_non_enumerable(o, k)
    }
    return o
}

// O objeto do observador: `mk_bound_obj` põe em vm.native_bound; `this` cobre
// o caso de o método ter sido destacado (`var f = mo.observe`).
@(private = "file")
mo_self :: proc(vm: ^Interp, this: Value) -> ^Object {
    if o, ok := vm.native_bound.(^Object); ok && o.props[MO_QUEUE] != nil do return o
    if o, ok := this.(^Object); ok do return o
    return nil
}

@(private = "file")
mo_observe :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    obs := mo_self(vm, this)
    if obs == nil do return nil
    target, tok := arg(a, 0).(^Object)
    if !tok || target.host == nil {
        throw_type_error(vm, "MutationObserver.observe: target must be a Node")
        return nil
    }
    opts, _ := arg(a, 1).(^Object)

    child_list := opts != nil && truthy(opts.props["childList"])
    attrs      := opts != nil && truthy(opts.props["attributes"])
    char_data  := opts != nil && truthy(opts.props["characterData"])
    attr_old   := opts != nil && truthy(opts.props["attributeOldValue"])
    cd_old     := opts != nil && truthy(opts.props["characterDataOldValue"])
    filter: ^Array
    if opts != nil do filter, _ = opts.props["attributeFilter"].(^Array)
    // attributeFilter/attributeOldValue IMPLICAM attributes; characterDataOldValue
    // implica characterData (spec) — é como o idioma `{attributeFilter:['class']}`
    // (sem `attributes:true`) funciona nas páginas.
    if filter != nil || attr_old do attrs = true
    if cd_old do char_data = true
    if !child_list && !attrs && !char_data {
        throw_type_error(vm, "MutationObserver.observe: at least one of childList, attributes, characterData must be true")
        return nil
    }

    reg := new_object(vm)
    reg.props["n"]         = target
    reg.props["childList"] = child_list
    reg.props["attrs"]     = attrs
    reg.props["char"]      = char_data
    reg.props["subtree"]   = opts != nil && truthy(opts.props["subtree"])
    reg.props["attrOld"]   = attr_old
    reg.props["charOld"]   = cd_old
    if filter != nil do reg.props["filter"] = filter

    vm.mo_observe_calls += 1 // uso real da API; sai no --diagnose
    regs, _ := obs.props[MO_REGS].(^Array)
    if regs == nil do return nil
    // observar o MESMO alvo de novo SUBSTITUI o registro anterior (spec)
    for it, i in regs.items {
        if r, ok := it.(^Object); ok {
            if t, tk := r.props["n"].(^Object); tk && t.host == target.host {
                regs.items[i] = reg
                mo_track(vm, obs)
                return nil
            }
        }
    }
    append(&regs.items, reg)
    mo_track(vm, obs)
    return nil
}

@(private = "file")
mo_disconnect :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    obs := mo_self(vm, this)
    if obs == nil do return nil
    if regs, ok := obs.props[MO_REGS].(^Array); ok do clear(&regs.items)
    if q, ok := obs.props[MO_QUEUE].(^Array); ok do clear(&q.items) // spec: esvazia a fila
    for o, i in vm.mut_observers {
        if o == obs {
            ordered_remove(&vm.mut_observers, i)
            break
        }
    }
    return nil
}

@(private = "file")
mo_take_records :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    out := new_array(vm)
    obs := mo_self(vm, this)
    if obs == nil do return out
    if q, ok := obs.props[MO_QUEUE].(^Array); ok {
        for e in q.items do append(&out.items, e)
        clear(&q.items)
    }
    return out
}

@(private = "file")
mo_track :: proc(vm: ^Interp, obs: ^Object) {
    for o in vm.mut_observers do if o == obs do return
    append(&vm.mut_observers, obs)
}

// ── casamento (quem se interessa por esta mutação) ──────────────────────────

// `target` é o nó cujo registro seria emitido: o PAI na mutação de childList, o
// próprio nó em atributo/texto.
@(private = "file")
reg_matches :: proc(reg: ^Object, target: ^dom.Node, kind: MO_Kind, attr: string) -> bool {
    t, ok := reg.props["n"].(^Object)
    if !ok || t.host == nil do return false
    root := cast(^dom.Node) t.host
    if root != target {
        if !truthy(reg.props["subtree"]) do return false
        found := false
        for n := target.parent; n != nil; n = n.parent do if n == root { found = true; break }
        if !found do return false
    }
    switch kind {
    case .Child:
        return truthy(reg.props["childList"])
    case .Attr:
        if !truthy(reg.props["attrs"]) do return false
        if f, fok := reg.props["filter"].(^Array); fok {
            for it in f.items do if s, sok := it.(string); sok && s == attr do return true
            return false
        }
        return true
    case .Char:
        return truthy(reg.props["char"])
    }
    return false
}

// Algum observador quer esta mutação? Consultado ANTES de montar o record (que
// custa objetos e wrappers).
@(private = "file")
mo_wanted :: proc(vm: ^Interp, target: ^dom.Node, kind: MO_Kind, attr: string) -> bool {
    if !mo_active(vm) || target == nil do return false
    for obs in vm.mut_observers {
        regs, ok := obs.props[MO_REGS].(^Array)
        if !ok do continue
        for it in regs.items {
            if r, rok := it.(^Object); rok && reg_matches(r, target, kind, attr) do return true
        }
    }
    return false
}

// Enfileira `rec` em todo observador interessado. Um observador com DOIS
// registros que casam recebe UM record só (spec).
@(private = "file")
mo_enqueue :: proc(vm: ^Interp, target: ^dom.Node, kind: MO_Kind, attr: string, rec: ^Object, old: Value) {
    for obs in vm.mut_observers {
        regs, ok := obs.props[MO_REGS].(^Array)
        if !ok do continue
        hit := false
        want_old := false
        for it in regs.items {
            r, rok := it.(^Object)
            if !rok || !reg_matches(r, target, kind, attr) do continue
            hit = true
            #partial switch kind {
            case .Attr: if truthy(r.props["attrOld"]) do want_old = true
            case .Char: if truthy(r.props["charOld"]) do want_old = true
            }
        }
        if !hit do continue
        q, qok := obs.props[MO_QUEUE].(^Array)
        if !qok || len(q.items) >= MO_QUEUE_MAX do continue
        // `oldValue` é POR OBSERVADOR (só quem pediu attributeOldValue o vê), e o
        // record é compartilhado — então quem pediu ganha uma cópia rasa com o
        // campo preenchido. É o único campo que difere entre observadores.
        if want_old && old != nil {
            dup := new_object(vm)
            for k, v in rec.props do dup.props[k] = v
            dup.props["oldValue"] = old
            append(&q.items, dup)
        } else {
            append(&q.items, rec)
        }
    }
}

@(private = "file")
mk_record :: proc(vm: ^Interp, type: string, target: ^dom.Node) -> ^Object {
    r := new_object(vm)
    r.props["type"]               = type
    r.props["target"]             = wrap_element(vm, target)
    r.props["addedNodes"]         = new_array(vm)
    r.props["removedNodes"]       = new_array(vm)
    r.props["previousSibling"]    = JS_Null{}
    r.props["nextSibling"]        = JS_Null{}
    r.props["attributeName"]      = JS_Null{}
    r.props["attributeNamespace"] = JS_Null{}
    r.props["oldValue"]           = JS_Null{}
    return r
}

// ── as três gravações (chamadas pelo funil de dom_bindings) ─────────────────

// Inserção/remoção de filhos. `added`/`removed` podem ser listas (o caso de
// replaceChildren/innerHTML=); `prev`/`next` são os irmãos do ponto da mudança.
mo_record_children :: proc(vm: ^Interp, parent: ^dom.Node, added, removed: []^dom.Node, prev, next: ^dom.Node) {
    if !mo_wanted(vm, parent, .Child, "") do return
    if len(added) == 0 && len(removed) == 0 do return
    rec := mk_record(vm, "childList", parent)
    if a, ok := rec.props["addedNodes"].(^Array); ok {
        for n in added do if n != nil do append(&a.items, wrap_element(vm, n))
    }
    if r, ok := rec.props["removedNodes"].(^Array); ok {
        // wrap_element aqui NÃO é só p/ o JS ler: é o que impede o
        // detach_or_free_children de liberar o nó antes da entrega.
        for n in removed do if n != nil do append(&r.items, wrap_element(vm, n))
    }
    if prev != nil do rec.props["previousSibling"] = wrap_element(vm, prev)
    if next != nil do rec.props["nextSibling"]     = wrap_element(vm, next)
    mo_enqueue(vm, parent, .Child, "", rec, nil)
}

// Atributo. `old`/`had` descrevem o valor ANTES da escrita (a leitura tem de ser
// feita pelo chamador, antes de gravar).
mo_record_attr :: proc(vm: ^Interp, node: ^dom.Node, name: string, old: string, had: bool) {
    if !mo_wanted(vm, node, .Attr, name) do return
    rec := mk_record(vm, "attributes", node)
    rec.props["attributeName"] = own_str(vm, name)
    old_v: Value = JS_Null{}
    if had do old_v = own_str(vm, old) // sem o atributo antes ⇒ oldValue null (spec)
    mo_enqueue(vm, node, .Attr, name, rec, old_v)
}

// Texto de um nó Text/Comment (characterData).
mo_record_char :: proc(vm: ^Interp, node: ^dom.Node, old: string) {
    if !mo_wanted(vm, node, .Char, "") do return
    rec := mk_record(vm, "characterData", node)
    mo_enqueue(vm, node, .Char, "", rec, own_str(vm, old))
}

// ── entrega (fim de tarefa) ─────────────────────────────────────────────────

// Entrada/saída de TAREFA síncrona de JS: script da página (vm_run/vm_run_module),
// cada callback de timer/rAF (vm_pump_timers) e cada dispatch de evento. A entrega
// sai só quando a pilha volta a ZERO, porque a spec só roda o microtask checkpoint
// com a pilha de execução VAZIA. Sem a contagem, um `el.click()` chamado de DENTRO
// de um handler entregaria records no meio da tarefa de fora — reentrância que a
// página não tem como esperar.
mo_task_enter :: proc(vm: ^Interp) {
    if vm != nil do vm.mo_task_depth += 1
}

mo_task_exit :: proc(vm: ^Interp) {
    if vm == nil do return
    vm.mo_task_depth -= 1
    if vm.mo_task_depth > 0 do return
    vm.mo_task_depth = 0 // defensivo: um enter/exit desbalanceado não trava a entrega
    mo_notify(vm)
}

// O checkpoint em si. É o análogo possível do "microtask checkpoint" da spec —
// este motor não tem fila de microtasks separada (as reações de Promise drenam
// ávidas no settle).
mo_notify :: proc(vm: ^Interp) {
    if !mo_active(vm) || vm.mo_notifying do return
    vm.mo_notifying = true
    defer vm.mo_notifying = false
    // Uma CÓPIA da lista por rodada: o callback pode chamar observe/disconnect e
    // mexer em vm.mut_observers no meio do laço. Alocador padrão (não o temp) de
    // propósito — o buffer atravessa chamadas de JS arbitrário, e amarrá-lo ao
    // ciclo de vida da arena temporária do frame seria acoplamento invisível.
    // Um observador desconectado durante a rodada continua no snapshot, mas o
    // disconnect esvazia a fila dele, então ele é só pulado.
    snap: [dynamic]^Object
    defer delete(snap)
    for _ in 0 ..< MO_ROUNDS {
        any := false
        clear(&snap)
        for o in vm.mut_observers do append(&snap, o)
        for obs in snap {
            q, ok := obs.props[MO_QUEUE].(^Array)
            if !ok || len(q.items) == 0 do continue
            recs := new_array(vm)
            for it in q.items do append(&recs.items, it)
            clear(&q.items)
            vm.mo_records_sent += len(recs.items)
            any = true
            cb, cok := obs.props[MO_CB].(^Function)
            if !cok do continue
            call_function(vm, cb, obs, []Value{recs, obs})
            // um callback que lança não impede os demais (como no navegador); a
            // mensagem já foi para o uncaught_log, aqui só limpamos o estado de
            // propagação p/ não vazar na tarefa que nos chamou.
            vm_clear_uncaught(vm)
        }
        if !any do break
    }
}

// vm_destroy: só a lista (os objetos são rastreados pelo vm).
mo_free :: proc(vm: ^Interp) {
    delete(vm.mut_observers)
    vm.mut_observers = nil
}
