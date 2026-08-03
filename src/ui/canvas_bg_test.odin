package ui

// FUNDO DO CANVAS (css-backgrounds §2.11.2). Quem manda é o ELEMENTO RAIZ: seu
// fundo vira o do canvas e cobre o viewport inteiro. Só quando a raiz NÃO tem
// fundo é que o do <body> propaga no lugar dela (quirk histórico do HTML).
//
// Antes, `compute_styles` olhava APENAS o <body>: uma página com
// `html{background:#333}` — php.net e todo tema escuro — ficava BRANCA abaixo
// do fim do conteúdo, porque o #333 só pintava a caixa do <html>.

import "core:testing"
import htmlp "../html"
import csspkg "../css"

@(private = "file")
canvas :: proc(css: string, html_src := `<html><body><p>x</p></body></html>`) -> (bg: u32, fonte: string) {
    dom := htmlp.parse(html_src)
    rules, _ := csspkg.parse(css)
    styles, page_bg := compute_styles(dom, &rules, 800, 600)
    for n, c in styles {
        if c.bg_canvas do return page_bg, n.tag
    }
    return page_bg, ""
}

@(test)
test_canvas_bg_vem_da_raiz :: proc(t: ^testing.T) {
    bg, fonte := canvas(`html { background: #332211 } body { background: #ffffff }`)
    testing.expect_value(t, bg, 0x332211) // a RAIZ ganha do body
    testing.expect_value(t, fonte, "html")
}

@(test)
test_canvas_bg_cai_no_body_sem_fundo_na_raiz :: proc(t: ^testing.T) {
    bg, fonte := canvas(`body { background: #123456 }`)
    testing.expect_value(t, bg, 0x123456)
    testing.expect_value(t, fonte, "body")
}

@(test)
test_canvas_bg_gradiente_tambem_propaga :: proc(t: ^testing.T) {
    // sem background-color, mas com gradiente: o elemento ainda é a fonte do
    // canvas (o paint estende a ÁREA dele à página toda)
    _, fonte := canvas(`body { background: linear-gradient(#000, #fff) }`)
    testing.expect_value(t, fonte, "body")
}

@(test)
test_canvas_bg_branco_quando_ninguem_tem :: proc(t: ^testing.T) {
    bg, fonte := canvas(`p { background: #ff0000 }`)
    testing.expect_value(t, bg, 0xffffff)
    testing.expect_value(t, fonte, "") // ninguém é fonte do canvas
}

// ⚠️ cor TRANSLÚCIDA não entra no page_bg. O backdrop da página é BRANCO e a
// composição tem de acontecer UMA vez: como a área de pintura do elemento já É
// o canvas, quem compõe é o paint dele. Somar no page_bg também escurecia —
// foi o reftest `css/compositing/root-element-background-transparency`
// (`html{background:rgba(45,45,45,.5)}` deve dar exatamente rgb(150,150,150))
// que pegou isso.
@(test)
test_canvas_bg_translucido_fica_fora_do_page_bg :: proc(t: ^testing.T) {
    bg, fonte := canvas(`html { background: rgba(45, 45, 45, 0.5) }`)
    testing.expect_value(t, bg, 0xffffff)  // page_bg segue branco…
    testing.expect_value(t, fonte, "html") // …mas o <html> ainda pinta o canvas

    // opaco continua indo p/ o page_bg (é o caminho comum)
    bg2, _ := canvas(`html { background: rgb(45, 45, 45) }`)
    testing.expect_value(t, bg2, 0x2d2d2d)
}

@(test)
test_canvas_bg_contain_suprime :: proc(t: ^testing.T) {
    // `contain` suprime a propagação (css-contain)
    bg, fonte := canvas(`body { background: #123456; contain: paint }`)
    testing.expect_value(t, bg, 0xffffff)
    testing.expect_value(t, fonte, "")
}

@(test)
test_canvas_bg_so_a_fonte_recebe_a_marca :: proc(t: ^testing.T) {
    dom := htmlp.parse(`<html><body><div id="d">x</div></body></html>`)
    rules, _ := csspkg.parse(`html { background:#111 } body { background:#222 } #d { background:#333 }`)
    styles, _ := compute_styles(dom, &rules, 800, 600)
    n := 0
    for _, c in styles do if c.bg_canvas do n += 1
    testing.expect_value(t, n, 1) // só o <html>, nunca body/div junto
}
