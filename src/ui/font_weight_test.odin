package ui

// font-weight guarda o NÚMERO do CSS (1..1000). Duas camadas, testadas aqui:
//
//  1. o Computed tem o peso PEDIDO, inteiro — é o que chega à @font-face, e
//     uma fonte variável (`font-weight: 100 900`) instancia exatamente ele. Era
//     um enum de 3 degraus e o 300 virava 400, o 900 virava 700 (animate.style).
//  2. a face EMBUTIDA (Segoe UI 400/600/700) quantiza por `fw_class`.
//     ⚠️ 500 fica REGULAR de propósito: é a regra de font-matching do CSS
//     (Fonts 4 §5.2.1) — p/ um alvo entre 400 e 500 procura-se ATÉ 500 em ordem
//     crescente e, não achando, DESCE; logo 500 → 400. Verificado lado a lado
//     com o Chrome: 300/400/500 saem idênticos, só o 600 engrossa.

import "core:testing"
import htmlp "../html"
import csspkg "../css"
import dompkg "../dom"

@(private = "file")
peso :: proc(decl: string) -> int {
    return fw_css(test_apply(decl).weight)
}

@(test)
test_weight_guarda_o_numero_pedido :: proc(t: ^testing.T) {
    testing.expect_value(t, peso("font-weight: 700"), 700)
    testing.expect_value(t, peso("font-weight: bold"), 700)
    testing.expect_value(t, peso("font-weight: 900"), 900)
    testing.expect_value(t, peso("font-weight: 600"), 600)
    testing.expect_value(t, peso("font-weight: 500"), 500)
    testing.expect_value(t, peso("font-weight: 400"), 400)
    testing.expect_value(t, peso("font-weight: 300"), 300)
    testing.expect_value(t, peso("font-weight: 100"), 100)
    testing.expect_value(t, peso("font-weight: normal"), 400)
    // Fonts 4: qualquer <number> em [1,1000], não só as centenas
    testing.expect_value(t, peso("font-weight: 450"), 450)
    testing.expect_value(t, peso("font-weight: 1000"), 1000)
    testing.expect_value(t, peso("font-weight: 1"), 1)
    // fora da faixa / com unidade / lixo: inválido, mantém o herdado (normal)
    testing.expect_value(t, peso("font-weight: 0"), 400)
    testing.expect_value(t, peso("font-weight: 1001"), 400)
    testing.expect_value(t, peso("font-weight: 700px"), 400)
    testing.expect_value(t, peso("font-weight: -300"), 400)
    testing.expect_value(t, peso("font-weight: heavy"), 400)
}

@(test)
test_weight_shorthand_font_guarda_o_numero :: proc(t: ^testing.T) {
    testing.expect_value(t, peso("font: 300 14px Arial"), 300)
    testing.expect_value(t, peso("font: italic 900 1rem sans-serif"), 900)
    testing.expect_value(t, peso("font: 14px Arial"), 400) // reset p/ o inicial
}

// A face embutida: os 3 degraus e as fronteiras da regra de matching.
@(test)
test_weight_classe_da_face_embutida :: proc(t: ^testing.T) {
    casos := [?]struct { w: int, c: Weight_Class }{
        {0, .Regular}, // zero-value = normal
        {100, .Regular}, {300, .Regular}, {400, .Regular}, {500, .Regular},
        {501, .Semi}, {550, .Semi}, {600, .Semi},
        {601, .Bold}, {700, .Bold}, {900, .Bold}, {1000, .Bold},
    }
    for k in casos {
        testing.expectf(t, fw_class(Font_Weight(k.w)) == k.c, "%d → %v, veio %v", k.w, k.c, fw_class(Font_Weight(k.w)))
    }
}

@(test)
test_weight_zero_value_e_normal :: proc(t: ^testing.T) {
    // sem declaração: o zero-value tem de LER como o default do CSS
    c := test_apply("color: red")
    testing.expect_value(t, fw_css(c.weight), 400)
    testing.expect_value(t, fw_class(c.weight), Weight_Class.Regular)
}

@(private = "file")
peso_do_no :: proc(html_src, css: string, tag: string) -> int {
    dom := htmlp.parse(html_src)
    rules, _ := csspkg.parse(css)
    styles, _ := compute_styles(dom, &rules, 800, 600)
    alvo: ^dompkg.Node
    walk :: proc(n: ^dompkg.Node, tag: string, out: ^^dompkg.Node) {
        if n.kind == .Element && n.tag == tag && out^ == nil do out^ = n
        for c in n.children do walk(c, tag, out)
    }
    walk(dom, tag, &alvo)
    if alvo == nil do return -1
    return fw_css(styles[alvo].weight)
}

// O negrito de heading é do UA e tem de PERDER p/ o autor — antes era aplicado
// no layout (`comp.bold || is_heading`), depois da cascata, e um
// `h3{font-weight:500}` ainda saía 700 (o Chrome renderiza regular).
@(test)
test_weight_heading_e_default_do_ua_e_o_autor_vence :: proc(t: ^testing.T) {
    testing.expect_value(t, peso_do_no("<h3>x</h3>", "", "h3"), 700)
    testing.expect_value(t, peso_do_no("<h3>x</h3>", "h3 { font-weight: 500 }", "h3"), 500)
    testing.expect_value(t, peso_do_no("<h3>x</h3>", "h3 { font-weight: 300 }", "h3"), 300)
    // e o peso do heading HERDA p/ os filhos (o texto dentro sai negrito)
    testing.expect_value(t, peso_do_no("<h2><span>x</span></h2>", "", "span"), 700)
    testing.expect_value(t, peso_do_no("<div><span>x</span></div>", "div { font-weight: 900 }", "span"), 900)
}

// bolder/lighter são RELATIVOS ao peso do pai (Fonts 4 §2.2). Antes `bolder`
// valia 700 fixo e `lighter` era ignorado.
@(test)
test_weight_bolder_lighter_relativos_ao_pai :: proc(t: ^testing.T) {
    caso :: proc(t: ^testing.T, pai: string, kw: string, want: int) {
        got := peso_do_no("<div><b>x</b></div>",
            fmt_css("div { font-weight: %s } b { font-weight: %s }", pai, kw), "b")
        testing.expectf(t, got == want, "pai %s + %s → %d, veio %d", pai, kw, want, got)
    }
    caso(t, "100", "bolder", 400)
    caso(t, "300", "bolder", 400)
    caso(t, "400", "bolder", 700)
    caso(t, "700", "bolder", 900)
    caso(t, "900", "bolder", 900)
    caso(t, "900", "lighter", 700)
    caso(t, "700", "lighter", 400)
    caso(t, "400", "lighter", 100)
    caso(t, "100", "lighter", 100)
    // o caso do h1..h6: o UA já pôs 700 no próprio heading, mas o relativo é
    // contra o PAI (400) — `h2{font-weight:bolder}` dentro de texto normal é 700,
    // não 900; `lighter` dá 100, não 400.
    testing.expect_value(t, peso_do_no("<div><h2>x</h2></div>", "h2 { font-weight: bolder }", "h2"), 700)
    testing.expect_value(t, peso_do_no("<div><h2>x</h2></div>", "h2 { font-weight: lighter }", "h2"), 100)
}

@(private = "file")
fmt_css :: proc(f: string, a, b: string) -> string {
    // `fmt.tprintf` não serve p/ montar CSS: o `{` é chave de formatação.
    out := make([dynamic]u8, context.temp_allocator)
    arg := 0
    for i := 0; i < len(f); i += 1 {
        if i + 1 < len(f) && f[i] == '%' && f[i + 1] == 's' {
            append(&out, arg == 0 ? a : b)
            arg += 1
            i += 1
            continue
        }
        append(&out, f[i])
    }
    return string(out[:])
}
