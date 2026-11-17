package js

// Antes (M52) o parser RECUPERAVA em silêncio de sintaxe inválida (token
// inesperado → 0, atribuição descartada...) e só CONTAVA. Desde os early errors de
// verdade não existe mais recuperação: o fonte inteiro é rejeitado com SyntaxError
// e nada dele executa. Estes testes afirmam isso no nível do vm (vm_run direto, sem
// o check_parse_recoveries, que entraria em pânico de propósito).

import "core:testing"

@(private = "file")
rejected_count :: proc(src: string) -> (syntax_errors: int, silent: int) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, src)
    return vm.syntax_errors, vm.parse_recoveries
}

@(test)
test_recovery_zero_em_js_valido :: proc(t: ^testing.T) {
    se, silent := rejected_count(`
        var a = 1; let [b, c] = [2, 3]; const o = { x: a, get g(){ return 1 } };
        class K { #p = 1; static s(){ return 2 } }
        for (let i = 0; i < 3; i++) a += i;
        function* g(){ yield* [1, 2] }
        async function f(){ return await Promise.resolve(1) }
        ` + "`tpl ${a} ok`; a ??= 9; if (a) /re/.test('x');")
    testing.expect_value(t, se, 0)
    testing.expect_value(t, silent, 0)
}

@(test)
test_recovery_conta_token_inesperado :: proc(t: ^testing.T) {
    // `#` solto não é nada em JS: o fonte é REJEITADO (não há mais recuperação)
    se, silent := rejected_count("var a = # 1;")
    testing.expect_value(t, se, 1)
    testing.expect_value(t, silent, 0)
}

@(test)
test_recovery_conta_atribuicao_descartada :: proc(t: ^testing.T) {
    // alvo de atribuição inválido: `f() = 5` era descartado em silêncio; agora é SyntaxError
    msg, rejected := early_error_of("function f(){ return 1 }\nf() = 5;")
    testing.expect(t, rejected, "atribuição a chamada devia ser SyntaxError")
    testing.expect_value(t, msg, "Invalid left-hand side in assignment")
}

@(test)
test_recovery_persiste_no_vm :: proc(t: ^testing.T) {
    // acumula entre vm_runs no mesmo vm (páginas com vários <script>), e o script
    // rejeitado não derruba os outros
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, "var ok = 1;")
    testing.expect_value(t, vm.syntax_errors, 0)
    vm_run(vm, "var a = # 2;")
    testing.expect_value(t, vm.syntax_errors, 1)
    vm_run(vm, "ok += 1;")
    testing.expect_value(t, as_number(vm_run(vm, "ok")), f64(2))
}
