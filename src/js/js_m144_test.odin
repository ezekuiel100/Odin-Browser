package js

// M144 — REST com PADRÃO: `function j(e, ...[t]) {}`.
//
// A spec permite um BindingPattern no rest (BindingRestElement : ... BindingPattern),
// não só um nome. É o que o Babel emite ao compilar parâmetro desestruturado, e era
// o que sobrava do cluster de "recuperações de parse" da mineração de 2026-07-22
// (figma 207, angular 31) depois do M143 fechar a vírgula final.
//
// O parser pegava `advance(p).text` como se fosse o NOME do rest — ou seja, o texto
// do token `[` — e o resto do padrão (`t`, `]`) virava lixo em posição de expressão,
// cascateando erro pelo corpo da função inteira.
//
// Fix: `Node.rest_pat`/`Function.rest_pat`; o parser chama parse_pattern quando o
// rest começa com `[` ou `{`, e a chamada desestrutura nele o array já recolhido
// (bind_pattern, o mesmo usado por parâmetro desestruturado comum).

import "core:testing"

@(test)
m144_rest_com_padrao_de_array :: proc(t: ^testing.T) {
    // a forma EXATA do bundle (figma/angular): um param fixo + rest desestruturado.
    testing.expect_value(t, as_number(run("function j(e, ...[t]) { return e + t } j(1, 2)")), f64(3))
}

@(test)
m144_rest_padrao_com_dois_elementos :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("function f(...[a, b]) { return a * 10 + b } f(7, 8)")), f64(78))
}

@(test)
m144_rest_padrao_com_default :: proc(t: ^testing.T) {
    // sem argumento, o default DENTRO do padrão vale (o array recolhido é vazio).
    testing.expect_value(t, as_number(run("function f(...[a = 5]) { return a } f()")), f64(5))
}

@(test)
m144_rest_com_padrao_de_objeto :: proc(t: ^testing.T) {
    // `...{length: n}` — o rest é um array, então o padrão de objeto lê .length.
    testing.expect_value(t, as_number(run("function f(...{length: n}) { return n } f(1, 2, 3)")), f64(3))
}

@(test)
m144_rest_padrao_em_arrow :: proc(t: ^testing.T) {
    // arrow com parênteses usa o MESMO parse_params, então herda o fix.
    testing.expect_value(t, as_number(run("var g = (...[a, b]) => a - b; g(10, 4)")), f64(6))
}

@(test)
m144_rest_padrao_pula_os_params_fixos :: proc(t: ^testing.T) {
    // o padrão tem de casar contra os args APÓS os fixos, não desde o começo:
    // com o off-by-one clássico `t` viraria 1 e o total 11, não 13.
    src := `
        function j(a, b, ...[t, u]) { return a + b + t + u }
        j(1, 2, 3, 7)
    `
    testing.expect_value(t, as_number(run(src)), f64(13))
}

@(test)
m144_rest_simples_segue_igual :: proc(t: ^testing.T) {
    // CONTRA-CASO: o rest por NOME não pode ter mudado de comportamento.
    testing.expect_value(t, as_number(run("function f(...xs) { return xs.length } f(1, 2, 3)")), f64(3))
    testing.expect_value(t, as_number(run("function f(a, ...xs) { return a * 100 + xs.length } f(1, 2, 3)")), f64(102))
}
