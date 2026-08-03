package js

// M146 — `[NoIn]` vazava para dentro de parênteses/colchetes/argumentos.
//
// No cabeçalho de um `for`, `in` marca for-in e não pode virar operador — daí o
// flag `p.no_in`. Só que ele era do Parser INTEIRO e valia até o fim do init,
// enquanto a spec restringe `[NoIn]` ao NÍVEL DE TOPO: dentro de parênteses,
// colchetes, argumentos, array e objeto o `in` volta a ser operador
// (`PrimaryExpression : ( Expression[+In] )`, e análogos).
//
// Efeito: `for (var i = ("a" in o) ? 1 : 2; ...)` não via o `in` como operador,
// a expressão era despedaçada e o parser saía recuperando token a token. Era o
// que sobrava de weather.com (8 recuperações) e metade de slack.com no ranking
// do gap-miner — medido depois: weather 8→0, slack 9→3 (as 3 restantes são uma
// resposta JSON de erro servida no lugar de um script, não gap do motor).
//
// ⚠️ Cheguei aqui DEPOIS de uma hipótese errada: o dump de tokens do relatório
// mostrava `¿` no lugar dos operadores de 2+ caracteres (fallback do tok_glyph),
// e sem eles o contexto não dizia nada. Completar a tabela de glifos foi o que
// revelou o `in` dentro de parêntese. Instrumentar antes de teorizar.

import "core:testing"

@(test)
m146_in_entre_parenteses_no_for_init :: proc(t: ^testing.T) {
    // o caso central: sem o fix o init virava lixo e o laço nem rodava direito.
    src := `
        var o = {a:1}, r = "";
        for (var i = ("a" in o) ? 10 : 20; i < 11; i++) { r += i }
        r
    `
    testing.expect_value(t, run(src).(string), "10")
}

@(test)
m146_in_em_argumento_de_chamada :: proc(t: ^testing.T) {
    src := `
        var o = {a:1};
        function f(x) { return x ? 5 : 9 }
        var v = 0;
        for (var i = f("a" in o); i < 6; i++) { v = i }
        v
    `
    testing.expect_value(t, as_number(run(src)), f64(5))
}

@(test)
m146_in_em_indice :: proc(t: ^testing.T) {
    src := `
        var o = {a:1}, arr = [7, 8], v = 0;
        for (var i = arr[("a" in o) ? 0 : 1]; i < 8; i++) { v = i }
        v
    `
    testing.expect_value(t, as_number(run(src)), f64(7))
}

@(test)
m146_in_em_array_e_objeto_literais :: proc(t: ^testing.T) {
    src := `
        var o = {a:1}, n = 0;
        for (var xs = [("a" in o), ("z" in o)]; n < 1; n++) {}
        for (var ob = { hit: ("a" in o) }; n < 2; n++) {}
        (xs[0] ? "1" : "0") + (xs[1] ? "1" : "0") + (ob.hit ? "1" : "0")
    `
    testing.expect_value(t, run(src).(string), "101")
}

@(test)
m146_for_in_continua_sendo_for_in :: proc(t: ^testing.T) {
    // CONTRA-CASO 1 — o mais importante: no NÍVEL DE TOPO do cabeçalho o `in`
    // TEM de continuar marcando for-in. Se o fix tivesse zerado o no_in geral,
    // isto viraria um for clássico com uma comparação e o teste pegaria.
    testing.expect_value(t, run("var o={a:1,b:2}, k=''; for (var x in o) { k += x } k").(string), "ab")
    testing.expect_value(t, run("var o={a:1}, k=''; for (x in o) { k += x } k").(string), "a")
}

@(test)
m146_for_classico_e_for_of_intactos :: proc(t: ^testing.T) {
    // CONTRA-CASO 2: as outras formas de cabeçalho não podem ter mudado.
    testing.expect_value(t, as_number(run("var s=0; for (var i=0, n=3; i<n; i++) s+=i; s")), f64(3))
    testing.expect_value(t, as_number(run("var s=0; for (var v of [1,2,3]) s+=v; s")), f64(6))
}

@(test)
m146_in_como_operador_fora_de_for_intacto :: proc(t: ^testing.T) {
    // CONTRA-CASO 3: fora de cabeçalho de for nada disso se aplica.
    testing.expect_value(t, run("var o={a:1}; ('a' in o) ? 'sim' : 'nao'").(string), "sim")
    testing.expect_value(t, run("var o={a:1}; 'z' in o ? 'sim' : 'nao'").(string), "nao")
}

// ── M149: o M146 tinha DEIXADO DOIS contextos de fora ────────────────────────
// A sonda [unresolved] do peel do airbnb achou um Ident chamado `in` (palavra
// reservada!) em react.dev e figma — sintoma de `no_in` ainda vazando. Faltavam
// CORPO `{…}` (função/método/arrow-com-chaves, todos via parse_block) e
// INTERPOLAÇÃO de template. Ambos são `[+In]` pela spec.

@(test)
m149_in_dentro_de_corpo_de_funcao_no_for_init :: proc(t: ^testing.T) {
    src := `
        var o = {a:1}, r = "";
        for (var f = function(){ return ("a" in o) ? "sim" : "nao" }; r === ""; ) { r = f() }
        r
    `
    testing.expect_value(t, run(src).(string), "sim")
}

@(test)
m149_in_dentro_de_template_no_for_init :: proc(t: ^testing.T) {
    src := `
        var o = {a:1}, s = "";
        for (var q = ` + "`${\"a\" in o}`" + `; s === ""; ) { s = q }
        s
    `
    testing.expect_value(t, run(src).(string), "true")
}

@(test)
m149_in_dentro_de_arrow_conciso_no_for_init :: proc(t: ^testing.T) {
    src := `
        var o = {a:1}, r = "";
        for (var g = () => (("a" in o) ? "sim" : "nao"); r === ""; ) { r = g() }
        r
    `
    testing.expect_value(t, run(src).(string), "sim")
}

@(test)
m149_for_in_segue_intacto_com_corpo :: proc(t: ^testing.T) {
    // CONTRA-CASO: restaurar no_in no BLOCO não pode ter afetado o for-in, cujo
    // cabeçalho é parseado ANTES de qualquer bloco.
    testing.expect_value(t, run("var o={a:1,b:2}, k=''; for (var x in o) { k += x } k").(string), "ab")
}
