package ui

// Primeiro renderizador: percorre a árvore DOM e desenha o conteúdo
// (títulos, parágrafos, listas, links) com tamanhos de fonte e quebra de
// linha. Por enquanto usa o empilhamento e a quebra do próprio ImGui — é o
// "paint" inicial. O layout engine dedicado + Skia entram depois.
//
// Modelo simplificado de fluxo de blocos:
//   - tags ignoradas (head, script, style, ...) não aparecem
//   - blocos de texto (p, h1..h6, li, ...) viram um parágrafo quebrado
//   - containers (div, body, section, ul, ...) recursam nos filhos

import "core:strings"
import im  "../../vendor/imgui"
import dompkg "../dom"
import netpkg "../net"

// Espaçamento antes/depois de um bloco de texto (a fonte/cor vêm do CSS).
Block_Style :: struct {
    color:  u32,
    before: f32,
    after:  f32,
}

COL_BODY :: 0xd4d4d8
COL_HEAD :: 0xffffff
COL_LINK :: 0x0b57d0 // azul de link (UA); legível em fundo branco, sobreposto pela cor do autor

block_style :: proc(tag: string) -> Block_Style {
    s: Block_Style
    switch tag {
    case "h1": s = {COL_HEAD, 18, 10}
    case "h2": s = {COL_HEAD, 16, 8}
    case "h3": s = {COL_HEAD, 14, 6}
    case "h4", "h5", "h6": s = {COL_HEAD, 12, 4}
    case "p": s = {COL_BODY, 16, 16} // margem UA = 1em (16px no tamanho de fonte padrão)
    case "ul", "ol", "blockquote", "pre", "table", "form": s = {COL_BODY, 8, 8}
    case "li", "dd", "dt": s = {COL_BODY, 3, 3}
    case "a":  s = {COL_LINK, 4, 4}
    case:      s = {COL_BODY, 0, 0} // div, section etc. — sem margem padrão
    }
    s.before *= g_zoom; s.after *= g_zoom // margens default acompanham o zoom
    return s
}

// Tamanho padrão de fonte (px) por tag, quando o CSS não especifica.
@(private="file")
default_size :: proc(tag: string) -> f32 {
    switch tag {
    case "h1": return 32
    case "h2": return 24
    case "h3": return 19
    case "h4": return 16
    case "h5": return 13
    case "h6": return 12
    }
    return 16
}

// Escolhe a fonte mais próxima do tamanho desejado (nítida) e a escala restante.
@(private="file")
pick_font :: proc(size: f32, bold: bool) -> (^im.Font, f32) {
    best := 0
    for s, i in g_font_sizes {
        if abs(s - size) < abs(g_font_sizes[best] - size) do best = i
    }
    font := bold ? g_bold[best] : g_reg[best]
    return font, size / g_font_sizes[best]
}

@(private="file")
is_skip :: proc(tag: string) -> bool {
    switch tag {
    case "head", "script", "style", "title", "meta", "link", "base",
         "noscript", "template", "svg", "iframe", "object":
        return true
    }
    return false
}

@(private="file")
is_text_block :: proc(tag: string) -> bool {
    switch tag {
    case "p", "h1", "h2", "h3", "h4", "h5", "h6",
         "li", "td", "th", "caption", "figcaption", "pre",
         "blockquote", "a", "label", "button", "dt", "dd", "summary":
        return true
    }
    return false
}

@(private="file")
is_indent :: proc(tag: string) -> bool {
    switch tag {
    case "ul", "ol", "blockquote", "dl":
        return true
    }
    return false
}

// Estilos computados da página em renderização (setado por draw_content).
g_styles: map[^dompkg.Node]Computed

@(private="file") sc_color  :: proc(n: ^dompkg.Node) -> u32  { if c, ok := g_styles[n]; ok do return c.color; return DEFAULT_TEXT }
@(private="file") sc_bold   :: proc(n: ^dompkg.Node) -> bool { if c, ok := g_styles[n]; ok do return c.weight != .Regular; return false }
@(private="file") sc_hidden :: proc(n: ^dompkg.Node) -> bool { if c, ok := g_styles[n]; ok do return c.display_none; return false }
@(private="file") sc_size   :: proc(n: ^dompkg.Node) -> (f32, bool) { if c, ok := g_styles[n]; ok && c.has_font_size do return c.font_size, true; return 16, false }
@(private="file") sc_bg     :: proc(n: ^dompkg.Node) -> (u32, bool)  { if c, ok := g_styles[n]; ok && c.has_bg do return c.bg, true; return 0, false }
@(private="file") sc_margin :: proc(n: ^dompkg.Node) -> ([4]f32, bool) { if c, ok := g_styles[n]; ok do return c.margin, c.has_margin; return {}, false }
@(private="file") sc_pad    :: proc(n: ^dompkg.Node) -> [4]f32 { if c, ok := g_styles[n]; ok do return c.padding; return {} }
@(private="file") sc_border :: proc(n: ^dompkg.Node) -> ([4]f32, [4]u32, bool) { if c, ok := g_styles[n]; ok && c.has_border do return c.border_w, c.border_c, true; return {}, {}, false }
@(private="file") sc_width  :: proc(n: ^dompkg.Node) -> (f32, bool, bool) { if c, ok := g_styles[n]; ok && c.has_width do return c.width, c.width_pct, true; return 0, false, false }
@(private="file") sc_maxw   :: proc(n: ^dompkg.Node) -> (f32, bool, bool) { if c, ok := g_styles[n]; ok && c.has_maxw  do return c.maxw,  c.maxw_pct,  true; return 0, false, false }

@(private="file")
resolve_w :: proc(v: f32, pct: bool, avail: f32) -> f32 {
    return pct ? v * avail : v
}

@(private="file")
is_heading :: proc(tag: string) -> bool {
    switch tag { case "h1","h2","h3","h4","h5","h6": return true }
    return false
}

// Escolhe a fonte/escala de um nó: usa font-size do CSS ou o padrão da tag,
// pegando a fonte da escada mais próxima (texto grande fica nítido).
@(private="file")
text_font :: proc(n: ^dompkg.Node, tag: string) -> (^im.Font, f32) {
    size, has := sc_size(n)
    if !has do size = default_size(tag)
    bold := sc_bold(n) || is_heading(tag)
    return pick_font(size, bold)
}

// Renderiza a árvore inteira dentro do viewport atual.
render_dom :: proc(s: ^State, root: ^dompkg.Node, wrap_x: f32) {
    im.Indent(16)
    im.Dummy({0, 8})
    render_node(s, root, wrap_x)
    im.Dummy({0, 16})
    im.Unindent(16)
}

@(private="file")
render_node :: proc(s: ^State, n: ^dompkg.Node, wrap_x: f32) {
    switch n.kind {
    case .Document:
        for c in n.children do render_node(s, c, wrap_x)

    case .Element:
        if is_skip(n.tag) do return
        if sc_hidden(n)   do return // display: none

        if n.tag == "img" { render_image(s, n, wrap_x); return }
        if n.tag == "br"  { im.Dummy({0, 6}); return }
        if n.tag == "hr"  { im.Dummy({0, 6}); im.Separator(); im.Dummy({0, 6}); return }

        render_block(s, n, wrap_x)

    case .Text:
        txt := collapse_ws(n.text)
        if strings.trim_space(txt) == "" do return
        font, scale := text_font(n, "")
        draw_paragraph(txt, font, sc_color(n), wrap_x, scale)

    case .Comment:
        // ignora
    }
}

// Aplica o box model de um bloco: margem, padding e largura/max-width.
// (Fundo e borda por elemento ainda não — precisam de child windows p/
// lidar com aninhamento corretamente; próximo passo.)
@(private="file")
render_block :: proc(s: ^State, n: ^dompkg.Node, wrap_x: f32) {
    st := block_style(n.tag)
    m, has_m := sc_margin(n)
    p := sc_pad(n)

    // margens efetivas (CSS, ou o padrão da tag)
    mt := has_m ? m[0] : st.before
    mb := has_m ? m[2] : st.after
    ml := m[3]
    mr := m[1]

    if mt > 0 do im.Dummy({0, mt})

    left_inset  := ml + p[3]
    right_inset := mr + p[1]
    if left_inset > 0 do im.Indent(left_inset)

    cur_x := im.GetCursorPosX()
    inner_wrap := wrap_x - right_inset
    // NOTA: width/max-width do CSS NÃO são aplicados — sem um motor de layout
    // 2D (floats/flex/grid), honrar larguras quebra o fluxo linear (texto
    // espremido a uma letra por linha). Larguras dependem do layout real.
    if inner_wrap < cur_x + 16 do inner_wrap = cur_x + 16 // sanidade

    if p[0] > 0 do im.Dummy({0, p[0]}) // padding superior

    render_block_inner(s, n, inner_wrap)

    if p[2] > 0 do im.Dummy({0, p[2]}) // padding inferior
    if left_inset > 0 do im.Unindent(left_inset)
    if mb > 0 do im.Dummy({0, mb})
}

// Conteúdo interno de um bloco (texto direto ou fluxo de filhos).
@(private="file")
render_block_inner :: proc(s: ^State, n: ^dompkg.Node, wrap_x: f32) {
    // bloco de texto SEM imagens: parágrafo único (preserva link clicável)
    if is_text_block(n.tag) && !subtree_has_img(n) {
        txt := gather_text(n)
        if strings.trim_space(txt) == "" do return
        href  := block_link_href(n)
        color := href != "" ? COL_LINK : sc_color(n)
        font, scale := text_font(n, n.tag)
        prefix := n.tag == "li" ? "•  " : ""
        draw_paragraph(strings.concatenate({prefix, txt}, context.temp_allocator), font, color, wrap_x, scale)
        if href != "" do handle_link_click(s, href)
        return
    }
    // demais: fluxo de blocos (texto inline + imagens + blocos aninhados)
    indent := is_indent(n.tag)
    if indent do im.Indent(22)
    render_children_block(s, n, wrap_x)
    if indent do im.Unindent(22)
}

// Percorre os filhos separando texto inline (vira parágrafo) de filhos de
// bloco/imagem (renderizados na ordem). É um fluxo de blocos simplificado.
@(private="file")
render_children_block :: proc(s: ^State, n: ^dompkg.Node, wrap_x: f32) {
    sb := strings.builder_make(context.temp_allocator)
    color := sc_color(n)
    font, scale := text_font(n, n.tag)

    for c in n.children {
        switch c.kind {
        case .Text:
            strings.write_string(&sb, c.text)

        case .Element:
            if is_skip(c.tag) do continue
            if sc_hidden(c)   do continue

            if c.tag == "img" {
                flush_inline(&sb, font, color, scale, wrap_x)
                render_image(s, c, wrap_x)
            } else if is_inline(c.tag) {
                if subtree_has_img(c) {
                    // ex.: <a><img></a> — solta o texto e renderiza a imagem
                    flush_inline(&sb, font, color, scale, wrap_x)
                    render_children_block(s, c, wrap_x)
                } else {
                    strings.write_string(&sb, gather_text(c))
                    strings.write_byte(&sb, ' ')
                }
            } else {
                flush_inline(&sb, font, color, scale, wrap_x)
                render_node(s, c, wrap_x)
            }

        case .Document, .Comment:
        }
    }
    flush_inline(&sb, font, color, scale, wrap_x)
}

@(private="file")
flush_inline :: proc(sb: ^strings.Builder, font: ^im.Font, color: u32, scale, wrap_x: f32) {
    t := collapse_ws(strings.to_string(sb^))
    if t != "" {
        im.Dummy({0, 4})
        draw_paragraph(t, font, color, wrap_x, scale)
        im.Dummy({0, 4})
    }
    strings.builder_reset(sb)
}

@(private="file")
subtree_has_img :: proc(n: ^dompkg.Node) -> bool {
    if n.kind == .Element && n.tag == "img" do return true
    for c in n.children {
        if subtree_has_img(c) do return true
    }
    return false
}

@(private="file")
is_inline :: proc(tag: string) -> bool {
    switch tag {
    case "a", "span", "b", "strong", "i", "em", "u", "s", "small",
         "mark", "code", "abbr", "cite", "q", "sub", "sup", "label",
         "time", "big", "tt", "font", "bdi", "bdo", "ins", "del":
        return true
    }
    return false
}

// Renderiza uma imagem <img> (assíncrona: placeholder até carregar).
@(private="file")
render_image :: proc(s: ^State, n: ^dompkg.Node, wrap_x: f32) {
    src, ok := n.attrs["src"]
    if !ok || src == "" do return
    if strings.has_prefix(src, "data:") {
        draw_img_placeholder(n, "[imagem embutida]")
        return
    }

    base := len(s.tabs) > 0 ? s.tabs[s.active].url : ""
    url := netpkg.resolve_url(base, src, context.temp_allocator)
    if url == "" do return

    img := image_get(url)
    switch img.state {
    case .Ready:
        w := f32(img.w)
        h := f32(img.h)
        maxw := wrap_x - 16
        if maxw > 0 && w > maxw {
            h *= maxw / w
            w = maxw
        }
        im.Dummy({0, 6})
        im.Image(im.TextureID(uintptr(img.tex)), {w, h})
        im.Dummy({0, 6})
    case .Loading:
        draw_img_placeholder(n, "carregando imagem...")
    case .Failed:
        draw_img_placeholder(n, "[imagem]")
    }
}

@(private="file")
draw_img_placeholder :: proc(n: ^dompkg.Node, label: string) {
    txt := label
    if alt, ok := n.attrs["alt"]; ok && alt != "" do txt = alt

    bw : f32 = 200
    bh : f32 = 110
    im.Dummy({0, 4})
    dl := im.GetWindowDrawList()
    p  := im.GetCursorScreenPos()
    im.DrawList_AddRectFilled(dl, p, {p.x + bw, p.y + bh}, col(0x2a2a2e), 8)
    im.DrawList_AddRect(dl, p, {p.x + bw, p.y + bh}, col(0x46464c), 8)
    im.DrawList_AddText(dl, {p.x + 12, p.y + bh/2 - 8}, col(0x8a8a90),
        strings.clone_to_cstring(txt, context.temp_allocator))
    im.Dummy({bw, bh})
    im.Dummy({0, 4})
}

// Se o bloco recém-desenhado é um link, trata hover (cursor de mão) e clique.
@(private="file")
handle_link_click :: proc(s: ^State, href: string) {
    rmin := im.GetItemRectMin()
    rmax := im.GetItemRectMax()
    if !im.IsMouseHoveringRect(rmin, rmax) do return
    im.SetMouseCursor(.Hand)
    if im.IsMouseClicked(.Left) {
        base := len(s.tabs) > 0 ? s.tabs[s.active].url : ""
        resolved := netpkg.resolve_url(base, href, context.temp_allocator)
        if resolved != "" do start_navigation(s, resolved)
    }
}

// Devolve o href se o bloco inteiro corresponde a um único link, senão "".
@(private="file")
block_link_href :: proc(n: ^dompkg.Node) -> string {
    link := find_link(n)
    if link == nil do return ""
    href, ok := link.attrs["href"]
    if !ok || href == "" do return ""
    // só consideramos clicável quando o bloco É o link (texto idêntico),
    // evitando tornar um parágrafo inteiro clicável por um link interno.
    if n.tag == "a" do return href
    if gather_text(n) == gather_text(link) do return href
    return ""
}

@(private="file")
find_link :: proc(n: ^dompkg.Node) -> ^dompkg.Node {
    if n.kind == .Element && n.tag == "a" && "href" in n.attrs {
        return n
    }
    for c in n.children {
        if r := find_link(c); r != nil do return r
    }
    return nil
}

// Desenha um parágrafo com a fonte/cor dadas, quebrando em wrap_x.
@(private="file")
draw_paragraph :: proc(text: string, font: ^im.Font, color: u32, wrap_x: f32, scale: f32 = 1) {
    im.PushFont(font)
    if scale != 1 do im.SetWindowFontScale(scale)
    push_col(.Text, color)
    im.PushTextWrapPos(wrap_x)
    im.TextUnformatted(strings.clone_to_cstring(text, context.temp_allocator))
    im.PopTextWrapPos()
    im.PopStyleColor(1)
    if scale != 1 do im.SetWindowFontScale(1)
    im.PopFont()
}

// Junta o texto da subárvore e colapsa espaços (como o HTML faz).
@(private="file")
gather_text :: proc(n: ^dompkg.Node) -> string {
    sb := strings.builder_make(context.temp_allocator)
    dompkg.text_content(n, &sb)
    return collapse_ws(strings.to_string(sb))
}

// Colapsa sequências de espaços/quebras em um único espaço e apara as pontas.
@(private="file")
collapse_ws :: proc(s: string) -> string {
    sb := strings.builder_make(context.temp_allocator)
    prev_space := false
    for i in 0 ..< len(s) {
        c := s[i]
        is_ws := c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\f'
        if is_ws {
            if !prev_space do strings.write_byte(&sb, ' ')
            prev_space = true
        } else {
            strings.write_byte(&sb, c)
            prev_space = false
        }
    }
    return strings.trim_space(strings.to_string(sb))
}
