package js

// M163 — property escapes `\p{...}` / `\P{...}` no regex.
//
// Última divergência de regex das sondas. Uma categoria Unicode não cabe em
// ranges (seriam milhares), então a classe passou a carregar PREDICADOS ao lado
// dos ranges, e o matcher os consulta. As tabelas vêm do `core:unicode` do Odin
// (geradas do UCD) — nenhuma tabela escrita à mão aqui.
//
// Duas fronteiras deliberadas, ambas com teste:
//   • Só COM a flag `u`. Sem ela a spec diz que `\p` é o literal 'p', e é o que
//     este motor já fazia — mudar isso quebraria padrões que hoje funcionam.
//   • Nome NÃO reconhecido (o caso real é `Script=...`, que exigiria tabelas de
//     script que o core:unicode não expõe) casa NADA, em vez de lançar
//     SyntaxError (derrubaria o script inteiro por um regex de enfeite) ou de
//     casar a string literal "p{...}", que era o comportamento antigo.

import "core:testing"

@(test)
m163_categorias_gerais :: proc(t: ^testing.T) {
    // letras, de vários alfabetos
    testing.expect_value(t, run(`/\p{L}/u.test("a")`).(bool), true)
    testing.expect_value(t, run(`/\p{L}/u.test("é")`).(bool), true)
    testing.expect_value(t, run(`/\p{L}/u.test("Ж")`).(bool), true)
    testing.expect_value(t, run(`/\p{L}/u.test("中")`).(bool), true)
    testing.expect_value(t, run(`/\p{L}/u.test("1")`).(bool), false)
    testing.expect_value(t, run(`/\p{L}/u.test(" ")`).(bool), false)
    testing.expect_value(t, run(`/\p{Letter}/u.test("x")`).(bool), true)
    testing.expect_value(t, run(`/\p{Alphabetic}/u.test("x")`).(bool), true)

    // caixa
    testing.expect_value(t, run(`/\p{Lu}/u.test("A")`).(bool), true)
    testing.expect_value(t, run(`/\p{Lu}/u.test("a")`).(bool), false)
    testing.expect_value(t, run(`/\p{Ll}/u.test("a")`).(bool), true)
    testing.expect_value(t, run(`/\p{Ll}/u.test("A")`).(bool), false)
    testing.expect_value(t, run(`/\p{Uppercase}/u.test("Ç")`).(bool), true)

    // números
    testing.expect_value(t, run(`/\p{N}/u.test("7")`).(bool), true)
    testing.expect_value(t, run(`/\p{Nd}/u.test("7")`).(bool), true)
    testing.expect_value(t, run(`/\p{N}/u.test("a")`).(bool), false)

    // pontuação, símbolo, espaço, controle
    testing.expect_value(t, run(`/\p{P}/u.test(",")`).(bool), true)
    testing.expect_value(t, run(`/\p{P}/u.test("a")`).(bool), false)
    testing.expect_value(t, run(`/\p{S}/u.test("+")`).(bool), true)
    testing.expect_value(t, run(`/\p{White_Space}/u.test(" ")`).(bool), true)
    testing.expect_value(t, run(`/\p{White_Space}/u.test("a")`).(bool), false)
    testing.expect_value(t, run(`/\p{ASCII}/u.test("a")`).(bool), true)
    testing.expect_value(t, run(`/\p{ASCII}/u.test("é")`).(bool), false)
    testing.expect_value(t, run(`/\p{Any}/u.test("é")`).(bool), true)
}

@(test)
m163_negado_com_P_maiusculo :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`/\P{L}/u.test("1")`).(bool), true)
    testing.expect_value(t, run(`/\P{L}/u.test("a")`).(bool), false)
    testing.expect_value(t, run(`/\P{N}/u.test("a")`).(bool), true)
    testing.expect_value(t, run(`/^\P{L}+$/u.test("123 ")`).(bool), true)
    testing.expect_value(t, run(`/^\P{L}+$/u.test("12a")`).(bool), false)
}

@(test)
m163_dentro_de_classe :: proc(t: ^testing.T) {
    // combinado com ranges e atalhos no MESMO colchete
    testing.expect_value(t, run(`/[\p{L}\d]/u.test("a")`).(bool), true)
    testing.expect_value(t, run(`/[\p{L}\d]/u.test("5")`).(bool), true)
    testing.expect_value(t, run(`/[\p{L}\d]/u.test("!")`).(bool), false)
    testing.expect_value(t, run(`/[\p{Lu}_]/u.test("_")`).(bool), true)
    testing.expect_value(t, run(`/[0-9\p{L}]/u.test("é")`).(bool), true)
    // classe NEGADA contendo property
    testing.expect_value(t, run(`/[^\p{L}]/u.test("1")`).(bool), true)
    testing.expect_value(t, run(`/[^\p{L}]/u.test("a")`).(bool), false)
    // duas properties na mesma classe
    testing.expect_value(t, run(`/^[\p{L}\p{N}]+$/u.test("abc123")`).(bool), true)
    testing.expect_value(t, run(`/^[\p{L}\p{N}]+$/u.test("abc-123")`).(bool), false)
}

@(test)
m163_com_quantificador_e_extracao :: proc(t: ^testing.T) {
    str :: proc(src: string) -> string {
        v := run(src)
        s, _ := v.(string)
        return s
    }
    testing.expect_value(t, run(`/^\p{L}+$/u.test("olá")`).(bool), true)
    testing.expect_value(t, run(`/^\p{L}+$/u.test("olá!")`).(bool), false)
    testing.expect_value(t, str(`"ab12cd".match(/\p{L}+/u)[0]`), "ab")
    testing.expect_value(t, str(`"João, 42".replace(/\p{L}+/gu, "X")`), "X, 42")
    testing.expect_value(t, str(`"a1b2".replace(/\p{N}/gu, "#")`), "a#b#")
    // com grupo de captura
    testing.expect_value(t, str(`"nome: José".match(/(\p{Lu}\p{Ll}+)/u)[1]`), "José")
}

@(test)
m163_sem_flag_u_mantem_sentido_antigo :: proc(t: ^testing.T) {
    // SEM `u`, `\p` é o literal 'p' — é o que a spec manda e o que já fazíamos.
    testing.expect_value(t, run(`/\p/.test("p")`).(bool), true)
    testing.expect_value(t, run(`/\p{L}/.test("p{L}")`).(bool), true)
    testing.expect_value(t, run(`/\p{L}/.test("a")`).(bool), false)
    testing.expect_value(t, run(`/[\p]/.test("p")`).(bool), true)
}

@(test)
m163_nome_desconhecido_casa_nada :: proc(t: ^testing.T) {
    // DEGRADAÇÃO ANOTADA: `Script=...` precisaria de tabelas de script que o
    // core:unicode não expõe. Casa NADA — não lança (derrubaria o script) e não
    // casa o literal "p{Script=Han}" (que era o comportamento antigo, absurdo).
    testing.expect_value(t, run(`/\p{Script=Han}/u.test("中")`).(bool), false)
    testing.expect_value(t, run(`/\p{Script=Han}/u.test("p{Script=Han}")`).(bool), false)
    testing.expect_value(t, run(`/\p{Bidi_Control}/u.test("a")`).(bool), false)
    // e a regex COMPILA (não lança) — é o que impede o bundle inteiro de morrer
    testing.expect_value(t, run(`(function(){ try { new RegExp("\\p{Script=Han}","u"); return "ok" } catch(e){ return e.name } })()`).(string), "ok")
    // `\P{desconhecido}` é o complemento de "nada" = casa qualquer char
    testing.expect_value(t, run(`/\P{Script=Han}/u.test("a")`).(bool), true)
}

@(test)
m163_regex_sem_property_nao_mudou :: proc(t: ^testing.T) {
    // controle: o resto do motor de classes segue igual
    testing.expect_value(t, run(`/\d+/.test("123")`).(bool), true)
    testing.expect_value(t, run(`/[a-z]+/.test("abc")`).(bool), true)
    testing.expect_value(t, run(`/[^a-z]/.test("A")`).(bool), true)
    testing.expect_value(t, run(`/[\s\S]/.test("\n")`).(bool), true)
    testing.expect_value(t, run(`/[\d\-]/.test("-")`).(bool), true)
    testing.expect_value(t, run(`/\w+/.test("a_1")`).(bool), true)
    testing.expect_value(t, run(`/[A-Z]+/.test("ABC")`).(bool), true)
    testing.expect_value(t, run(`/\u{1F600}/u.test("\u{1F600}")`).(bool), true) // M162 segue de pé
}
