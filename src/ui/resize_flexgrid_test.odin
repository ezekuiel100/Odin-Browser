package ui

// Tamanho de item DENTRO de um container (flex/grid/linha/absoluto). Dois
// assuntos, a mesma raiz — **quem IMPÕE o tamanho a um filho tem de resolvê-lo
// por inteiro, porque o caminho `force_w`/`force_h` do layout_box não recalcula
// nada**: (1) a alça de `resize`, cujo tamanho arrastado chegava tarde demais
// para o container ver; (2) min/max-width/height, que o caminho imposto pulava.
//
// O tamanho arrastado entra pelos campos de `width`/`height` do autor
// (resize_apply_size). Em fluxo de bloco isso basta: quem decide a largura é o
// próprio layout_box. Em flex/grid NÃO: o CONTAINER lê `has_width`/`def_w` do
// item ANTES de chamar layout_box(item) — pra calcular a base do flex ou pra
// decidir se estica na trilha — e depois impõe o resultado por `force_w`, que
// vence qualquer width. Como o tamanho arrastado só era aplicado DENTRO do
// layout_box do item, ele chegava tarde e era descartado.
//
// Estes testes medem pela raiz (é o que o app faz: arrasta num frame, no frame
// seguinte re-dispõe a árvore inteira), então enxergam a ordem container→item.
//
// ⚠️ RODE COM `-define:ODIN_TEST_THREADS=1` (é o que o test.ps1 faz p/ src/ui).
// Com o runner PARALELO este teste dá falso vermelho, e vale saber por quê: a
// varredura de topo dispara em `g_layout_depth == 0`, e esse contador é um
// global do pacote — se OUTRA thread está no meio de um layout, a minha
// passada não se reconhece como de topo, a varredura não roda e o item volta ao
// tamanho pré-arraste. Não é intermitente: com o teste-controle ao lado falha
// 5 em 5. (O define é `-define:`, não variável de ambiente — perdi uma medição
// achando que tinha fixado a thread quando não tinha.)
// Este arquivo também é o ÚNICO que escreve em `g_resize`, e escreve tudo de um
// test proc só, pelo mesmo motivo.

import "core:testing"
import "core:fmt"
import htmlp "../html"
import csspkg "../css"

@(private = "file")
arvore :: proc(html: string, vw: f32 = 600) -> ^Box {
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, vw, 600)
    return build_layout(dom, styles, "")
}

// UM passe, de propósito: é o que o app faz por frame (browser_ui.odin só
// relayouta uma 2ª vez quando uma container query suja o estilo). Com dois
// passes o flex row e o grid "funcionavam" por acidente — o 1º passe mutava
// has_width como efeito colateral e o 2º enxergava. Medir com um passe é o que
// separa "funciona" de "converge depois".
@(private = "file")
dispoe :: proc(root: ^Box, vw: f32 = 600) {
    layout_box(root, 0, 0, vw)
    page := Rect{0, 0, vw, 600}
    layout_absolutes(root, page, page)
}

// átomo inline (<textarea>) mora em inlines[].box, não em children — ver a nota
// no style_resize_test.odin.
@(private = "file")
acha :: proc(b: ^Box, tag: string) -> ^Box {
    if b == nil do return nil
    if b.node != nil && b.node.tag == tag do return b
    for c in b.children {
        if r := acha(c, tag); r != nil do return r
    }
    for it in b.inlines {
        if it.kind != .InlineBox do continue
        if r := acha(it.box, tag); r != nil do return r
    }
    return nil
}

@(test)
test_resize_em_flex_e_grid :: proc(t: ^testing.T) {
    // Um caso por container. Em todos: o item NÃO tem width própria (é o caso em
    // que o container manda no tamanho — com width do autor o grid já respeitava),
    // arrastamos p/ 320x150 e o tamanho tem de sobreviver ao passe do container.
    caso :: proc(t: ^testing.T, nome, html: string, esp_w, esp_h: f32) {
        root := arvore(html)
        item := acha(root, "section")
        testing.expectf(t, item != nil, "%s: não achei a <section>", nome)
        if item == nil do return

        g_resize[item.node] = {w = 320, h = 150, has_w = true, has_h = true}
        defer delete_key(&g_resize, item.node)

        dispoe(root)
        testing.expectf(t, abs(item.w - esp_w) < 0.5, "%s: largura arrastada deveria ser %v, veio %v", nome, esp_w, item.w)
        testing.expectf(t, abs(item.h - esp_h) < 0.5, "%s: altura arrastada deveria ser %v, veio %v", nome, esp_h, item.h)
    }

    // flex ROW: largura é o eixo PRINCIPAL (a base do flex tem de sair do arraste,
    // senão o item volta ao intrínseco); altura é o eixo cruzado (align-items
    // stretch não pode esticar um item de altura definida).
    caso(t, "flex row", `<body style="margin:0"><div style="display:flex;width:600px;height:300px">` +
        `<section style="resize:both;overflow:auto">x</section><p style="width:100px">y</p></div></body>`, 320, 150)

    // flex COLUMN: os eixos trocam — largura vira o cruzado (é aqui que o
    // stretch atropelava) e altura o principal.
    caso(t, "flex column", `<body style="margin:0"><div style="display:flex;flex-direction:column;width:600px;height:300px">` +
        `<section style="resize:both;overflow:auto">x</section></div></body>`, 320, 150)

    // grid: a trilha de 400px esticaria o item (justify-items stretch é o padrão).
    caso(t, "grid", `<body style="margin:0"><div style="display:grid;grid-template-columns:400px 200px;width:600px">` +
        `<section style="resize:both;overflow:auto">x</section><p>y</p></div></body>`, 320, 150)

    // <textarea> — o uso real da alça, e um ÁTOMO INLINE: quem o dimensiona é o
    // layout de linha, que também mede antes (measure_intrinsic_w) e impõe por
    // force_w. Vale nos dois contextos, então testamos os dois.
    // ⚠️ o mapa guarda o tamanho no espaço do BOX-SIZING (aqui content-box), e
    // b.w/b.h são BORDER-box: +10 na largura e +6 na altura são o padding {2,4}
    // e a borda 1px do UA style. (Minha 1ª expectativa aqui era 260/90 — o motor
    // estava certo e o teste, errado.)
    ta_caso :: proc(t: ^testing.T, nome, html: string) {
        root := arvore(html)
        ta := acha(root, "textarea")
        testing.expectf(t, ta != nil, "%s: não achei o textarea", nome)
        if ta == nil do return
        g_resize[ta.node] = {w = 260, h = 90, has_w = true, has_h = true}
        defer delete_key(&g_resize, ta.node)
        dispoe(root)
        testing.expectf(t, abs(ta.w - 270) < 0.5, "%s: largura 260+10 de borda/padding, veio %v", nome, ta.w)
        testing.expectf(t, abs(ta.h - 96) < 0.5, "%s: altura 90+6 de borda/padding, veio %v", nome, ta.h)
    }
    // fluxo NORMAL primeiro: é o CONTROLE — se este falhar, o problema não é o flex
    ta_caso(t, "textarea em fluxo normal", `<body style="margin:0"><textarea></textarea></body>`)
    ta_caso(t, "textarea em flex row", `<body style="margin:0"><div style="display:flex;width:600px"><textarea></textarea></div></body>`)
    ta_caso(t, "textarea em grid", `<body style="margin:0"><div style="display:grid;grid-template-columns:400px"><textarea></textarea></div></body>`)
}

@(test)
test_resize_flexgrid_controle :: proc(t: ^testing.T) {
    // CONTROLE (não escreve em g_resize): sem arraste, flex e grid dimensionam os
    // itens exatamente como antes. É o que separa "a alça funciona" de "eu
    // desliguei o stretch".
    root := arvore(`<body style="margin:0"><div style="display:flex;flex-direction:column;width:600px;height:300px">` +
        `<section style="overflow:auto">x</section></div></body>`)
    it := acha(root, "section")
    testing.expect(t, it != nil, "não achei a <section> do controle")
    if it != nil {
        dispoe(root)
        testing.expectf(t, abs(it.w - 600) < 0.5, "sem arraste, align-items:stretch estica a 600, veio %v", it.w)
    }

    root2 := arvore(`<body style="margin:0"><div style="display:grid;grid-template-columns:400px 200px;width:600px">` +
        `<section style="overflow:auto">x</section><p>y</p></div></body>`)
    it2 := acha(root2, "section")
    testing.expect(t, it2 != nil, "não achei a <section> do controle (grid)")
    if it2 != nil {
        dispoe(root2)
        testing.expectf(t, abs(it2.w - 400) < 0.5, "sem arraste, o item preenche a trilha de 400, veio %v", it2.w)
    }
}

@(test)
test_flex_coluna_largura_propria :: proc(t: ^testing.T) {
    // A guarda de stretch que o arraste precisa (item com largura PRÓPRIA não é
    // esticado) tem de valer para a `width` do AUTOR — que é o caso comum — e nas
    // DUAS grafias: px e %. A % é o caso perigoso: measure_intrinsic_w a ignora de
    // propósito, então o item tem de resolver a própria largura (force_w=-1) em vez
    // de receber o intrínseco forçado. Antes desta guarda os três primeiros casos
    // davam 600 (a largura do container): errado no px e no 50% — e só `width:100%`
    // acertava, por acidente, porque esticar coincide com 100%.
    caso :: proc(t: ^testing.T, nome, css: string, esperado: f32) {
        html := fmt.tprintf(`<body style="margin:0"><div style="display:flex;flex-direction:column;width:600px">`+
            `<section style="%s">x</section></div></body>`, css)
        root := arvore(html)
        it := acha(root, "section")
        testing.expectf(t, it != nil, "%s: não achei a <section>", nome)
        if it == nil do return
        dispoe(root)
        testing.expectf(t, abs(it.w - esperado) < 0.5, "%s: largura %v, veio %v", nome, esperado, it.w)
    }
    caso(t, "width px",          "width:200px", 200)
    caso(t, "width %",           "width:50%",   300)
    caso(t, "width calc mista",  "width:calc(50% - 20px)", 280)
    caso(t, "sem width (auto)",  "background:#eee", 600) // CONTROLE: auto ainda estica
}

@(test)
test_stretch_respeita_minmax :: proc(t: ^testing.T) {
    // `stretch` (o padrão de align-items/justify-items) preenche o container, mas o
    // tamanho usado É LIMITADO por min/max — spec css-align §4.2 e css-flexbox §9.4.
    // Aqui o tamanho é imposto por `force_w`/`force_h`, e esse caminho do layout_box
    // NÃO clampa (ele só clampa quando calcula a largura ele mesmo) — mesmo buraco
    // que o `float_fit_width` já tinha de compensar nos floats.
    // ⚠️ min vence max, e min MAIOR que o container faz o item TRANSBORDAR (é o que
    // o Chrome faz) — por isso o caso de 700 num container de 600.
    caso :: proc(t: ^testing.T, nome, container, item: string, esp_w, esp_h: f32) {
        html := fmt.tprintf(`<body style="margin:0"><div style="%s">`+
            `<section style="%s">x</section></div></body>`, container, item)
        root := arvore(html)
        it := acha(root, "section")
        testing.expectf(t, it != nil, "%s: não achei a <section>", nome)
        if it == nil do return
        dispoe(root)
        if esp_w >= 0 do testing.expectf(t, abs(it.w - esp_w) < 0.5, "%s: largura %v, veio %v", nome, esp_w, it.w)
        if esp_h >= 0 do testing.expectf(t, abs(it.h - esp_h) < 0.5, "%s: altura %v, veio %v", nome, esp_h, it.h)
    }
    COL :: `display:flex;flex-direction:column;width:600px;height:300px`
    ROW :: `display:flex;width:600px;height:300px`
    GRID :: `display:grid;grid-template-columns:400px;width:600px;height:300px`

    // coluna flex — eixo CRUZADO é a largura
    caso(t, "coluna: max-width",     COL, "max-width:150px", 150, -1)
    caso(t, "coluna: min-width",     COL, "min-width:700px", 700, -1) // transborda, como no Chrome
    caso(t, "coluna: min vence max", COL, "min-width:400px;max-width:150px", 400, -1)
    caso(t, "coluna: sem limite",    COL, "background:#eee", 600, -1) // CONTROLE

    // linha flex — eixo CRUZADO é a altura (align-items:stretch)
    caso(t, "linha: max-height",     ROW, "max-height:50px",  -1, 50)
    caso(t, "linha: sem limite",     ROW, "background:#eee",  -1, 300) // CONTROLE

    // grid — os dois eixos esticam na célula
    caso(t, "grid: max-width",       GRID, "max-width:150px", 150, -1)
    caso(t, "grid: max-height",      GRID, "max-height:50px",  -1, 50)
    caso(t, "grid: sem limite",      GRID, "background:#eee", 400, 300) // CONTROLE

    // Átomo INLINE (inline-block): quem impõe a largura é o layout de LINHA, pelo
    // intrínseco — e ele também passava por cima do max-width (300 em vez de 150).
    // ⚠️ o conteúdo é uma CAIXA de 300px, não texto: sem atlas de fonte no
    // `odin test` todo texto mede ~22px e a afirmação seria VAZIA (a 1ª versão
    // deste teste passava antes do conserto, medindo nada).
    inl :: proc(t: ^testing.T, nome, css: string, esperado: f32) {
        html := fmt.tprintf(`<body style="margin:0"><span style="display:%s">`+
            `<div style="width:300px;height:20px"></div></span></body>`, css)
        root := arvore(html)
        sp := acha(root, "span")
        testing.expectf(t, sp != nil, "%s: não achei o span", nome)
        if sp == nil do return
        dispoe(root)
        testing.expectf(t, abs(sp.w - esperado) < 0.5, "%s: largura %v, veio %v", nome, esperado, sp.w)
    }
    inl(t, "inline-block max-width",  "inline-block;max-width:150px", 150)
    inl(t, "inline-block min-width",  "inline-block;min-width:420px", 420)
    inl(t, "inline-block sem limite", "inline-block", 300)          // CONTROLE
    inl(t, "bloco (controle)",        "block;max-width:150px", 150) // já funcionava

    // ABSOLUTO esticado entre left/right — o 3º sítio que impõe tamanho. É onde
    // mora o idioma do conteúdo centrado da página.
    abs_caso :: proc(t: ^testing.T, nome, css: string, esp_w, esp_x: f32) {
        html := fmt.tprintf(`<body style="margin:0"><section style="position:absolute;height:20px;%s"></section></body>`, css)
        root := arvore(html)
        it := acha(root, "section")
        testing.expectf(t, it != nil, "%s: não achei a <section>", nome)
        if it == nil do return
        dispoe(root)
        testing.expectf(t, abs(it.w - esp_w) < 0.5, "%s: largura %v, veio %v", nome, esp_w, it.w)
        if esp_x >= 0 do testing.expectf(t, abs(it.x - esp_x) < 0.5, "%s: x %v, veio %v", nome, esp_x, it.x)
    }
    abs_caso(t, "abs esticado sem limite", "left:0;right:0", 600, 0) // CONTROLE
    abs_caso(t, "abs + max-width",         "left:0;right:0;max-width:150px", 150, 0)
    abs_caso(t, "abs + max-width + margin:auto", "left:0;right:0;max-width:150px;margin-left:auto;margin-right:auto", 150, 225)
}
