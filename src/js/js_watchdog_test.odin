package js

// Watchdog anti-hang + funções Math que faltavam (clz32 foi a causa do
// travamento em tradebig.com.br: o scheduler do React usa clz32 no laço de
// "lanes"; sem ele o laço nunca converge e a UI trava).

import "core:strings"
import "core:testing"

@(test)
test_watchdog_infinite_loop :: proc(t: ^testing.T) {
    // laço infinito deve virar RangeError (capturável), NÃO travar o processo
    vm := vm_create()
    defer vm_free(vm)
    vm.step_limit = 10_000 // teto baixo p/ o teste ser rápido
    res := vm_run(vm, "var c='no'; try { while(true){} } catch(e){ c = e.name; } c")
    s, _ := res.(string)
    testing.expect(t, s == "RangeError", "while(true) deve estourar o watchdog")
}

@(test)
test_watchdog_for_loop :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm.step_limit = 10_000
    res := vm_run(vm, "var c='no'; try { for(;;){} } catch(e){ c = e.name; } c")
    s, _ := res.(string)
    testing.expect(t, s == "RangeError", "for(;;) deve estourar o watchdog")
}

@(test)
test_time_watchdog :: proc(t: ^testing.T) {
    // laço que NÃO estoura o teto de PASSOS (200M) mas roda muito tempo deve ser
    // cortado pelo watchdog por TEMPO — evita congelar a UI por dezenas de segundos
    // (ex.: o gtag.js do Google). step_limit fica no default (alto); só o tempo corta.
    vm := vm_create()
    defer vm_free(vm)
    vm.time_budget_ms = 100 // teto de tempo baixo p/ o teste ser rápido
    res := vm_run(vm, "var m=''; try { while(true){} } catch(e){ m = e.message; } m")
    s, _ := res.(string)
    testing.expect(t, strings.contains(s, "tempo"), "loop longo deve estourar o watchdog por TEMPO")
}

@(test)
test_time_watchdog_allows_normal :: proc(t: ^testing.T) {
    // tarefa curta (bem abaixo do teto de tempo) roda normalmente
    vm := vm_create()
    defer vm_free(vm)
    vm.time_budget_ms = 5000
    testing.expect_value(t, as_number(vm_run(vm, "var s=0; for(var i=0;i<100000;i++) s++; s")), f64(100000))
}

@(test)
test_watchdog_allows_normal_loops :: proc(t: ^testing.T) {
    // laço legítimo (bem abaixo do teto) roda normalmente
    testing.expect_value(t, as_number(run("var s=0; for(var i=0;i<1000;i++) s+=i; s")), f64(499500))
}

@(test)
test_recursion_guard :: proc(t: ^testing.T) {
    // recursão infinita/profunda deve virar RangeError capturável, NÃO estourar a
    // stack nativa e matar o processo. Teto baixo p/ o teste não chegar perto do
    // limite real da stack do binário de teste.
    vm := vm_create()
    defer vm_free(vm)
    // teto MUITO baixo: o binário de teste não usa /STACK (stack ~1MB, e frames
    // maiores em debug), então a guarda precisa disparar BEM antes do estouro real.
    vm.call_depth_limit = 30
    res := vm_run(vm, "function rec(n){ return rec(n+1); } var c='no'; try { rec(0); } catch(e){ c = e.name; } c")
    s, _ := res.(string)
    testing.expect(t, s == "RangeError", "recursão infinita deve estourar a guarda de profundidade")
}

@(test)
test_recursion_guard_allows_normal :: proc(t: ^testing.T) {
    // recursão legítima roda normalmente. Profundidade baixa de propósito: o
    // BINÁRIO DE TESTE não usa /STACK (stack de 1MB → só ~85 frames nativos),
    // então o app real (build com /STACK:256MB) suporta ~20000; aqui só validamos
    // que a guarda não atrapalha recursão normal abaixo do teto.
    vm := vm_create()
    defer vm_free(vm)
    res := vm_run(vm, "function rec(n){ return n<=0 ? 0 : 1 + rec(n-1); } rec(20)")
    testing.expect_value(t, as_number(res), f64(20))
}

@(test)
test_math_clz32 :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("Math.clz32(1)")), f64(31))
    testing.expect_value(t, as_number(run("Math.clz32(0)")), f64(32))
    testing.expect_value(t, as_number(run("Math.clz32(0xFFFFFFFF)")), f64(0))
    testing.expect_value(t, as_number(run("Math.clz32(1000)")), f64(22)) // 1000 usa 10 bits
}

@(test)
test_math_imul :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("Math.imul(3, 4)")), f64(12))
    testing.expect_value(t, as_number(run("Math.imul(0xffffffff, 5)")), f64(-5)) // (-1)*5
}

@(test)
test_math_extra :: proc(t: ^testing.T) {
    // valores exatos (evita imprecisão de ponto flutuante)
    testing.expect_value(t, as_number(run("Math.exp(0)")), f64(1))
    testing.expect_value(t, as_number(run("Math.log(1)")), f64(0))
    testing.expect_value(t, as_number(run("Math.log2(8)")), f64(3))
    testing.expect_value(t, as_number(run("Math.cos(0)")), f64(1))
    testing.expect_value(t, as_number(run("Math.sin(0)")), f64(0))
    testing.expect_value(t, as_number(run("Math.hypot(3, 4)")), f64(5))
    testing.expect_value(t, as_number(run("Math.cbrt(27)")), f64(3))
}
