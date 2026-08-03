package ui

// font-weight: a engine tinha só DOIS pesos (`bold: bool`), então 500 e 600 —
// o peso que todo design moderno usa em título/botão (Tailwind `font-medium`/
// `font-semibold`, Bootstrap `.fw-semibold`) — caíam em REGULAR e o texto saía
// fino demais perto do Chrome. Agora `Font_Weight{Regular,Semi,Bold}` (1 byte,
// o mesmo do bool que substituiu) com a face Segoe UI Semibold no atlas.
//
// ⚠️ 500 fica REGULAR de propósito: é a regra de font-matching do CSS (Fonts 4
// §5.2.1) — p/ um alvo entre 400 e 500 procura-se ATÉ 500 em ordem crescente e,
// não achando, DESCE; a Segoe UI tem 400/600/700, logo 500 → 400. Verificado
// lado a lado com o Chrome: 300/400/500 saem idênticos, só o 600 engrossa.

import "core:testing"
import htmlp "../html"
import csspkg "../css"
import dompkg "../dom"

@(private = "file")
peso :: proc(decl: string) -> Font_Weight {
    return test_apply(decl).weight
}

@(test)
test_weight_mapeia_os_valores_numericos :: proc(t: ^testing.T) {
    testing.expect_value(t, peso("font-weight: 700"), Font_Weight.Bold)
    testing.expect_value(t, peso("font-weight: bold"), Font_Weight.Bold)
    testing.expect_value(t, peso("font-weight: 900"), Font_Weight.Bold)
    testing.expect_value(t, peso("font-weight: 600"), Font_Weight.Semi)
    testing.expect_value(t, peso("font-weight: 500"), Font_Weight.Regular) // ver a regra acima
    testing.expect_value(t, peso("font-weight: 400"), Font_Weight.Regular)
    testing.expect_value(t, peso("font-weight: 300"), Font_Weight.Regular)
    testing.expect_value(t, peso("font-weight: normal"), Font_Weight.Regular)
}

@(test)
test_weight_zero_value_e_regular :: proc(t: ^testing.T) {
    // sem declaração: o zero-value do enum tem de ser o default do CSS
    c := test_apply("color: red")
    testing.expect_value(t, c.weight, Font_Weight.Regular)
}

@(private = "file")
peso_do_no :: proc(html_src, css: string, tag: string) -> Font_Weight {
    dom := htmlp.parse(html_src)
    rules, _ := csspkg.parse(css)
    styles, _ := compute_styles(dom, &rules, 800, 600)
    alvo: ^dompkg.Node
    walk :: proc(n: ^dompkg.Node, tag: string, out: ^^dompkg.Node) {
        if n.kind == .Element && n.tag == tag && out^ == nil do out^ = n
        for c in n.children do walk(c, tag, out)
    }
    walk(dom, tag, &alvo)
    if alvo == nil do return .Regular
    return styles[alvo].weight
}

// O negrito de heading é do UA e tem de PERDER p/ o autor — antes era aplicado
// no layout (`comp.bold || is_heading`), depois da cascata, e um
// `h3{font-weight:500}` ainda saía 700 (o Chrome renderiza regular).
@(test)
test_weight_heading_e_default_do_ua_e_o_autor_vence :: proc(t: ^testing.T) {
    testing.expect_value(t, peso_do_no("<h3>x</h3>", "", "h3"), Font_Weight.Bold)
    testing.expect_value(t, peso_do_no("<h3>x</h3>", "h3 { font-weight: 500 }", "h3"), Font_Weight.Regular)
    testing.expect_value(t, peso_do_no("<h3>x</h3>", "h3 { font-weight: 600 }", "h3"), Font_Weight.Semi)
    // e o peso do heading HERDA p/ os filhos (o texto dentro sai negrito)
    testing.expect_value(t, peso_do_no("<h2><span>x</span></h2>", "", "span"), Font_Weight.Bold)
}
