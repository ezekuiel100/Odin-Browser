package ui

// Track-sizing de grid (2026-07-23): dois fixes guiados pelo WPT css-grid.
//   1. Item com tamanho DEFINIDO não é esticado à trilha (a altura já tinha o
//      guarda; a largura NÃO tinha — item com width explícita colapsava à trilha
//      colapsada). Achado por --dumplayout no cluster "overflowing-item-is-painted".
//   2. width:max-content num grid = SOMA das larguras de coluna (grid_intrinsic_w),
//      não a largura cheia. Fecha child-border-box-and-max-content-001/002.

import "core:testing"
import dompkg "../dom"
import htmlp "../html"
import csspkg "../css"

@(private = "file")
gi_find_grid :: proc(b: ^Box) -> ^Box {
    if b == nil do return nil
    if b.is_grid do return b
    for c in b.children {
        if r := gi_find_grid(c); r != nil do return r
    }
    return nil
}

@(private = "file")
gi_find_rel :: proc(b: ^Box) -> ^Box {
    if b == nil do return nil
    if b.pos == .Relative do return b
    for c in b.children {
        if r := gi_find_rel(c); r != nil do return r
    }
    return nil
}

@(test)
test_relative_top_pct_cb_definido :: proc(t: ^testing.T) {
    // top:-100% em position:relative resolve contra a ALTURA do CB (pai definido = 100)
    // → rel_dy = -100 (offset de pintura). Antes o inset em % era IGNORADO (rel_dy=0).
    dom := htmlp.parse(`<body style="margin:0"><div style="height:100px;width:50px"><div style="position:relative;top:-100%;height:10px"></div></div></body>`)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, 600, 600)
    root := build_layout(dom, styles, "")
    layout_box(root, 0, 0, 600)
    r := gi_find_rel(root)
    testing.expect(t, r != nil, "esperado um box relativo")
    if r == nil do return
    testing.expectf(t, r.rel_dy == -100, "top:-100% de CB 100 → rel_dy=-100, veio %v", r.rel_dy)
}

@(test)
test_relative_top_pct_cb_indefinido :: proc(t: ^testing.T) {
    // CONTRA-CASO: pai com altura AUTO (CB indefinido) → top:% resolve p/ 0 (per spec),
    // não p/ a altura do próprio elemento. Prova que a base é o CB, não o box.
    dom := htmlp.parse(`<body style="margin:0"><div style="width:50px"><div style="position:relative;top:-100%;height:10px"></div></div></body>`)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, 600, 600)
    root := build_layout(dom, styles, "")
    layout_box(root, 0, 0, 600)
    r := gi_find_rel(root)
    testing.expect(t, r != nil, "esperado um box relativo")
    if r == nil do return
    testing.expectf(t, r.rel_dy == 0, "CB indefinido → top:% = 0, veio %v", r.rel_dy)
}

@(private = "file")
gi_find_flex :: proc(b: ^Box) -> ^Box {
    if b == nil do return nil
    if b.is_flex do return b
    for c in b.children {
        if r := gi_find_flex(c); r != nil do return r
    }
    return nil
}

@(private = "file")
gi_flex :: proc(html: string, vw: f32 = 600) -> ^Box {
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, vw, 600)
    root := build_layout(dom, styles, "")
    layout_box(root, 0, 0, vw)
    return gi_find_flex(root)
}

@(test)
test_flex_col_min_height_grow :: proc(t: ^testing.T) {
    // flex column com min-height e SEM height: flex:1 distribui (min-height − conteúdo)
    // e o item PREENCHE. Antes o item flex:1 (base 0) saía h=0 — o min-height só
    // clampava a caixa DEPOIS do flex (grid-within-flexbox-indefinite).
    f := gi_flex(`<body style="margin:0"><div style="display:flex;flex-direction:column;min-height:100px;width:50px">
        <div style="flex:1"></div></div></body>`)
    testing.expect(t, f != nil && len(f.children) == 1, "esperado 1 filho flex")
    if f == nil || len(f.children) < 1 do return
    testing.expectf(t, f.children[0].h == 100, "flex:1 deveria preencher o min-height 100, veio %v", f.children[0].h)
}

@(test)
test_flex_col_min_height_grow_com_header :: proc(t: ^testing.T) {
    // header fixo de 30 + flex:1 → o flex:1 preenche a SOBRA (100−30=70), não 100.
    f := gi_flex(`<body style="margin:0"><div style="display:flex;flex-direction:column;min-height:100px;width:50px">
        <div style="height:30px"></div><div style="flex:1"></div></div></body>`)
    testing.expect(t, f != nil && len(f.children) == 2, "esperados 2 filhos flex")
    if f == nil || len(f.children) < 2 do return
    testing.expectf(t, f.children[1].h == 70, "flex:1 deveria preencher a sobra (100−30=70), veio %v", f.children[1].h)
}

@(test)
test_flex_col_min_height_conteudo_maior :: proc(t: ^testing.T) {
    // CONTRA-CASO: conteúdo (120) MAIOR que o min-height (100) → o container segue o
    // conteúdo, o flex:1 fica na base (sem sobra a distribuir), NÃO encolhe p/ 100.
    f := gi_flex(`<body style="margin:0"><div style="display:flex;flex-direction:column;min-height:100px;width:50px">
        <div style="height:120px"></div><div style="flex:1"></div></div></body>`)
    testing.expect(t, f != nil && len(f.children) == 2, "esperados 2 filhos flex")
    if f == nil || len(f.children) < 2 do return
    testing.expectf(t, f.children[0].h == 120, "o item de 120 não deveria encolher, veio %v", f.children[0].h)
}

@(test)
test_flex_min_size_clip_nao_encolhe :: proc(t: ^testing.T) {
    // overflow:clip NÃO é scroll container → o min-size:auto (conteúdo) VALE, o item
    // não encolhe abaixo do conteúdo. flex-basis:20, conteúdo 50 → item = 50.
    f := gi_flex(`<body style="margin:0"><div style="display:flex;flex-direction:column;width:50px">
        <div style="overflow:clip;flex-basis:20px"><div style="height:50px"></div></div></div></body>`)
    testing.expect(t, f != nil && len(f.children) == 1, "esperado 1 filho flex")
    if f == nil || len(f.children) < 1 do return
    testing.expectf(t, f.children[0].h == 50, "overflow:clip deveria honrar o min-size de conteúdo (50), veio %v", f.children[0].h)
}

@(test)
test_flex_min_size_hidden_encolhe :: proc(t: ^testing.T) {
    // CONTRA-CASO: overflow:hidden É scroll container → min-size:auto = 0, o item fica
    // no flex-basis (20) e o conteúdo (50) transborda clipado. Prova que a distinção
    // clip vs hidden é real (senão o teste acima passaria p/ o motivo errado).
    f := gi_flex(`<body style="margin:0"><div style="display:flex;flex-direction:column;width:50px">
        <div style="overflow:hidden;flex-basis:20px"><div style="height:50px"></div></div></div></body>`)
    testing.expect(t, f != nil && len(f.children) == 1, "esperado 1 filho flex")
    if f == nil || len(f.children) < 1 do return
    testing.expectf(t, f.children[0].h == 20, "overflow:hidden (scroll container) deveria encolher p/ o flex-basis 20, veio %v", f.children[0].h)
}

@(private = "file")
gi_grid :: proc(html: string, vw: f32 = 600) -> ^Box {
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, vw, 600)
    root := build_layout(dom, styles, "")
    layout_box(root, 0, 0, vw)
    return gi_find_grid(root)
}

@(test)
test_grid_item_width_definida_nao_estica :: proc(t: ^testing.T) {
    // Coluna de 300px, item width:100px → o item fica 100 (não estica p/ 300). A
    // altura já se comportava assim; a largura era esticada SEMPRE (bug de assimetria).
    g := gi_grid(`<body style="margin:0"><div style="display:grid;grid-template-columns:300px">
        <div style="width:100px;height:20px">a</div></div></body>`)
    testing.expect(t, g != nil && len(g.children) == 1, "esperado 1 item de grid")
    if g == nil || len(g.children) < 1 do return
    testing.expectf(t, g.children[0].w == 100, "item width:100px não deveria esticar p/ a coluna de 300, veio %v", g.children[0].w)
}

@(test)
test_grid_item_width_auto_estica :: proc(t: ^testing.T) {
    // CONTRA-CASO (senão o teste acima poderia passar por não esticar NADA): item
    // SEM width, na mesma coluna de 300px, DEVE esticar p/ 300 (justify default).
    g := gi_grid(`<body style="margin:0"><div style="display:grid;grid-template-columns:300px">
        <div style="height:20px">a</div></div></body>`)
    testing.expect(t, g != nil && len(g.children) == 1, "esperado 1 item de grid")
    if g == nil || len(g.children) < 1 do return
    testing.expectf(t, g.children[0].w == 300, "item width:auto deveria esticar p/ a coluna de 300, veio %v", g.children[0].w)
}

@(test)
test_grid_width_max_content_soma_colunas :: proc(t: ^testing.T) {
    // width:max-content no grid → largura de conteúdo = SOMA das colunas (não a
    // largura cheia do container). 2 itens de 60 e 70px em colunas auto → 130.
    g := gi_grid(`<body style="margin:0"><div style="display:grid;grid-auto-flow:column;grid-auto-columns:auto;width:max-content">
        <div style="width:60px;height:10px">a</div><div style="width:70px;height:10px">b</div></div></body>`)
    testing.expect(t, g != nil, "grid não encontrado")
    if g == nil do return
    testing.expectf(t, g.content_w == 130, "grid width:max-content deveria somar as colunas (60+70=130), veio %v", g.content_w)
}

@(test)
test_grid_auto_row_estica_p_preencher :: proc(t: ^testing.T) {
    // §11.8: grid altura 100, linha `auto` única, align-content default (normal→
    // stretch) → a linha estica p/ 100 e o item (altura auto) preenche. Antes a
    // linha ficava no tamanho do conteúdo e a sobra ficava vazia embaixo.
    g := gi_grid(`<body style="margin:0"><div style="display:grid;height:100px;width:50px">
        <div>a</div></div></body>`)
    testing.expect(t, g != nil && len(g.children) == 1, "esperado 1 item")
    if g == nil || len(g.children) < 1 do return
    testing.expectf(t, g.children[0].h == 100, "linha auto deveria esticar p/ 100, veio %v", g.children[0].h)
}

@(test)
test_grid_align_content_start_nao_estica :: proc(t: ^testing.T) {
    // CONTRA-CASO (senão o teste acima poderia passar por outro motivo):
    // align-content:start desliga o stretch → a linha fica no conteúdo (10px) e a
    // sobra vai p/ baixo; o item mantém a própria altura.
    g := gi_grid(`<body style="margin:0"><div style="display:grid;height:100px;width:50px;align-content:start">
        <div style="height:10px">a</div></div></body>`)
    testing.expect(t, g != nil && len(g.children) == 1, "esperado 1 item")
    if g == nil || len(g.children) < 1 do return
    testing.expectf(t, g.children[0].h == 10, "align-content:start não deveria esticar (fica 10), veio %v", g.children[0].h)
}

@(test)
test_grid_item_max_content_nao_estica :: proc(t: ^testing.T) {
    // WPT grid-item-non-auto-height-stretch-002 (vertical-lr): item width:max-content
    // é tamanho INTRÍNSECO, não auto → NÃO estica à coluna. Item VAZIO → max-content=0.
    // (em vertical-lr a `width` é o block-size; block-size não-auto não estica. Nosso
    // motor é horizontal, mas o pixel bate: vermelho de largura 0 → quadrado verde.)
    // Antes stretch_w só checava def_w (has_width), não width_mc → esticava p/ 100.
    g := gi_grid(`<body style="margin:0"><div style="display:grid;width:100px;height:100px;grid-template:100% / 100%">
        <div style="width:max-content"></div></div></body>`)
    testing.expect(t, g != nil && len(g.children) == 1, "esperado 1 item")
    if g == nil || len(g.children) < 1 do return
    testing.expectf(t, g.children[0].w == 0, "item width:max-content vazio deveria ter largura 0, veio %v", g.children[0].w)
}

@(test)
test_grid_item_min_content_nao_estica :: proc(t: ^testing.T) {
    // WPT -004: idem com min-content. Item vazio → 0.
    g := gi_grid(`<body style="margin:0"><div style="display:grid;width:100px;height:100px;grid-template:100% / 100%">
        <div style="width:min-content"></div></div></body>`)
    testing.expect(t, g != nil && len(g.children) == 1, "esperado 1 item")
    if g == nil || len(g.children) < 1 do return
    testing.expectf(t, g.children[0].w == 0, "item width:min-content vazio deveria ter largura 0, veio %v", g.children[0].w)
}

@(test)
test_grid_item_auto_estica_contra_max_content :: proc(t: ^testing.T) {
    // CONTRA-CASO: MESMO grid, item SEM width (auto) DEVE esticar p/ 100 (o fix de
    // width_mc não pode ter desligado o stretch de itens auto).
    g := gi_grid(`<body style="margin:0"><div style="display:grid;width:100px;height:100px;grid-template:100% / 100%">
        <div></div></div></body>`)
    testing.expect(t, g != nil && len(g.children) == 1, "esperado 1 item")
    if g == nil || len(g.children) < 1 do return
    testing.expectf(t, g.children[0].w == 100, "item auto deveria esticar p/ 100, veio %v", g.children[0].w)
}

@(test)
test_grid_width_max_content_com_gap :: proc(t: ^testing.T) {
    // o gap entre colunas entra na largura intrínseca: 60 + 70 + gap 8 = 138.
    g := gi_grid(`<body style="margin:0"><div style="display:grid;grid-auto-flow:column;grid-auto-columns:auto;gap:8px;width:max-content">
        <div style="width:60px;height:10px">a</div><div style="width:70px;height:10px">b</div></div></body>`)
    testing.expect(t, g != nil, "grid não encontrado")
    if g == nil do return
    testing.expectf(t, g.content_w == 138, "largura intrínseca deveria incluir o gap (60+70+8=138), veio %v", g.content_w)
}

// ── M233: item com SPAN contribui para a largura intrínseca ──────────────────
// O caso degenerado que quebrava o hero do github.com: um grid cujo ÚNICO item
// span TODAS as colunas media só a soma dos GAPS (as trilhas ficavam em 0), e a
// coluna saía estreita demais para o texto. Aqui o item tem largura FIXA, então
// o número esperado é exato e não depende de fonte.
@(test)
test_grid_intrinsic_item_com_span :: proc(t: ^testing.T) {
    // grid max-content dentro de um pai que dimensiona por conteúdo (float):
    // 4 colunas, gap 10, um item de 400px com span 4.
    // Esperado: **400** — o item paga os 3 gaps que ATRAVESSA, então as trilhas
    // ficam com 370 e o grid mede exatamente a largura do item.
    // ⚠️ a 1ª versão deste teste esperava 430 (somando os gaps por fora): a
    // expectativa é que estava errada, não o motor.
    dom := htmlp.parse(`<body style="margin:0"><div style="float:left">` +
        `<div style="display:grid;grid-template-columns:repeat(4,1fr);gap:10px">` +
        `<div style="grid-column:span 4"><div style="width:400px;height:10px"></div></div>` +
        `</div></div></body>`)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, 1000, 600)
    root := build_layout(dom, styles, "")
    defer { free_layout(root); free_styles(styles); csspkg.free_rules(&rules); dompkg.free_tree(dom) }
    layout_box(root, 0, 0, 1000)
    g := gi_find_grid(root)
    testing.expect(t, g != nil, "esperado um grid")
    if g == nil do return
    testing.expectf(t, abs(g.w - 400) < 1.5, "grid com item span-4 de 400px: esperava w=400, veio %v", g.w)
}

@(test)
test_grid_intrinsic_span_nao_infla_alem_do_necessario :: proc(t: ^testing.T) {
    // CONTROLE do teste acima: com as colunas JÁ atendendo o item que faz span,
    // ele não pode inflar nada. 2 itens span-1 de 300px + 1 item span-2 de 100px
    // ⇒ as duas colunas ficam em 300 e o span-2 (100) não acrescenta:
    // 300 + 300 + 10 de gap = 610.
    dom := htmlp.parse(`<body style="margin:0"><div style="float:left">` +
        `<div style="display:grid;grid-template-columns:repeat(2,auto);gap:10px">` +
        `<div><div style="width:300px;height:10px"></div></div>` +
        `<div><div style="width:300px;height:10px"></div></div>` +
        `<div style="grid-column:span 2"><div style="width:100px;height:10px"></div></div>` +
        `</div></div></body>`)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, 1000, 600)
    root := build_layout(dom, styles, "")
    defer { free_layout(root); free_styles(styles); csspkg.free_rules(&rules); dompkg.free_tree(dom) }
    layout_box(root, 0, 0, 1000)
    g := gi_find_grid(root)
    testing.expect(t, g != nil, "esperado um grid")
    if g == nil do return
    testing.expectf(t, abs(g.w - 610) < 1.5, "span que já cabe não infla: esperava w=610, veio %v", g.w)
}

@(test)
test_grid_intrinsic_span_pula_trilha_de_px_fixo :: proc(t: ^testing.T) {
    // A trilha de px FIXO não cresce: o item de span paga os 100px dela e o resto
    // (500-100-10 = 390) vai só para a trilha intrínseca.
    // Total = 100 (fixa) + 390 (auto) + 10 (gap) = 500.
    dom := htmlp.parse(`<body style="margin:0"><div style="float:left">` +
        `<div style="display:grid;grid-template-columns:100px auto;gap:10px">` +
        `<div style="grid-column:span 2"><div style="width:500px;height:10px"></div></div>` +
        `</div></div></body>`)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, 1000, 600)
    root := build_layout(dom, styles, "")
    defer { free_layout(root); free_styles(styles); csspkg.free_rules(&rules); dompkg.free_tree(dom) }
    layout_box(root, 0, 0, 1000)
    g := gi_find_grid(root)
    testing.expect(t, g != nil, "esperado um grid")
    if g == nil do return
    testing.expectf(t, abs(g.w - 500) < 1.5, "trilha fixa não cresce: esperava w=500, veio %v", g.w)
}
