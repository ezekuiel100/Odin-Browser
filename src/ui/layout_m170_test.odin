package ui

// M170 — `display:flex`/`grid` numa tag que é INLINE por padrão (<label>, <span>,
// <a>, <button>) era ignorado: o elemento fluía como item de TEXTO, o formatador
// flex nunca rodava, `gap` sumia e width/height dos filhos era descartada.
//
// Raiz: `l_flows_inline` decidia inline-ness por display_block/_inline/_inline_block
// + a TAG, sem nunca consultar display_flex/_grid/_table. Aí `is_inline_ctx` via
// "todos os filhos fluem inline", convertia o bloco PAI em contexto inline e os
// filhos viravam palavras. Dentro de pai flex/grid funcionava (build_item_children
// dá Box a todo filho) — só quebrava sob pai BLOCO, que é o caso comum.
//
// Sintoma em site real (tradebig.com.br, painel "Tipo de Ativo"): quatro
// `<label class="flex items-center gap-3">` com um chip `<span class="w-8 h-8">`
// enfileiravam numa linha só e quebravam no meio, sem gap e sem os quadrados de
// 32px — em vez de quatro linhas de 48px.
//
// A distinção flex-vs-inline-flex saiu de `display_inline_level` (style.odin): as
// duas famílias compartilhavam a MESMA flag, então não havia como separá-las.
//
// ⚠️ sem atlas de fontes em `odin test` a medição de texto devolve 0 — todas as
// asserções usam dimensões EXPLÍCITAS (ver [[odin-test-armadilhas]]).

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

// (1) O BUG, na forma do painel do tradebig: dois <label> flex sob um bloco.
// Cada um tem de virar caixa flex PRÓPRIA, empilhada, com o gap aplicado.
@(test)
test_m170_flex_em_label :: proc(t: ^testing.T) {
    html := `<div id="wrap" style="width:260px">
        <label id="l1" style="display:flex;align-items:center;gap:12px">
            <span id="chip1" style="width:32px;height:32px"></span>
            <span id="txt1" style="width:40px;height:18px"></span>
        </label>
        <label id="l2" style="display:flex;align-items:center;gap:12px">
            <span id="chip2" style="width:32px;height:32px"></span>
        </label>
    </div>`
    root := layout_from_html(html)
    l1, l2 := find_id(root, "l1"), find_id(root, "l2")
    chip1, txt1 := find_id(root, "chip1"), find_id(root, "txt1")
    testing.expect(t, l1 != nil && l2 != nil, "os <label> flex têm caixa própria (antes: item de texto, sem Box)")
    if l1 == nil || l2 == nil do return
    testing.expect(t, l1.is_flex && l2.is_flex, "cada <label> é container flex")
    // nível BLOCO: ocupa a largura do pai e o segundo desce
    testing.expectf(t, l1.w == 260, "label flex é de nível bloco (w=260); veio %.0f", l1.w)
    testing.expectf(t, l2.y >= l1.y + l1.h, "o 2º label desce (empilham); l1.y=%.0f l1.h=%.0f l2.y=%.0f", l1.y, l1.h, l2.y)
    // gap e dimensões dos filhos honradas — era o que sumia
    testing.expect(t, chip1 != nil && txt1 != nil, "os chips têm caixa")
    if chip1 == nil || txt1 == nil do return
    testing.expectf(t, chip1.w == 32 && chip1.h == 32, "chip 32x32; veio %.0fx%.0f", chip1.w, chip1.h)
    testing.expectf(t, txt1.x == chip1.x + 32 + 12, "gap:12 entre os itens; chip.x=%.0f txt.x=%.0f", chip1.x, txt1.x)
    testing.expectf(t, l1.h == 32, "altura do label = o item mais alto; veio %.0f", l1.h)
}

// (2) O CONTROLE do caso 1: o MESMO CSS num <div> (tag de bloco) já funcionava.
// Sem esta asserção o teste 1 não distingue "consertei" de "sempre foi assim".
@(test)
test_m170_flex_em_div_e_label_batem :: proc(t: ^testing.T) {
    div_html :=`<div style="width:260px"><div id="a" style="display:flex;gap:12px"><span id="x" style="width:32px;height:32px"></span><span id="y" style="width:40px;height:18px"></span></div></div>`
    lbl_html := `<div style="width:260px"><label id="a" style="display:flex;gap:12px"><span id="x" style="width:32px;height:32px"></span><span id="y" style="width:40px;height:18px"></span></label></div>`
    d := find_id(layout_from_html(div_html), "a")
    l := find_id(layout_from_html(lbl_html), "a")
    testing.expect(t, d != nil && l != nil, "achou as duas caixas")
    if d == nil || l == nil do return
    testing.expectf(t, d.w == l.w && d.h == l.h, "div.flex e label.flex medem igual: div %.0fx%.0f vs label %.0fx%.0f", d.w, d.h, l.w, l.h)
    dy, ly := find_id(layout_from_html(div_html), "y"), find_id(layout_from_html(lbl_html), "y")
    testing.expect(t, dy != nil && ly != nil, "achou o 2º item nos dois")
    if dy == nil || ly == nil do return
    testing.expectf(t, dy.x == ly.x, "o 2º item cai no mesmo x: div %.0f vs label %.0f", dy.x, ly.x)
}

// (3) O caso SEM a feature não pode ter mudado: <span>/<label> comuns continuam
// fluindo inline (não viram caixa de bloco).
@(test)
test_m170_span_comum_segue_inline :: proc(t: ^testing.T) {
    html := `<div id="wrap" style="width:260px">
        <span id="s" style="width:32px;height:32px"></span>
        <label id="l"></label>
    </div>`
    root := layout_from_html(html)
    wrap := find_id(root, "wrap")
    testing.expect(t, wrap != nil, "achou o wrap")
    if wrap == nil do return
    testing.expect(t, wrap.is_inline, "sem display:flex o pai segue contexto inline")
    testing.expect(t, find_id(root, "s") == nil && find_id(root, "l") == nil, "span/label comuns não geram Box de bloco")
}

// (4) `inline-flex` é átomo INLINE: container flex por dentro, mas na linha e com
// largura shrink-to-fit (não a do pai). Era indistinguível de `flex` antes.
@(test)
test_m170_inline_flex_e_atomo :: proc(t: ^testing.T) {
    html := `<div id="wrap" style="width:400px">
        <span id="a" style="display:inline-flex;gap:8px">
            <span id="x" style="width:30px;height:20px"></span>
            <span id="y" style="width:30px;height:20px"></span>
        </span>
        <span id="b" style="display:inline-flex">
            <span style="width:50px;height:20px"></span>
        </span>
    </div>`
    root := layout_from_html(html)
    wrap := find_id(root, "wrap")
    testing.expect(t, wrap != nil, "achou o wrap")
    if wrap == nil do return
    testing.expect(t, wrap.is_inline, "inline-flex NÃO quebra o contexto inline do pai")
    // o átomo vive em b.inlines como InlineBox, não em children
    n_atoms := 0
    a_w, a_h: f32
    for &it in wrap.inlines {
        if it.kind == .InlineBox && it.box != nil {
            n_atoms += 1
            if it.box.is_flex && a_w == 0 { a_w = it.box.w; a_h = it.box.h }
        }
    }
    testing.expectf(t, n_atoms == 2, "dois átomos inline-flex na linha; veio %d", n_atoms)
    // shrink-to-fit: 30 + gap 8 + 30 = 68 (não 400)
    testing.expectf(t, a_w == 68, "inline-flex encolhe p/ o conteúdo (30+8+30); veio %.0f", a_w)
    testing.expectf(t, a_h == 20, "altura do átomo = item mais alto; veio %.0f", a_h)
}

// (5) `display:grid` numa tag inline também é de nível bloco (mesma raiz).
@(test)
test_m170_grid_em_a :: proc(t: ^testing.T) {
    html := `<div style="width:300px">
        <a id="card" style="display:grid;grid-template-columns:100px 200px">
            <span id="c1" style="height:20px"></span>
            <span id="c2" style="height:20px"></span>
        </a>
    </div>`
    root := layout_from_html(html)
    card, c2 := find_id(root, "card"), find_id(root, "c2")
    testing.expect(t, card != nil && c2 != nil, "o <a> grid tem caixa própria")
    if card == nil || c2 == nil do return
    testing.expect(t, card.is_grid, "<a display:grid> é container grid")
    // relativo à caixa do grid: x absoluto inclui a margem default de 8px do <body>
    testing.expectf(t, c2.x - card.x == 100, "2ª coluna começa a 100 do grid; veio %.0f (card.x=%.0f)", c2.x - card.x, card.x)
}
