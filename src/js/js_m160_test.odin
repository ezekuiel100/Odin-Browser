package js

// M160 — `==` com ToPrimitive + Number::toString pela spec.
//
// Duas divergências que a auditoria do M159 mediu e que aparecem em código real:
//
//   (1) `==` entre OBJETO e PRIMITIVO devolvia sempre false. `[1] == "1"`,
//       `[] == false` e `{toString(){...}} == "x"` são todos true no JS real.
//       O `to_primitive` já existia (o `binop` o usa desde a correção da
//       aritmética); faltava ligá-lo aqui. O caso do React — `objeto == null`
//       tem de continuar FALSE — está no primeiro teste abaixo, porque foi
//       exatamente o bug que a versão anterior deste código consertava.
//
//   (2) A formatação de número seguia o estilo do C: `String(1e-6)` dava
//       "1e-06" (o JS só troca para científica ABAIXO de 1e-6, ou seja "0.000001")
//       e `String(1e-7)` dava "1e-07" em vez de "1e-7" (expoente sem zero à
//       esquerda). Agora write_number segue o Number::toString da spec, partindo
//       dos menores dígitos que fazem round-trip.
//
// Todo número aqui foi conferido contra o valor que um browser real devolve.

import "core:testing"

// ── (1) igualdade frouxa ─────────────────────────────────────────────────────

@(test)
m160_nullish_nao_iguala_objeto :: proc(t: ^testing.T) {
    // A REGRESSÃO a não reintroduzir: `x != null` é onipresente no React, e um
    // objeto que se iguale a null colapsa a árvore inteira.
    testing.expect_value(t, run(`({}) == null`).(bool), false)
    testing.expect_value(t, run(`[] == null`).(bool), false)
    testing.expect_value(t, run(`({}) == undefined`).(bool), false)
    testing.expect_value(t, run(`(function(){}) == null`).(bool), false)
    testing.expect_value(t, run(`null == 0`).(bool), false)
    testing.expect_value(t, run(`undefined == 0`).(bool), false)
    testing.expect_value(t, run(`null == false`).(bool), false)
    testing.expect_value(t, run(`null == undefined`).(bool), true)
    testing.expect_value(t, run(`null == null`).(bool), true)
}

@(test)
m160_objeto_vs_primitivo_coage :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`[1] == "1"`).(bool), true)
    testing.expect_value(t, run(`[1] == 1`).(bool), true)
    testing.expect_value(t, run(`[] == false`).(bool), true)
    testing.expect_value(t, run(`[] == 0`).(bool), true)
    testing.expect_value(t, run(`[0] == false`).(bool), true)
    testing.expect_value(t, run(`["a"] == "a"`).(bool), true)
    testing.expect_value(t, run(`[1,2] == "1,2"`).(bool), true)
    testing.expect_value(t, run(`({toString: function(){ return "x" }}) == "x"`).(bool), true)
    testing.expect_value(t, run(`({valueOf: function(){ return 5 }}) == 5`).(bool), true)
    // valueOf tem precedência sobre toString no hint default
    testing.expect_value(t, run(`({valueOf: function(){ return 1 }, toString: function(){ return "2" }}) == 1`).(bool), true)
    // e o != correspondente
    testing.expect_value(t, run(`[1] != "1"`).(bool), false)
    testing.expect_value(t, run(`[2] == "1"`).(bool), false)
}

@(test)
m160_objeto_vs_objeto_e_identidade :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`({}) == ({})`).(bool), false)
    testing.expect_value(t, run(`[] == []`).(bool), false)
    testing.expect_value(t, run(`var o = {}; o == o`).(bool), true)
    testing.expect_value(t, run(`var a = [1]; a == a`).(bool), true)
    // NÃO coage os dois lados: dois arrays com o mesmo texto seguem diferentes
    testing.expect_value(t, run(`[1] == [1]`).(bool), false)
}

@(test)
m160_primitivos_seguem_como_antes :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`1 == true`).(bool), true)
    testing.expect_value(t, run(`0 == false`).(bool), true)
    testing.expect_value(t, run(`"1" == 1`).(bool), true)
    testing.expect_value(t, run(`"" == 0`).(bool), true)
    testing.expect_value(t, run(`"abc" == "abc"`).(bool), true)
    testing.expect_value(t, run(`"abc" == "abd"`).(bool), false)
    testing.expect_value(t, run(`NaN == NaN`).(bool), false)
    testing.expect_value(t, run(`2 == 2`).(bool), true)
}

@(test)
m160_symbol_nunca_coage :: proc(t: ^testing.T) {
    // Symbol é primitivo e só é igual a si mesmo — não vira número nem texto.
    testing.expect_value(t, run(`var s = Symbol("a"); s == s`).(bool), true)
    testing.expect_value(t, run(`Symbol("a") == Symbol("a")`).(bool), false)
    testing.expect_value(t, run(`Symbol("a") == "a"`).(bool), false)
    testing.expect_value(t, run(`Symbol("a") == ({})`).(bool), false)
}

@(test)
m160_date_usa_hint_string :: proc(t: ^testing.T) {
    // O @@toPrimitive default de Date é STRING (mesma regra que o `+` já segue),
    // então uma Date se compara ao seu texto, não ao timestamp.
    testing.expect_value(t, run(`var d = new Date(0); d == d.toString()`).(bool), true)
}

@(test)
m160_estrito_nao_mudou :: proc(t: ^testing.T) {
    // `===` NUNCA coage: é o contraste que prova que a mudança ficou contida no `==`.
    testing.expect_value(t, run(`[1] === "1"`).(bool), false)
    testing.expect_value(t, run(`[] === false`).(bool), false)
    testing.expect_value(t, run(`"1" === 1`).(bool), false)
    testing.expect_value(t, run(`1 === true`).(bool), false)
}

// ── (2) Number::toString ─────────────────────────────────────────────────────

@(private = "file")
str_of :: proc(src: string) -> string {
    v := run(src)
    s, _ := v.(string)
    return s
}

@(test)
m160_limiar_decimal_vs_cientifica_pequenos :: proc(t: ^testing.T) {
    // O JS só troca para científica ABAIXO de 1e-6. Era o bug mais visível:
    // "1e-06"/"1e-07" (estilo C, com zero à esquerda no expoente).
    testing.expect_value(t, str_of(`String(0.000001)`), "0.000001")
    testing.expect_value(t, str_of(`String(1e-6)`), "0.000001")
    testing.expect_value(t, str_of(`String(1e-7)`), "1e-7")
    testing.expect_value(t, str_of(`String(0.0000001)`), "1e-7")
    testing.expect_value(t, str_of(`String(1e-10)`), "1e-10")
    testing.expect_value(t, str_of(`String(1.5e-7)`), "1.5e-7")
    testing.expect_value(t, str_of(`String(0.00001)`), "0.00001")
    testing.expect_value(t, str_of(`String(0.0001)`), "0.0001")
    testing.expect_value(t, str_of(`String(5e-324)`), "5e-324")
}

@(test)
m160_limiar_decimal_vs_cientifica_grandes :: proc(t: ^testing.T) {
    // 1e21 é a fronteira: até 1e20 a spec escreve os zeros; de 1e21 em diante,
    // notação científica com "e+".
    testing.expect_value(t, str_of(`String(1e20)`), "100000000000000000000")
    testing.expect_value(t, str_of(`String(1e21)`), "1e+21")
    testing.expect_value(t, str_of(`String(1e22)`), "1e+22")
    testing.expect_value(t, str_of(`String(1.5e21)`), "1.5e+21")
    testing.expect_value(t, str_of(`String(1.7976931348623157e308)`), "1.7976931348623157e+308")
}

@(test)
m160_formas_decimais_comuns :: proc(t: ^testing.T) {
    testing.expect_value(t, str_of(`String(0.1)`), "0.1")
    testing.expect_value(t, str_of(`String(1.5)`), "1.5")
    testing.expect_value(t, str_of(`String(0.1 + 0.2)`), "0.30000000000000004")
    testing.expect_value(t, str_of(`String(1234.5678)`), "1234.5678")
    testing.expect_value(t, str_of(`String(100)`), "100")
    testing.expect_value(t, str_of(`String(1e6)`), "1000000")
    testing.expect_value(t, str_of(`String(-0.5)`), "-0.5")
    testing.expect_value(t, str_of(`String(1/3)`), "0.3333333333333333")
}

@(test)
m160_casos_especiais :: proc(t: ^testing.T) {
    testing.expect_value(t, str_of(`String(0)`), "0")
    testing.expect_value(t, str_of(`String(-0)`), "0")
    testing.expect_value(t, str_of(`String(NaN)`), "NaN")
    testing.expect_value(t, str_of(`String(Infinity)`), "Infinity")
    testing.expect_value(t, str_of(`String(-Infinity)`), "-Infinity")
    testing.expect_value(t, str_of(`String(-1e-7)`), "-1e-7")
    testing.expect_value(t, str_of(`String(Number.MAX_SAFE_INTEGER)`), "9007199254740991")
}

@(test)
m160_mesma_formatacao_em_todos_os_caminhos :: proc(t: ^testing.T) {
    // String(), concatenação, template e .toString() têm de concordar — todos
    // desembocam no mesmo write_number.
    testing.expect_value(t, str_of(`"" + 1e-7`), "1e-7")
    testing.expect_value(t, str_of("`${1e-7}`"), "1e-7")
    testing.expect_value(t, str_of(`(1e-7).toString()`), "1e-7")
    testing.expect_value(t, str_of(`[1e-7].join("")`), "1e-7")
    testing.expect_value(t, str_of(`JSON.stringify(1e-7)`), "1e-7")
    testing.expect_value(t, str_of(`"" + 1e21`), "1e+21")
    testing.expect_value(t, str_of(`(0.000001).toString()`), "0.000001")
    // toString com radix != 10 segue por outro caminho e não foi tocado
    testing.expect_value(t, str_of(`(255).toString(16)`), "ff")
}

@(test)
m160_numero_sobrevive_ao_round_trip :: proc(t: ^testing.T) {
    // A propriedade que o algoritmo garante: o texto reparseado dá o mesmo double.
    src := `
        var vs = [1e-7, 1e-6, 1e20, 1e21, 0.1, 1/3, 0.1+0.2, 1234.5678, 5e-324,
                  1.7976931348623157e308, -1e-7, 123456789012345680000];
        var ruins = [];
        for (var i = 0; i < vs.length; i++) {
            if (Number(String(vs[i])) !== vs[i]) ruins.push(String(vs[i]));
        }
        ruins.length;
    `
    testing.expect_value(t, as_number(run(src)), f64(0))
}
