package ui

// M169 — linha `fr` de grid em container de altura INDEFINIDA colapsava a 0.
//
// `1fr` é `minmax(auto, 1fr)`: o piso da trilha é o conteúdo, e o fator `fr` só
// governa o crescimento ALÉM disso, quando há sobra para distribuir. O motor
// tratava a linha `fr` como não-candidata a crescer pelo conteúdo E só distribuía
// sobra quando o container tinha height explícita — então, com height auto, a
// linha nunca recebia nada.
//
// Sintoma em site real (pt.wikipedia.org): `.mw-page-container-inner` e
// `main.mw-body` são grids de altura auto cujo conteúdo mora numa linha `1fr`
// (`grid-area: pageContent` / `grid-area: content`). Ambas mediam h=0, então o
// rodapé — linha SEGUINTE — era pintado por cima do artigo.
//
// ⚠️ os testes usam alturas EXPLÍCITAS, nunca texto: em `odin test` não há atlas
// de fontes, então medição de texto devolve 0 (ver [[odin-test-armadilhas]]).

import "core:testing"
import htmlp "../html"
import csspkg "../css"

@(private = "file")
layout_from_html :: proc(html: string, vw: f32 = 800, vh: f32 = 600) -> ^Box {
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, vw, vh)
    root := build_layout(dom, styles, "")
    layout_box(root, 0, 0, vw)
    page := Rect{0, 0, vw, vh}
    layout_absolutes(root, page, page)
    return root
}

@(private = "file")
find_id :: proc(b: ^Box, want: string) -> ^Box {
    if b == nil do return nil
    if b.node != nil && b.node.attrs != nil {
        if v, ok := b.node.attrs["id"]; ok && v == want do return b
    }
    for c in b.children {
        if r := find_id(c, want); r != nil do return r
    }
    return nil
}

// (1) O BUG: altura auto + linha do meio `1fr` → a linha tem de medir o conteúdo.
@(test)
test_m169_fr_row_altura_indefinida :: proc(t: ^testing.T) {
    html := `<div id="g" style="display:grid;grid-template-rows:20px 1fr 20px;width:400px">
        <div id="a" style="height:20px"></div>
        <div id="b" style="height:60px"></div>
        <div id="c" style="height:20px"></div>
    </div>`
    root := layout_from_html(html)
    g := find_id(root, "g")
    b := find_id(root, "b")
    testing.expect(t, g != nil && b != nil, "achou as caixas")
    // antes do fix: linha fr = 0 → g.h = 40 e b espremido na origem da linha
    testing.expectf(t, g.h == 100, "grid de altura auto soma 20+60+20; veio %.0f", g.h)
    testing.expectf(t, b.h == 60, "item da linha fr mantém sua altura; veio %.0f", b.h)
    // o item DEPOIS da linha fr não pode cair em cima dela — era a sobreposição
    c := find_id(root, "c")
    testing.expectf(t, c.y >= b.y + b.h, "linha seguinte começa abaixo da fr (b.y=%.0f b.h=%.0f c.y=%.0f)", b.y, b.h, c.y)
}

// (2) Mesma forma da Wikipédia: `min-content 1fr min-content`. `min-content` não é
// suportado como função de dimensionamento e cai em .Auto — o que importa é que a
// linha `fr` do meio não zere.
@(test)
test_m169_fr_row_forma_wikipedia :: proc(t: ^testing.T) {
    html := `<div id="g" style="display:grid;grid-template-rows:min-content 1fr min-content;width:400px">
        <div id="sitenotice" style="height:10px"></div>
        <div id="content" style="height:300px"></div>
        <div id="footer" style="height:40px"></div>
    </div>`
    root := layout_from_html(html)
    g := find_id(root, "g")
    content := find_id(root, "content")
    footer := find_id(root, "footer")
    testing.expect(t, g != nil && content != nil && footer != nil, "achou as caixas")
    testing.expectf(t, g.h == 350, "grid soma 10+300+40; veio %.0f", g.h)
    testing.expectf(t, footer.y >= content.y + 300, "rodapé abaixo do conteúdo, não por cima (content.y=%.0f footer.y=%.0f)", content.y, footer.y)
}

// (3) §12.7.1: com espaço livre indefinido a fração usada é o MAIOR (base÷fator)
// entre as trilhas flexíveis — `1fr 2fr` com conteúdos iguais dá 40 e 80, não 40 e 40.
@(test)
test_m169_fr_proporcao_entre_linhas :: proc(t: ^testing.T) {
    html := `<div id="g" style="display:grid;grid-template-rows:1fr 2fr;width:400px">
        <div id="a" style="height:40px"></div>
        <div id="b" style="height:40px"></div>
    </div>`
    root := layout_from_html(html)
    g := find_id(root, "g")
    testing.expect(t, g != nil, "achou o grid")
    testing.expectf(t, g.h == 120, "fração usada = max(40/1, 40/2) = 40 → 40 + 80; veio %.0f", g.h)
}

// (4) CONTROLE — altura DEFINIDA segue igual: a linha fr come toda a sobra.
// Este é o caminho que já funcionava; o fix não pode tocá-lo.
@(test)
test_m169_fr_row_altura_definida_inalterada :: proc(t: ^testing.T) {
    html := `<div id="g" style="display:grid;grid-template-rows:20px 1fr 20px;width:400px;height:300px">
        <div id="a" style="height:20px"></div>
        <div id="b"></div>
        <div id="c" style="height:20px"></div>
    </div>`
    root := layout_from_html(html)
    g := find_id(root, "g")
    b := find_id(root, "b")
    testing.expect(t, g != nil && b != nil, "achou as caixas")
    testing.expectf(t, g.h == 300, "grid respeita a height explícita; veio %.0f", g.h)
    testing.expectf(t, b.h == 260, "linha fr = 300-20-20; veio %.0f", b.h)
}

// (5) CONTROLE — linha FIXA continua transbordando (não vira candidata a crescer).
// `grid-auto-rows: 20px` pede exatamente isso, e o fix mexeu nessa mesma guarda.
@(test)
test_m169_linha_fixa_ainda_transborda :: proc(t: ^testing.T) {
    html := `<div id="g" style="display:grid;grid-template-rows:20px 20px;width:400px">
        <div id="a" style="height:20px"></div>
        <div id="b" style="height:200px"></div>
    </div>`
    root := layout_from_html(html)
    g := find_id(root, "g")
    testing.expect(t, g != nil, "achou o grid")
    testing.expectf(t, g.h == 40, "linhas px não esticam pelo conteúdo; veio %.0f", g.h)
}
