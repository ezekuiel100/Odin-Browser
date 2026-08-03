package js

// Testes do #5 do roadmap SPA: requestAnimationFrame/cancelAnimationFrame +
// Promise.all/allSettled/race/any. Rodar: odin test src/js
//
// As Promises deste motor assentam SÍNCRONO (M19): .then numa promise já
// resolvida roda na hora, então os combinadores sobre Promise.resolve/valores
// são observáveis sem bombear. Já rAF depende do pump de timers (vm_pump_timers).

import "core:testing"

// ── requestAnimationFrame ────────────────────────────────────────────────────

@(test)
test_raf_fires_with_timestamp :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    // o callback recebe um timestamp (clock_ms); guardamos se veio número > 0
    vm_run(vm, "var ts = -1; requestAnimationFrame(function(t) { ts = t; });")
    testing.expect_value(t, as_number(vm_run(vm, "ts")), f64(-1)) // ainda não

    fired := vm_pump_timers(vm, 20) // ~16ms → vence
    testing.expect(t, fired, "rAF deve disparar após ~16ms")
    // clock avançou 20ms; o timestamp passado deve ser 20
    testing.expect_value(t, as_number(vm_run(vm, "ts")), f64(20))
}

@(test)
test_raf_cancel :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, "var n = 0; var id = requestAnimationFrame(function() { n++; }); cancelAnimationFrame(id);")
    vm_pump_timers(vm, 32)
    testing.expect_value(t, as_number(vm_run(vm, "n")), f64(0))
}

@(test)
test_raf_is_one_shot :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, "var n = 0; requestAnimationFrame(function() { n++; });")
    vm_pump_timers(vm, 20)
    vm_pump_timers(vm, 20) // não deve repetir (não é setInterval)
    testing.expect_value(t, as_number(vm_run(vm, "n")), f64(1))
}

// ── Promise.all ──────────────────────────────────────────────────────────────

@(test)
test_promise_all_resolves_in_order :: proc(t: ^testing.T) {
    // mistura promises resolvidas e um valor cru; resultado preserva a ordem
    ok, _ := run(`
        var out = '';
        Promise.all([Promise.resolve(1), 2, Promise.resolve(3)]).then(function(r) {
            out = r.join(',');
        });
        out === '1,2,3'
    `).(bool)
    testing.expect(t, ok, "Promise.all deve resolver com o array na ordem")
}

@(test)
test_promise_all_rejects_on_first :: proc(t: ^testing.T) {
    ok, _ := run(`
        var err = '';
        Promise.all([Promise.resolve(1), Promise.reject('boom'), Promise.resolve(3)])
            .then(function(r) { err = 'nao devia'; }, function(e) { err = e; });
        err === 'boom'
    `).(bool)
    testing.expect(t, ok, "Promise.all deve rejeitar com o 1º erro")
}

@(test)
test_promise_all_empty :: proc(t: ^testing.T) {
    ok, _ := run(`
        var n = -1;
        Promise.all([]).then(function(r) { n = r.length; });
        n === 0
    `).(bool)
    testing.expect(t, ok, "Promise.all([]) resolve com array vazio")
}

// ── Promise.allSettled ───────────────────────────────────────────────────────

@(test)
test_promise_all_settled :: proc(t: ^testing.T) {
    ok, _ := run(`
        var res = null;
        Promise.allSettled([Promise.resolve(9), Promise.reject('x')]).then(function(r) { res = r; });
        res.length === 2 &&
        res[0].status === 'fulfilled' && res[0].value === 9 &&
        res[1].status === 'rejected'  && res[1].reason === 'x'
    `).(bool)
    testing.expect(t, ok, "allSettled deve reportar status+value/reason por entrada")
}

// ── Promise.race ─────────────────────────────────────────────────────────────

@(test)
test_promise_race_first_settles :: proc(t: ^testing.T) {
    // ambas já resolvidas: a 1ª (ordem de iteração) vence
    ok, _ := run(`
        var v = 0;
        Promise.race([Promise.resolve('a'), Promise.resolve('b')]).then(function(r) { v = r; });
        v === 'a'
    `).(bool)
    testing.expect(t, ok, "race deve assentar com o primeiro")
}

@(test)
test_promise_race_reject_wins :: proc(t: ^testing.T) {
    ok, _ := run(`
        var got = '';
        Promise.race([Promise.reject('nao'), Promise.resolve('sim')])
            .then(function(r) { got = 'f:' + r; }, function(e) { got = 'r:' + e; });
        got === 'r:nao'
    `).(bool)
    testing.expect(t, ok, "race com rejeição primeiro deve rejeitar")
}

// ── Promise.any ──────────────────────────────────────────────────────────────

@(test)
test_promise_any_first_fulfilled :: proc(t: ^testing.T) {
    ok, _ := run(`
        var v = '';
        Promise.any([Promise.reject('e1'), Promise.resolve('ok'), Promise.reject('e3')])
            .then(function(r) { v = r; });
        v === 'ok'
    `).(bool)
    testing.expect(t, ok, "any deve resolver com a 1ª cumprida, ignorando rejeições")
}

@(test)
test_promise_any_all_reject :: proc(t: ^testing.T) {
    ok, _ := run(`
        var name = '', errs = 0;
        Promise.any([Promise.reject('a'), Promise.reject('b')])
            .then(function(r) {}, function(e) { name = e.name; errs = e.errors.length; });
        name === 'AggregateError' && errs === 2
    `).(bool)
    testing.expect(t, ok, "any com todas rejeitadas deve dar AggregateError com errors")
}

// ── integração: all + await (fetch paralelo, o uso típico em SPA) ────────────

@(test)
test_promise_all_await :: proc(t: ^testing.T) {
    // combina all com timers reais via await (padrão fetch paralelo)
    vm := vm_create()
    defer vm_free(vm)
    src := `
        function later(v, ms) {
            return new Promise(function(res) { setTimeout(function() { res(v); }, ms); });
        }
        var total = 0;
        (async function() {
            var r = await Promise.all([later(10, 10), later(20, 20), later(30, 5)]);
            total = r[0] + r[1] + r[2];
        })();
    `
    vm_run(vm, src)
    // M130: await suspende (não bloqueia) — roda o loop até os 3 timers vencerem.
    for _ in 0 ..< 200 {
        vm_pump_timers(vm, 1)
        if as_number(vm_run(vm, "total")) == 60 do break
    }
    testing.expect_value(t, as_number(vm_run(vm, "total")), f64(60))
}
