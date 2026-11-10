package js

// M50: grupo async (auditoria 2026-07-08) — await dentro de callback de .then
// (drenava nunca → hang de 10s), adoção de thenables, interleaving de
// microtasks no settle, resolve(própria promise) → TypeError, timers por
// ordem de vencimento e clearTimeout dentro do mesmo pump.

import "core:testing"

// ── thenable ──────────────────────────────────────────────────────────────────

@(test)
test_thenable_adotado :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run_settled(`
        var out = 0;
        Promise.resolve({ then: function(f){ f(42) } })
            .then(function(v){ out = (v === 42) ? 1 : 2 });`, "out")), f64(1))
}

@(test)
test_thenable_rejeita :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run_settled(`
        var out = 0;
        Promise.resolve({ then: function(f, r){ r('nope') } })
            .catch(function(e){ out = (e === 'nope') ? 1 : 2 });`, "out")), f64(1))
}

@(test)
test_thenable_que_lanca :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run_settled(`
        var out = 0;
        Promise.resolve({ then: function(){ throw 'boom' } })
            .catch(function(e){ out = (e === 'boom') ? 1 : 2 });`, "out")), f64(1))
}

// ── interleaving de microtasks (promise pendente assentada depois) ────────────

@(test)
test_microtask_irmaos_interleave :: proc(t: ^testing.T) {
    // p.then(A).then(a); p.then(B) com settle posterior: A, B, a (não A, a, B)
    testing.expect_value(t, as_number(run_settled(`
        var log = '';
        var r; var p = new Promise(function(res){ r = res });
        p.then(function(){ log += 'A' }).then(function(){ log += 'a' });
        p.then(function(){ log += 'B' });
        r(1);`, "log == 'ABa' ? 1 : 0")), f64(1))
}

// ── resolve(própria promise) ──────────────────────────────────────────────────

@(test)
test_resolve_ciclo_typeerror :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run_settled(`
        var r; var p = new Promise(function(res){ r = res });
        var err = 0;
        p.catch(function(e){ err = (e && e.name == 'TypeError') ? 1 : 2 });
        r(p);`, "err")), f64(1))
}

// ── await dentro de callback de .then (o hang de 10s) ─────────────────────────

@(test)
test_await_dentro_de_then :: proc(t: ^testing.T) {
    // antes: o drain externo ficava bloqueado no await e a reação do .then
    // interno nunca rodava → 10s de timeout e valor falso. Agora: instantâneo.
    testing.expect_value(t, as_number(run_settled(`
        var out = 0;
        Promise.resolve().then(function(){
            return (async function(){
                var v = await Promise.resolve(41).then(function(x){ return x + 1 });
                out = v;
            })();
        });`, "out")), f64(42))
}

@(test)
test_await_encadeado_dentro_de_then :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run_settled(`
        var out = 0;
        Promise.resolve().then(function(){
            return (async function(){
                var a = await Promise.resolve(10).then(function(x){ return x * 2 });
                var b = await Promise.resolve(a).then(function(x){ return x + 2 });
                out = b;
            })();
        });`, "out")), f64(22))
}

// ── timers: ordem de vencimento e cancelamento no mesmo pump ──────────────────

@(test)
test_timer_ordem_vencimento :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, "var log = ''; setTimeout(function(){ log += 'f' }, 100); setTimeout(function(){ log += 'g' }, 50);")
    vm_pump_timers(vm, 200) // os dois vencem no mesmo pump: g (50ms) antes de f (100ms)
    v, _ := vm_run(vm, "log == 'gf'").(bool)
    testing.expect(t, v, "timers vencidos juntos disparam por ordem de vencimento")
}

@(test)
test_cleartimeout_no_mesmo_pump :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var log = '';
        var id2;
        setTimeout(function(){ log += 'a'; clearTimeout(id2) }, 10);
        id2 = setTimeout(function(){ log += 'b' }, 20);
    `)
    vm_pump_timers(vm, 100) // 'a' roda primeiro e cancela 'b' — 'b' NÃO pode disparar
    v, _ := vm_run(vm, "log == 'a'").(bool)
    testing.expect(t, v, "clearTimeout dentro de um callback cancela timer vencido do mesmo pump")
}

@(test)
test_clearinterval_dentro_do_callback :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var n = 0;
        var id = setInterval(function(){ n++; if (n >= 3) clearInterval(id) }, 10);
    `)
    for _ in 0 ..< 10 do vm_pump_timers(vm, 15)
    testing.expect_value(t, as_number(vm_run(vm, "n")), f64(3))
}
