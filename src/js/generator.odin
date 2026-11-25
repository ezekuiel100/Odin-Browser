package js

// All resumable executions use heap-owned continuation frames on the caller's
// thread. Await resumes through Promise jobs; suspension retains no native stack.
Gen_Inject :: enum { None, Return, Throw }
Async_Gen_Request :: struct { value: Value, kind: Gen_Inject, promise: ^Object }
Generator :: struct {
    vm: ^Interp,
    program: ^Node,
    program_env: ^Env,
    module: ^Module,
    program_result: Value,
    fn: ^Function,
    this: Value,
    args: []Value,
    obj: ^Object,
    frames: [dynamic]Exec_Frame,
    result: Value,
    reference: Target_Ref,
    suspended: bool,
    transfer: Value,
    inject: Gen_Inject,
    inject_val: Value,
    is_async, awaiting, async_busy, is_async_fn: bool,
    requests: [dynamic]Async_Gen_Request,
    async_promise: Value,
    started, running, done: bool,
    frame: Stack_Frame,
    script: ^Script_Src,
    pos: u32,
}

make_generator :: proc(vm: ^Interp, fn: ^Function, this: Value, args: []Value) -> Value {
    o := new_object(vm)
    g := new(Generator)
    g.vm, g.fn, g.module, g.this = vm, fn, vm.current_module, this
    g.args = make([]Value, len(args))
    copy(g.args, args)
    g.is_async, g.obj, o.gen = fn.is_async, o, g
    if g.is_async {
        o.props["next"], o.props["return"], o.props["throw"] = vm.async_gen_next_fn, vm.async_gen_return_fn, vm.async_gen_throw_fn
        if vm.sym_async_iterator_key != "" do o.props[vm.sym_async_iterator_key] = vm.gen_iter_fn
    } else {
        o.props["next"], o.props["return"], o.props["throw"] = vm.gen_next_fn, vm.gen_return_fn, vm.gen_throw_fn
        if vm.sym_iterator_key != "" do o.props[vm.sym_iterator_key] = vm.gen_iter_fn
    }
    append(&vm.all_generators, g)
    return o
}

make_iter_result :: proc(vm: ^Interp, value: Value, done: bool) -> ^Object {
    r := new_object(vm)
    r.props["value"], r.props["done"] = value, done
    return r
}

// A suspension must be intercepted by a continuation before reaching native eval.
generator_yield :: proc(vm: ^Interp, val: Value) -> Value {
    throw_type_error(vm, "Suspension requires an execution frame")
    return nil
}

gen_resume :: proc(vm: ^Interp, g: ^Generator, val: Value, kind: Gen_Inject) -> Value {
    if g.running { throw_type_error(vm, "Generator is already running"); return nil }
    if g.done || !g.started && kind != .None {
        g.done = true
        exec_dispose(g)
        g.frame = {}
        if kind == .Throw { vm.throwing = true; vm.thrown = val; return nil }
        return make_iter_result(vm, val if kind == .Return else nil, true)
    }
    stack_probe: int
    if vm.call_depth >= vm.call_depth_limit || stack_near_limit(vm, uintptr(&stack_probe)) {
        vm.throwing = true
        vm.thrown = mk_error(vm, "RangeError", "Maximum call stack size exceeded")
        return nil
    }
    env_escaped(vm)
    saved_gen, saved_module := vm.current_gen, vm.current_module
    saved_short, saved_depth := vm.opt_short, vm.call_depth
    saved_frame, saved_script, saved_pos := vm.frame, vm.cur_script, vm.cur_pos
    saved_signal := exec_signal(vm)
    exec_clear_signal(vm)
    vm.current_gen, vm.current_module = g, g.module
    vm.opt_short = false
    vm.call_depth += 1
    g.running = true
    if !g.started do g.script = g.fn.script if g.fn != nil else vm.cur_script
    if g.fn != nil {
        g.frame = Stack_Frame{parent = saved_frame, fn = g.fn, call_pos = saved_pos, call_script = saved_script}
        vm.frame = &g.frame
    } else { vm.frame = nil }
    vm.cur_script, vm.cur_pos = g.script, g.pos
    if !g.started {
        g.started = true
        if g.program != nil { exec_push(g, g.program, g.program_env) }
        else {
            scope := setup_call_scope(vm, g.fn, g.this, g.args)
            if g.fn.body != nil {
                append(&g.frames, Exec_Frame{mode = .Body, node = g.fn.body, env = scope})
            }
        }
    } else { g.inject, g.inject_val = kind, val }
    exec_run(vm, g)
    g.running = false
    g.pos = vm.cur_pos
    outcome := exec_signal(vm)
    if !g.suspended {
        g.done = true
        if outcome.throwing { g.transfer = nil }
        else if outcome.returning { g.transfer = outcome.returned }
        else if g.program != nil { g.transfer = g.result }
        else { g.transfer = nil }
        exec_dispose(g)
    }
    vm.frame, vm.cur_script, vm.cur_pos = saved_frame, saved_script, saved_pos
    g.frame.parent = nil
    if g.done do g.frame = {}
    vm.current_gen, vm.current_module = saved_gen, saved_module
    vm.opt_short, vm.call_depth = saved_short, saved_depth
    exec_restore_signal(vm, saved_signal)
    if outcome.throwing { vm.throwing = true; vm.thrown = outcome.thrown; return nil }
    return make_iter_result(vm, g.transfer, g.done)
}

@(private = "file")
gen_of :: proc(this: Value) -> ^Generator {
    o, ok := this.(^Object)
    if !ok do return nil
    return o.gen
}

@(private = "file")
native_gen_next :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    g := gen_of(this)
    if g == nil do return make_iter_result(vm, nil, true)
    sent: Value = args[0] if len(args) >= 1 else nil
    return gen_resume(vm, g, sent, .None)
}

@(private = "file")
native_gen_return :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    g := gen_of(this)
    v: Value = args[0] if len(args) >= 1 else nil
    if g == nil do return make_iter_result(vm, v, true)
    return gen_resume(vm, g, v, .Return)
}

@(private = "file")
native_gen_throw :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    g := gen_of(this)
    v: Value = args[0] if len(args) >= 1 else nil
    if g == nil {
        vm.throwing = true
        vm.thrown = v
        return nil
    }
    return gen_resume(vm, g, v, .Throw)
}

@(private = "file")
native_gen_iter :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return this // um generator é o seu próprio iterador
}

// ── async generators (async function*) ───────────────────────────────────────
//
// Cada pedido conserva sua Promise até yield/fim. Await apenas suspende o
// corpo: a reação de Promise retoma o mesmo pedido, sem bombear timers.
async_gen_enqueue :: proc(vm: ^Interp, g: ^Generator, value: Value, kind: Gen_Inject) -> Value {
    p := promise_new(vm)
    if g == nil {
        promise_settle(vm, p, PROMISE_REJECTED, mk_error(vm, "TypeError", "Invalid async generator receiver"))
        return p
    }
    append(&g.requests, Async_Gen_Request{value = value, kind = kind, promise = p})
    async_gen_drain(vm, g)
    return p
}

async_gen_drain :: proc(vm: ^Interp, g: ^Generator) {
    if g.async_busy || len(g.requests) == 0 do return
    g.async_busy = true
    req := g.requests[0]
    async_gen_step(vm, g, req.value, req.kind)
}

async_gen_finish :: proc(vm: ^Interp, g: ^Generator, value: Value, rejected: bool) {
    req := g.requests[0]
    ordered_remove(&g.requests, 0)
    if rejected {
        promise_settle(vm, req.promise, PROMISE_REJECTED, value)
    } else {
        promise_resolve_with(vm, req.promise, value)
    }
    // Desenrola a pilha antes do pedido seguinte (inclusive milhares de throws
    // enfileirados enquanto o corpo estava suspenso).
    if len(g.requests) > 0 {
        hold := new_object(vm)
        hold.gen = g
        job := new_function(vm)
        job.native = async_gen_next_request
        job.bound = hold
        append(&vm.reaction_queue, Reaction_Job{microtask = job})
    } else {
        g.async_busy = false
    }
}

async_gen_next_request :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if g := async_gen_from_bound(vm); g != nil {
        g.async_busy = false
        async_gen_drain(vm, g)
    }
    return nil
}

async_gen_step :: proc(vm: ^Interp, g: ^Generator, value: Value, kind: Gen_Inject) {
    result := gen_resume(vm, g, value, kind)
    if vm.throwing {
        exc := vm.thrown
        vm.throwing = false; vm.thrown = nil
        async_gen_finish(vm, g, exc, true)
        return
    }
    ro := result.(^Object)
    if g.awaiting && !g.done {
        async_wait(vm, g, ro.props["value"], async_resume_ok, async_resume_err)
    } else if g.done {
        // AsyncGenerator return awaita o valor antes de concluir o pedido.
        async_wait(vm, g, ro.props["value"], async_gen_done_ok, async_gen_done_err)
    } else {
        async_gen_finish(vm, g, result, false)
    }
}

async_gen_done_ok :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if g := async_gen_from_bound(vm); g != nil {
        async_gen_finish(vm, g, make_iter_result(vm, arg(args, 0), true), false)
    }
    return nil
}

async_gen_done_err :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if g := async_gen_from_bound(vm); g != nil do async_gen_finish(vm, g, arg(args, 0), true)
    return nil
}

@(private = "file")
native_async_gen_next :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return async_gen_enqueue(vm, gen_of(this), arg(args, 0), .None)
}

@(private = "file")
native_async_gen_return :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return async_gen_enqueue(vm, gen_of(this), arg(args, 0), .Return)
}

@(private = "file")
native_async_gen_throw :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return async_gen_enqueue(vm, gen_of(this), arg(args, 0), .Throw)
}

install_generator :: proc(vm: ^Interp) {
    vm.gen_next_fn   = mk_native(vm, native_gen_next)
    vm.gen_next_fn.name = "next"
    vm.gen_return_fn = mk_native(vm, native_gen_return)
    vm.gen_return_fn.name = "return"
    vm.gen_throw_fn  = mk_native(vm, native_gen_throw)
    vm.gen_throw_fn.name = "throw"
    vm.gen_iter_fn   = mk_native(vm, native_gen_iter)
    vm.gen_iter_fn.name = "[Symbol.iterator]"
    vm.async_gen_next_fn   = mk_native(vm, native_async_gen_next)
    vm.async_gen_next_fn.name = "next"
    vm.async_gen_return_fn = mk_native(vm, native_async_gen_return)
    vm.async_gen_return_fn.name = "return"
    vm.async_gen_throw_fn  = mk_native(vm, native_async_gen_throw)
    vm.async_gen_throw_fn.name = "throw"
}

// ── limpeza (vm_destroy) ─────────────────────────────────────────────────────

// Discard saved frames without executing user catch/finally blocks.
cleanup_generators :: proc(vm: ^Interp) {
    for g in vm.all_generators {
        exec_dispose(g)
        delete(g.requests)
        free(g)
    }
    delete(vm.all_generators)
}

// ── async function como CORROTINA (M130) ─────────────────────────────────────
//
// Async bodies execute synchronously until await. Promise reactions schedule
// subsequent resumes, retaining the continuation through their bound holder.
async_call :: proc(vm: ^Interp, fn: ^Function, this: Value, args: []Value) -> Value {
    o := new_object(vm)
    g := new(Generator)
    g.vm = vm
    g.fn = fn
    g.module = vm.current_module
    g.this = this
    g.args = make([]Value, len(args))
    copy(g.args, args)
    g.is_async_fn = true
    g.obj = o
    o.gen = g
    append(&vm.all_generators, g)

    p := promise_new(vm)
    g.async_promise = p
    async_step(vm, g, nil, .None)
    return p
}

// Um passo da corrotina: retoma o corpo, e trata o que ele devolveu — terminou
// (assenta a promise) ou parou num await (encadeia a retomada).
@(private = "file")
async_step :: proc(vm: ^Interp, g: ^Generator, val: Value, kind: Gen_Inject) {
    r := gen_resume(vm, g, val, kind)
    pr, _ := g.async_promise.(^Object)

    if vm.throwing { // exceção que escapou do corpo → Promise REJEITADA
        vm_note_rejection(vm, vm.thrown) // senão o erro some (ver rejected_log)
        exc := vm.thrown
        vm.throwing = false
        vm.thrown = nil
        if pr != nil do promise_settle(vm, pr, PROMISE_REJECTED, exc)
        return
    }
    ro, rok := r.(^Object)
    if !rok do return
    if truthy(ro.props["done"]) { // corpo terminou → Promise CUMPRIDA
        if pr != nil do promise_resolve_with(vm, pr, ro.props["value"])
        return
    }

    // parou num await: encadeia a retomada no valor awaitado. Envolver com
    // promise_resolve_with normaliza não-promise/thenable — assim `await 1`
    // também retoma por microtask, como na spec.
    async_wait(vm, g, ro.props["value"], async_resume_ok, async_resume_err)
}

// Mesmo mecanismo de retomada para funções e geradores assíncronos.
async_wait :: proc(vm: ^Interp, g: ^Generator, value: Value, onf, onr: Native_Fn) {
    // Promise nativa: anexa diretamente. Uma adoção intermediária acrescenta
    // um job e troca a ordem entre a continuação de await e queueMicrotask.
    awaited := promise_for_await(vm, value)
    hold := new_object(vm)
    hold.gen = g // o passo seguinte precisa do MESMO generator

    on_ok := new_function(vm)
    on_ok.native = onf
    on_ok.name = "asyncResume"
    on_ok.bound = hold

    on_err := new_function(vm)
    on_err.native = onr
    on_err.name = "asyncResumeErr"
    on_err.bound = hold

    promise_then_impl(vm, awaited, on_ok, on_err)
}

@(private = "file")
async_gen_from_bound :: proc(vm: ^Interp) -> ^Generator {
    h, ok := vm.native_bound.(^Object)
    if !ok do return nil
    return h.gen
}

@(private = "file")
async_resume_ok :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if g := async_gen_from_bound(vm); g != nil {
        if g.program != nil { program_step(vm, g, arg(args, 0), .None); return nil }
        if g.is_async_fn { async_step(vm, g, arg(args, 0), .None) }
        else { async_gen_step(vm, g, arg(args, 0), .None) }
    }
    return nil
}

@(private = "file")
async_resume_err :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    // rejeição vira `throw` DENTRO do corpo, no ponto do await (capturável).
    if g := async_gen_from_bound(vm); g != nil {
        if g.program != nil { program_step(vm, g, arg(args, 0), .Throw); return nil }
        if g.is_async_fn { async_step(vm, g, arg(args, 0), .Throw) }
        else { async_gen_step(vm, g, arg(args, 0), .Throw) }
    }
    return nil
}

// A program retains its original environment: top-level var/let are not
// moved into a synthetic function scope. A suspended execution returns a Promise.
program_call :: proc(vm: ^Interp, program: ^Node, env: ^Env) -> Value {
    g := new(Generator)
    g.vm = vm
    g.program = program
    g.program_env = env
    g.module = vm.current_module
    g.is_async_fn = true
    if g.module != nil {
        g.async_promise = g.module.evaluation
    } else {
        g.async_promise = promise_new(vm)
    }
    append(&vm.all_generators, g)
    program_step(vm, g, nil, .None, true)
    if g.done do return g.program_result
    return g.async_promise
}

program_step :: proc(vm: ^Interp, g: ^Generator, value: Value, kind: Gen_Inject, initial := false) {
    result := gen_resume(vm, g, value, kind)
    p := g.async_promise.(^Object)
    if vm.throwing {
        exc := vm.thrown
        vm.throwing = false; vm.thrown = nil
        if g.module != nil {
            g.module.state = .Failed
            g.module.error = exc
        } else if !initial {
            vm_note_rejection(vm, exc)
        }
        promise_settle(vm, p, PROMISE_REJECTED, exc)
        if initial { vm.throwing = true; vm.thrown = exc }
        return
    }
    ro := result.(^Object)
    if g.done {
        g.program_result = completion_value(ro.props["value"]) // conclusão vazia → undefined
        if g.module != nil {
            module_snapshot_exports(vm, g.module)
            g.module.state = .Done
            promise_settle(vm, p, PROMISE_FULFILLED, g.module.ns)
        } else {
            // A completion value is not an async function return: do not adopt
            // a Promise used merely as the final expression of the script.
            promise_settle(vm, p, PROMISE_FULFILLED, g.program_result)
        }
    } else {
        async_wait(vm, g, ro.props["value"], async_resume_ok, async_resume_err)
    }
}
