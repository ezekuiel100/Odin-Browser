package js

import "core:testing"

// ── M85: async generators (async function*) + for-await-of ───────────────────
// Reusa a infra de generator (thread + ping-pong). O await é bloqueante, então o
// corpo roda até o próximo yield de forma síncrona (awaits internos bombeiam na
// thread do gen); next/return/throw devolvem Promise<{value,done}>; yield awaita
// o valor; for-await drena o async iterator awaitando cada passo.

// ── async generator básico via for-await ─────────────────────────────────────

@(test)
test_async_gen_basico :: proc(t: ^testing.T) {
    src := `
        async function* g(){ yield 1; yield 2; yield 3; }
        var sum = 0;
        for await (const x of g()) sum += x;
        sum
    `
    testing.expect_value(t, as_number(run(src)), f64(6))
}

// next() de async gen devolve Promise<{value,done}>.
@(test)
test_async_gen_next_promise :: proc(t: ^testing.T) {
    src := `
        async function* g(){ yield 10; }
        var it = g();
        var r1 = await it.next();
        var r2 = await it.next();
        r1.value + ':' + r1.done + ':' + r2.value + ':' + r2.done
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "10:false:undefined:true", "next() deve dar {value,done} via Promise")
}

// yield awaita o valor: `yield promise` rende o valor RESOLVIDO.
@(test)
test_async_gen_yield_awaita :: proc(t: ^testing.T) {
    src := `
        async function* g(){ yield Promise.resolve(42); }
        var got;
        for await (const x of g()) got = x;
        got
    `
    testing.expect_value(t, as_number(run(src)), f64(42))
}

// await DENTRO do corpo do async gen (com timer real).
@(test)
test_async_gen_await_interno :: proc(t: ^testing.T) {
    src := `
        function delay(v){ return new Promise(function(res){ setTimeout(function(){ res(v); }, 5); }); }
        async function* g(){
            var a = await delay(10);
            yield a;
            yield a + 1;
        }
        var out = [];
        for await (const x of g()) out.push(x);
        out.join(',')
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "10,11", "await interno deve resolver antes dos yields")
}

// corpo que lança → next() rejeita (await propaga como throw).
@(test)
test_async_gen_throw_rejeita :: proc(t: ^testing.T) {
    src := `
        async function* g(){ throw new Error('boom'); }
        var msg = '';
        try { await g().next(); } catch (e) { msg = e.message; }
        msg
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "boom", "corpo que lança deve rejeitar a promise de next()")
}

// combina await + yield alternados, acumulando.
@(test)
test_async_gen_await_yield_alternados :: proc(t: ^testing.T) {
    src := `
        async function* range(n){
            for (var i = 0; i < n; i++){
                yield await Promise.resolve(i * 2);
            }
        }
        var out = [];
        for await (const x of range(4)) out.push(x);
        out.join(',')
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "0,2,4,6", "yield await deve render valores resolvidos em sequência")
}

// ── for-await sobre iteráveis SÍNCRONOS ──────────────────────────────────────

// array de promises: cada elemento é awaitado.
@(test)
test_for_await_array_promises :: proc(t: ^testing.T) {
    src := `
        var out = [];
        for await (const x of [Promise.resolve(1), Promise.resolve(2), 3]) out.push(x);
        out.join(',')
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "1,2,3", "for-await sobre array de promises deve awaitar cada elemento")
}

// array de valores comuns (não-promises).
@(test)
test_for_await_array_valores :: proc(t: ^testing.T) {
    src := `
        var out = [];
        for await (const x of [1,2,3]) out.push(x);
        out.join(',')
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "1,2,3", "for-await deve funcionar sobre array de valores simples")
}

// for-await sobre um generator SÍNCRONO (fallback ao Symbol.iterator).
@(test)
test_for_await_sync_generator :: proc(t: ^testing.T) {
    src := `
        function* g(){ yield 5; yield 6; yield 7; }
        var out = [];
        for await (const x of g()) out.push(x);
        out.join(',')
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "5,6,7", "for-await deve envolver um generator síncrono")
}

// ── controle de fluxo ────────────────────────────────────────────────────────

// break no for-await fecha o iterador (finally do async gen roda).
@(test)
test_for_await_break_fecha :: proc(t: ^testing.T) {
    src := `
        var cleaned = false;
        async function* g(){ try { yield 1; yield 2; yield 3; } finally { cleaned = true; } }
        var out = [];
        for await (const x of g()) { out.push(x); if (x === 2) break; }
        out.join(',') + ':' + cleaned
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "1,2:true", "break no for-await deve rodar o finally via it.return()")
}

// async gen consumido dentro de uma função async comum.
@(test)
test_async_gen_dentro_async_fn :: proc(t: ^testing.T) {
    src := `
        async function* nums(){ yield 1; yield 2; yield 3; }
        async function total(){
            var s = 0;
            for await (const n of nums()) s += n;
            return s;
        }
        await total()
    `
    testing.expect_value(t, as_number(run(src)), f64(6))
}

// return() encerra o async gen antes do fim.
@(test)
test_async_gen_return :: proc(t: ^testing.T) {
    src := `
        async function* g(){ yield 1; yield 2; yield 3; }
        var it = g();
        var a = await it.next();
        var r = await it.return(99);
        var b = await it.next();
        a.value + ':' + r.value + ':' + r.done + ':' + b.done
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "1:99:true:true", "it.return() deve encerrar o async gen")
}

// Symbol.asyncIterator do async gen devolve o próprio objeto.
@(test)
test_async_gen_symbol_async_iterator :: proc(t: ^testing.T) {
    src := `
        async function* g(){ yield 1; }
        var it = g();
        it[Symbol.asyncIterator]() === it
    `
    testing.expect(t, truthy(run(src)), "async gen[Symbol.asyncIterator]() deve devolver o próprio iterador")
}

// ── yield* de iterável assíncrono (delegação) ────────────────────────────────

// async gen delega a OUTRO async gen via yield*.
@(test)
test_async_gen_yield_star_async :: proc(t: ^testing.T) {
    src := `
        async function* inner(){ yield 1; yield 2; }
        async function* outer(){ yield 0; yield* inner(); yield 3; }
        var out = [];
        for await (const x of outer()) out.push(x);
        out.join(',')
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "0,1,2,3", "yield* deve delegar a outro async generator")
}

// yield* delegando a um array (síncrono) dentro de async gen.
@(test)
test_async_gen_yield_star_array :: proc(t: ^testing.T) {
    src := `
        async function* g(){ yield* [10, 20, 30]; }
        var out = [];
        for await (const x of g()) out.push(x);
        out.join(',')
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "10,20,30", "yield* deve delegar a um array dentro de async gen")
}

// yield* delegando a um array de PROMISES: cada valor é awaitado.
@(test)
test_async_gen_yield_star_promises :: proc(t: ^testing.T) {
    src := `
        async function* g(){ yield* [Promise.resolve('a'), Promise.resolve('b')]; }
        var out = [];
        for await (const x of g()) out.push(x);
        out.join(',')
    `
    v, _ := run(src).(string)
    testing.expect(t, v == "a,b", "yield* deve awaitar cada elemento delegado")
}
