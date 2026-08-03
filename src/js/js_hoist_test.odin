package js

// Testes de hoisting de declarações de função: `function f(){}` fica disponível
// ANTES da sua linha de declaração, no escopo envolvente (programa, bloco,
// corpo de função). Expressões de função NÃO são içadas.

import "core:testing"

@(test)
test_hoist_toplevel :: proc(t: ^testing.T) {
    // chamada ANTES da declaração no programa
    testing.expect_value(t, as_number(run("foo(); function foo(){}; 0")), f64(0))
}

@(test)
test_hoist_call_before_decl :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var r = dobro(21); function dobro(x){ return x * 2; } r")), f64(42))
}

@(test)
test_hoist_mutual_recursion :: proc(t: ^testing.T) {
    // par/ímpar mutuamente recursivos, ambos usados antes de declarados
    src := `
        var r = ehPar(10);
        function ehPar(n){ return n == 0 ? true : ehImpar(n - 1); }
        function ehImpar(n){ return n == 0 ? false : ehPar(n - 1); }
        r
    `
    v, _ := run(src).(bool)
    testing.expect(t, v, "ehPar(10) deve ser true via recursão mútua içada")
}

@(test)
test_hoist_inside_function :: proc(t: ^testing.T) {
    // declaração içada dentro do corpo de outra função
    src := `
        function outer(){
            return inner(5);
            function inner(x){ return x + 1; }
        }
        outer()
    `
    testing.expect_value(t, as_number(run(src)), f64(6))
}

@(test)
test_hoist_expression_not_hoisted :: proc(t: ^testing.T) {
    // expressão de função NÃO é içada: chamar antes da atribuição dá erro/undefined,
    // mas chamar DEPOIS funciona. Verifica que a atribuição é que a torna disponível.
    testing.expect_value(t, as_number(run("var f; f = function(){ return 7; }; f()")), f64(7))
}

@(test)
test_hoist_later_decl_wins :: proc(t: ^testing.T) {
    // duas declarações de mesmo nome: a última vence (semântica JS)
    src := `
        function pick(){ return 1; }
        function pick(){ return 2; }
        pick()
    `
    testing.expect_value(t, as_number(run(src)), f64(2))
}

@(test)
test_hoist_still_reassignable :: proc(t: ^testing.T) {
    // após a declaração, o nome continua reatribuível
    src := `
        function g(){ return 1; }
        var a = g();
        g = function(){ return 9; };
        var b = g();
        a + b
    `
    testing.expect_value(t, as_number(run(src)), f64(10))
}
