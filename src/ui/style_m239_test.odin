package ui

// M239 — BLOCKIFICAÇÃO do overflow (css-overflow-3 §3.1): os dois eixos não são
// independentes. Um eixo `visible` ao lado de hidden/scroll/auto computa para
// `auto` — e portanto CLIPA. `clip` é a exceção: não arrasta o outro eixo.
//
// Como isto foi medido (e por que o teste antigo afirmava o contrário): fixture
// com um filho 300x150 dentro de uma caixa 120x50, renderizada no Chrome
// headless. Nos três casos — `overflow: hidden visible`, `overflow: visible
// hidden` e `overflow-x: hidden` — o Chrome corta o transbordo NOS DOIS eixos.
//
// ⚠️ `html`/`body` ficam FORA: neles o overflow propaga para o viewport
// (css-overflow §3.3) e a caixa do elemento segue visível. Sem a exceção, o
// `body{overflow-x:hidden}` que meio site escreve para matar a rolagem
// horizontal passaria a cortar a página inteira na vertical.

import "core:testing"

@(test)
test_m239_blockificacao_um_eixo :: proc(t: ^testing.T) {
    // longhand de UM eixo arrasta o outro
    cx := test_compute_one(".i{overflow-x: hidden}", "div", "i")
    testing.expectf(t, cx.ovf_clip_x && cx.ovf_clip_y,
        "overflow-x:hidden → os dois clipam; veio x=%v y=%v", cx.ovf_clip_x, cx.ovf_clip_y)

    cy := test_compute_one(".i{overflow-y: scroll}", "div", "i")
    testing.expectf(t, cy.ovf_clip_x && cy.ovf_clip_y,
        "overflow-y:scroll → os dois clipam; veio x=%v y=%v", cy.ovf_clip_x, cy.ovf_clip_y)

    ca := test_compute_one(".i{overflow-y: auto}", "div", "i")
    testing.expectf(t, ca.ovf_clip_x && ca.ovf_clip_y,
        "overflow-y:auto → os dois clipam; veio x=%v y=%v", ca.ovf_clip_x, ca.ovf_clip_y)
}

@(test)
test_m239_clip_nao_blockifica :: proc(t: ^testing.T) {
    // `clip` com `visible` do outro lado é combinação LEGAL: só o eixo pedido clipa
    c := test_compute_one(".i{overflow-x: clip}", "div", "i")
    testing.expectf(t, c.ovf_clip_x && !c.ovf_clip_y,
        "overflow-x:clip NÃO arrasta o y; veio x=%v y=%v", c.ovf_clip_x, c.ovf_clip_y)

    c2 := test_compute_one(".i{overflow: clip visible}", "div", "i")
    testing.expectf(t, c2.ovf_clip_x && !c2.ovf_clip_y,
        "overflow:clip visible → só x; veio x=%v y=%v", c2.ovf_clip_x, c2.ovf_clip_y)

    // …e `clip` NÃO é scroll container (importa p/ o min-size:auto de item flex)
    testing.expectf(t, !c.scroll_container, "clip não é scroll container; veio %v", c.scroll_container)
}

@(test)
test_m239_shorthand_dois_valores :: proc(t: ^testing.T) {
    // `overflow: <x> <y>` — cada palavra vale para o SEU eixo. Antes era um
    // `strings.contains` sobre a string inteira.
    a := test_compute_one(".i{overflow: hidden visible}", "div", "i")
    testing.expectf(t, a.ovf_clip_x && a.ovf_clip_y, "hidden visible → os dois; veio x=%v y=%v", a.ovf_clip_x, a.ovf_clip_y)

    b := test_compute_one(".i{overflow: visible hidden}", "div", "i")
    testing.expectf(t, b.ovf_clip_x && b.ovf_clip_y, "visible hidden → os dois; veio x=%v y=%v", b.ovf_clip_x, b.ovf_clip_y)

    // o caso que NÃO clipava nada antes (o `contains` não achava nada e o
    // `lo == "clip"` falhava por causa do 2º token)
    c := test_compute_one(".i{overflow: clip clip}", "div", "i")
    testing.expectf(t, c.ovf_clip_x && c.ovf_clip_y, "clip clip → os dois; veio x=%v y=%v", c.ovf_clip_x, c.ovf_clip_y)

    // controle: visible visible não clipa nada
    d := test_compute_one(".i{overflow: visible visible}", "div", "i")
    testing.expectf(t, !d.ovf_clip_x && !d.ovf_clip_y, "visible visible → nada; veio x=%v y=%v", d.ovf_clip_x, d.ovf_clip_y)

    // e o shorthand de UMA palavra segue valendo p/ os dois
    e := test_compute_one(".i{overflow: auto}", "div", "i")
    testing.expectf(t, e.ovf_clip_x && e.ovf_clip_y && e.overflow_scroll, "overflow:auto; veio x=%v y=%v scroll=%v",
        e.ovf_clip_x, e.ovf_clip_y, e.overflow_scroll)
}

@(test)
test_m239_raiz_fica_de_fora :: proc(t: ^testing.T) {
    // O caso que torna a exceção obrigatória: `body{overflow-x:hidden}` não pode
    // passar a cortar a página na vertical.
    b := test_compute_one("body{overflow-x: hidden}", "body")
    testing.expectf(t, b.ovf_clip_x && !b.ovf_clip_y,
        "body: overflow-x:hidden não blockifica o y; veio x=%v y=%v", b.ovf_clip_x, b.ovf_clip_y)

    h := test_compute_one("html{overflow-x: hidden}", "html")
    testing.expectf(t, h.ovf_clip_x && !h.ovf_clip_y,
        "html: idem; veio x=%v y=%v", h.ovf_clip_x, h.ovf_clip_y)

    // controle: num elemento comum a MESMA declaração blockifica
    d := test_compute_one("div{overflow-x: hidden}", "div")
    testing.expectf(t, d.ovf_clip_x && d.ovf_clip_y,
        "controle: num <div> a mesma regra blockifica; veio x=%v y=%v", d.ovf_clip_x, d.ovf_clip_y)

    // e a raiz com os DOIS eixos pedidos continua clipando os dois
    b2 := test_compute_one("body{overflow: hidden}", "body")
    testing.expectf(t, b2.ovf_clip_x && b2.ovf_clip_y, "body{overflow:hidden} clipa os dois; veio x=%v y=%v",
        b2.ovf_clip_x, b2.ovf_clip_y)
}
