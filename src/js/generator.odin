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
// LIMITAÇÕES: yield* NÃO encaminha next(v)/throw/return ao iterável delegado
// (só repassa os valores); async generators não são suportados; um generator
// deixado suspenso mantém a thread viva até o vm_destroy (limpeza abaixo).

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

Generator :: struct {
    vm:      ^Interp,
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
}

// ── criação ──────────────────────────────────────────────────────────────────

// Chamar uma função generator NÃO roda o corpo: devolve um objeto generator
// (iterável — tem next/return/throw + Symbol.iterator). O corpo só roda em .next().
make_generator :: proc(vm: ^Interp, fn: ^Function, this: Value, args: []Value) -> Value {
    o := new_object(vm)
    g := new(Generator)
    g.vm = vm
    g.fn = fn
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
    saved_depth := vm.call_depth
    saved_low := vm.stack_low
    vm.current_gen = g
    vm.call_depth = g.depth
    vm.stack_low = g.stack_low

    g.running = true
    sync.sema_post(&g.resume)  // -> generator
    sync.sema_wait(&g.yielded) // <- generator parou de novo / terminou
    g.running = false

    g.depth = vm.call_depth      // salva o progresso da pilha do generator
    g.stack_low = vm.stack_low
    vm.current_gen = saved_gen
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
// next/return/throw devolvem uma Promise de {value,done}. Como o await é
// BLOQUEANTE (promise_await_blocking), gen_resume roda o corpo até o próximo
// yield/fim de forma síncrona (os `await` internos bombeiam na thread do gen),
// então basta empacotar o resultado numa promise já resolvida — ou rejeitada, se
// o corpo lançou. O `yield` em si awaita o valor (feito no eval de .Yield).
@(private = "file")
async_gen_settle :: proc(vm: ^Interp, res: Value) -> Value {
    p := promise_new(vm)
    if vm.throwing {
        vm.throwing = false
        exc := vm.thrown; vm.thrown = nil
        promise_settle(vm, p, PROMISE_REJECTED, exc)
    } else {
        promise_resolve_with(vm, p, res)
    }
    return p
}

@(private = "file")
native_async_gen_next :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    g := gen_of(this)
    if g == nil {
        p := promise_new(vm)
        promise_resolve_with(vm, p, make_iter_result(vm, nil, true))
        return p
    }
    sent: Value = args[0] if len(args) >= 1 else nil
    return async_gen_settle(vm, gen_resume(vm, g, sent, .None))
}

@(private = "file")
native_async_gen_return :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    g := gen_of(this)
    v: Value = args[0] if len(args) >= 1 else nil
    if g == nil {
        p := promise_new(vm)
        promise_resolve_with(vm, p, make_iter_result(vm, v, true))
        return p
    }
    return async_gen_settle(vm, gen_resume(vm, g, v, .Return))
}

@(private = "file")
native_async_gen_throw :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    g := gen_of(this)
    v: Value = args[0] if len(args) >= 1 else nil
    if g == nil {
        p := promise_new(vm)
        promise_settle(vm, p, PROMISE_REJECTED, v)
        return p
    }
    return async_gen_settle(vm, gen_resume(vm, g, v, .Throw))
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
// O caminho bloqueante continua existindo para await de TOPO (fora de corrotina).

// Chama uma `async function` comum. Devolve a Promise do resultado; o corpo roda
// até o 1º await de forma síncrona (como manda a spec) e depois suspende.
async_call :: proc(vm: ^Interp, fn: ^Function, this: Value, args: []Value) -> Value {
    o := new_object(vm)
    g := new(Generator)
    g.vm = vm
    g.fn = fn
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
    awaited := promise_new(vm)
    promise_resolve_with(vm, awaited, ro.props["value"])
    hold := new_object(vm)
    hold.host = rawptr(g) // o passo seguinte precisa do MESMO generator

    on_ok := new_function(vm)
    on_ok.native = async_resume_ok
    on_ok.name = "asyncResume"
    on_ok.bound = hold

    on_err := new_function(vm)
    on_err.native = async_resume_err
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
    if g := async_gen_from_bound(vm); g != nil do async_step(vm, g, arg(args, 0), .None)
    return nil
}

@(private = "file")
async_resume_err :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    // rejeição vira `throw` DENTRO do corpo, no ponto do await (capturável).
    if g := async_gen_from_bound(vm); g != nil do async_step(vm, g, arg(args, 0), .Throw)
    return nil
}
