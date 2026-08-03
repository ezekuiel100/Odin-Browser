package js

// M145 — ESCAPE UNICODE em identificador (`ɵinject`).
//
// Alvo escolhido por dado: depois que o M143/M144 derrubaram as recuperações de
// parse de 337 p/ 99, o topo do que sobrou era angular.dev com 31, todas
// `caractere(s) desconhecido(s) ignorado(s) no lexer` em torno de `u0275`.
// `ɵ` é `ɵ` — o prefixo Ivy do Angular. O bundle escreve `ɵɵinject`,
// e como o lexer não conhecia a barra, ela virava "caractere desconhecido" e UM
// nome virava DOIS identificadores (`u0275` e `u0275inject`), quebrando a expressão.
//
// Identificador unicode LITERAL (π, café, ɵ) já funcionava — `is_ident_start`
// aceita byte >= 0x80. O que faltava era só a forma escapada.

import "core:testing"

@(test)
m145_identificador_escapado :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var \\u0275x = 5; \\u0275x")), f64(5))
}

@(test)
m145_escapado_e_literal_sao_A_MESMA_variavel :: proc(t: ^testing.T) {
    // O CORAÇÃO do fix: o nome tem de ser DECODIFICADO, não guardado cru. Se
    // ficássemos com a fatia do fonte, `ɵx` e `ɵx` seriam variáveis
    // diferentes e este teste pegaria — declara numa forma, lê na outra.
    testing.expect_value(t, as_number(run("var ɵx = 1; \\u0275x")), f64(1))
    testing.expect_value(t, as_number(run("var \\u0275y = 2; ɵy")), f64(2))
}

@(test)
m145_idioma_ivy_do_angular :: proc(t: ^testing.T) {
    // a forma EXATA do bundle: dois escapes seguidos + resto do nome em ASCII.
    src := `
        var obj = { ɵɵinject: 7 };
        var ɵɵinject = obj.ɵɵinject;
        ɵɵinject
    `
    testing.expect_value(t, as_number(run(src)), f64(7))
}

@(test)
m145_escape_no_meio_do_nome :: proc(t: ^testing.T) {
    // IdentifierPart também aceita escape, não só IdentifierStart.
    testing.expect_value(t, as_number(run("var a\\u0275b = 9; aɵb")), f64(9))
}

@(test)
m145_forma_com_chaves :: proc(t: ^testing.T) {
    // `\u{...}` (ES6) além da forma de 4 dígitos.
    testing.expect_value(t, as_number(run("var \\u{275}z = 4; ɵz")), f64(4))
}

@(test)
m145_nome_de_propriedade_escapado :: proc(t: ^testing.T) {
    // acesso a membro usa o mesmo lexema: `obj.a` é `obj.a`.
    testing.expect_value(t, as_number(run("var o = { a: 6 }; o.\\u0061")), f64(6))
}

@(test)
m145_unicode_literal_segue_funcionando :: proc(t: ^testing.T) {
    // CONTRA-CASO 1: o caminho antigo (byte >= 0x80) não pode ter regredido.
    testing.expect_value(t, as_number(run("var café = 3; café")), f64(3))
    testing.expect_value(t, as_number(run("var π = 8; π")), f64(8))
}

@(test)
m145_escape_em_string_nao_muda :: proc(t: ^testing.T) {
    // CONTRA-CASO 2: escape dentro de STRING continua sendo escape de string —
    // o novo caminho é só para identificador.
    testing.expect_value(t, run("'\\u0275'.length").(f64), f64(1))
    testing.expect_value(t, run("typeof '\\u0275'").(string), "string")
}

@(test)
m145_escape_malformado_nao_trava :: proc(t: ^testing.T) {
    // ROBUSTEZ: `\uZZZZ` NÃO é identificador válido; `lex_ident_run` devolve
    // next==start nesse caso e quem chama TEM de avançar por conta — sem esse
    // guarda o lexer ficava preso na mesma posição para sempre.
    //
    // Vai direto no `tokenize` em vez do `run`: o harness entra em PÂNICO se o
    // JS de um teste parseia com recuperação silenciosa, e aqui a recuperação é
    // justamente o que se quer exercitar. (Se o guarda sumir, este teste PENDURA
    // em vez de falhar — é o sintoma do bug que ele cobre.)
    toks, owned, bad := tokenize("var ok = 1; \\uZZZZ; ok")
    defer { delete(toks); for s in owned do delete(s); delete(owned) }
    testing.expect(t, bad > 0, "a barra malformada devia contar como caractere descartado")
    testing.expect(t, len(toks) > 0, "o lexer devia ter terminado e emitido tokens")
    // e o que era válido antes/depois continua lá: `var`, `ok`, `1`, `ok`
    n_ok := 0
    for tk in toks do if tk.kind == .Ident && tk.text == "ok" do n_ok += 1
    testing.expect_value(t, n_ok, 2)
}
