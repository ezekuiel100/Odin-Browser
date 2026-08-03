package js

// M143 — VÍRGULA FINAL em lista de ARGUMENTOS (`f(a, b,)`), válida desde ES2017.
//
// Motivador: a mineração de 2026-07-22 mostrou que o topo das "recuperações de
// parse" deixou de ser HTML-alimentado-ao-parser-de-JS e passou a ser sintaxe
// REAL que o motor não aceitava — figma 207, angular 31, spotify 14, slack 9.
// O idioma sai do minificador/transpilador:
//
//     Object.defineProperties(target, Object.getOwnPropertyDescriptors(source),)
//
// Os três laços de argumento (chamada, `new X()`, chamada opcional `f?.()`)
// consumiam a vírgula e chamavam parse_arg JÁ EM CIMA do ')'. Como ')' não é
// posição de expressão, a recuperação do parser injetava um argumento `0`
// ESPÚRIO — o erro não era só ruído no log: a lista de argumentos ficava com
// aridade errada. Por isso os testes conferem ARIDADE e VALORES, não só que
// parseia sem reclamar.
//
// Parâmetros de função, literal de objeto e literal de array JÁ aceitavam a
// vírgula final (o laço deles rechecha o token de fechamento no topo).

import "core:testing"

@(test)
m143_virgula_final_em_chamada :: proc(t: ^testing.T) {
    // o `0` espúrio aparecia como um 3º argumento: arity tinha de virar 3.
    testing.expect_value(t, as_number(run("function f(){ return arguments.length } f(1, 2,)")), f64(2))
}

@(test)
m143_virgula_final_nao_altera_valores :: proc(t: ^testing.T) {
    // soma dos args: com o argumento fantasma o resultado continuaria 3, então
    // este caso sozinho NÃO pegaria o bug — vale como guarda de valor junto do
    // teste de aridade acima.
    testing.expect_value(t, as_number(run("function f(a,b){ return a+b } f(1, 2,)")), f64(3))
}

@(test)
m143_virgula_final_com_um_arg :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("function f(){ return arguments.length } f(7,)")), f64(1))
}

@(test)
m143_virgula_final_em_new :: proc(t: ^testing.T) {
    // `new X(a,)` — o mesmo laço vivia duplicado no caminho do new.
    src := `
        function P(a, b) { this.n = arguments.length; this.s = a + b }
        var p = new P(10, 20,);
        p.n * 1000 + p.s
    `
    testing.expect_value(t, as_number(run(src)), f64(2030))
}

@(test)
m143_virgula_final_em_chamada_opcional :: proc(t: ^testing.T) {
    // `f?.(a,)` — 3ª cópia do laço.
    src := `
        var f = function(){ return arguments.length };
        f?.(1, 2, 3,)
    `
    testing.expect_value(t, as_number(run(src)), f64(3))
}

@(test)
m143_virgula_final_com_spread :: proc(t: ^testing.T) {
    // spread seguido de vírgula final: o argumento fantasma entrava DEPOIS do
    // spread expandido, então a aridade final ficava errada.
    src := `
        function f(){ return arguments.length }
        var xs = [1, 2, 3];
        f(...xs,)
    `
    testing.expect_value(t, as_number(run(src)), f64(3))
}

@(test)
m143_virgula_final_idioma_do_minificador :: proc(t: ^testing.T) {
    // a forma EXATA achada no bundle do spotify (Object.defineProperties com a
    // vírgula final), verificada pelo efeito e não pelo parse.
    src := `
        var src = { a: 1, b: 2 };
        var dst = {};
        Object.defineProperties(dst, Object.getOwnPropertyDescriptors(src),);
        dst.a + dst.b
    `
    testing.expect_value(t, as_number(run(src)), f64(3))
}

@(test)
m143_lista_vazia_e_sem_virgula_seguem_iguais :: proc(t: ^testing.T) {
    // contra-caso: o helper novo não pode ter mexido no caminho comum.
    testing.expect_value(t, as_number(run("function f(){ return arguments.length } f()")), f64(0))
    testing.expect_value(t, as_number(run("function f(){ return arguments.length } f(1,2,3)")), f64(3))
}
