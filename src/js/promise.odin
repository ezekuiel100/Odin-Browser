package js

// Promise state lives in Object.promise, outside JavaScript properties.
// The object owns these slots; GC traces the value and pending reactions.
//
// Reações e queueMicrotask compartilham uma FIFO, drenada no checkpoint de
// fim de tarefa. Await retoma corrotinas por esta mesma fila, sem pump aninhado.
//
// Encadeamento completo: then devolve promise derivada; callback que devolve
// uma promise é ADOTADO (a derivada espera a interna — essencial p/ o padrão
// fetch(u).then(r => r.json()).then(data => ...)).

import "core:time"

PROMISE_PENDING   :: 0.0
PROMISE_FULFILLED :: 1.0
PROMISE_REJECTED  :: 2.0

Promise_Data :: struct {
    state: f64,
    value: Value,
    reactions: [dynamic]Promise_Reaction,
}

Promise_Reaction :: struct {
    onf, onr: Value,
    next: ^Object,
}

// Shared by sweeping and VM destruction; neither leaves a side-table root.
promise_destroy :: proc(o: ^Object) {
    if o.promise == nil do return
    delete(o.promise.reactions)
    free(o.promise)
    o.promise = nil
}

// Uma reação de Promise ainda não executada (a "microtask"). O que run_reaction
// precisa: os callbacks dos dois lados, a promise derivada, e o estado/valor.
Reaction_Job :: struct {
    mutation_notify: bool,
    microtask: ^Function, // não-nil: callback queueMicrotask, sem promise derivada
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
compact_reaction_queue :: proc(vm: ^Interp, head: int) {
    if head == 0 do return
    remaining := len(vm.reaction_queue) - head
    copy(vm.reaction_queue[:remaining], vm.reaction_queue[head:])
    for &job in vm.reaction_queue[remaining:] do job = {}
    resize(&vm.reaction_queue, remaining)
}

@(private = "file")
drain_reaction_queue :: proc(vm: ^Interp) {
    // Checkpoints indiretos não reentram no drain durante um callback.
    was_draining := vm.draining
    vm.draining = true
    defer vm.draining = was_draining
    processed := 0
    head := 0
    defer compact_reaction_queue(vm, head)
    for head < len(vm.reaction_queue) {
        // Preserve the remaining FIFO for the next host turn.
        if vm_host_turn_expired(vm) do break
        job := vm.reaction_queue[head]
        vm.reaction_queue[head] = {} // consumed jobs must not retain references
        head += 1
        if job.mutation_notify {
            mo_notify(vm)
        } else if job.microtask != nil {
            call_function(vm, job.microtask, nil, nil)
            vm_clear_uncaught(vm) // reporta e limpa; não rejeita uma Promise
        } else {
            run_reaction(vm, job.onf, job.onr, job.next, job.state, job.val)
        }
        // Bound storage for a chain that keeps appending jobs. Moving at most
        // the consumed prefix's size keeps total FIFO maintenance linear.
        if head >= 1024 && head >= len(vm.reaction_queue) - head {
            compact_reaction_queue(vm, head)
            head = 0
        }
        processed += 1
        // guarda contra loop de microtask infinito (ex.: Promise.resolve().then(loop)):
        // step_guard não vê isto (não é laço JS), então checamos o relógio da tarefa.
        if vm.time_budget_ms > 0 && (processed & 0x3FF) == 0 {
            if time.duration_milliseconds(time.tick_since(vm.task_start)) > vm.time_budget_ms {
                clear(&vm.reaction_queue) // abandona a cauda patológica p/ não travar a UI
                head = 0
                break
            }
        }
    }
}

// Fronteira pública de tarefa; nunca reentra por eventos/timers chamados
// durante um callback.
promise_checkpoint :: proc(vm: ^Interp) {
    if vm == nil || vm.draining do return
    saved_throwing, saved_thrown := vm.throwing, vm.thrown
    vm.throwing = false
    vm.thrown = nil
    defer {
        vm.throwing = saved_throwing
        vm.thrown = saved_thrown
    }
    drain_reaction_queue(vm)
}

// Só enfileira (o chamador decide quando drenar — promise_settle enfileira
// TODAS as reações irmãs antes do drain, senão a 1ª drenaria a própria cadeia
// derivada inteira antes de a 2ª entrar: p.then(A); p.then(B) rodaria A,A2,B
// em vez de A,B,A2 como no navegador).
@(private = "file")
schedule_reaction :: proc(vm: ^Interp, onf, onr: Value, next: ^Object, state: f64, val: Value) {
    append(&vm.reaction_queue, Reaction_Job{onf = onf, onr = onr, next = next, state = state, val = val})
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
    // Promise.prototype supplies the inherited then/catch/finally methods.
    // core-js faz `Promise.prototype.finally` no init — sem o prototype,
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
// contador de pendentes e o "kind". Cada entrada e normalizada como Promise;
// seus callbacks entram na mesma fila de microtasks das outras reacoes.

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
    run_combinator_inputs(vm, agg, arg(args, 0), kind)
    if vm.throwing {
        exc := vm.thrown
        vm.throwing = false; vm.thrown = nil
        promise_settle(vm, agg, PROMISE_REJECTED, exc)
    }
    return agg
}

// Consume the iterator incrementally: resolving one input can run getters that
// affect its next step. The sentinel keeps an empty input on the same path.
@(private = "file")
run_combinator_inputs :: proc(vm: ^Interp, agg: ^Object, input: Value, kind: string) {
    if is_nullish(input) { throw_type_error(vm, "Promise combinator requires an iterable"); return }
    method := get_member(vm, input, vm.sym_iterator_key)
    if vm.throwing do return
    fn, callable := method.(^Function)
    if !callable { throw_type_error(vm, "Promise combinator requires an iterable"); return }
    iter := call_function(vm, fn, input, nil)
    if vm.throwing do return
    if is_primitive(iter) { throw_type_error(vm, "Invalid iterator"); return }
    next_value := get_member(vm, iter, "next")
    if vm.throwing do return
    next, next_ok := next_value.(^Function)
    if !next_ok { throw_type_error(vm, "Iterator next is not callable"); return }

    results := new_array(vm)
    st := new_object(vm)
    st.props["agg"] = agg
    st.props["kind"] = kind
    st.props["results"] = results
    st.props["remaining"] = f64(1)
    for i := 0; ; i += 1 {
        if step_guard(vm) do return
        result := call_function(vm, next, iter, nil)
        if vm.throwing do return
        if is_primitive(result) { throw_type_error(vm, "Invalid iterator result"); return }
        done := get_member(vm, result, "done")
        if vm.throwing do return
        if truthy(done) {
            combinator_finish(vm, st)
            return
        }
        value := get_member(vm, result, "value")
        if vm.throwing do return
        append(&results.items, nil)
        st.props["remaining"] = as_number(st.props["remaining"]) + 1
        p := promise_for_await(vm, value)
        onf := mk_input_cb(vm, combinator_on_fulfill, st, i)
        onr := mk_input_cb(vm, combinator_on_reject, st, i)
        promise_then_impl(vm, p, onf, onr)
    }
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
    p.proto = vm.promise_proto
    p.promise = new(Promise_Data)
    return p
}

@(private = "file")
is_promise :: proc(v: Value) -> (^Object, bool) {
    o, ok := v.(^Object)
    if !ok || o.promise == nil do return nil, false
    return o, true
}

// PromiseResolve para await: promises nativas não ganham adoção intermediária;
// o getter de then é síncrono, mas a chamada ao thenable acontece em um job.
promise_for_await :: proc(vm: ^Interp, value: Value) -> ^Object {
    if p, ok := is_promise(value); ok do return p
    p := promise_new(vm)
    promise_resolve_with(vm, p, value)
    return p
}

// Each invocation of a thenable receives a fresh pair. Its first call wins even
// when it adopts a still-pending promise; later throws use that same reject.
@(private = "file")
promise_thenable_job :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    hold := vm.native_bound.(^Object)
    p := hold.props["promise"].(^Object)
    fn := hold.props["then"].(^Function)
    resolve, reject := promise_resolving_functions(vm, p)
    call_function(vm, fn, hold.props["receiver"], []Value{resolve, reject})
    if vm.throwing do promise_reject_exception(vm, reject)
    return nil
}

@(private = "file")
promise_resolving_functions :: proc(vm: ^Interp, p: ^Object) -> (resolve, reject: ^Function) {
    shared := new_object(vm)
    shared.props["promise"] = p
    shared.props["resolved"] = false
    // CreateResolvingFunctions (spec 27.2.1.3): anônimas, length 1, NÃO construtoras —
    // o código que recebe as duas (executor de `new Promise`, um `then` de thenable)
    // pode inspecioná-las. `new resolve()` lançava nada; Test262 finally/*-argument.
    resolve = new_function(vm)
    resolve.native = native_promise_resolve_bound
    resolve.bound = shared
    resolve.native_length = 1
    resolve.non_constructor = true
    reject = new_function(vm)
    reject.native = native_promise_reject_bound
    reject.bound = shared
    reject.native_length = 1
    reject.non_constructor = true
    return
}

@(private = "file")
promise_reject_exception :: proc(vm: ^Interp, reject: ^Function) {
    exc := vm.thrown
    vm.throwing = false; vm.thrown = nil
    call_function(vm, reject, nil, []Value{exc})
}

// Assenta a promise (idempotente) e dispara as reações pendentes — TODAS
// enfileiradas antes do drain, p/ interleaving igual ao do navegador.
promise_settle :: proc(vm: ^Interp, p: ^Object, state: f64, val: Value) {
    data := p.promise
    if data.state != PROMISE_PENDING do return
    data.state = state
    data.value = val
    for r in data.reactions {
        schedule_reaction(vm, r.onf, r.onr, r.next, state, val)
    }
    clear(&data.reactions)
}

// Cumpre a promise com `v` — a menos que `v` seja outra promise (ADOTA: assenta
// junto com ela) ou um THENABLE (objeto com .then chamável: adota via protocolo,
// como axios-likes e polyfills esperam).
promise_resolve_with :: proc(vm: ^Interp, p: ^Object, v: Value) {
    if p.promise.state != PROMISE_PENDING do return
    if inner, ok := v.(^Object); ok && inner == p {
        promise_settle(vm, p, PROMISE_REJECTED, mk_error(vm, "TypeError", "Chaining cycle detected for promise"))
        return
    }
    if !is_primitive(v) {
        then := get_member(vm, v, "then")
        if vm.throwing {
            exc := vm.thrown
            vm.throwing = false; vm.thrown = nil
            promise_settle(vm, p, PROMISE_REJECTED, exc)
            return
        }
        if fn, callable := then.(^Function); callable {
            hold := new_object(vm)
            hold.props["promise"] = p
            hold.props["receiver"] = v
            hold.props["then"] = fn
            job := new_function(vm)
            job.native = promise_thenable_job
            job.bound = hold
            append(&vm.reaction_queue, Reaction_Job{microtask = job})
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

// Núcleo do then/catch: registra (pendente) ou enfileira (já assentada).
// Visível no pacote: a corrotina async (generator.odin) encadeia a retomada aqui.
promise_then_impl :: proc(vm: ^Interp, p: ^Object, onf, onr: Value) -> Value {
    next := promise_new(vm)
    data := p.promise
    if data.state == PROMISE_PENDING {
        append(&data.reactions, Promise_Reaction{onf = onf, onr = onr, next = next})
    } else {
        schedule_reaction(vm, onf, onr, next, data.state, data.value)
    }
    return next
}

// ── nativas ─────────────────────────────────────────────────────────────────

@(private = "file")
native_promise_then :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    p, ok := is_promise(this)
    if !ok {
        throw_type_error(vm, "Promise.prototype.then requires a Promise")
        return nil
    }
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

// Promise.prototype.finally (spec 27.2.5.3). Tudo que a spec faz por Invoke(_, "then")
// é OBSERVÁVEL e tem de passar pelo `then` que o objeto tiver — inclusive um
// Promise.prototype.then sobrescrito. Antes, o finally usava o then INTERNO e, no
// thenFinally, devolvia a promise do cleanup para a promise derivada adotar; com o
// `then` agora herdado (314ae3d), o Test262 finally/*-observable-then-calls-argument
// passou a ver funções com length/name errados. As funções que o finally cria são
// anônimas, não construtoras: thenFinally/catchFinally (length 1), valueThunk/thrower
// (length 0).
@(private = "file")
native_promise_finally :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if is_primitive(this) {
        throw_type_error(vm, "Promise.prototype.finally called on a non-object")
        return nil
    }
    on_finally := arg(args, 0)
    then_args: []Value
    if cb, cok := on_finally.(^Function); cok {
        onf := finally_fn(vm, finally_on_fulfilled, 1, cb)
        onr := finally_fn(vm, finally_on_rejected, 1, cb)
        then_args = []Value{onf, onr}
    } else {
        then_args = []Value{on_finally, on_finally} // não chamável: passa adiante como está
    }
    return finally_invoke_then(vm, this, then_args)
}

// Função anônima e não construtora, como as que a spec cria com CreateBuiltinFunction.
@(private = "file")
finally_fn :: proc(vm: ^Interp, native: Native_Fn, length: int, bound: Value) -> ^Function {
    f := new_function(vm)
    f.native = native
    f.native_length = length
    f.non_constructor = true
    f.bound = bound
    return f
}

// Invoke(target, "then", args).
@(private = "file")
finally_invoke_then :: proc(vm: ^Interp, target: Value, args: []Value) -> Value {
    then_v := get_member(vm, target, "then")
    if vm.throwing do return nil
    then_fn, ok := then_v.(^Function)
    if !ok {
        throw_type_error(vm, "then is not a function")
        return nil
    }
    return call_function(vm, then_fn, target, args)
}

@(private = "file")
finally_on_fulfilled :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return finally_wait(vm, arg(args, 0), false)
}

@(private = "file")
finally_on_rejected :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return finally_wait(vm, arg(args, 0), true)
}

// thenFinally/catchFinally: chama onFinally, PromiseResolve(resultado) e devolve
// `promise.then(valueThunk)` / `promise.then(thrower)` — por Invoke, com UM argumento.
@(private = "file")
finally_wait :: proc(vm: ^Interp, value: Value, rejected: bool) -> Value {
    cb := vm.native_bound.(^Function)
    result := call_function(vm, cb, nil, nil)
    if vm.throwing do return nil
    cleanup := promise_for_await(vm, result)
    hold := new_object(vm)
    hold.props["value"] = value
    hold.props["rejected"] = rejected
    thunk := finally_fn(vm, finally_resume, 0, hold)
    return finally_invoke_then(vm, cleanup, []Value{thunk})
}

// valueThunk (devolve o valor original) ou thrower (relança o motivo original).
@(private = "file")
finally_resume :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    hold := vm.native_bound.(^Object)
    value := hold.props["value"]
    if hold.props["rejected"].(bool) {
        vm.thrown = value
        vm.throwing = true
        return nil
    }
    return value
}

// new Promise(function(resolve, reject) { ... })
@(private = "file")
native_promise_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    executor, ok := arg(args, 0).(^Function)
    if !ok {
        vm.thrown = mk_error(vm, "TypeError", "Promise executor must be callable")
        vm.throwing = true
        return nil
    }
    p := promise_new(vm)

    resolve_fn, reject_fn := promise_resolving_functions(vm, p)

    call_function(vm, executor, nil, []Value{resolve_fn, reject_fn})
    if vm.throwing do promise_reject_exception(vm, reject_fn)
    return p
}

@(private = "file")
native_promise_resolve_bound :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    shared := vm.native_bound.(^Object)
    if truthy(shared.props["resolved"]) do return nil
    shared.props["resolved"] = true
    promise_resolve_with(vm, shared.props["promise"].(^Object), arg(args, 0))
    return nil
}

@(private = "file")
native_promise_reject_bound :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    shared := vm.native_bound.(^Object)
    if truthy(shared.props["resolved"]) do return nil
    shared.props["resolved"] = true
    promise_settle(vm, shared.props["promise"].(^Object), PROMISE_REJECTED, arg(args, 0))
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
    resolve_fn, reject_fn := promise_resolving_functions(vm, p)
    o := new_object(vm)
    oput(o, "promise", p)
    oput(o, "resolve", resolve_fn)
    oput(o, "reject", reject_fn)
    return o
}

@(private = "file")
native_promise_resolve_static :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    value := arg(args, 0)
    if p, ok := is_promise(value); ok {
        ctor := get_member(vm, p, "constructor")
        if vm.throwing do return nil
        if ctor == this do return p
    }
    p := promise_new(vm)
    promise_resolve_with(vm, p, value)
    return p
}

@(private = "file")
native_promise_reject_static :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    p := promise_new(vm)
    promise_settle(vm, p, PROMISE_REJECTED, len(args) >= 1 ? args[0] : nil)
    return p
}
