package js

// Testes do CONTADOR DE RECUPERAÇÕES silenciosas (M52). O parser tolera sintaxe
// não suportada em sites reais (token inesperado → 0, atribuição descartada...),
// mas agora CONTA cada recuperação; run()/run_with_dom() em build de teste
// entram em pânico se um teste parseou com recuperação — assim, sintaxe nova
// que a engine engoliria em silêncio derruba a suíte em vez de miscompilar.
//
// Estes testes usam vm_run direto (sem o check) p/ afirmar o contador em si.

import "core:testing"

@(private = "file")
recoveries_of :: proc(src: string) -> int {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, src)
    return vm.parse_recoveries
}

@(test)
test_recovery_zero_em_js_valido :: proc(t: ^testing.T) {
    testing.expect_value(t, recoveries_of(`
        var a = 1; let [b, c] = [2, 3]; const o = { x: a, get g(){ return 1 } };
        class K { #p = 1; static s(){ return 2 } }
        for (let i = 0; i < 3; i++) a += i;
        function* g(){ yield* [1, 2] }
        async function f(){ return await Promise.resolve(1) }
        ` + "`tpl ${a} ok`; a ??= 9; if (a) /re/.test('x');"), 0)
}

@(test)
test_recovery_conta_token_inesperado :: proc(t: ^testing.T) {
    // `#` solto não é nada em JS — o parser recupera (vira 0) e CONTA
    testing.expect(t, recoveries_of("var a = # 1;") > 0, "token inesperado deve contar recuperação")
}

@(test)
test_recovery_conta_atribuicao_descartada :: proc(t: ^testing.T) {
    // alvo de atribuição inválido: `f() = 5` — a atribuição é descartada e conta
    testing.expect(t, recoveries_of("function f(){ return 1 }\nf() = 5;") > 0,
        "atribuição com alvo inválido deve contar recuperação")
}

@(test)
test_recovery_persiste_no_vm :: proc(t: ^testing.T) {
    // acumula entre vm_runs no mesmo vm (páginas com vários <script>)
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, "var ok = 1;")
    testing.expect_value(t, vm.parse_recoveries, 0)
    vm_run(vm, "var a = # 2;")
    testing.expect(t, vm.parse_recoveries > 0, "recuperação do segundo script deve acumular")
}
