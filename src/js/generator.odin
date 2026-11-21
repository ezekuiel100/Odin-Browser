package js

// Generators (function* / yield). Um tree-walker NÃO consegue suspender a pilha
// nativa do Odin no meio de um laço/try — então cada generator roda o seu corpo
// numa THREAD própria e a troca de controle é um PING-PONG por semáforos:
//
//   consumidor (.next())          generator (thread própria)
//   ───────────────────           ──────────────────────────
//   post(resume); wait(yielded) ─▶ corpo roda até `yield e`
//                               ◀─ transfer=e; post(yielded); wait(resume)
//   lê transfer/done
//
// SÓ UMA das duas threads roda por vez (o par de semáforos garante alternância
// estrita), então NÃO há concorrência real sobre o vm — as duas compartilham
// todas as estruturas com segurança. O "contexto de execução" que É por-pilha
// (vm.call_depth e vm.stack_low — a guarda de stack nativa) é salvo/restaurado a
// cada troca em gen_resume, pois cada thread tem a sua própria pilha nativa.
//
// Um generator deixado suspenso mantém a thread viva até vm_destroy.
// Async generators serializam pedidos e retomam awaits pela fila de microtasks.

import "core:thread"
import "core:sync"
import "core:time"
import "base:runtime"

// O que injetar ao retomar um generator suspenso num `yield`.
Gen_Inject :: enum {
    None,      // next(v): retoma normal, yield devolve v
    Return,    // return(v): yield vira `return v` (roda finally)
    Throw,     // throw(e): yield vira `throw e` (capturável no corpo)
    Terminate, // vm_destroy: desenrola o corpo SEM rodar mais JS (gen_hard_kill)
}

Async_Gen_Request :: struct {
    value: Value,
    kind: Gen_Inject,
    promise: ^Object,
}

Generator :: struct {
    vm:      ^Interp,
    program: ^Node,
    program_env: ^Env,
    module: ^Module,
    program_result: Value,
    fn:      ^Function,  // a função generator (corpo a rodar)
    this:    Value,
    args:    []Value,    // clonados (posse do Generator)
    obj:     ^Object,    // o objeto generator exposto ao JS (tem .gen = este)
    alloc:   runtime.Allocator, // alocador do vm; a thread do generator o adota

    thread:  ^thread.Thread,
    resume:  sync.Sema,  // consumidor -> generator (retomar)
    yielded: sync.Sema,  // generator -> consumidor (parou num yield / terminou)

    transfer: Value,     // valor cruzando a fronteira (yield out / next(v) in / return)
    inject:   Gen_Inject,// pedido do consumidor ao retomar
    inject_val: Value,

    is_async: bool,      // async function*: next/return/throw devolvem Promise e yield awaita o valor
    // async FUNCTION comum rodando como CORROTINA: o corpo vive nesta thread e cada
    // `await` suspende (generator_yield) em vez de bloquear. `async_promise` é a
    // Promise devolvida ao chamador, assentada quando o corpo termina. Ver
    // async_call/async_step — M130.
    awaiting: bool, // último ponto de suspensão foi await, e não yield
    async_busy: bool,
    requests: [dynamic]Async_Gen_Request, // next/return/throw em FIFO
    is_async_fn:   bool,
    async_promise: Value,
    started: bool,       // a thread já foi criada? (1ª next inicia o corpo)
    running: bool,       // o corpo está RODANDO agora? (next reentrante = deadlock dos semáforos)
    done:    bool,       // o corpo terminou (return/fim/exceção)?
    has_thrown_out: bool,// o corpo lançou uma exceção não capturada?
    thrown_out: Value,   // a exceção que escapou (propaga ao chamador de next)

    // contexto de execução por-pilha, salvo entre trocas (a thread tem outra pilha)
    depth:     int,
    stack_low: uintptr,
    // Error.stack: o corpo é um frame (cujo pai é QUEM retomou — o chamador na 1ª
    // vez, o executor de microtasks depois) e lembra onde parou no próprio fonte.
    frame:  Stack_Frame,
    script: ^Script_Src,
    pos:    u32,
}

// ── criação ──────────────────────────────────────────────────────────────────

// Chamar uma função generator NÃO roda o corpo: devolve um objeto generator
// (iterável — tem next/return/throw + Symbol.iterator). O corpo só roda em .next().
make_generator :: proc(vm: ^Interp, fn: ^Function, this: Value, args: []Value) -> Value {
    o := new_object(vm)
    g := new(Generator)
    g.vm = vm
    g.fn = fn
    g.module = vm.current_module
    g.this = this
    g.args = make([]Value, len(args))
    copy(g.args, args)
    g.alloc = context.allocator
    g.is_async = fn.is_async
    g.obj = o
    o.gen = g
    // métodos do iterador (compartilhados; instalados em install_generator).
    // Async generator: next/return/throw devolvem Promise<{value,done}> e o objeto
    // é ASYNC-iterável (Symbol.asyncIterator, não Symbol.iterator — não é síncrono).
    if g.is_async {
        o.props["next"]   = vm.async_gen_next_fn
        o.props["return"] = vm.async_gen_return_fn
        o.props["throw"]  = vm.async_gen_throw_fn
        if vm.sym_async_iterator_key != "" do o.props[vm.sym_async_iterator_key] = vm.gen_iter_fn
    } else {
        o.props["next"]   = vm.gen_next_fn
        o.props["return"] = vm.gen_return_fn
        o.props["throw"]  = vm.gen_throw_fn
        if vm.sym_iterator_key != "" do o.props[vm.sym_iterator_key] = vm.gen_iter_fn
    }
    append(&vm.all_generators, g)
    return o
}

@(private = "file")
make_iter_result :: proc(vm: ^Interp, value: Value, done: bool) -> ^Object {
    r := new_object(vm)
    r.props["value"] = value
    r.props["done"] = done
    return r
}

// ── a thread do generator ────────────────────────────────────────────────────

@(private = "file")
gen_thread_proc :: proc(g: ^Generator) {
    context.allocator = g.alloc // aloca objetos/escopos do vm no alocador do vm
    sync.sema_wait(&g.resume)   // espera a 1ª next()
    vm := g.vm
    // esta thread tem a SUA pilha nativa: registra o limite p/ a guarda de stack
    vm.stack_low = stack_low_limit()
    g.stack_low = vm.stack_low

    run_generator_body(vm, g) // roda o corpo até terminar (definido em interp.odin)

    // o corpo terminou — traduz o sinal pendente no estado final do generator
    if vm.gen_hard_kill {
        vm.gen_hard_kill = false // terminado pelo vm_destroy: não propaga nada
        vm.throwing = false; vm.thrown = nil
    } else if vm.throwing {
        g.has_thrown_out = true
        g.thrown_out = vm.thrown
        vm.throwing = false; vm.thrown = nil
    } else if vm.returning {
        g.transfer = vm.ret_val
        vm.returning = false; vm.ret_val = nil
    } else {
        g.transfer = nil // caiu do fim → return undefined
    }
    vm.breaking = false; vm.continuing = false
    g.done = true
    sync.sema_post(&g.yielded) // devolve o controle ao consumidor (pela última vez)
}

// ── yield (roda NA thread do generator) ──────────────────────────────────────

// Entrega `val` ao consumidor e bloqueia até o próximo next()/return()/throw().
// Devolve o valor passado a next(v). Chamado pelo eval de .Yield (interp.odin).
generator_yield :: proc(vm: ^Interp, val: Value) -> Value {
    g := vm.current_gen
    if g == nil do return nil // yield fora de generator (não deveria ocorrer)
    g.transfer = val
    g.done = false
    sync.sema_post(&g.yielded) // -> consumidor
    sync.sema_wait(&g.resume)  // <- retomado por next/return/throw

    switch g.inject {
    case .Return:
        g.inject = .None
        vm.returning = true
        vm.ret_val = g.inject_val
        return nil
    case .Throw:
        g.inject = .None
        vm.throwing = true
        vm.thrown = g.inject_val
        return nil
    case .Terminate:
        // vm_destroy: desenrola sem rodar mais JS (o eval bail em gen_hard_kill)
        vm.gen_hard_kill = true
        vm.throwing = true
        vm.thrown = nil
        return nil
    case .None:
        return g.transfer // valor de next(v)
    }
    return nil
}

// ── retomada (roda NA thread do consumidor) ──────────────────────────────────

// Passa o controle ao generator com um pedido (next/return/throw) e espera ele
// parar de novo (num yield) ou terminar. Devolve o {value, done} resultante, ou
// propaga (via vm.throwing) a exceção que escapou do corpo.
@(private = "file")
gen_resume :: proc(vm: ^Interp, g: ^Generator, val: Value, kind: Gen_Inject) -> Value {
    if g.running {
        // next()/return()/throw() de DENTRO do próprio corpo: sem esta guarda o
        // post(resume)+wait(yielded) na própria thread deadlockaria os semáforos
        // p/ sempre (e o watchdog não salva — é bloqueio nativo, não laço JS).
        vm.throwing = true
        vm.thrown = mk_error(vm, "TypeError", "Generator is already running")
        return nil
    }
    if g.done {
        if kind == .Throw {
            vm.throwing = true
            vm.thrown = val
            return nil
        }
        rv: Value = val if kind == .Return else nil
        return make_iter_result(vm, rv, true)
    }
    if !g.started {
        // return()/throw() ANTES de iniciar: conclui sem nunca rodar o corpo
        if kind == .Return {
            g.done = true
            return make_iter_result(vm, val, true)
        }
        if kind == .Throw {
            g.done = true
            vm.throwing = true
            vm.thrown = val
            return nil
        }
        g.started = true
        g.script = g.fn != nil ? g.fn.script : vm.cur_script // program_call: o próprio fonte
        g.transfer = val // (1ª next: descartado — o corpo roda do início)
        g.thread = thread.create_and_start_with_poly_data(g, gen_thread_proc, self_cleanup = false)
    } else {
        g.transfer = val   // next(v): valor de retorno do yield
        g.inject_val = val // return(v)/throw(e): valor injetado (lido por generator_yield)
        g.inject = kind
    }

    // A thread do generator tem a SUA pilha de escopos, que continua viva entre um
    // next() e o seguinte (o corpo está suspenso num yield/await). Esses escopos
    // nascem intercalados com os da thread principal em vm.all_envs, então marcamos
    // escape: nenhuma chamada que retome um generator pode reciclar seu intervalo.
    env_escaped(vm)

    // troca o contexto de execução por-pilha p/ o do generator e entrega o controle
    saved_gen := vm.current_gen
    saved_module := vm.current_module
    saved_short := vm.opt_short
    saved_depth := vm.call_depth
    saved_low := vm.stack_low
    saved_frame, saved_script, saved_pos := vm.frame, vm.cur_script, vm.cur_pos
    if g.fn != nil { // programa (await de topo) não é frame: é o fundo da pilha
        g.frame = Stack_Frame{parent = vm.frame, fn = g.fn, call_pos = vm.cur_pos, call_script = vm.cur_script}
        vm.frame = &g.frame
    } else {
        vm.frame = nil
    }
    vm.cur_script = g.script
    vm.cur_pos = g.pos
    vm.current_gen = g
    vm.current_module = g.module
    vm.opt_short = false
    vm.call_depth = g.depth
    vm.stack_low = g.stack_low

    g.awaiting = false
    g.running = true
    sync.sema_post(&g.resume)  // -> generator
    sync.sema_wait(&g.yielded) // <- generator parou de novo / terminou
    g.running = false

    g.depth = vm.call_depth      // salva o progresso da pilha do generator
    g.stack_low = vm.stack_low
    g.pos = vm.cur_pos
    vm.frame, vm.cur_script, vm.cur_pos = saved_frame, saved_script, saved_pos
    vm.current_gen = saved_gen
    vm.current_module = saved_module
    vm.opt_short = saved_short
    vm.call_depth = saved_depth
    vm.stack_low = saved_low

    if g.has_thrown_out {
        g.has_thrown_out = false
        exc := g.thrown_out
        g.thrown_out = nil
        gen_join(g)
        vm.throwing = true
        vm.thrown = exc
        return nil
    }
    if g.done {
        rv := g.transfer
        gen_join(g)
        return make_iter_result(vm, rv, true)
    }
    return make_iter_result(vm, g.transfer, false)
}

// Junta e destrói a thread já terminada (idempotente).
@(private = "file")
gen_join :: proc(g: ^Generator) {
    if g.thread != nil {
        thread.join(g.thread)
        thread.destroy(g.thread)
        g.thread = nil
    }
}

// ── métodos do objeto generator (nativas) ────────────────────────────────────

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
        hold.host = rawptr(g)
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

// Threads de generators deixados suspensos ficam bloqueadas em wait(resume). Para
// encerrá-las: injeta Terminate e retoma — o `yield` seta gen_hard_kill e o corpo
// desenrola sem rodar mais JS (try/catch/finally são pulados), a thread retorna.
// Ordem REVERSA (mais novos primeiro) p/ desfazer generators aninhados de dentro
// p/ fora. wait com timeout evita travar o fechamento se algo não cooperar.
cleanup_generators :: proc(vm: ^Interp) {
    #reverse for g in vm.all_generators {
        if g.started && !g.done && g.thread != nil {
            g.inject = .Terminate
            saved_gen := vm.current_gen
            saved_depth := vm.call_depth
            saved_low := vm.stack_low
            vm.current_gen = g
            vm.call_depth = g.depth
            vm.stack_low = g.stack_low
            sync.sema_post(&g.resume)
            if sync.sema_wait_with_timeout(&g.yielded, 2 * time.Second) {
                gen_join(g)
            }
            // (se deu timeout, a thread ficou presa — abandona; o processo segue)
            vm.current_gen = saved_gen
            vm.call_depth = saved_depth
            vm.stack_low = saved_low
        } else {
            gen_join(g)
        }
        delete(g.requests)
        delete(g.args)
        free(g)
    }
    delete(vm.all_generators)
}

// ── async function como CORROTINA (M130) ─────────────────────────────────────
//
// Antes, `await` era BLOQUEANTE: girava bombeando timers até a promise assentar,
// com timeout de 10s. Isso é um deadlock por construção sempre que quem resolve a
// promise é código que só roda DEPOIS da chamada async — que é exatamente o ciclo
// de update do Lit (`this.__updatePromise` criada no construtor e resolvida no
// connectedCallback). O corpo travava 10s e morria com "promise nunca assentou".
//
// Agora o corpo roda na mesma máquina dos generators (thread + semáforos): cada
// `await` faz generator_yield, devolvendo o controle ao chamador, e o valor
// awaitado é encadeado com .then para RETOMAR a corrotina quando assentar.
// Programas com await de topo também usam esta máquina, preservando seu escopo.

// Chama uma `async function` comum. Devolve a Promise do resultado; o corpo roda
// até o 1º await de forma síncrona (como manda a spec) e depois suspende.
async_call :: proc(vm: ^Interp, fn: ^Function, this: Value, args: []Value) -> Value {
    o := new_object(vm)
    g := new(Generator)
    g.vm = vm
    g.fn = fn
    g.module = vm.current_module
    g.this = this
    g.args = make([]Value, len(args))
    copy(g.args, args)
    g.alloc = context.allocator
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
    hold.host = rawptr(g) // o passo seguinte precisa do MESMO generator

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
    if !ok || h.host == nil do return nil
    return cast(^Generator) h.host
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
    g.alloc = context.allocator
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
        g.program_result = ro.props["value"]
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
