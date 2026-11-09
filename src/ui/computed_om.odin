package ui

// ── getComputedStyle REAL + GEOMETRIA (getBoundingClientRect & cia) ──────────
//
// Este arquivo é a ponte de LEITURA do motor de estilo/layout para o JS: o que a
// página pergunta sobre si mesma. Duas metades, mesma fonte e mesmo flush:
//   1. estilo computado  → `js_computed_style`   (M199)
//   2. geometria         → `js_element_rect` / `js_element_metric`  (M200)
//
// Até aqui `getComputedStyle(el)` devolvia uma CSSStyleDeclaration vazia: um
// stub cujo acesso a QUALQUER propriedade dava "". A degradação era honesta
// (string falsy em vez de TypeError) mas cara: `getComputedStyle` é uma das APIs
// mais lidas por código de site real — medir tema, largura, `display` p/ decidir
// se um menu está aberto — e "" leva o site à decisão ERRADA em silêncio. Este
// arquivo liga a leitura ao mesmo `Computed` que a pintura usa.
//
// ── DE ONDE VEM O VALOR ─────────────────────────────────────────────────────
// O `Computed` é o valor computado do nosso motor de estilo. Para as props de
// caixa (width/height/margin/padding/inset) o navegador devolve o valor USADO,
// depois do layout — então preferimos a `Box` do layout quando ela existe, e só
// caímos no Computed quando não há layout (ex.: o nó não gera caixa).
//
// ── AS TRÊS DEGRADAÇÕES, NOMEADAS ───────────────────────────────────────────
// 1. **Antes do 1º layout devolve ""**. Scripts de carga rodam ANTES do primeiro
//    compute_styles (ver a ordem em headless_render/fetch_worker), então não há
//    o que ler. Depois disso — timer, rAF, handler de evento, ou seja TODO código
//    interativo — o valor é real. É a mesma degradação de antes, mas agora
//    restrita à janela de carga em vez de valer para sempre.
// 2. **Propriedade não mapeada devolve ""** (mesma coisa que antes). O conjunto
//    mapeado está no switch de `js_computed_style` — é o que código real lê.
//    Prop nova no motor NÃO aparece aqui sozinha: tem de ganhar um `case`.
// 3. **Onde o nosso Computed é mais pobre que a spec, devolvemos o que temos e
//    não inventamos**: `font-family` virou uma família genérica na cascata (a
//    lista do autor não sobrevive), então devolvemos sans-serif/serif/monospace;
//    `border-*-style` só distingue none de "tem borda", então quem tem largura
//    sai como `solid`. Documentado aqui, não escondido.

import "core:fmt"
import "core:strings"
import csspkg "../css"
import dompkg "../dom"

// ── Fonte ativa ─────────────────────────────────────────────────────────────
// O hook não recebe contexto (é chamado do js), então o mapa de estilos e a
// árvore de layout correntes ficam aqui. Regra de segurança: **setar depois de
// CADA compute_styles/build_layout da thread principal** — quem re-estiliza
// libera o mapa anterior, e o ponteiro velho apontaria p/ memória liberada. Os
// pontos são poucos e enumerados: restyle_tab (funil da UI), o laço de frames
// do headless_render, e o desenho do viewport (que cobre a troca de aba, cujo
// mapa veio pronto do worker sem passar por restyle_tab).
// ⚠️ NÃO setar do worker de fetch: ele roda em OUTRA thread e o mapa dele ainda
// não pertence a nenhuma aba (seria corrida com a main).
@(private = "file", thread_local) g_js_styles: map[^dompkg.Node]Computed
@(private = "file", thread_local) g_js_layout: ^Box
@(private = "file", thread_local) g_js_have:   bool
@(private = "file", thread_local) g_js_vw, g_js_vh: f32
// Índice nó→caixa, construído sob demanda na 1ª pergunta de geometria de cada
// fonte (uma varredura da árvore em vez de uma por propriedade lida: sem isto,
// um laço do site sobre N elementos custaria O(N²)).
// Valor do índice: a caixa MAIS o deslocamento acumulado de `position:relative` e
// `transform` dos ancestrais (e dela própria). ⚠️ Esse offset NÃO está em b.x/b.y:
// o paint o acumula descendo a árvore (`ox2 := ox + b.rel_dx`), então quem lê a
// caixa isolada erra a posição de todo elemento relativo/transformado. Guardamos
// só a parte que NÃO depende de scroll — a compensação de fixed/sticky é aplicada
// na leitura, senão o índice ficaria velho a cada rolagem.
@(private = "file")
Box_Ref :: struct { b: ^Box, ox, oy: f32 }
@(private = "file", thread_local) g_js_boxes:  map[^dompkg.Node]Box_Ref
@(private = "file", thread_local) g_js_boxes_ok: bool
// A árvore de layout desta fonte já tem GEOMETRIA (passou por layout_box)?
@(private = "file", thread_local) g_js_laid_out: bool

// `laid_out`: passe true quando o chamador ACABOU de rodar layout_box sobre esta
// árvore (evita o flush redundante do box_of).
js_style_source_set :: proc(styles: map[^dompkg.Node]Computed, layout: ^Box, vw, vh: f32, laid_out := false) {
    g_js_styles = styles
    g_js_layout = layout
    g_js_have   = true
    g_js_vw, g_js_vh = vw, vh
    g_js_laid_out = laid_out
    if g_js_boxes_ok { clear(&g_js_boxes) } // índice velho aponta p/ caixas liberadas
    g_js_boxes_ok = false
    svg_css_bind(styles) // paint de SVG na main thread depois do worker
}

js_style_source_clear :: proc() {
    svg_css_clear()
    g_js_styles = nil
    g_js_layout = nil
    g_js_have   = false
    g_js_laid_out = false
    g_js_scroll_x, g_js_scroll_y = 0, 0 // "sem página" ⇒ sem scroll; e evita que um
                                        // teste vaze scroll no seguinte (lição do M192)
    if g_js_boxes_ok { clear(&g_js_boxes) }
    g_js_boxes_ok = false
}

// Liberação definitiva (fim de processo/teste): o `clear` acima recicla, este
// devolve a memória do índice.
js_style_source_free :: proc() {
    js_style_source_clear()
    delete(g_js_boxes)
    g_js_boxes = nil
}

// FLUSH DE LAYOUT NA LEITURA. O JS do frame roda ANTES do layout_box (timers e
// rAF são bombeados no topo do frame), então na 1ª leitura a árvore recém-montada
// ainda tem geometria zerada — medido: `setTimeout(...,0)` via `width` dava 0px e
// `setTimeout(...,100)` dava 300px. É a mesma situação em que o navegador faz
// LAYOUT SÍNCRONO FORÇADO ao ler geometria; fazemos igual, e no máximo uma vez por
// fonte (ou seja, por frame), só se o JS realmente perguntar.
@(private = "file")
box_ref_of :: proc(node: ^dompkg.Node) -> (Box_Ref, bool) {
    if g_js_layout == nil do return {}, false
    if !g_js_laid_out {
        layout_box(g_js_layout, 0, 0, g_js_vw)
        page := Rect{0, 0, g_js_vw, g_js_vh} // ICB = viewport (CSS 2.1 §10.1)
        layout_absolutes(g_js_layout, page, page)
        g_js_laid_out = true
    }
    if !g_js_boxes_ok {
        if g_js_boxes == nil do g_js_boxes = make(map[^dompkg.Node]Box_Ref)
        index_boxes(g_js_layout, 0, 0)
        g_js_boxes_ok = true
    }
    r, ok := g_js_boxes[node]
    return r, ok
}

@(private = "file")
box_of :: proc(node: ^dompkg.Node) -> ^Box {
    r, ok := box_ref_of(node)
    if !ok do return nil
    return r.b
}

// Acumula o offset como o paint faz (`ox2 := ox + b.rel_dx`), inclusive p/ a
// PRÓPRIA caixa — é assim que o paint posiciona `b.x + ox2`.
@(private = "file")
index_boxes :: proc(b: ^Box, ox, oy: f32) {
    if b == nil do return
    ox2 := ox + b.rel_dx
    oy2 := oy + b.rel_dy
    // O 1º a gravar vence: uma caixa anônima (§9.2.1.1) repete o `node` do pai,
    // e quem manda é a caixa PRINCIPAL do elemento, que vem antes na árvore.
    if b.node != nil {
        if _, ja := g_js_boxes[b.node]; !ja do g_js_boxes[b.node] = Box_Ref{b, ox2, oy2}
    }
    for c in b.children do index_boxes(c, ox2, oy2)
}

// Offset final em Y, com a compensação de fixed/sticky do paint aplicada AGORA
// (depende do scroll do frame, então não pode entrar no índice).
@(private = "file")
pinned_oy :: proc(r: Box_Ref) -> f32 {
    b := r.b
    if b.pos == .Fixed {
        // Fixed é pinado ao VIEWPORT: o paint devolve o scroll ao y, e a subtração
        // do scroll lá embaixo cancela — o rect fica constante ao rolar, como manda
        // a spec. Sem isto, um cabeçalho fixo reportaria posição negativa ao rolar.
        return r.oy + g_js_scroll_y
    }
    if b.pos == .Sticky && b.inset_has[0] && !b.inset_pct[0] {
        dy := g_js_scroll_y + b.inset[0] - (b.y + r.oy)
        if dy > 0 do return r.oy + min(dy, b.sticky_max_dy)
    }
    return r.oy
}

// ── GEOMETRIA: getBoundingClientRect e a família offset*/client*/scroll* ─────
//
// Mesma fonte e mesmo flush do getComputedStyle acima — a `Box` do layout já tem
// tudo. O que muda é o SISTEMA DE COORDENADAS: as caixas são relativas ao
// DOCUMENTO (o paint mapeia `tela = g_viewport_o + {b.x, b.y}`, e é o
// GetCursorScreenPos do child rolado que aplica o -scroll), enquanto o
// getBoundingClientRect da spec é relativo ao VIEWPORT. Daí subtrair o scroll.
//
// Degradações NOMEADAS (cada uma com teste):
//  a. **`offsetTop/offsetLeft` são relativos ao DOCUMENTO**, não ao offsetParent.
//     Coincide com a spec quando o offsetParent é o `<body>` (o caso comum); num
//     ancestral posicionado o nosso valor é maior. Não temos cadeia de
//     offsetParent, e inventar uma seria pior que documentar.
//  b. **`scrollWidth` = clientWidth**: guardamos extensão de scroll só no eixo Y
//     (`Box.scroll_max`), então no X não temos o que dizer.
//  c. **`clientWidth/Height` não descontam barra de rolagem** — a nossa não ocupa
//     espaço de layout.
//  d. **`getClientRects()` devolve UM retângulo** (a caixa de borda). No navegador
//     um inline quebrado em N linhas devolve N retângulos.
//  e. **`el.scrollTop = X` continua sem efeito**: aqui só EXPOMOS geometria; rolar
//     de fato é mexer no container de scroll da UI, que é outra conversa.
//
// ⚠️ Duas coisas que NÃO estão na Box e por isso já causaram erro de posição:
// o deslocamento de `position:relative`/`transform` (o paint acumula descendo a
// árvore) e a compensação de `position:fixed` (o paint devolve o scroll ao y).
// Ambas entram aqui — a 1ª no índice, a 2ª na leitura, porque depende do scroll.

// Scroll da PÁGINA, em coords de layout. Quem sabe é o laço de frame (o child
// rolado do ImGui), então ele empurra por aqui; fora dele fica 0, que é o valor
// certo p/ headless sem scroll.
@(private = "file", thread_local) g_js_scroll_x, g_js_scroll_y: f32

js_scroll_set :: proc(x, y: f32) { g_js_scroll_x = x; g_js_scroll_y = y }
js_scroll_get :: proc() -> (f32, f32) { return g_js_scroll_x, g_js_scroll_y }

// Viewport da fonte corrente: raiz IMPLÍCITA do IntersectionObserver e valor de
// `window.innerWidth/innerHeight`. Mesma fonte do rect — quem empurra o mapa de
// estilos empurra as dimensões junto, então os dois não podem divergir.
js_viewport_dims :: proc() -> (w, h: f32) { return g_js_vw, g_js_vh }

// Empurra SÓ as dimensões, antes de haver estilo/layout. Existe porque os
// <script> de carga da página rodam ANTES do 1º compute_styles (e, no navegador
// vivo, em OUTRA thread — a do fetch_worker, onde estes thread_local nascem
// zerados): sem isto, todo `window.innerWidth` lido no carregamento — que é onde
// site decide mobile×desktop — cairia no fallback de 800x600.
// ⚠️ chamar na MESMA thread em que os scripts vão rodar.
js_viewport_set :: proc(w, h: f32) { g_js_vw, g_js_vh = w, h }

// `window.matchMedia(q).matches`: MESMO parser e MESMA avaliação do `@media` da
// folha (csspkg.media_query_matches) e MESMA altura de referência que o passe de
// estilo usa (`g_viewport_h > 0 ? … : 720`, ver compute_styles) — CSS e JS da
// mesma página não podem discordar sobre "sou mobile?".
js_media_matches :: proc(query: string) -> bool {
    vw := g_js_vw
    if vw <= 0 do vw = 800 // mesmo fallback do window.innerWidth
    vh := g_viewport_h > 0 ? g_viewport_h : 720
    return csspkg.media_query_matches(query, vw, vh, g_prefers_dark)
}

// As DUAS caixas de um elemento numa tacada só, para o ResizeObserver: ele
// pergunta as duas (contentBoxSize e borderBoxSize) de TODO alvo a CADA frame, e
// perguntar métrica por métrica multiplicaria as buscas no índice nó→caixa.
// `pad_x/pad_y` são o offset do conteúdo dentro da caixa de borda MENOS a borda —
// é o `contentRect.x/y` da spec, que é o padding (não o padding+borda).
js_element_box :: proc(node: ^dompkg.Node) -> (cw, ch, bw, bh, pad_x, pad_y: f32, ok: bool) {
    if node == nil || !g_js_have do return 0, 0, 0, 0, 0, 0, false
    r, found := box_ref_of(node)
    if !found || r.b == nil do return 0, 0, 0, 0, 0, 0, false
    b := r.b
    cw = max(b.w - b.border_w[3] - b.border_w[1] - b.padding[3] - b.padding[1], 0)
    ch = max(b.h - b.border_w[0] - b.border_w[2] - b.padding[0] - b.padding[2], 0)
    return cw, ch, b.w, b.h, b.padding[3], b.padding[0], true
}

// getBoundingClientRect(): caixa de BORDA em coordenadas do viewport.
// ok=false quando o nó não gera caixa (display:none, fora do fluxo de layout) —
// o js devolve o DOMRect zerado nesse caso, como o navegador.
js_element_rect :: proc(node: ^dompkg.Node) -> (x, y, w, h: f32, ok: bool) {
    if node == nil || !g_js_have do return 0, 0, 0, 0, false
    r, found := box_ref_of(node)
    if !found || r.b == nil do return 0, 0, 0, 0, false
    b := r.b
    return b.x + r.ox - g_js_scroll_x, b.y + pinned_oy(r) - g_js_scroll_y, b.w, b.h, true
}

// Métrica escalar (offsetWidth, clientHeight, scrollTop, …). Separada do rect
// porque o js as lê uma a uma pelo get-hook do elemento.
js_element_metric :: proc(node: ^dompkg.Node, which: string) -> (v: f32, ok: bool) {
    if node == nil || !g_js_have do return 0, false
    // `documentElement.clientWidth/Height` É o viewport, por spec — não a caixa do
    // <html> (que pode ser mais curta ou mais alta que a janela).
    if node.tag == "html" {
        switch which {
        case "clientWidth":  return g_js_vw, true
        case "clientHeight": return g_js_vh, true
        }
    }
    // `document.documentElement.scrollTop` (e o do body) É o scroll da PÁGINA — é
    // a metade do idioma `window.pageYOffset || document.documentElement.scrollTop`.
    // A `Box` da raiz não sabe disso: o scroll da página vive no container de
    // scroll da UI, não numa caixa.
    if node.tag == "html" || node.tag == "body" {
        switch which {
        case "scrollTop":  return g_js_scroll_y, true
        case "scrollLeft": return g_js_scroll_x, true
        }
    }
    // scrollHeight de <html>/<body> = altura do DOCUMENTO (é o que "carregar mais
    // ao chegar no fim" lê). ⚠️ NÃO usar `root.h`: essa é a altura EM FLUXO, e ela
    // MENTE quando o conteúdo vive em caixas fixed/absolute (o root não as soma).
    // `box_max_extent` é a maior extensão y+h de QUALQUER caixa — é a mesma função
    // que o diagnose usa como `content_h` justamente porque o `page_h` mentia.
    if (node.tag == "html" || node.tag == "body") && which == "scrollHeight" && g_js_layout != nil {
        _ = box_of(node) // garante o flush de layout antes de medir
        return max(box_max_extent(g_js_layout), g_js_vh), true
    }
    r, found := box_ref_of(node)
    if !found || r.b == nil do return 0, false
    b := r.b
    switch which {
    case "offsetWidth":  return b.w, true
    case "offsetHeight": return b.h, true
    case "clientWidth":  return max(b.w - b.border_w[3] - b.border_w[1], 0), true // degradação (c)
    case "clientHeight": return max(b.h - b.border_w[0] - b.border_w[2], 0), true
    case "scrollWidth":  return max(b.w - b.border_w[3] - b.border_w[1], 0), true // degradação (b)
    case "scrollHeight": return max(b.h - b.border_w[0] - b.border_w[2], 0) + b.scroll_max, true
    // offsetTop/Left incluem o deslocamento de relative/transform (é a posição de
    // LAYOUT final), mas seguem relativos ao DOCUMENTO — degradação (a).
    case "offsetTop":    return b.y + r.oy, true
    case "offsetLeft":   return b.x + r.ox, true
    case "scrollTop":    return b.scroll_y, true
    case "scrollLeft":   return 0, true
    }
    return 0, false
}

// ── Serialização de valor ───────────────────────────────────────────────────

// Número no estilo do CSSOM: sem casas quando é inteiro, sem zeros à direita
// quando não é (o navegador devolve "10px", não "10.0000px").
@(private = "file")
num_str :: proc(v: f32) -> string {
    if v == f32(int(v)) do return fmt.tprintf("%d", int(v))
    s := fmt.tprintf("%.4f", v)
    s = strings.trim_right(s, "0")
    s = strings.trim_right(s, ".")
    return s
}

@(private = "file")
px :: proc(v: f32) -> string { return fmt.tprintf("%spx", num_str(v)) }

// Cor no formato do CSSOM: `rgb(r, g, b)` quando opaca, `rgba(r, g, b, a)` com
// alpha. ⚠️ a convenção da engine é **byte alto 0 = OPACO** (retrocompat com
// 0xRRGGBB), e COLOR_TRANSPARENT (0x01000000) é o nosso `transparent` — ele sai
// como `rgba(0, 0, 0, 0)`, que é o que o navegador devolve.
@(private = "file")
css_color :: proc(c: u32) -> string {
    if c == COLOR_TRANSPARENT do return "rgba(0, 0, 0, 0)"
    r := (c >> 16) & 0xFF
    g := (c >>  8) & 0xFF
    b :=  c        & 0xFF
    a := (c >> 24) & 0xFF
    if a == 0 do return fmt.tprintf("rgb(%d, %d, %d)", r, g, b)
    return fmt.tprintf("rgba(%d, %d, %d, %s)", r, g, b, num_str(f32(a) / 255.0))
}

@(private = "file")
side_index :: proc(prop, prefix, suffix: string) -> (idx: int, ok: bool) {
    // margin-top → 0, -right → 1, -bottom → 2, -left → 3 (ordem t r b l do Computed)
    if !strings.has_prefix(prop, prefix) do return 0, false
    rest := prop[len(prefix):]
    if suffix != "" {
        if !strings.has_suffix(rest, suffix) do return 0, false
        rest = rest[:len(rest) - len(suffix)]
    }
    switch rest {
    case "top":    return 0, true
    case "right":  return 1, true
    case "bottom": return 2, true
    case "left":   return 3, true
    }
    return 0, false
}

// ── O hook ──────────────────────────────────────────────────────────────────
// `prop` chega em kebab-case minúsculo (o js normaliza camelCase antes). O
// resultado é do TEMP allocator: o chamador (js) clona com own_str.
// Sonda compile-gated do custo da degradação #1: quantas leituras caem na janela
// de CARGA (sem estilo ainda) vs. quantas pegam valor real? Responde "vale a pena
// reordenar a carga?" com número em vez de intuição.
//   odin build . -define:GCSPROBE=true ...   e depois `browser.exe --diagnose <url>`
GCSPROBE :: #config(GCSPROBE, false)
when GCSPROBE {
    g_gcs_sem_fonte, g_gcs_com_fonte, g_gcs_vazio: int
    gcs_probe_report :: proc() {
        fmt.eprintfln("[gcsprobe] leituras: %d na carga (sem estilo) | %d com estilo | destas, %d devolveram vazio (prop nao mapeada)",
                      g_gcs_sem_fonte, g_gcs_com_fonte, g_gcs_vazio)
    }
}

js_computed_style :: proc(node: ^dompkg.Node, prop: string) -> string {
    when GCSPROBE {
        if g_js_have { g_gcs_com_fonte += 1 } else { g_gcs_sem_fonte += 1 }
        r := js_computed_style_inner(node, prop)
        if r == "" {
            g_gcs_vazio += 1
            // O NOME importa: é ele que diz qual `case` falta no switch.
            fmt.eprintfln("[gcsprobe] vazio p/ %q (tag=%s)", prop, node != nil ? node.tag : "<nil>")
        }
        return r
    } else {
        return js_computed_style_inner(node, prop)
    }
}

@(private = "file")
js_computed_style_inner :: proc(node: ^dompkg.Node, prop: string) -> string {
    if node == nil || !g_js_have do return ""
    c, ok := g_js_styles[node]
    if !ok do return ""
    // ⚠️ `box_of` é chamado SÓ nas props que precisam de geometria (width/height/
    // margin/padding). Pegá-lo aqui em cima custaria um passe de layout inteiro
    // para responder `cs.color` — e um site que lê cor num laço pagaria por isso.

    switch prop {

    // ── caixa: display/position/visibilidade ────────────────────────────────
    case "display":
        if c.display_none      do return "none"
        if c.display_contents  do return "contents"
        if c.display_flex      do return c.display_inline_level ? "inline-flex"  : "flex"
        if c.display_grid      do return c.display_inline_level ? "inline-grid"  : "grid"
        if c.display_table     do return c.display_inline_level ? "inline-table" : "table"
        if c.display_table_row    do return "table-row"
        if c.display_table_cell   do return "table-cell"
        if c.display_table_rowgrp do return "table-row-group"
        if c.display_inline_block do return "inline-block"
        if c.display_block        do return "block"
        if c.display_inline       do return "inline"
        // Sem override do autor: o default da TAG (o Computed só guarda o que a
        // cascata mudou, então a tabela do UA mora no layout). Usamos a MESMA
        // `l_is_inline` do layout — uma tabela só, sem 2ª cópia p/ divergir.
        if node.tag == "li" do return "list-item"
        if node.tag == "img" || node.tag == "br" || node.tag == "svg" do return "inline"
        return l_is_inline(node.tag) ? "inline" : "block"
    case "position":
        switch c.position {
        case .Static:   return "static"
        case .Relative: return "relative"
        case .Absolute: return "absolute"
        case .Fixed:    return "fixed"
        case .Sticky:   return "sticky"
        }
        return "static"
    case "visibility": return c.invisible ? "hidden" : "visible"
    case "opacity":    return num_str(c.opacity)
    case "z-index":    return !c.z_index_set ? "auto" : fmt.tprintf("%d", c.z_index)
    case "float":
        switch c.float {
        case .None:        return "none"
        case .Left:        return "left"
        case .Right:       return "right"
        case .InlineStart: return "inline-start"
        case .InlineEnd:   return "inline-end"
        }
        return "none"
    case "box-sizing": return c.box_sizing == .Border ? "border-box" : "content-box"
    case "overflow", "overflow-x", "overflow-y":
        clip := prop == "overflow-y" ? c.ovf_clip_y : c.ovf_clip_x
        if prop == "overflow" do clip = c.overflow_hidden
        if !clip do return "visible"
        return c.overflow_scroll ? "auto" : "hidden"
    // O valor COMPUTADO de `resize` é o declarado — a aplicabilidade (overflow ≠
    // visible) é decidida no uso, não na cascata, e o Chrome também devolve
    // "both" para uma <div> com overflow:visible.
    case "resize":
        switch c.resize {
        case .Both:       return "both"
        case .Horizontal: return "horizontal"
        case .Vertical:   return "vertical"
        case .None:       return "none"
        }
        return "none"

    // ── cor e texto ─────────────────────────────────────────────────────────
    case "color": return css_color(c.color)
    case "background-color":
        if !c.has_bg do return "rgba(0, 0, 0, 0)"
        return css_color(c.bg)
    case "font-size": return px(c.font_size)
    case "font-weight":
        switch c.weight {
        case .Regular: return "400"
        case .Semi:    return "600"
        case .Bold:    return "700"
        }
        return "400"
    case "font-style":  return c.italic ? "italic" : "normal"
    case "font-kerning":
        switch c.font_kerning { case .Auto: return "auto"; case .Normal: return "normal"; case .None: return "none" }
    case "font-family":
        // degradação #3: a cascata guarda só a família GENÉRICA
        switch c.font_family {
        case .Serif: return "serif"
        case .Mono:  return "monospace"
        case .Sans:  return "sans-serif"
        }
        return "sans-serif"
    case "line-height":
        // `line_height` é multiplicador; o navegador devolve o valor USADO em px
        return px(c.line_height * c.font_size)
    case "text-align":
        switch c.text_align {
        case .Left:    return "left"
        case .Center:  return "center"
        case .Right:   return "right"
        case .Justify: return "justify"
        }
        return "left"
    case "text-transform":
        switch c.text_transform {
        case .None:       return "none"
        case .Upper:      return "uppercase"
        case .Lower:      return "lowercase"
        case .Capitalize: return "capitalize"
        }
        return "none"
    case "letter-spacing": return c.letter_spacing == 0 ? "normal" : px(c.letter_spacing)
    case "word-spacing":   return c.word_spacing   == 0 ? "normal" : px(c.word_spacing)
    case "white-space":
        switch c.white_space {
        case .Normal: return "normal"
        case .Nowrap: return "nowrap"
        case .Pre:    return "pre"
        }
        return "normal"
    case "direction": return c.direction == .Rtl ? "rtl" : "ltr"
    case "text-indent":
        if c.text_indent_pct do return fmt.tprintf("%s%%", num_str(c.text_indent * 100))
        return px(c.text_indent)
    case "text-decoration-line", "text-decoration":
        parts := make([dynamic]string, context.temp_allocator)
        if c.underline do append(&parts, "underline")
        if c.overline  do append(&parts, "overline")
        if c.strike    do append(&parts, "line-through")
        if len(parts) == 0 do return "none"
        return strings.join(parts[:], " ", context.temp_allocator)
    case "text-decoration-color":
        return css_color(c.deco_color == DECO_UNSET ? c.color : c.deco_color)
    case "text-decoration-style":
        switch c.deco_style {
        case .Solid:  return "solid"
        case .Double: return "double"
        case .Dotted: return "dotted"
        case .Dashed: return "dashed"
        case .Wavy:   return "wavy"
        }
        return "solid"
    case "text-decoration-thickness": return c.deco_thick == 0 ? "auto" : px(c.deco_thick)
    case "cursor":
        switch c.cursor {
        case .Auto:       return "auto"
        case .Pointer:    return "pointer"
        case .Text:       return "text"
        case .Move:       return "move"
        case .NotAllowed: return "not-allowed"
        case .Progress:   return "progress"
        }
        return "auto"
    case "list-style-type":
        switch c.list_style {
        case .None:         return "none"
        case .Disc:         return "disc"
        case .Circle:       return "circle"
        case .Square:       return "square"
        case .Decimal:      return "decimal"
        case .Decimal_Zero: return "decimal-leading-zero"
        case .Lower_Alpha:  return "lower-alpha"
        case .Upper_Alpha:  return "upper-alpha"
        case .Lower_Roman:  return "lower-roman"
        case .Upper_Roman:  return "upper-roman"
        case .Auto:
            // valor inicial da spec = disc; só <ol> muda o default dos filhos
            if node.parent != nil && node.parent.tag == "ol" do return "decimal"
            return "disc"
        }
        return "disc"

    // ── geometria: valor USADO (da Box) quando há layout ────────────────────
    case "width":
        if b := box_of(node); b != nil {
            if c.box_sizing == .Border do return px(b.w)
            return px(b.content_w)
        }
        if c.has_width && !c.width_pct do return px(c.width)
        if c.width_minc do return "min-content"
        if c.width_fit do return "fit-content"
        if c.width_mc do return "max-content"
        return "auto"
    case "height":
        if b := box_of(node); b != nil {
            if c.box_sizing == .Border do return px(b.h)
            inner := b.h - b.padding[0] - b.padding[2] - b.border_w[0] - b.border_w[2]
            return px(max(inner, 0))
        }
        if c.has_height do return px(c.height)
        return "auto"
    case "min-width":  return c.has_minw ? px(c.minw) : "auto"
    case "max-width":  return c.has_maxw ? px(c.maxw) : "none"
    case "min-height": return c.has_minh ? px(c.minh) : "auto"
    case "max-height": return c.has_maxh ? px(c.maxh) : "none"

    // scroll-padding-top: a ÚNICA prop que uma leitura de site real pediu e caiu
    // na degradação #2 (a sonda -define:GCSPROBE pegou, no <html> da Wikipedia —
    // é o padrão "âncora não fica embaixo do cabeçalho fixo"). O motor já tinha o
    // campo; faltava o `case`.
    case "scroll-padding-top":  return c.scroll_padding_top == 0 ? "auto" : px(c.scroll_padding_top)
    case "scroll-margin-top":   return px(c.scroll_margin_top)

    case "border-radius":
        return fmt.tprintf("%s %s %s %s", px(c.border_radius[0]), px(c.border_radius[1]),
                                          px(c.border_radius[2]), px(c.border_radius[3]))
    }

    // ── famílias com sufixo por LADO (margin-top, border-left-width, …) ─────
    if i, k := side_index(prop, "margin-", ""); k {
        if b := box_of(node); b != nil do return px(b.margin[i]) // valor USADO (% já resolvido)
        return px(c.margin[i])
    }
    if i, k := side_index(prop, "padding-", ""); k {
        if b := box_of(node); b != nil do return px(b.padding[i])
        return px(c.padding[i])
    }
    if i, k := side_index(prop, "border-", "-width"); k {
        return px(c.border_w[i])
    }
    if i, k := side_index(prop, "border-", "-color"); k {
        return css_color(c.border_c[i])
    }
    if i, k := side_index(prop, "border-", "-style"); k {
        // degradação #3: guardamos "tem borda" e "none", não o traço
        if c.border_style_none[i] || c.border_w[i] == 0 do return "none"
        return "solid"
    }
    // inset: top/right/bottom/left soltos (só quando o autor definiu)
    switch prop {
    case "top", "right", "bottom", "left":
        i := 0
        switch prop {
        case "right":  i = 1
        case "bottom": i = 2
        case "left":   i = 3
        }
        if !c.inset_has[i] do return "auto"
        if c.inset_pct[i]  do return fmt.tprintf("%s%%", num_str(c.inset[i] * 100))
        return px(c.inset[i])

    // ── flex / grid ─────────────────────────────────────────────────────────
    case "flex-direction":
        if c.flex_dir == .Column do return c.flex_reverse ? "column-reverse" : "column"
        return c.flex_reverse ? "row-reverse" : "row"
    case "flex-wrap":   return c.flex_wrap ? "wrap" : "nowrap"
    case "flex-grow":   return num_str(c.flex_grow)
    case "flex-shrink": return num_str(c.flex_shrink)
    case "flex-basis":
        if !c.has_flex_basis || c.flex_basis_auto do return "auto"
        if c.flex_basis_pct do return fmt.tprintf("%s%%", num_str(c.flex_basis * 100))
        return px(c.flex_basis)
    case "order": return fmt.tprintf("%d", c.order)
    case "justify-content": return flex_just_str(c.justify)
    case "align-content":   return flex_just_str(c.align_content)
    case "align-items":     return flex_align_str(c.align_items)
    case "align-self":      return c.has_align_self ? flex_align_str(c.align_self) : "auto"
    case "justify-items":   return flex_align_str(c.justify_items)
    case "justify-self":    return c.has_justify_self ? flex_align_str(c.justify_self) : "auto"
    case "gap", "row-gap":
        return px(prop == "row-gap" ? c.row_gap : c.gap)
    case "column-gap":
        return px(c.col_gap < 0 ? c.gap : c.col_gap)
    }
    return "" // degradação #2: não mapeada
}

@(private = "file")
flex_just_str :: proc(j: Flex_Just) -> string {
    switch j {
    case .Start:   return "flex-start"
    case .Center:  return "center"
    case .End:     return "flex-end"
    case .Between: return "space-between"
    case .Around:  return "space-around"
    case .Evenly:  return "space-evenly"
    }
    return "flex-start"
}

@(private = "file")
flex_align_str :: proc(a: Flex_Align) -> string {
    switch a {
    case .Stretch: return "stretch"
    case .Start:   return "flex-start"
    case .Center:  return "center"
    case .End:     return "flex-end"
    }
    return "stretch"
}
