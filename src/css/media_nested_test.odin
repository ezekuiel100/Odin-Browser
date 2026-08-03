package css

// O atributo `media` do <link> vale p/ a folha INTEIRA e era IGNORADO: uma
// folha `media="print"` entrava como se fosse de tela (folha de impressão
// costuma esconder nav/sidebar e trocar as cores para tinta). O coletor passou
// a envolver a folha baixada num `@media <attr> { … }`, e a avaliação fica com
// a máquina que já existe. Estes testes pinam o que essa máquina precisa
// garantir: o tipo `print` exclui, `screen` aplica, e o wrapper COMPÕE com os
// @media de dentro da folha (nesting) em vez de anular um deles.

import "core:testing"

@(private = "file")
first_rule_applies :: proc(css: string, vw: f32 = 800) -> (aplicou: bool, achou: bool) {
    rules, _ := parse(css)
    defer free_rules(&rules)
    for r in rules {
        for s in r.selectors do if len(s.parts) > 0 && s.parts[0].tag == "p" {
            return media_matches(r, vw), true
        }
    }
    return false, false
}

@(test)
test_link_media_print_exclui_a_folha :: proc(t: ^testing.T) {
    ap, achou := first_rule_applies(`@media print { p { color: red } }`)
    testing.expect(t, achou, "regra parseada")
    testing.expect(t, !ap, "folha de impressao NAO aplica na tela")
}

@(test)
test_link_media_screen_aplica :: proc(t: ^testing.T) {
    ap, achou := first_rule_applies(`@media screen { p { color: red } }`)
    testing.expect(t, achou && ap, "media=screen aplica")
}

@(test)
test_link_media_compoe_com_o_de_dentro :: proc(t: ^testing.T) {
    // wrapper screen + @media interno de largura: compõem (AND), não se anulam
    css :: `@media screen { @media (min-width: 600px) { p { color: red } } }`
    largo, achou := first_rule_applies(css, 800)
    testing.expect(t, achou && largo, "600px+ com viewport 800 aplica")
    estreito, _ := first_rule_applies(css, 400)
    testing.expect(t, !estreito, "mesmo com screen, 400 < min-width nao aplica")

    // wrapper print manda mesmo com o interno casando
    pr, _ := first_rule_applies(`@media print { @media (min-width: 600px) { p { color: red } } }`, 800)
    testing.expect(t, !pr, "wrapper print exclui o que esta dentro")
}

@(test)
test_link_media_condicao_de_largura_no_wrapper :: proc(t: ^testing.T) {
    // `<link media="(min-width: 700px)">` — sem media-type, só a feature
    css :: `@media (min-width: 700px) { p { color: red } }`
    a, _ := first_rule_applies(css, 800)
    b, _ := first_rule_applies(css, 600)
    testing.expect(t, a, "800 >= 700 aplica")
    testing.expect(t, !b, "600 < 700 nao aplica")
}
