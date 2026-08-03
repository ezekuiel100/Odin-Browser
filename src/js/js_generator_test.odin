package js

// Generators (function* / yield / yield*) — cada generator roda o corpo numa
// thread própria em ping-pong (generator.odin). Cobre next()/return()/throw(),
// for-of, spread, delegação yield*, métodos generator e valores enviados.
// Rodar: odin test src/js

import "core:testing"

// ── básico ───────────────────────────────────────────────────────────────────

@(test)
test_gen_typeof :: proc(t: ^testing.T) {
    testing.expect_value(t, run("function* g(){}; typeof g"), "function")
    testing.expect_value(t, run("function* g(){}; typeof g()"), "object")
}

@(test)
test_gen_next_values :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        function* g(){ yield 1; yield 2; yield 3; }
        var it = g();
        it.next().value * 100 + it.next().value * 10 + it.next().value
    `)), f64(123))
}

@(test)
test_gen_done :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        function* g(){ yield 1; }
        var it = g();
        it.next();             // {1, false}
        var r = it.next();     // {undefined, true}
        (r.value===undefined && r.done===true) ? 'ok' : 'no'
    `), "ok")
}

@(test)
test_gen_return_value :: proc(t: ^testing.T) {
    // `return x` no corpo vira {value:x, done:true} no fim
    testing.expect_value(t, as_number(run(`
        function* g(){ yield 1; return 99; }
        var it = g();
        it.next();
        var r = it.next();
        r.value * 10 + (r.done ? 1 : 0)
    `)), f64(991))
}

@(test)
test_gen_yield_undefined :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        function* g(){ yield; }
        var r = g().next();
        (r.value===undefined && r.done===false) ? 'ok' : 'no'
    `), "ok")
}

// ── valores enviados via next(v) ─────────────────────────────────────────────

@(test)
test_gen_next_sends_value :: proc(t: ^testing.T) {
    // o argumento de next(v) vira o resultado da expressão yield
    testing.expect_value(t, as_number(run(`
        function* g(){ var x = yield 1; yield x + 10; }
        var it = g();
        var a = it.next().value;   // 1 (1º next ignora o argumento)
        var b = it.next(5).value;  // x=5 -> 15
        a * 100 + b
    `)), f64(115))
}

@(test)
test_gen_two_way :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        function* adder(){ var total = 0; while(true){ total += yield total; } }
        var it = adder();
        it.next();          // total=0, pausa no 1º yield
        it.next(10);        // total += 10
        it.next(20).value;  // total += 20 -> 30
    `)), f64(30))
}

// ── laços dentro do generator ────────────────────────────────────────────────

@(test)
test_gen_loop :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        function* range(n){ for(var i=0;i<n;i++) yield i; }
        var s = 0; for (var x of range(5)) s += x; s
    `)), f64(10))
}

@(test)
test_gen_closure :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        function* g(){ var arr=[10,20,30]; for(var i=0;i<arr.length;i++) yield arr[i]; }
        var s=0; for (var x of g()) s+=x; s
    `)), f64(60))
}

// ── for-of e spread ──────────────────────────────────────────────────────────

@(test)
test_gen_for_of :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        function* nums(){ yield 1; yield 2; yield 3; }
        var out = 0; for (var x of nums()) out += x; out
    `)), f64(6))
}

@(test)
test_gen_spread :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        function* nums(){ yield 1; yield 2; yield 3; }
        var a = [...nums()];
        a.length * 100 + a[0] + a[2]
    `)), f64(304))
}

// ── yield* (delegação) ───────────────────────────────────────────────────────

@(test)
test_gen_yield_star :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        function* inner(){ yield 2; yield 3; }
        function* outer(){ yield 1; yield* inner(); yield 4; }
        var out = ''; for (var x of outer()) out += x; out
    `), "1234")
}

@(test)
test_gen_yield_star_array :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        function* g(){ yield* [1,2,3]; }
        var out=''; for (var x of g()) out += x; out
    `), "123")
}

@(test)
test_gen_yield_star_string :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        function* g(){ yield* "ab"; }
        var out=''; for (var x of g()) out += x + '.'; out
    `), "a.b.")
}

// ── return() / throw() ───────────────────────────────────────────────────────

@(test)
test_gen_return_early :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        function* g(){ yield 1; yield 2; yield 3; }
        var it = g();
        it.next();
        var r = it.return(99);
        var r2 = it.next();
        (r.value===99 && r.done===true && r2.done===true) ? 'ok' : 'no'
    `), "ok")
}

@(test)
test_gen_return_runs_finally :: proc(t: ^testing.T) {
    // return() desenrola o corpo rodando os finally
    testing.expect_value(t, run(`
        var log = '';
        function* g(){ try { yield 1; yield 2; } finally { log += 'F'; } }
        var it = g();
        it.next();
        it.return(0);
        log
    `), "F")
}

@(test)
test_gen_throw_caught :: proc(t: ^testing.T) {
    // throw() injeta uma exceção no ponto do yield; try/catch no corpo captura
    testing.expect_value(t, run(`
        function* g(){ try { yield 1; } catch(e){ yield 'caught:'+e; } yield 'end'; }
        var it = g();
        it.next();
        var r = it.throw('boom');
        r.value
    `), "caught:boom")
}

@(test)
test_gen_throw_propagates :: proc(t: ^testing.T) {
    // throw() sem try/catch no corpo propaga ao chamador de throw()
    testing.expect_value(t, run(`
        function* g(){ yield 1; yield 2; }
        var it = g();
        it.next();
        var caught = 'no';
        try { it.throw('boom'); } catch(e){ caught = e; }
        caught
    `), "boom")
}

// ── métodos generator ────────────────────────────────────────────────────────

@(test)
test_gen_object_method :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        var o = { *gen(){ yield 1; yield 2; } };
        var out=0; for (var x of o.gen()) out += x; out
    `)), f64(3))
}

@(test)
test_gen_class_method :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        class C { *gen(){ yield 5; yield 6; } }
        var out=0; for (var x of new C().gen()) out += x; out
    `)), f64(11))
}

// ── instâncias independentes + generator infinito abandonado ─────────────────

@(test)
test_gen_independent_instances :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        function* g(){ yield 1; yield 2; }
        var a = g(), b = g();
        a.next();                    // a -> 1
        var av = a.next().value;     // a -> 2
        var bv = b.next().value;     // b -> 1 (independente)
        av * 10 + bv
    `)), f64(21))
}

@(test)
test_gen_infinite_abandoned :: proc(t: ^testing.T) {
    // generator infinito consumido parcialmente e depois abandonado: a thread
    // suspensa é encerrada no vm_destroy (cleanup_generators) sem travar/crashar
    testing.expect_value(t, as_number(run(`
        function* inf(){ var i = 0; while(true) yield i++; }
        var it = inf();
        it.next().value + it.next().value + it.next().value  // 0+1+2
    `)), f64(3))
}

@(test)
test_gen_nested :: proc(t: ^testing.T) {
    // um generator que dirige outro manualmente (next aninhado em thread aninhada)
    testing.expect_value(t, run(`
        function* inner(){ yield 'a'; yield 'b'; }
        function* outer(){
            var it = inner();
            yield it.next().value;
            yield 'x';
            yield it.next().value;
        }
        var out=''; for (var v of outer()) out += v; out
    `), "axb")
}
