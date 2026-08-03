package js

import "core:testing"

// ── M86: regex lookbehind (?<=...) e (?<!...) ────────────────────────────────
// Antes viravam SyntaxError. Casam PARA TRÁS: no ponto sp, procura j<=sp tal que
// o sub case exatamente s[j..sp] (zero-width, não consome). Suporta comprimento
// variável (a+, alternância). lb_target no Re_Ctx faz o Match do sub exigir o fim
// na posição-alvo; save/restore cobre aninhamento com lookahead.

// positivo: dígitos precedidos de '$'.
@(test)
test_lookbehind_positivo :: proc(t: ^testing.T) {
    src := `"$100".match(/(?<=\$)\d+/)[0]`
    v, _ := run(src).(string)
    testing.expect(t, v == "100", "(?<=\\$)\\d+ deve casar os dígitos após '$'")
}

// o lookbehind NÃO entra no match (zero-width) — index aponta p/ o dígito.
@(test)
test_lookbehind_index :: proc(t: ^testing.T) {
    src := `"$100".match(/(?<=\$)\d+/).index`
    testing.expect_value(t, as_number(run(src)), f64(1))
}

// negativo: dígito NÃO precedido de '-'.
@(test)
test_lookbehind_negativo :: proc(t: ^testing.T) {
    src := `"-12".match(/(?<!-)\d+/)[0]`
    v, _ := run(src).(string)
    testing.expect(t, v == "2", "(?<!-)\\d+ deve pular o dígito logo após '-'")
}

// negativo que falha totalmente → null.
@(test)
test_lookbehind_negativo_sem_match :: proc(t: ^testing.T) {
    testing.expect(t, !truthy(run(`/(?<!x)y/.test("xy")`)), "(?<!x)y não deve casar 'y' após 'x'")
    testing.expect(t,  truthy(run(`/(?<!x)y/.test("ay")`)), "(?<!x)y deve casar 'y' após 'a'")
}

// comprimento VARIÁVEL: a+.
@(test)
test_lookbehind_variavel :: proc(t: ^testing.T) {
    src := `var m = /(?<=a+)b/.exec("aaab"); m[0] + ':' + m.index`
    v, _ := run(src).(string)
    testing.expect(t, v == "b:3", "lookbehind de comprimento variável (a+) deve casar")
}

// alternância dentro do lookbehind.
@(test)
test_lookbehind_alternancia :: proc(t: ^testing.T) {
    src := `("cats and dogs".match(/(?<=cat|dog)s/g) || []).join(',')`
    v, _ := run(src).(string)
    testing.expect(t, v == "s,s", "(?<=cat|dog)s deve casar após cat E dog")
}

// captura DENTRO do lookbehind.
@(test)
test_lookbehind_captura :: proc(t: ^testing.T) {
    src := `var m = /(?<=(\d))X/.exec("5X"); m[0] + ':' + m[1]`
    v, _ := run(src).(string)
    testing.expect(t, v == "X:5", "captura dentro de lookbehind deve funcionar")
}

// lookbehind combinado com lookahead (aninhamento não confunde os terminais).
@(test)
test_lookbehind_com_lookahead :: proc(t: ^testing.T) {
    src := `("a1b2c3".match(/(?<=[a-z])\d(?=[a-z]|$)/g) || []).join(',')`
    v, _ := run(src).(string)
    testing.expect(t, v == "1,2,3", "lookbehind + lookahead juntos devem casar cada dígito")
}

// replace com lookbehind (inserir separador de milhar simplificado).
@(test)
test_lookbehind_replace :: proc(t: ^testing.T) {
    src := `"abc".replace(/(?<=b)c/, "X")`
    v, _ := run(src).(string)
    testing.expect(t, v == "abX", "replace deve usar o lookbehind para localizar")
}

// grupo NOMEADO (?<nome>...) segue funcionando (não confundido com lookbehind).
@(test)
test_named_group_ainda_funciona :: proc(t: ^testing.T) {
    src := `/(?<year>\d{4})/.exec("2024").groups.year`
    v, _ := run(src).(string)
    testing.expect(t, v == "2024", "grupo nomeado deve continuar funcionando após lookbehind")
}
