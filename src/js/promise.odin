package js

// Promise mínima. Estado guardado em props do próprio Object (tudo rastreado
// pelo vm — zero gestão de memória nova):
//   _state:     f64  (0 pendente, 1 cumprida, 2 rejeitada)
//   _value:     Value
//   _reactions: ^Array de reações {f, r, next} (next = promise derivada)
//
// SIMPLIFICAÇÃO consciente: as reações rodam SINCRONAMENTE no settle (sem fila
// de microtasks). Um .then numa promise já resolvida roda o callback na hora.
// Para o fetch (que resolve a partir do pump de frames) o efeito é idêntico ao
// navegador; a diferença só aparece em códigos que dependem da ordem exata
// síncrono-vs-microtask.
//
// Encadeamento completo: then devolve promise derivada; callback que devolve
// uma promise é ADOTADO (a derivada espera a interna — essencial p/ o padrão
// fetch(u).then(r => r.json()).then(data => ...)).

import "core:time"

PROMISE_PENDING   :: 0.0
PROMISE_FULFILLED :: 1.0
PROMISE_REJECTED  :: 2.0

// Uma reação de Promise ainda não executada (a "microtask"). O que run_reaction
// precisa: os callbacks dos dois lados, a promise derivada, e o estado/valor.
Reaction_Job :: struct {
    onf, onr: Value,
    next:     ^Object,
    state:    f64,
    val:      Value,
}

// Processa a fila de reações até esvaziar (FIFO plano, não recursivo). Antes as
// reações rodavam síncronas ANINHADAS (settle→run_reaction→callback→settle→...),
// então um padrão de Promise recursivo/profundo (comum em libs de auth/fetch
// reais) estourava a stack. A fila plana desenrola a stack a cada `.then`, como
// as microtasks de um navegador.
@(private = "file")
drain_reaction_queue :: proc(vm: ^Interp) {
    processed := 0
    for len(vm.reaction_queue) > 0 {
        job := vm.reaction_queue[0]
        ordered_remove(&vm.reaction_queue, 0) // FIFO; a fila fica curta (cada reação enfileira ~1)
        run_reaction(vm, job.onf, job.onr, job.next, job.state, job.val)
        processed += 1
        // guarda contra loop de microtask infinito (ex.: Promise.resolve().then(loop)):
        // step_guard não vê isto (não é laço JS), então checamos o relógio da tarefa.
        if vm.time_budget_ms > 0 && (processed & 0x3FF) == 0 {
            if time.duration_milliseconds(time.tick_since(vm.task_start)) > vm.time_budget_ms {
                clear(&vm.reaction_queue) // abandona a cauda patológica p/ não travar a UI
                break
            }
        }
    }
}

// Dispara o drain se ninguém está drenando (o drain é ÁVIDO: roda antes de
// devolver o controle, então a observação continua "síncrona" p/ o código).
@(private = "file")
kick_drain :: proc(vm: ^Interp) {
    if vm.draining do return // já há um loop drenando; ele pega as novas também
    vm.draining = true
    drain_reaction_queue(vm)
    vm.draining = false
}

// Só enfileira (o chamador decide quando drenar — promise_settle enfileira
// TODAS as reações irmãs antes do drain, senão a 1ª drenaria a própria cadeia
// derivada inteira antes de a 2ª entrar: p.then(A); p.then(B) rodaria A,A2,B
// em vez de A,B,A2 como no navegador).
@(private = "file")
schedule_reaction :: proc(vm: ^Interp, onf, onr: Value, next: ^Object, state: f64, val: Value) {
    append(&vm.reaction_queue, Reaction_Job{onf = onf, onr = onr, next = next, state = state, val = val})
}

// Espera BLOQUEANTE do await: bomba timers/fetches (relógio real) até a
// promise assentar. Não-promise devolve na hora. `rejected` indica que o
// await deve LANÇAR o valor. Teto de segurança contra promise que nunca
// assenta (senão o navegador travaria para sempre).
//
// SIMPLIFICAÇÃO consciente: enquanto um await espera, a renderização pausa
// (o frame não avança), mas timers/fetches/promises continuam fluindo pelo
// pump aninhado — o resultado do código é o mesmo do navegador real.
AWAIT_TIMEOUT_MS :: 10_000.0

promise_await_blocking :: proc(vm: ^Interp, v: Value) -> (out: Value, rejected: bool) {
    p, isp := is_promise(v)
    if !isp do return v, false // await de não-promise: o próprio valor

    waited: f64 = 0
    last := time.tick_now()
    for as_number(p.props["_state"]) == PROMISE_PENDING {
        now := time.tick_now()
        dt := time.duration_milliseconds(time.tick_diff(last, now))
        last = now
        vm_pump_timers(vm, dt) // fetches + timers reais continuam rodando
        // Se este await está DENTRO de um callback de .then (drain ativo), as
        // reações enfileiradas durante a espera não rodariam nunca — o drenador
        // externo está bloqueado exatamente aqui. Drena a fila nós mesmos, senão
        // qualquer promise derivada de .then fica pendente até o timeout de 10s.
        if len(vm.reaction_queue) > 0 do drain_reaction_queue(vm)
        if as_number(p.props["_state"]) != PROMISE_PENDING do break
        time.sleep(time.Millisecond) // não fritar a CPU
        waited += dt + 1
        if waited > AWAIT_TIMEOUT_MS {
            e := new_object(vm)
            e.props["name"] = "Error"
            e.props["message"] = "await: tempo esgotado (promise nunca assentou)"
            return e, true
        }
    }
    // O await pausou a execução (bombeando timers) por um tempo real que NÃO deve
    // contar contra o watchdog por tempo: reinicia o relógio p/ o código pós-await.
    reset_task_clock(vm)
    if as_number(p.props["_state"]) == PROMISE_REJECTED do return p.props["_value"], true
    return p.props["_value"], false
}

install_promise :: proc(vm: ^Interp) {
    vm.promise_then_fn = new_function(vm)
    vm.promise_then_fn.native = native_promise_then
    vm.promise_then_fn.name = "then"
    vm.promise_catch_fn = new_function(vm)
    vm.promise_catch_fn.native = native_promise_catch
    vm.promise_catch_fn.name = "catch"
    vm.promise_finally_fn = new_function(vm)
    vm.promise_finally_fn.native = native_promise_finally
    vm.promise_finally_fn.name = "finally"

    ctor := new_function(vm)
    ctor.native = native_promise_ctor
    ctor.name = "Promise"
    ctor.props = make(map[string]Value)
    res_static := new_function(vm)
    res_static.native = native_promise_resolve_static
    rej_static := new_function(vm)
    rej_static.native = native_promise_reject_static
    ctor.props["resolve"] = res_static
    ctor.props["reject"] = rej_static
    ctor.props["all"]        = mk_combinator(vm, "all")
    ctor.props["allSettled"] = mk_combinator(vm, "allSettled")
    ctor.props["race"]       = mk_combinator(vm, "race")
    ctor.props["any"]        = mk_combinator(vm, "any")
    wr := new_function(vm)
    wr.native = native_promise_with_resolvers
    wr.name = "withResolvers"
    ctor.props["withResolvers"] = wr
    // Promise.prototype com then/catch/finally (os mesmos natives que cada promise
    // carrega). core-js faz `Promise.prototype.finally` no init — sem o prototype,
    // `reading 'finally' of undefined` matava o bundle.
    proto := new_object(vm)
    proto.props["then"]        = vm.promise_then_fn
    proto.props["catch"]       = vm.promise_catch_fn
    proto.props["finally"]     = vm.promise_finally_fn
    proto.props["constructor"] = ctor
    ctor.props["prototype"] = proto
    vm.promise_proto = proto // toda promise nasce com este [[Prototype]] (ver promise_new)
    env_define(vm.global, "Promise", ctor)
}

// ── combinadores: Promise.all / allSettled / race / any ─────────────────────
//
// Cada um recebe um iterável de valores (promises ou não). Reusam o mesmo motor
// de reações: para cada entrada anexamos callbacks nativos cujo `bound` é um
// contexto {st, i}. `st` guarda a promise agregada, o array de resultados, o
// contador de pendentes e o "kind". Sem microtasks — assenta síncrono como o
// resto deste Promise (M19).

@(private = "file")
mk_combinator :: proc(vm: ^Interp, kind: string) -> ^Function {
    f := new_function(vm)
    switch kind {
    case "all":        f.native = promise_all
    case "allSettled": f.native = promise_all_settled
    case "race":       f.native = promise_race
    case "any":        f.native = promise_any
    }
    f.name = kind
    return f
}

// Coleta as entradas do iterável (Array direto; senão protocolo de iterador).
@(private = "file")
gather_inputs :: proc(vm: ^Interp, v: Value) -> [dynamic]Value {
    out: [dynamic]Value
    if arr, ok := v.(^Array); ok {
        for it in arr.items do append(&out, it)
        return out
    }
    iterate_protocol(vm, v, &out) // Collections, iteráveis custom
    return out
}

// Callback por-entrada com contexto {st, i} em bound.
@(private = "file")
mk_input_cb :: proc(vm: ^Interp, native: proc(^Interp, Value, []Value) -> Value, st: ^Object, i: int) -> ^Function {
    f := new_function(vm)
    f.native = native
    ctx := new_object(vm)
    ctx.props["st"] = st
    ctx.props["i"]  = f64(i)
    f.bound = ctx
    return f
}

// Motor comum: monta o estado, liga os callbacks e trata o caso vazio.
@(private = "file")
run_combinator :: proc(vm: ^Interp, args: []Value, kind: string) -> Value {
    agg := promise_new(vm)
    items := gather_inputs(vm, arg(args, 0))
    defer delete(items)

    results := new_array(vm)
    for _ in items do append(&results.items, nil) // 1 slot por entrada (ordem preservada)

    st := new_object(vm)
    st.props["agg"]       = agg
    st.props["kind"]      = kind
    st.props["results"]   = results
    st.props["remaining"] = f64(len(items))

    if len(items) == 0 {
        switch kind {
        case "all", "allSettled":
            promise_settle(vm, agg, PROMISE_FULFILLED, results) // resolve com []
        case "any":
            promise_settle(vm, agg, PROMISE_REJECTED, aggregate_error(vm, results))
        case "race":
            // fica pendente para sempre (como no navegador)
        }
        return agg
    }

    for it, i in items {
        onf := mk_input_cb(vm, combinator_on_fulfill, st, i)
        onr := mk_input_cb(vm, combinator_on_reject, st, i)
        if p, isp := is_promise(it); isp {
            promise_then_impl(vm, p, onf, onr)
        } else {
            call_function(vm, onf, nil, []Value{it}) // não-promise = já cumprida
        }
    }
    return agg
}

@(private = "file")
aggregate_error :: proc(vm: ^Interp, errors: ^Array) -> ^Object {
    e := new_object(vm)
    e.props["name"]    = "AggregateError"
    e.props["message"] = own_str(vm, "All promises were rejected")
    e.props["errors"]  = errors
    // cadeia de protótipo: sem isto o objeto não era `instanceof AggregateError`
    // nem `instanceof Error`, e não tinha o toString de erro.
    if proto, ok := vm.error_protos["AggregateError"]; ok do e.proto = proto
    return e
}

// Decrementa o contador; ao zerar, assenta a agregada conforme o kind.
@(private = "file")
combinator_finish :: proc(vm: ^Interp, st: ^Object) {
    rem := as_number(st.props["remaining"]) - 1
    st.props["remaining"] = rem
    if rem > 0 do return
    agg := st.props["agg"].(^Object)
    results := st.props["results"].(^Array)
    switch st.props["kind"].(string) {
    case "all", "allSettled":
        promise_settle(vm, agg, PROMISE_FULFILLED, results)
    case "any":
        promise_settle(vm, agg, PROMISE_REJECTED, aggregate_error(vm, results))
    }
}

@(private = "file")
combinator_ctx :: proc(vm: ^Interp) -> (st: ^Object, i: int, ok: bool) {
    ctx, cok := vm.native_bound.(^Object)
    if !cok do return nil, 0, false
    st, _ = ctx.props["st"].(^Object)
    i = int(as_number(ctx.props["i"]))
    return st, i, st != nil
}

@(private = "file")
combinator_on_fulfill :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    st, i, ok := combinator_ctx(vm)
    if !ok do return nil
    val := arg(args, 0)
    agg := st.props["agg"].(^Object)
    results := st.props["results"].(^Array)
    switch st.props["kind"].(string) {
    case "race", "any":
        promise_settle(vm, agg, PROMISE_FULFILLED, val) // 1º a cumprir vence (idempotente)
    case "all":
        if i < len(results.items) do results.items[i] = val
        combinator_finish(vm, st)
    case "allSettled":
        o := new_object(vm)
        o.props["status"] = "fulfilled"
        o.props["value"]  = val
        if i < len(results.items) do results.items[i] = o
        combinator_finish(vm, st)
    }
    return nil
}

@(private = "file")
combinator_on_reject :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    st, i, ok := combinator_ctx(vm)
    if !ok do return nil
    val := arg(args, 0)
    agg := st.props["agg"].(^Object)
    results := st.props["results"].(^Array)
    switch st.props["kind"].(string) {
    case "race", "all":
        promise_settle(vm, agg, PROMISE_REJECTED, val) // 1º a rejeitar decide
    case "any":
        if i < len(results.items) do results.items[i] = val // guarda o erro
        combinator_finish(vm, st) // ao zerar → AggregateError
    case "allSettled":
        o := new_object(vm)
        o.props["status"] = "rejected"
        o.props["reason"] = val
        if i < len(results.items) do results.items[i] = o
        combinator_finish(vm, st)
    }
    return nil
}

@(private = "file")
promise_all :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return run_combinator(vm, args, "all")
}
@(private = "file")
promise_all_settled :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return run_combinator(vm, args, "allSettled")
}
@(private = "file")
promise_race :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return run_combinator(vm, args, "race")
}
@(private = "file")
promise_any :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return run_combinator(vm, args, "any")
}

// Cria uma promise pendente com os métodos then/catch.
promise_new :: proc(vm: ^Interp) -> ^Object {
    p := new_object(vm)
    // [[Prototype]] = Promise.prototype. Sem isto `x instanceof Promise` e
    // `x.constructor === Promise` davam FALSE para TODA promise da engine (inclusive
    // as de `new Promise`, `.then` e `fetch`) — o modo de errar silencioso: uma lib
    // que ramifica por `instanceof Promise` escolhia sempre o outro galho. Os
    // then/catch/finally continuam como props PRÓPRIAS (own vence proto no
    // get_member): o caminho quente não passa a depender da cadeia.
    p.proto = vm.promise_proto
    p.props["_state"] = f64(PROMISE_PENDING)
    p.props["_reactions"] = new_array(vm)
    p.props["then"] = vm.promise_then_fn
    p.props["catch"] = vm.promise_catch_fn
    p.props["finally"] = vm.promise_finally_fn
    return p
}

@(private = "file")
is_promise :: proc(v: Value) -> (^Object, bool) {
    o, ok := v.(^Object)
    if !ok do return nil, false
    _, has := o.props["_state"]
    return o, has
}

// Assenta a promise (idempotente) e dispara as reações pendentes — TODAS
// enfileiradas antes do drain, p/ interleaving igual ao do navegador.
promise_settle :: proc(vm: ^Interp, p: ^Object, state: f64, val: Value) {
    if as_number(p.props["_state"]) != PROMISE_PENDING do return
    p.props["_state"] = state
    p.props["_value"] = val
    reactions, _ := p.props["_reactions"].(^Array)
    if reactions == nil do return
    for item in reactions.items {
        r, ok := item.(^Object)
        if !ok do continue
        next, nok := r.props["next"].(^Object)
        if !nok do continue
        schedule_reaction(vm, r.props["f"], r.props["r"], next, state, val) // microtask
    }
    clear(&reactions.items)
    kick_drain(vm)
}

// Cumpre a promise com `v` — a menos que `v` seja outra promise (ADOTA: assenta
// junto com ela) ou um THENABLE (objeto com .then chamável: adota via protocolo,
// como axios-likes e polyfills esperam).
promise_resolve_with :: proc(vm: ^Interp, p: ^Object, v: Value) {
    if inner, ok := is_promise(v); ok {
        if inner == p {
            // resolve(a própria promise): ciclo — spec manda TypeError, não pendurar p/ sempre
            promise_settle(vm, p, PROMISE_REJECTED, mk_error(vm, "TypeError", "Chaining cycle detected for promise"))
            return
        }
        istate := as_number(inner.props["_state"])
        if istate == PROMISE_PENDING {
            // reação passthrough: quando a interna assentar, p assenta igual
            reactions, _ := inner.props["_reactions"].(^Array)
            if reactions != nil {
                r := new_object(vm)
                r.props["next"] = p
                append(&reactions.items, r)
            }
        } else {
            promise_settle(vm, p, istate, inner.props["_value"])
        }
        return
    }
    // thenable genérico: {then(resolve, reject){...}} — chama o then dele com
    // resolvedores ligados a p (mesma mecânica do executor do construtor)
    if o, ook := v.(^Object); ook {
        if thenfn, tok := get_member(vm, o, "then").(^Function); tok {
            resolve_fn := new_function(vm)
            resolve_fn.native = native_promise_resolve_bound
            resolve_fn.bound = p
            reject_fn := new_function(vm)
            reject_fn.native = native_promise_reject_bound
            reject_fn.bound = p
            call_function(vm, thenfn, o, []Value{resolve_fn, reject_fn})
            if vm.throwing { // then lançou: rejeita (se ainda pendente)
                vm.throwing = false
                thrown := vm.thrown
                vm.thrown = nil
                promise_settle(vm, p, PROMISE_REJECTED, thrown)
            }
            return
        }
    }
    promise_settle(vm, p, PROMISE_FULFILLED, v)
}

// Executa uma reação: chama o callback do lado certo (ou passthrough) e
// assenta a promise derivada com o resultado / exceção.
@(private = "file")
run_reaction :: proc(vm: ^Interp, onf, onr: Value, next: ^Object, state: f64, val: Value) {
    cb_val := onf if state == PROMISE_FULFILLED else onr
    cb, is_fn := cb_val.(^Function)
    if !is_fn {
        // sem handler deste lado: propaga o estado como está
        if state == PROMISE_FULFILLED do promise_resolve_with(vm, next, val)
        else do promise_settle(vm, next, PROMISE_REJECTED, val)
        return
    }
    res := call_function(vm, cb, nil, []Value{val})
    if vm.throwing {
        vm.throwing = false
        thrown := vm.thrown
        vm.thrown = nil
        promise_settle(vm, next, PROMISE_REJECTED, thrown) // throw no callback rejeita a derivada
    } else {
        promise_resolve_with(vm, next, res)
    }
}

// Núcleo do then/catch: registra (pendente) ou roda na hora (já assentada).
// Visível no pacote: a corrotina async (generator.odin) encadeia a retomada aqui.
promise_then_impl :: proc(vm: ^Interp, p: ^Object, onf, onr: Value) -> Value {
    next := promise_new(vm)
    state := as_number(p.props["_state"])
    if state == PROMISE_PENDING {
        reactions, _ := p.props["_reactions"].(^Array)
        if reactions != nil {
            r := new_object(vm)
            r.props["f"] = onf
            r.props["r"] = onr
            r.props["next"] = next
            append(&reactions.items, r)
        }
    } else {
        schedule_reaction(vm, onf, onr, next, state, p.props["_value"]) // já assentada: microtask
        kick_drain(vm)
    }
    return next
}

// ── nativas ─────────────────────────────────────────────────────────────────

@(private = "file")
native_promise_then :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    p, ok := is_promise(this)
    if !ok do return nil
    onf: Value = len(args) >= 1 ? args[0] : nil
    onr: Value = len(args) >= 2 ? args[1] : nil
    return promise_then_impl(vm, p, onf, onr)
}

@(private = "file")
native_promise_catch :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    p, ok := is_promise(this)
    if !ok do return nil
    onr: Value = len(args) >= 1 ? args[0] : nil
    return promise_then_impl(vm, p, nil, onr)
}

// p.finally(cb): cb roda nos DOIS desfechos, sem receber o valor; o resultado
// passa adiante (valor preservado, rejeição re-lançada). Se o cb lançar, a
// exceção dele prevalece (run_reaction rejeita a derivada). SIMPLIFICAÇÃO:
// cb que devolve promise não é aguardado (spec espera; raro).
@(private = "file")
native_promise_finally :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    p, ok := is_promise(this)
    if !ok do return nil
    cb, cok := arg(args, 0).(^Function)
    if !cok do return promise_then_impl(vm, p, nil, nil)
    onf := new_function(vm)
    onf.native = finally_on_fulfilled
    onf.bound = cb
    onr := new_function(vm)
    onr.native = finally_on_rejected
    onr.bound = cb
    return promise_then_impl(vm, p, onf, onr)
}

@(private = "file")
finally_on_fulfilled :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if cb, ok := vm.native_bound.(^Function); ok {
        call_function(vm, cb, nil, nil)
        if vm.throwing do return nil // exceção do cb rejeita a derivada
    }
    return arg(args, 0) // valor original segue adiante
}

@(private = "file")
finally_on_rejected :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if cb, ok := vm.native_bound.(^Function); ok {
        call_function(vm, cb, nil, nil)
        if vm.throwing do return nil // exceção do cb substitui a razão
    }
    vm.thrown = arg(args, 0) // re-lança a razão original
    vm.throwing = true
    return nil
}

// new Promise(function(resolve, reject) { ... })
@(private = "file")
native_promise_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    p := promise_new(vm)
    if len(args) < 1 do return p // sem executor: fica pendente para sempre
    executor, ok := args[0].(^Function)
    if !ok do return p

    resolve_fn := new_function(vm)
    resolve_fn.native = native_promise_resolve_bound
    resolve_fn.bound = p
    reject_fn := new_function(vm)
    reject_fn.native = native_promise_reject_bound
    reject_fn.bound = p

    call_function(vm, executor, nil, []Value{resolve_fn, reject_fn})
    if vm.throwing { // executor lançou: rejeita
        vm.throwing = false
        thrown := vm.thrown
        vm.thrown = nil
        promise_settle(vm, p, PROMISE_REJECTED, thrown)
    }
    return p
}

@(private = "file")
native_promise_resolve_bound :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if p, ok := vm.native_bound.(^Object); ok {
        promise_resolve_with(vm, p, len(args) >= 1 ? args[0] : nil)
    }
    return nil
}

@(private = "file")
native_promise_reject_bound :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if p, ok := vm.native_bound.(^Object); ok {
        promise_settle(vm, p, PROMISE_REJECTED, len(args) >= 1 ? args[0] : nil)
    }
    return nil
}

// Promise.withResolvers() → { promise, resolve, reject } (ES2024). É o mesmo par
// de funções que o executor recebe, só que EXPOSTO — o idioma substituiu o
// "capability escapado do executor" (`let r; new Promise(x => r = x)`) que os
// bundles escreviam à mão. Sem ele o landing-pages do github.com morria na 1ª
// linha do módulo: `Promise.withResolvers is not a function`.
@(private = "file")
native_promise_with_resolvers :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    p := promise_new(vm)
    resolve_fn := new_function(vm)
    resolve_fn.native = native_promise_resolve_bound
    resolve_fn.bound = p
    reject_fn := new_function(vm)
    reject_fn.native = native_promise_reject_bound
    reject_fn.bound = p
    o := new_object(vm)
    oput(o, "promise", p)
    oput(o, "resolve", resolve_fn)
    oput(o, "reject", reject_fn)
    return o
}

@(private = "file")
native_promise_resolve_static :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    p := promise_new(vm)
    promise_resolve_with(vm, p, len(args) >= 1 ? args[0] : nil)
    return p
}

@(private = "file")
native_promise_reject_static :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    p := promise_new(vm)
    promise_settle(vm, p, PROMISE_REJECTED, len(args) >= 1 ? args[0] : nil)
    return p
}
