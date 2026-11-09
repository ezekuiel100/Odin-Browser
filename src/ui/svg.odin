package ui

// Renderização de <svg> INLINE (ícones — lucide, feather, heroicons, etc.).
// O <svg> é tratado como elemento SUBSTITUÍDO (box .Image com is_svg): aqui
// parseamos a subárvore gráfica (path/line/rect/circle/…) e emitimos polilinhas
// (PC_Polyline) em coords de tela. Suporta o subconjunto que os ícones usam:
// traço (stroke) e preenchimento (fill), currentColor, stroke-width, viewBox,
// grupos <g>, e o parser do atributo `d` (M/L/H/V/C/S/Q/T/A/Z, abs+rel).
// NÃO cobre: gradientes/patterns em fill, transform em <g>, clipPath, texto SVG.

import "core:strings"
import "core:fmt"
import "core:strconv"
import "core:math"
import "core:slice"
import im "../../vendor/imgui"
import csspkg "../css"
import dompkg "../dom"

SEG :: 14 // segmentos por curva de bézier ao achatar

// Entradas de `stroke-dasharray`. Aceitamos até 8 valores DECLARADOS; uma lista
// ÍMPAR é repetida p/ virar par (spec), daí o dobro aqui.
MAX_DASH :: 16

// contexto de pintura herdado (stroke/fill/largura), cores em formato IMGUI (ABGR).
SvgCtx :: struct {
    stroke: u32, has_stroke: bool,
    fill:   u32, has_fill: bool,
    sw: f32, // stroke-width em unidades de usuário (escala no emit)
    // fill-opacity/stroke-opacity: multiplicam SÓ o alfa da tinta (distinto de
    // `opacity`, que compõe o elemento inteiro). 1 = opaco.
    fill_op, stroke_op: f32,
    cap:  Svg_Cap,   // stroke-linecap
    join: Svg_Join,  // stroke-linejoin
    // fill-rule. ⚠️ DEFAULT = EvenOdd aqui, e não Nonzero como manda a spec: o
    // scanline even-odd foi o que fez os FUROS de ícone/letra vazarem certo neste
    // motor. `fill-rule:nonzero` explícito é honrado; o default fica como está p/
    // não regredir todo ícone já validado.
    evenodd: bool,
    // stroke-miterlimit: razão máxima entre o comprimento do BICO e a espessura.
    // Acima dela a junta vira BISEL (spec). 0 = não declarado → default 4.
    miterlimit: f32,
    // `fill="url(#id)"` / `stroke="url(#id)"`: guarda o ID, não uma cor. O
    // gradiente é resolvido no EMIT, que é onde a bounding box da forma existe
    // (o default `objectBoundingBox` é relativo a ela). "" = tinta sólida.
    fill_grad, stroke_grad: string,
    eff: f32, // opacidade efetiva do <svg> (as cores sólidas já vêm com ela aplicada;
              // o gradiente resolve a cor no EMIT e precisa aplicá-la lá)
    // stroke-dasharray / stroke-dashoffset, em unidades de USUÁRIO — escalam por
    // `savg` no emit, exatamente como o stroke-width. dash_n = 0 → traço SÓLIDO
    // (é também o que sobra de `none` e de uma lista inválida, per spec).
    dash: [MAX_DASH]f32, dash_n: int, dash_off: f32,
    // shape-rendering. `no_aa` = crispEdges|optimizeSpeed (a spec manda DESLIGAR
    // o antialias); `seg_mul` = multiplicador de segmentos no achatamento de
    // curva, 1 no auto e 3 em geometricPrecision. ⚠️ NÃO fazemos o encaixe na
    // grade de pixels que o crispEdges também permite — só o antialias, que é a
    // parte que a spec exige.
    no_aa: bool, seg_mul: int,
}
Svg_Cap  :: enum u8 { Butt, Round, Square }
Svg_Join :: enum u8 { Miter, Round, Bevel }

// Multiplica só o canal alfa de uma cor já em formato IMGUI (ABGR).
@(private="file")
mul_alpha :: proc(col: u32, f: f32) -> u32 {
    if f >= 1 do return col
    a := f32((col >> 24) & 0xFF) * max(f, 0)
    return (col & 0x00FF_FFFF) | (u32(clamp(a, 0, 255)) << 24)
}

// Transform user→tela como matriz afim: tela = (a·x + c·y + e, b·x + d·y + f).
// (Antes era só translate+scale; matriz completa suporta `transform` de <g>/elemento
// — rotate/skew/matrix — que SVGs do Inkscape usam p/ encaixar arte no viewBox.)
Svg_Xform :: struct { a, b, c, d, e, f: f32 }

svg_pt :: proc(t: Svg_Xform, x, y: f32) -> im.Vec2 {
    return { t.a * x + t.c * y + t.e, t.b * x + t.d * y + t.f }
}

// Fator de escala uniforme da matriz (√|det|) — usado p/ largura de traço.
svg_scale :: proc(t: Svg_Xform) -> f32 {
    return math.sqrt(abs(t.a * t.d - t.b * t.c))
}

// Composição m1 ∘ m2 (aplica m2 e depois m1): usado p/ encadear o transform de um
// <g> sobre o transform herdado. Convenção (a,b,c,d,e,f) do SVG.
svg_mul :: proc(m1, m2: Svg_Xform) -> Svg_Xform {
    return {
        a = m1.a * m2.a + m1.c * m2.b,
        b = m1.b * m2.a + m1.d * m2.b,
        c = m1.a * m2.c + m1.c * m2.d,
        d = m1.b * m2.c + m1.d * m2.d,
        e = m1.a * m2.e + m1.c * m2.f + m1.e,
        f = m1.b * m2.e + m1.d * m2.f + m1.f,
    }
}

// Parseia o atributo `transform` (lista de matrix/translate/scale/rotate/skewX/skewY,
// aplicada da esquerda p/ direita = a 1ª é a mais externa) → 1 matriz.
svg_parse_transform :: proc(s: string) -> Svg_Xform {
    m := Svg_Xform{1, 0, 0, 1, 0, 0} // identidade
    i := 0
    for i < len(s) {
        // nome da função
        for i < len(s) && (s[i] == ' ' || s[i] == ',' || s[i] == '\t' || s[i] == '\n' || s[i] == '\r') do i += 1
        ns := i
        for i < len(s) && ((s[i] >= 'a' && s[i] <= 'z') || (s[i] >= 'A' && s[i] <= 'Z')) do i += 1
        name := s[ns:i]
        if name == "" do break
        // argumentos entre parênteses
        for i < len(s) && s[i] != '(' do i += 1
        if i >= len(s) do break
        i += 1 // pula '('
        args: [6]f32
        na := 0
        for na < 6 {
            v, ok := svg_num(s, &i)
            if !ok do break
            args[na] = v; na += 1
        }
        for i < len(s) && s[i] != ')' do i += 1
        if i < len(s) do i += 1 // pula ')'

        op := Svg_Xform{1, 0, 0, 1, 0, 0}
        switch name {
        case "matrix":
            if na >= 6 do op = {args[0], args[1], args[2], args[3], args[4], args[5]}
        case "translate":
            op.e = na >= 1 ? args[0] : 0
            op.f = na >= 2 ? args[1] : 0
        case "scale":
            sx := na >= 1 ? args[0] : 1
            sy := na >= 2 ? args[1] : sx
            op.a = sx; op.d = sy
        case "rotate":
            ang := (na >= 1 ? args[0] : 0) * math.PI / 180
            ca := math.cos(ang); sa := math.sin(ang)
            if na >= 3 { // rotate(a cx cy) = translate(cx,cy) rot translate(-cx,-cy)
                cx := args[1]; cy := args[2]
                r := Svg_Xform{ca, sa, -sa, ca, 0, 0}
                op = svg_mul(Svg_Xform{1, 0, 0, 1, cx, cy}, svg_mul(r, Svg_Xform{1, 0, 0, 1, -cx, -cy}))
            } else {
                op = {ca, sa, -sa, ca, 0, 0}
            }
        case "skewx", "skewX":
            op.c = math.tan((na >= 1 ? args[0] : 0) * math.PI / 180)
        case "skewy", "skewY":
            op.b = math.tan((na >= 1 ? args[0] : 0) * math.PI / 180)
        }
        m = svg_mul(m, op)
    }
    return m
}

// viewBox = "minX minY width height". ok=false se ausente/inválido.
// Aceita "viewBox" (camelCase, do `foreign_attr_adjust` do parser p/ SVG inline)
// E "viewbox" (minúsculo): um arquivo .svg EXTERNO é parseado como documento e não
// entra em modo foreign content, então o atributo fica minúsculo. Sem este fallback
// o logo do HN (viewBox "4 4 188 188", width/height=18) renderizava a 188px.
svg_viewbox :: proc(node: ^dompkg.Node) -> (x, y, w, h: f32, ok: bool) {
    vb, has := node.attrs["viewBox"]
    if !has do vb, has = node.attrs["viewbox"]
    if !has do return 0, 0, 0, 0, false
    i := 0
    a, ka := svg_num(vb, &i); b, kb := svg_num(vb, &i)
    c, kc := svg_num(vb, &i); d, kd := svg_num(vb, &i)
    if !(ka && kb && kc && kd) do return 0, 0, 0, 0, false
    return a, b, c, d, true
}

// Ponto de entrada p/ <svg> INLINE: desenha o <svg> `b` na caixa (origin, dw×dh).
paint_svg :: proc(pt: ^Painter, b: ^Box, origin: im.Vec2, dw, dh, eff: f32) {
    paint_svg_node(pt, b.node, b.svg_fg, origin, dw, dh, eff)
}

// Desenha um <svg> a partir de um NÓ DOM qualquer (inline OU externo via <img
// src=".svg">, cujo documento foi baixado+parseado no cache de imagens).
// currentColor = `svg_fg`. A caixa de destino é (origin, dw×dh) em coords de tela.
paint_svg_node :: proc(pt: ^Painter, node: ^dompkg.Node, svg_fg: u32, origin: im.Vec2, dw, dh, eff: f32) {
    if node == nil do return
    vx, vy, vw, vh, has_vb := svg_viewbox(node)
    if !has_vb {
        vx = 0; vy = 0
        vw = attr_num(node, "width");  if vw <= 0 do vw = dw
        vh = attr_num(node, "height"); if vh <= 0 do vh = dh
    }
    if vw <= 0 do vw = 24
    if vh <= 0 do vh = 24
    // base viewBox→tela: escala (sx,sy) + translada (vx,vy)→origin, como matriz.
    sx := dw / vw; sy := dh / vh
    t := Svg_Xform{ sx, 0, 0, sy, origin.x - vx * sx, origin.y - vy * sy }
    savg := svg_scale(t)

    // ctx raiz = default SVG (fill preto, sem traço, sw=1), depois os atributos do
    // próprio <svg> (lucide: fill=none stroke=currentColor stroke-width=2).
    root := SvgCtx{ fill = col_o(0x000000, eff), has_fill = true, sw = 1,
                    fill_op = 1, stroke_op = 1, evenodd = true, eff = eff }
    // <defs>/<linearGradient> são PULADOS pelo walk (são definição, não desenho):
    // colhemos os gradientes ANTES, num passe próprio.
    svg_collect_gradients(node, svg_fg)
    root = svg_apply(root, node, svg_fg, eff)
    svg_walk(pt, node, root, t, savg, svg_fg, eff)
}

// Aplica os atributos/estilo de apresentação de `node` sobre `ctx`.
// Ordem (spec): atributo de apresentação (especificidade ZERO) → regra CSS →
// style="" do elemento. O style="" já está embutido no valor computado que vem
// de svg_css_get (Computed.svg_css); relê-lo aqui é redundante mas inofensivo (mesmo vencedor).
@(private="file")
svg_apply :: proc(ctx: SvgCtx, node: ^dompkg.Node, cur: u32, eff: f32) -> SvgCtx {
    c := ctx
    for prop in SVG_PROPS {
        if v, ok := node.attrs[prop]; ok do svg_set_prop(&c, prop, v, cur, eff)
    }
    // Regra CSS (`.icon path { fill: currentColor }`): vence o ATRIBUTO, que
    // per-spec tem especificidade zero. Vem de Computed.svg_css via svg_css_get,
    // preenchido na resolução de estilo. Só o que o nó DECLAROU —
    // a herança pela subárvore é o próprio SvgCtx.
    if e, ok := svg_css_get(node); ok {
        if e.fill_set {
            c.fill_grad = ""
            if e.fill_none { c.has_fill = false } else { c.fill = col_o(e.fill, eff); c.has_fill = true }
        }
        if e.stroke_set {
            if e.stroke_none { c.has_stroke = false } else { c.stroke = col_o(e.stroke, eff); c.has_stroke = true }
        }
        if e.sw_set        do c.sw        = e.sw
        if e.fill_op_set   do c.fill_op   = e.fill_op
        if e.stroke_op_set do c.stroke_op = e.stroke_op
        if e.cap_set       do c.cap       = Svg_Cap(e.cap)
        if e.join_set      do c.join      = Svg_Join(e.join)
        if e.rule_set      do c.evenodd   = e.evenodd
        if e.dash_set      { c.dash = e.dash; c.dash_n = e.dash_n }
        if e.doff_set      do c.dash_off  = e.doff
        if e.mlim_set      do c.miterlimit = e.mlim
        if e.shape_set     { c.no_aa = e.no_aa; c.seg_mul = e.seg_mul }
    }
    if st, ok := node.attrs["style"]; ok {
        for decl in strings.split(st, ";", context.temp_allocator) {
            ci := strings.index_byte(decl, ':')
            if ci < 0 do continue
            prop := strings.trim_space(strings.to_lower(decl[:ci], context.temp_allocator))
            svg_set_prop(&c, prop, strings.trim_space(decl[ci + 1:]), cur, eff)
        }
    }
    return c
}

// Props de apresentação que lemos do ATRIBUTO (mesma lista serve p/ style="").
SVG_PROPS :: []string{
    "fill", "stroke", "stroke-width",
    "fill-opacity", "stroke-opacity", "stroke-linecap", "stroke-linejoin", "fill-rule",
    "stroke-dasharray", "stroke-dashoffset", "stroke-miterlimit", "shape-rendering",
}

// shape-rendering: auto | optimizeSpeed | crispEdges | geometricPrecision.
// Devolve (no_aa, seg_mul, ok). HERDA pela subárvore, como as demais.
svg_parse_shape_rendering :: proc(val: string) -> (no_aa: bool, seg_mul: int, ok: bool) {
    switch strings.to_lower(strings.trim_space(val), context.temp_allocator) {
    case "auto", "inherit":     return false, 1, true
    case "optimizespeed":       return true,  1, true
    case "crispedges":          return true,  1, true
    case "geometricprecision":  return false, 3, true
    }
    return false, 1, false
}

// Conversão de UM item para unidades de usuário. Existe porque os dois caminhos
// da família usam convenções diferentes, e o certo é cada um seguir a que o
// `stroke-width` irmão já usa — o que se vê quando os dois discordam é o padrão
// fora de escala com a espessura do próprio traço:
//   • ATRIBUTO de apresentação → `svg_user_num` (número cru, como o stroke-width
//     de atributo).
//   • REGRA CSS / `style=` → o wrapper de `parse_len` em style.odin (que é
//     `@(private="file")` lá), como o stroke-width de regra: `em`/`rem` valem.
//     ⚠️ herda daí o mesmo `g_zoom` embutido — errado a rigor (o viewBox→tela já
//     carrega o zoom), mas erra JUNTO com a espessura, então o traço fica
//     uniformemente mais grosso em vez de desalinhar do padrão.
Svg_Len_Conv :: #type proc(tok: string, fs, vw, vh: f32) -> (f32, bool)

svg_user_num :: proc(tok: string, fs, vw, vh: f32) -> (f32, bool) {
    f, k := strconv.parse_f64(tok)
    return f32(f), k
}

// `none` | <dasharray>: números separados por vírgula e/ou espaço.
//
// Retorno `ok=false` = declaração INVÁLIDA (token que não é comprimento, ou `%`,
// que precisaria da diagonal do viewport): o chamador não escreve nada e o valor
// herdado continua valendo. Já valor negativo ou soma ZERO é ERRO per-spec, que
// manda renderizar como `none` → devolvemos `n=0, ok=true` (sólido).
svg_parse_dasharray :: proc(val: string, conv: Svg_Len_Conv, fs, vw, vh: f32) -> (out: [MAX_DASH]f32, n: int, ok: bool) {
    v := strings.trim_space(val)
    if v == "" do return out, 0, false
    if strings.equal_fold(v, "none") do return out, 0, true

    decl: [MAX_DASH / 2]f32
    dn := 0
    total: f32 = 0
    // vírgula é separador tanto quanto espaço: `4,2` e `4 2` são a mesma lista
    for tok in strings.split_multi(v, {",", " ", "\t", "\n", "\r"}, context.temp_allocator) {
        t := strings.trim_space(tok)
        if t == "" do continue // `4, 2` gera um campo vazio entre os separadores
        if dn >= len(decl) do return out, 0, false // lista longa demais p/ o buffer
        x, k := conv(t, fs, vw, vh)
        if !k do return out, 0, false
        if x < 0 do return out, 0, true // negativo = erro → sólido
        decl[dn] = x; dn += 1; total += x
    }
    if dn == 0 || total <= 0 do return out, 0, true // lista vazia ou toda zero = `none`

    // Lista ÍMPAR é REPETIDA p/ virar par (spec): `5` = `5 5`, `4 2 1` = `4 2 1 4 2 1`.
    // Sem isso, um `stroke-dasharray:5` (grafia comum) não teria vão nenhum.
    reps := dn % 2 == 1 ? 2 : 1
    for r in 0 ..< reps {
        for i in 0 ..< dn { out[n] = decl[i]; n += 1 }
    }
    return out, n, true
}

@(private="file")
svg_set_prop :: proc(c: ^SvgCtx, prop, val: string, cur: u32, eff: f32) {
    switch prop {
    case "fill":           svg_set_paint(&c.fill,   &c.has_fill,   val, cur, eff, &c.fill_grad)
    case "stroke":         svg_set_paint(&c.stroke, &c.has_stroke, val, cur, eff, &c.stroke_grad)
    case "stroke-width":   if n, k := strconv.parse_f64(strings.trim_space(val)); k do c.sw = f32(n)
    case "fill-opacity":   if o, k := svg_opacity(val); k do c.fill_op = o
    case "stroke-opacity": if o, k := svg_opacity(val); k do c.stroke_op = o
    case "stroke-linecap":
        switch strings.to_lower(strings.trim_space(val), context.temp_allocator) {
        case "round":  c.cap = .Round
        case "square": c.cap = .Square
        case "butt":   c.cap = .Butt
        }
    case "stroke-linejoin":
        switch strings.to_lower(strings.trim_space(val), context.temp_allocator) {
        case "round": c.join = .Round
        case "bevel": c.join = .Bevel
        case "miter": c.join = .Miter
        }
    case "fill-rule":
        lv := strings.to_lower(strings.trim_space(val), context.temp_allocator)
        if lv == "nonzero" do c.evenodd = false
        if lv == "evenodd" do c.evenodd = true
    case "stroke-dasharray":
        if a, n, k := svg_parse_dasharray(val, svg_user_num, 0, 0, 0); k { c.dash = a; c.dash_n = n }
    case "stroke-dashoffset":
        if f, k := strconv.parse_f64(strings.trim_space(val)); k do c.dash_off = f32(f)
    case "stroke-miterlimit":
        // per-spec o valor tem de ser >= 1; menor que isso é ERRO e a
        // declaração é ignorada (o herdado continua valendo).
        if f, k := strconv.parse_f64(strings.trim_space(val)); k && f >= 1 do c.miterlimit = f32(f)
    case "shape-rendering":
        if na, sm, k := svg_parse_shape_rendering(val); k { c.no_aa = na; c.seg_mul = sm }
    }
}

// <number> ou <percentage>, clampado a [0,1] (spec).
svg_opacity :: proc(val: string) -> (f32, bool) {
    t := strings.trim_space(val)
    pct := strings.has_suffix(t, "%")
    if pct do t = t[:len(t) - 1]
    if n, k := strconv.parse_f64(strings.trim_space(t)); k {
        v := f32(n) * (pct ? 0.01 : 1)
        return clamp(v, 0, 1), true
    }
    return 1, false
}

@(private="file")
svg_set_paint :: proc(field: ^u32, has: ^bool, val: string, cur: u32, eff: f32, grad: ^string = nil) {
    v := strings.trim_space(val)
    if v == "" do return
    if grad != nil do grad^ = "" // uma tinta nova cancela o gradiente herdado
    if grad != nil {
        if id := svg_url_ref(v); id != "" { grad^ = id; has^ = true; return }
    }
    if strings.equal_fold(v, "none")         { has^ = false; return }
    if strings.equal_fold(v, "currentcolor") { field^ = col_o(cur, eff); has^ = true; return }
    if cc, ok := csspkg.parse_color(v); ok   { field^ = col_o(cc, eff); has^ = true }
}

// Percorre a subárvore, resolvendo o contexto e emitindo cada forma.
@(private="file")
svg_walk :: proc(pt: ^Painter, node: ^dompkg.Node, ctx: SvgCtx, t: Svg_Xform, savg: f32, cur: u32, eff: f32) {
    for ch in node.children {
        if ch.kind != .Element do continue
        // Elementos de DEFINIÇÃO/metadata não são pintados diretamente (só
        // referenciados por id): <defs>/<clipPath>/<mask>/gradientes/etc. Sem este
        // skip, os paths dentro deles (coords enormes em SVGs do Inkscape, ex. o
        // banner do sqlite) vazavam como formas pretas gigantes na tela.
        switch ch.tag {
        case "defs", "clippath", "clipPath", "mask", "symbol", "pattern",
             "lineargradient", "linearGradient", "radialgradient", "radialGradient",
             "marker", "filter", "metadata", "title", "desc", "style", "use":
            continue
        }
        c2 := svg_apply(ctx, ch, cur, eff)
        // transform do elemento (compõe sobre o herdado; afeta o próprio e a subárvore)
        t2 := t; savg2 := savg
        if tf, ok := ch.attrs["transform"]; ok && tf != "" {
            t2 = svg_mul(t, svg_parse_transform(tf))
            savg2 = svg_scale(t2)
        }
        switch ch.tag {
        case "g", "a":
            svg_walk(pt, ch, c2, t2, savg2, cur, eff)
        case "path":
            if d, ok := ch.attrs["d"]; ok do svg_path(pt, d, c2, t2, savg2)
        case "line":
            x1 := attr_num(ch, "x1"); y1 := attr_num(ch, "y1")
            x2 := attr_num(ch, "x2"); y2 := attr_num(ch, "y2")
            svg_emit(pt, {{x1, y1}, {x2, y2}}, false, c2, t2, savg2)
        case "polyline", "polygon":
            if p, ok := ch.attrs["points"]; ok {
                pts := svg_points(p)
                svg_emit(pt, pts[:], ch.tag == "polygon", c2, t2, savg2)
            }
        case "rect":
            x := attr_num(ch, "x"); y := attr_num(ch, "y")
            w := attr_num(ch, "width"); h := attr_num(ch, "height")
            if w > 0 && h > 0 {
                svg_emit(pt, {{x, y}, {x + w, y}, {x + w, y + h}, {x, y + h}}, true, c2, t2, savg2)
            }
        case "circle":
            cx := attr_num(ch, "cx"); cy := attr_num(ch, "cy"); r := attr_num(ch, "r")
            if r > 0 { ep := svg_ellipse_pts(cx, cy, r, r, svg_seg_mul(c2)); svg_emit(pt, ep[:], true, c2, t2, savg2) }
        case "ellipse":
            cx := attr_num(ch, "cx"); cy := attr_num(ch, "cy")
            rx := attr_num(ch, "rx"); ry := attr_num(ch, "ry")
            if rx > 0 && ry > 0 { ep := svg_ellipse_pts(cx, cy, rx, ry, svg_seg_mul(c2)); svg_emit(pt, ep[:], true, c2, t2, savg2) }
        }
    }
}

// Transforma os pontos de usuário → tela e emite fill (se houver) + stroke.
@(private="file")
svg_emit :: proc(pt: ^Painter, pts_user: [][2]f32, closed: bool, ctx: SvgCtx, t: Svg_Xform, savg: f32) {
    if len(pts_user) < 2 do return
    scr := make([]im.Vec2, len(pts_user), context.temp_allocator)
    for p, i in pts_user do scr[i] = svg_pt(t, p[0], p[1])
    if ctx.has_fill && len(scr) >= 3 {
        // Gradiente exige varredura por SCANLINE (a cor varia dentro da forma);
        // o poly-fill do ImGui só aceita UMA cor. Formas de contorno único
        // (rect/circle/polygon) vinham por aqui e por isso não pegavam o
        // gradiente — era o caminho que faltava.
        if ctx.fill_grad != "" && svg_grad_ready(ctx.fill_grad) {
            one := [1][][2]f32{pts_user}
            svg_fill_scanline(pt, one[:], mul_alpha(ctx.fill, ctx.fill_op), t, ctx.evenodd, ctx)
        } else {
            emit(pt, PC_Polyline{ pts = scr, col = mul_alpha(ctx.fill, ctx.fill_op), fill = true, no_aa = ctx.no_aa })
        }
    }
    if ctx.has_stroke {
        th := max(ctx.sw * savg, 0.6)
        col := mul_alpha(ctx.stroke, ctx.stroke_op)
        svg_stroke_polyline(pt, scr, closed, ctx, col, th, savg)
    }
}

// ── stroke-dasharray / stroke-dashoffset ────────────────────────────────────
// O corte é feito em coords de TELA, com o padrão escalado por `savg` — a mesma
// aproximação que o stroke-width já faz p/ transform não-uniforme.

// Teto de peças por polilinha. Padrão minúsculo em caminho longo geraria dezenas
// de milhares de draw-calls; acima disso caímos p/ SÓLIDO (que é o que se vê de
// qualquer jeito quando o período some na rasterização).
MAX_DASH_PIECES :: 1500

// Fatia a polilinha de tela `scr` no padrão `pat` (JÁ em pixels), devolvendo as
// peças ACESAS. Vértices originais internos a uma peça são preservados — a peça
// continua sendo uma polilinha, não um segmento reto —, então uma curva achatada
// tracejada não vira uma sequência de cordas.
//
// ⚠️ Peça de comprimento ZERO (padrão `0 8`, o idioma da linha PONTILHADA) sai
// com UM ponto só; quem emite decide o que fazer com ela conforme o linecap.
//
// `ok=false` = estourou o teto de peças; o chamador desenha sólido. Devolver a
// lista parcial pintaria metade do traço, que é pior que não tracejar.
svg_dash_pieces :: proc(scr: []im.Vec2, closed: bool, pat: []f32, off: f32) -> (pieces: [][]im.Vec2, ok: bool) {
    out := make([dynamic][]im.Vec2, context.temp_allocator)
    if len(scr) < 2 || len(pat) < 2 do return out[:], false
    period: f32 = 0
    for v in pat do period += v
    if period <= 0 do return out[:], false

    pts := scr
    if closed { // o segmento de fechamento também é tracejado
        tmp := make([]im.Vec2, len(scr) + 1, context.temp_allocator)
        copy(tmp, scr); tmp[len(scr)] = scr[0]
        pts = tmp
    }

    total: f32 = 0
    for i in 0 ..< len(pts) - 1 {
        dx, dy := pts[i + 1].x - pts[i].x, pts[i + 1].y - pts[i].y
        total += math.sqrt(dx * dx + dy * dy)
    }
    if total / period * f32(len(pat) / 2) > MAX_DASH_PIECES do return out[:], false

    // Posição inicial DENTRO do padrão. `stroke-dashoffset` positivo avança no
    // padrão (o desenho "anda p/ trás"); negativo enrola pelo fim.
    o := math.mod(off, period)
    if o < 0 do o += period
    idx := 0
    for guard := 0; o > 0 && o >= pat[idx] && guard < len(pat); guard += 1 {
        o -= pat[idx]
        idx = (idx + 1) % len(pat)
    }
    on := idx % 2 == 0
    rem := pat[idx] - o

    cur := make([dynamic]im.Vec2, context.temp_allocator)
    if on do append(&cur, pts[0])

    for i in 0 ..< len(pts) - 1 {
        a, b := pts[i], pts[i + 1]
        dx, dy := b.x - a.x, b.y - a.y
        seg := math.sqrt(dx * dx + dy * dy)
        if seg <= 0 do continue
        t: f32 = 0
        for t < seg {
            step := min(rem, seg - t)
            t += step
            rem -= step
            p := im.Vec2{a.x + dx * (t / seg), a.y + dy * (t / seg)}
            // ponto repetido viraria peça de 2 pontos com comprimento zero, e o
            // emissor não saberia distinguir do PONTO de `dasharray:0 n`
            if on && (len(cur) == 0 || abs(cur[len(cur) - 1].x - p.x) > 0.001 ||
                                       abs(cur[len(cur) - 1].y - p.y) > 0.001) {
                append(&cur, p)
            }
            if rem > 1e-4 do continue // ainda no meio do traço/vão
            // fronteira do padrão: fecha a peça acesa ou abre a próxima.
            // O laço interno cobre entradas de comprimento ZERO, que alternam
            // sem consumir caminho (`0 8` = ponto, `4 0 4 2` = traço emendado).
            for z := 0; ; z += 1 {
                if on {
                    if len(cur) > 0 do append(&out, slice.clone(cur[:], context.temp_allocator))
                    clear(&cur)
                } else {
                    clear(&cur)
                    append(&cur, p)
                }
                on = !on
                idx = (idx + 1) % len(pat)
                rem = pat[idx]
                if rem > 0 || z >= len(pat) do break
            }
        }
    }
    // ⚠️ Aqui exige-se 2 pontos, e não 1 como dentro do laço. Quando o caminho
    // ACABA logo depois de um vão fechar, `cur` fica com o ponto de abertura de
    // um traço que nunca teve comprimento — emiti-lo pintaria um PONTO extra na
    // ponta da linha (com linecap round), que o Chrome não desenha. O ponto
    // legítimo de `dasharray:0 8` não passa por aqui: ele é fechado na fronteira
    // do padrão, dentro do laço.
    if on && len(cur) >= 2 do append(&out, slice.clone(cur[:], context.temp_allocator))
    return out[:], true
}

// Emite o TRAÇO de uma polilinha de tela: sólido, ou fatiado por dasharray.
// Extraído porque svg_emit e svg_emit_multi são os DOIS sítios de traço do
// painter — pendurar o dash num só deixaria metade das formas sem tracejado
// (o <path>, justamente o que os ícones usam, mora no segundo).
@(private="file")
svg_stroke_polyline :: proc(pt: ^Painter, scr: []im.Vec2, closed: bool, ctx: SvgCtx, col: u32, th, savg: f32) {
    if ctx.dash_n >= 2 {
        pat := make([]f32, ctx.dash_n, context.temp_allocator)
        period: f32 = 0
        for i in 0 ..< ctx.dash_n {
            pat[i] = ctx.dash[i] * savg
            period += pat[i]
        }
        // período sub-pixel: o tracejado não aparece e custaria milhares de
        // peças (mesmo espírito do `th < 1.2` em svg_caps_joins)
        if period >= 1.0 {
            if pieces, ok := svg_dash_pieces(scr, closed, pat, ctx.dash_off * savg); ok {
                for piece in pieces {
                    if len(piece) >= 2 {
                        // cada traço tem PONTAS próprias (o linecap vale por
                        // traço, não só nas extremidades do caminho)
                        svg_stroke_run(pt, piece, false, ctx, col, th)
                    } else if len(piece) == 1 && ctx.cap == .Round {
                        // traço de comprimento ZERO: per-spec só aparece com
                        // linecap round/square. ⚠️ só o round é desenhado — o
                        // square precisaria da direção do caminho, que a peça
                        // de 1 ponto já perdeu.
                        svg_disc(pt, piece[0], th * 0.5, col, ctx.no_aa)
                    }
                }
                return
            }
        }
    }
    svg_stroke_run(pt, scr, closed, ctx, col, th)
}

// Emite a polilinha honrando a JUNTA: quebra nos vértices onde o miter
// ilimitado do ImGui estaria errado (ver o bloco de junta abaixo) e desenha ali
// a geometria própria. Sem quebra nenhuma, é exatamente o emit de antes.
@(private="file")
svg_stroke_run :: proc(pt: ^Painter, scr: []im.Vec2, closed: bool, ctx: SvgCtx, col: u32, th: f32) {
    line :: proc(pt: ^Painter, p: []im.Vec2, closed: bool, col: u32, th: f32, no_aa: bool) {
        emit(pt, PC_Polyline{ pts = p, col = col, thickness = th, closed = closed, no_aa = no_aa })
    }
    // Traço fino: a junta não aparece e o custo de quebrar não se paga (mesmo
    // limiar dos caps).
    if th < 1.2 || len(scr) < 3 {
        line(pt, scr, closed, col, th, ctx.no_aa)
        svg_caps(pt, scr, ctx, col, th)
        return
    }
    limit := svg_miterlimit(ctx)
    brk :: proc(scr: []im.Vec2, i: int, closed: bool, ctx: SvgCtx, limit: f32) -> bool {
        n := len(scr)
        p0 := scr[(i - 1 + n) % n]
        p2 := scr[(i + 1) % n]
        return svg_join_breaks(ctx.join, svg_miter_ratio(p0, scr[i], p2), limit)
    }

    pts := scr
    if closed {
        // Numa forma FECHADA a junta do fecho também conta. Se alguma junta
        // precisa quebrar, giro a lista para começar NELA — assim o fecho vira
        // uma ponta comum, com geometria própria, e o resto segue o caminho de
        // caminho aberto. Sem nenhuma quebra, sai pelo atalho fechado de sempre.
        k := -1
        for i in 0 ..< len(scr) do if brk(scr, i, true, ctx, limit) { k = i; break }
        if k < 0 {
            line(pt, scr, true, col, th, ctx.no_aa)
            return
        }
        rot := make([]im.Vec2, len(scr) + 1, context.temp_allocator)
        for i in 0 ..< len(scr) do rot[i] = scr[(k + i) % len(scr)]
        rot[len(scr)] = scr[k]
        pts = rot
        // a junta do próprio vértice k (agora ponta dos dois lados)
        svg_emit_join(pt, pts[len(pts) - 2], pts[0], pts[1], ctx, col, th)
    }

    start := 0
    for i in 1 ..< len(pts) - 1 {
        if !brk(pts, i, false, ctx, limit) do continue
        line(pt, pts[start : i + 1], false, col, th, ctx.no_aa)
        svg_emit_join(pt, pts[i - 1], pts[i], pts[i + 1], ctx, col, th)
        start = i
    }
    line(pt, pts[start:], false, col, th, ctx.no_aa)
    // O linecap vale só nas DUAS pontas REAIS do caminho — as pontas internas
    // criadas pela quebra são JUNTAS, e capeá-las poria um disco de `cap:round`
    // em cima de um bico de `join:miter`.
    if !closed {
        svg_cap_at(pt, pts[0], pts[1], ctx, col, th)
        svg_cap_at(pt, pts[len(pts) - 1], pts[len(pts) - 2], ctx, col, th)
    }
}

// stroke-linecap: o AddPolyline do ImGui só faz ponta reta (butt). Aproximamos
// emitindo geometria EXTRA na ponta:
//   round  → um disco de raio th/2
//   square → estende a ponta por th/2 na direção do próprio segmento
// É o que dá o visual de ícone com traço arredondado (lucide/feather usam
// stroke-linecap:round em TODO ícone).
// Uma PONTA só: `end` é o extremo, `prev` o vizinho que dá a direção de saída.
@(private="file")
svg_cap_at :: proc(pt: ^Painter, end, prev: im.Vec2, ctx: SvgCtx, col: u32, th: f32) {
    if th < 1.2 do return // sub-pixel: não aparece e não compensa
    switch ctx.cap {
    case .Round:  svg_half_disc(pt, end, prev, th * 0.5, col, ctx.no_aa)
    case .Square: svg_square_cap(pt, end, prev, th * 0.5, col, ctx.no_aa)
    case .Butt:   // padrão do ImGui, nada a fazer
    }
}

// ⚠️⚠️ MEIO disco, não disco inteiro — e a razão só aparece com traço
// TRANSLÚCIDO. Um disco centrado na ponta cobre METADE do retângulo do próprio
// traço, e com `stroke-opacity < 1` esse trecho é composto DUAS vezes: sai uma
// mancha escura na ponta (medido contra o Chrome: 108 onde ele dá 166, uniforme).
// A metade que fica ALÉM da ponta é a única que a spec pede. Mesma razão pela
// qual a junta redonda virou CUNHA e não disco.
// Os pontos do semicírculo ALÉM da ponta. Puro: é o que permite afirmar que
// nenhum ponto cai para DENTRO do traço (que é a razão de existir).
svg_half_disc_pts :: proc(end, prev: im.Vec2, r: f32) -> ([]im.Vec2, bool) {
    dx, dy := end.x - prev.x, end.y - prev.y
    l := math.sqrt(dx * dx + dy * dy)
    if l <= 0.001 do return nil, false // sem direção: quem chama cai no disco
    base := math.atan2(dy / l, dx / l) // semicírculo de -90° a +90° em torno da saída
    N :: 8
    arc := make([]im.Vec2, N + 1, context.temp_allocator)
    for i in 0 ..= N {
        a := base - math.PI * 0.5 + math.PI * f32(i) / f32(N)
        arc[i] = {end.x + r * math.cos(a), end.y + r * math.sin(a)}
    }
    return arc, true
}

@(private="file")
svg_half_disc :: proc(pt: ^Painter, end, prev: im.Vec2, r: f32, col: u32, no_aa: bool) {
    arc, ok := svg_half_disc_pts(end, prev, r)
    if !ok { svg_disc(pt, end, r, col, no_aa); return }
    emit(pt, PC_Polyline{ pts = arc, col = col, fill = true, no_aa = no_aa })
}

@(private="file")
svg_caps :: proc(pt: ^Painter, scr: []im.Vec2, ctx: SvgCtx, col: u32, th: f32) {
    if len(scr) < 2 do return
    svg_cap_at(pt, scr[0], scr[1], ctx, col, th)
    svg_cap_at(pt, scr[len(scr) - 1], scr[len(scr) - 2], ctx, col, th)
}

// ── junta de traço (stroke-linejoin + stroke-miterlimit) ────────────────────
// ⚠️⚠️ O comentário que ficou aqui desde o lote 27 dizia que o `AddPolyline` do
// ImGui "junta em bisel". O PIXEL provou o contrário: ele faz **miter ILIMITADO**
// e não sabe cortar. Era por isso que `linejoin:bevel`, `linejoin:round` e o
// `stroke-miterlimit` não mudavam NADA no ápice — o disco do round era desenhado
// por cima de um espinho que continuava lá. O Chrome corta; nós cuspíamos bico.
//
// Como não há controle POR JUNTA no ImGui, a saída é QUEBRAR a polilinha no
// vértice que precisa de outra junta e desenhá-la nós mesmos. Ângulo raso
// (curva achatada, que é a esmagadora maioria dos vértices de um ícone) não
// quebra nada: segue num AddPolyline só, sem custo e sem costura.

MITERLIMIT_DEFAULT :: f32(4)

// Razão comprimentoDoBico/espessura no vértice p1 = 1/cos(α/2), com α = ângulo
// de VIRADA entre os segmentos (0 = reto → 1; 180° = dobra → infinito).
svg_miter_ratio :: proc(p0, p1, p2: im.Vec2) -> f32 {
    u1x, u1y := p1.x - p0.x, p1.y - p0.y
    u2x, u2y := p2.x - p1.x, p2.y - p1.y
    l1 := math.sqrt(u1x * u1x + u1y * u1y)
    l2 := math.sqrt(u2x * u2x + u2y * u2y)
    if l1 <= 0.0001 || l2 <= 0.0001 do return 1
    d := clamp((u1x * u2x + u1y * u2y) / (l1 * l2), -1, 1) // cos α
    c := math.sqrt((1 + d) * 0.5)                          // cos(α/2)
    if c <= 0.0001 do return max(f32)
    return 1 / c
}

// A junta em p1 precisa de geometria PRÓPRIA (⇒ quebrar a polilinha)? Só quando
// o que o ImGui faria (bico sem limite) está errado.
svg_join_breaks :: proc(kind: Svg_Join, ratio, limit: f32) -> bool {
    switch kind {
    case .Miter: return ratio > limit
    // Ângulo raso: o bico do ImGui é indistinguível do bisel e cabe dentro do
    // disco do round — não vale quebrar (é o caso de todo vértice de curva).
    case .Bevel, .Round: return ratio > 1.02
    }
    return false
}

// As duas normais EXTERNAS da virada em p1 (o lado onde fica o vão). Extraído
// porque o bisel/bico e a junta REDONDA partem exatamente da mesma base.
@(private="file")
svg_join_normals :: proc(p0, p1, p2: im.Vec2) -> (n1, n2: im.Vec2, ok: bool) {
    u1x, u1y := p1.x - p0.x, p1.y - p0.y
    u2x, u2y := p2.x - p1.x, p2.y - p1.y
    l1 := math.sqrt(u1x * u1x + u1y * u1y)
    l2 := math.sqrt(u2x * u2x + u2y * u2y)
    if l1 <= 0.0001 || l2 <= 0.0001 do return {}, {}, false
    u1x /= l1; u1y /= l1; u2x /= l2; u2y /= l2
    cross := u1x * u2y - u1y * u2x
    if abs(cross) < 1e-6 do return {}, {}, false // colineares: não há vão
    s: f32 = cross > 0 ? -1 : 1 // lado EXTERNO = o oposto ao sentido do giro
    return {-u1y * s, u1x * s}, {-u2y * s, u2x * s}, true
}

// ⚠️⚠️ CUNHA com arco, não disco. O disco centrado no vértice cobre metade dos
// DOIS segmentos, e com traço translúcido aquele trecho é composto TRÊS vezes —
// medido: 70 onde o Chrome dá 166 uniforme. A cunha preenche só o VÃO externo,
// que é a única parte que a junta precisa desenhar (mesma razão do meio-disco
// no cap). Com traço opaco os dois resultados são idênticos, e é por isso que o
// defeito ficou invisível até `stroke-opacity` entrar em cena.
svg_round_join_pts :: proc(p0, p1, p2: im.Vec2, r: f32) -> ([]im.Vec2, bool) {
    n1, n2, ok := svg_join_normals(p0, p1, p2)
    if !ok do return nil, false
    a1 := math.atan2(n1.y, n1.x)
    a2 := math.atan2(n2.y, n2.x)
    d  := a2 - a1 // percorre o MENOR arco: é o vão, não a volta inteira
    for d >  math.PI do d -= 2 * math.PI
    for d < -math.PI do d += 2 * math.PI
    N :: 8
    poly := make([]im.Vec2, N + 2, context.temp_allocator)
    poly[0] = p1
    for i in 0 ..= N {
        a := a1 + d * f32(i) / f32(N)
        poly[i + 1] = {p1.x + r * math.cos(a), p1.y + r * math.sin(a)}
    }
    return poly, true
}

@(private="file")
svg_round_join :: proc(pt: ^Painter, p0, p1, p2: im.Vec2, r: f32, col: u32, no_aa: bool) {
    poly, ok := svg_round_join_pts(p0, p1, p2, r)
    if !ok do return
    emit(pt, PC_Polyline{ pts = poly, col = col, fill = true, no_aa = no_aa })
}

// Polígono que PREENCHE o vão externo da junta em p1.
//   n=3 → bisel [vértice, ponta que chega, ponta que sai]
//   n=4 → bico  [vértice, ponta que chega, PONTA DO BICO, ponta que sai]
// Função pura de propósito: é o que permite afirmar o corte do miterlimit por
// unidade, sem janela.
svg_join_pts :: proc(p0, p1, p2: im.Vec2, r, limit: f32, kind: Svg_Join) -> (out: [4]im.Vec2, n: int) {
    n1, n2, ok := svg_join_normals(p0, p1, p2)
    if !ok do return out, 0
    out[0] = p1
    out[1] = {p1.x + n1.x * r, p1.y + n1.y * r}
    if kind == .Miter {
        ratio := svg_miter_ratio(p0, p1, p2)
        if ratio <= limit {
            mx, my := n1.x + n2.x, n1.y + n2.y
            ml := math.sqrt(mx * mx + my * my)
            if ml > 0.0001 {
                out[2] = {p1.x + mx / ml * r * ratio, p1.y + my / ml * r * ratio}
                out[3] = {p1.x + n2.x * r, p1.y + n2.y * r}
                return out, 4
            }
        }
    }
    out[2] = {p1.x + n2.x * r, p1.y + n2.y * r} // bisel
    return out, 3
}

@(private="file")
svg_emit_join :: proc(pt: ^Painter, p0, p1, p2: im.Vec2, ctx: SvgCtx, col: u32, th: f32) {
    r := th * 0.5
    if ctx.join == .Round { svg_round_join(pt, p0, p1, p2, r, col, ctx.no_aa); return }
    pts, n := svg_join_pts(p0, p1, p2, r, svg_miterlimit(ctx), ctx.join)
    if n < 3 do return
    poly := make([]im.Vec2, n, context.temp_allocator)
    copy(poly, pts[:n])
    emit(pt, PC_Polyline{ pts = poly, col = col, fill = true, no_aa = ctx.no_aa })
}

// Zero-value = "não declarado" nos dois casos, então o default mora aqui e não
// no reset do contexto (a lição do campo de LIMITE cujo zero tinha de significar
// "sem limite", do M222 — aqui é o inverso: zero significa "o default da spec").
svg_miterlimit :: proc(ctx: SvgCtx) -> f32 {
    return ctx.miterlimit > 0 ? ctx.miterlimit : MITERLIMIT_DEFAULT
}

svg_seg_mul :: proc(ctx: SvgCtx) -> int {
    return ctx.seg_mul > 0 ? ctx.seg_mul : 1
}

@(private="file")
svg_disc :: proc(pt: ^Painter, c: im.Vec2, r: f32, col: u32, no_aa: bool) {
    N :: 10
    ring := make([]im.Vec2, N, context.temp_allocator)
    for i in 0 ..< N {
        a := f32(i) * (2 * math.PI / N)
        ring[i] = {c.x + r * math.cos(a), c.y + r * math.sin(a)}
    }
    emit(pt, PC_Polyline{ pts = ring, col = col, fill = true, no_aa = no_aa })
}

// Ponta quadrada: um quadrado de lado th centrado meio-passo ALÉM da ponta `end`,
// na direção oposta a `prev`.
@(private="file")
svg_square_cap :: proc(pt: ^Painter, end, prev: im.Vec2, r: f32, col: u32, no_aa: bool) {
    dx, dy := end.x - prev.x, end.y - prev.y
    l := math.sqrt(dx * dx + dy * dy)
    if l <= 0.001 do return
    ux, uy := dx / l, dy / l          // direção de saída
    px, py := -uy, ux                 // normal
    q := make([]im.Vec2, 4, context.temp_allocator)
    q[0] = {end.x + px * r, end.y + py * r}
    q[1] = {end.x - px * r, end.y - py * r}
    q[2] = {end.x - px * r + ux * r, end.y - py * r + uy * r}
    q[3] = {end.x + px * r + ux * r, end.y + py * r + uy * r}
    emit(pt, PC_Polyline{ pts = q, col = col, fill = true, no_aa = no_aa })
}

// Emite um <path> com N subcaminhos: FILL combinado com regra even-odd (buracos
// de letras/ícones ficam vazados — AddConcavePolyFilled por subcaminho preenchia
// os furos) + STROKE por subcaminho.
@(private="file")
svg_emit_multi :: proc(pt: ^Painter, subs: [][][2]f32, closed: []bool, ctx: SvgCtx, t: Svg_Xform, savg: f32) {
    if ctx.has_fill do svg_fill_scanline(pt, subs, mul_alpha(ctx.fill, ctx.fill_op), t, ctx.evenodd, ctx)
    if ctx.has_stroke {
        th := max(ctx.sw * savg, 0.6)
        col := mul_alpha(ctx.stroke, ctx.stroke_op)
        for sub, si in subs {
            if len(sub) < 2 do continue
            scr := make([]im.Vec2, len(sub), context.temp_allocator)
            for p, i in sub do scr[i] = svg_pt(t, p[0], p[1])
            svg_stroke_polyline(pt, scr, closed[si], ctx, col, th, savg)
        }
    }
}

// Preenche o conjunto de subcaminhos pela regra EVEN-ODD via rasterização por
// scanline: p/ cada linha y, acha as interseções com todas as arestas (cada
// subcaminho é fechado implicitamente p/ fill), ordena, e preenche os intervalos
// ímpares (0-1, 2-3, …). Emite 1 retângulo de 1px por span. Correto p/ formas com
// furos (letras "e/a/o/d/p", ícones) — o que os navegadores fazem.
// Inverso de uma afim (tela→usuário). O gradiente é definido em coords de
// USUÁRIO, mas a rasterização por scanline trabalha em coords de TELA.
@(private="file")
svg_inv :: proc(t: Svg_Xform) -> (Svg_Xform, bool) {
    det := t.a * t.d - t.b * t.c
    if abs(det) < 1e-12 do return {}, false
    id := 1 / det
    inv := Svg_Xform{
        a =  t.d * id, b = -t.b * id,
        c = -t.c * id, d =  t.a * id,
        e = (t.c * t.f - t.d * t.e) * id,
        f = (t.b * t.e - t.a * t.f) * id,
    }
    return inv, true
}

@(private="file")
svg_fill_scanline :: proc(pt: ^Painter, subs: [][][2]f32, col: u32, t: Svg_Xform, evenodd: bool, ctx := SvgCtx{}) {
    ymin, ymax: f32 = 1e30, -1e30
    screen := make([][]im.Vec2, len(subs), context.temp_allocator)
    for sub, si in subs {
        s := make([]im.Vec2, len(sub), context.temp_allocator)
        for p, i in sub {
            v := svg_pt(t, p[0], p[1]); s[i] = v
            if v.y < ymin do ymin = v.y
            if v.y > ymax do ymax = v.y
        }
        screen[si] = s
    }
    if ymax <= ymin do return
    y0 := int(math.floor(ymin)); y1 := int(math.ceil(ymax))

    // ── gradiente (M225) ────────────────────────────────────────────────────
    // Resolvido AQUI porque é aqui que a bounding box da forma existe: o default
    // `objectBoundingBox` do SVG é relativo a ela. Sem gradiente utilizável,
    // `use_grad` fica false e tudo segue no caminho de cor sólida de sempre.
    grad: Svg_Grad
    use_grad := false
    inv: Svg_Xform
    bbx, bby, bbw, bbh: f32
    if ctx.fill_grad != "" {
        if g, ok := g_svg_grads[ctx.fill_grad]; ok && g.ok && len(g.stops) > 0 {
            if iv, k := svg_inv(t); k {
                grad = g; inv = iv; use_grad = true
                x0f, y0f, x1f, y1f: f32 = 1e30, 1e30, -1e30, -1e30
                for sub in subs do for p in sub {
                    x0f = min(x0f, p[0]); y0f = min(y0f, p[1])
                    x1f = max(x1f, p[0]); y1f = max(y1f, p[1])
                }
                bbx = x0f; bby = y0f; bbw = x1f - x0f; bbh = y1f - y0f
                when #config(SVGPROBE, false) {
                    @(static) n := 0
                    n += 1
                    if n <= 8 do fmt.eprintfln("[SVG] fill grad=%q radial=%v bbox=(%v,%v %vx%v) subs=%d",
                        ctx.fill_grad, g.radial, bbx, bby, bbw, bbh, len(subs))
                }
            }
        }
    }
    // Cor do gradiente num ponto de TELA (volta p/ usuário, projeta no eixo).
    grad_col :: proc(g: Svg_Grad, inv: Svg_Xform, sx, sy, bbx, bby, bbw, bbh, op, eff: f32) -> u32 {
        ux := inv.a * sx + inv.c * sy + inv.e
        uy := inv.b * sx + inv.d * sy + inv.f
        rgb, sop := svg_grad_at(g, svg_grad_frac(g, ux, uy, bbx, bby, bbw, bbh))
        return mul_alpha(col_o(rgb, eff), sop * op)
    }
    span :: proc(pt: ^Painter, xa, xb, y: f32, col: u32, use_grad: bool, g: Svg_Grad,
                 inv: Svg_Xform, bbx, bby, bbw, bbh, op, eff: f32) {
        if !use_grad {
            emit(pt, PC_RectFilled{{xa, y}, {xb, y + 1}, col, 0, {}})
            return
        }
        // ⚠️ SUBDIVIDIR é obrigatório: o AddRectFilledMultiColor interpola LINEAR
        // entre as pontas do retângulo. Num gradiente RADIAL a linha do meio tem
        // AZUL nas duas pontas e BRANCO no centro — amostrar só as pontas apaga o
        // centro e o círculo sai chapado (foi exatamente o que aconteceu). Vale
        // igual p/ linear diagonal. É a mesma lição dos painters de gradiente CSS.
        yc := y + 0.5
        STEP :: f32(8)     // px por pedaço: o suficiente p/ o olho não ver degrau
        MAXP :: 64         // teto de pedaços por span (custo)
        w := xb - xa
        np := 1
        if w > STEP do np = min(int(w / STEP) + 1, MAXP)
        dx := w / f32(np)
        cprev := grad_col(g, inv, xa, yc, bbx, bby, bbw, bbh, op, eff)
        for i in 0 ..< np {
            x0 := xa + dx * f32(i)
            x1 := i == np - 1 ? xb : x0 + dx
            cnext := grad_col(g, inv, x1, yc, bbx, bby, bbw, bbh, op, eff)
            emit(pt, PC_RectMulti{{x0, y}, {x1, y + 1}, cprev, cnext, cnext, cprev})
            cprev = cnext
        }
    }
    Cross :: struct { x: f32, dir: int } // dir = sentido do cruzamento (p/ nonzero)
    xs := make([dynamic]Cross, context.temp_allocator)
    for y := y0; y < y1; y += 1 {
        yc := f32(y) + 0.5
        clear(&xs)
        for s in screen {
            n := len(s)
            if n < 2 do continue
            for i in 0 ..< n {
                a := s[i]; b := s[(i + 1) % n] // aresta de fechamento incluída
                if (a.y <= yc && b.y > yc) || (b.y <= yc && a.y > yc) {
                    x := a.x + (yc - a.y) / (b.y - a.y) * (b.x - a.x)
                    append(&xs, Cross{x, b.y > a.y ? 1 : -1})
                }
            }
        }
        if len(xs) < 2 do continue
        slice.sort_by(xs[:], proc(a, b: Cross) -> bool { return a.x < b.x })
        if evenodd {
            // paridade: preenche os intervalos ímpares (0-1, 2-3, …)
            for k := 0; k + 1 < len(xs); k += 2 {
                if xs[k + 1].x > xs[k].x {
                    span(pt, xs[k].x, xs[k + 1].x, f32(y), col, use_grad, grad, inv, bbx, bby, bbw, bbh, ctx.fill_op, ctx.eff)
                }
            }
        } else {
            // NONZERO (default da SPEC): soma o SENTIDO dos cruzamentos e preenche
            // onde o contador != 0. Furo desenhado no sentido OPOSTO continua
            // vazando; dois subcaminhos no MESMO sentido se FUNDEM — com even-odd
            // o segundo abriria um buraco errado.
            w := 0
            for k := 0; k + 1 < len(xs); k += 1 {
                w += xs[k].dir
                if w != 0 && xs[k + 1].x > xs[k].x {
                    span(pt, xs[k].x, xs[k + 1].x, f32(y), col, use_grad, grad, inv, bbx, bby, bbw, bbh, ctx.fill_op, ctx.eff)
                }
            }
        }
    }
}

// pontos de um <polyline>/<polygon> ("x,y x,y" ou "x y x y")
@(private="file")
svg_points :: proc(s: string) -> [dynamic][2]f32 {
    out := make([dynamic][2]f32, context.temp_allocator)
    i := 0
    for {
        x, kx := svg_num(s, &i); y, ky := svg_num(s, &i)
        if !(kx && ky) do break
        append(&out, [2]f32{x, y})
    }
    return out
}

// polígono aproximando uma elipse (32 lados).
svg_ellipse_pts :: proc(cx, cy, rx, ry: f32, seg_mul := 1) -> [dynamic][2]f32 {
    N := 32 * max(seg_mul, 1) // shape-rendering:geometricPrecision refina o polígono
    out := make([dynamic][2]f32, 0, N, context.temp_allocator)
    for k in 0 ..< N {
        a := f32(k) / f32(N) * 2 * math.PI
        append(&out, [2]f32{ cx + rx * f32(math.cos(a)), cy + ry * f32(math.sin(a)) })
    }
    return out
}

// ── parser do atributo `d` ──────────────────────────────────────────────────
// Achata em subcaminhos (polilinhas). Cada subcaminho vira 1 svg_emit.
@(private="file")
svg_path :: proc(pt: ^Painter, d: string, ctx: SvgCtx, t: Svg_Xform, savg: f32) {
    seg := SEG * svg_seg_mul(ctx) // shape-rendering:geometricPrecision achata mais fino
    sub := make([dynamic][2]f32, context.temp_allocator) // subcaminho atual
    subs := make([dynamic][][2]f32, context.temp_allocator) // todos (p/ fill even-odd combinado)
    closed := make([dynamic]bool, context.temp_allocator)
    cx, cy: f32 // ponto atual
    sxp, syp: f32 // início do subcaminho (p/ Z)
    pcx, pcy: f32 // último ponto de controle (p/ S/T)
    prev_cmd: u8 = 0
    i := 0
    // fecha o subcaminho atual: guarda uma CÓPIA em `subs` (o fill/stroke combinado
    // roda ao final, com todos os subcaminhos juntos p/ a regra even-odd).
    flush :: proc(subs: ^[dynamic][][2]f32, cl: ^[dynamic]bool, sub: ^[dynamic][2]f32, is_closed: bool) {
        if len(sub) >= 2 {
            cp := make([][2]f32, len(sub), context.temp_allocator)
            copy(cp, sub[:])
            append(subs, cp); append(cl, is_closed)
        }
        clear(sub)
    }
    for i < len(d) {
        svg_skip_sep(d, &i)
        if i >= len(d) do break
        cmd := d[i]
        is_cmd := (cmd >= 'A' && cmd <= 'Z') || (cmd >= 'a' && cmd <= 'z')
        if is_cmd {
            i += 1
        } else {
            // sem letra: repete o comando anterior (M→L, m→l)
            cmd = prev_cmd
            if cmd == 'M' do cmd = 'L'
            else if cmd == 'm' do cmd = 'l'
        }
        rel := cmd >= 'a' && cmd <= 'z'
        switch cmd {
        case 'M', 'm':
            flush(&subs, &closed, &sub, false)
            x, kx := svg_num(d, &i); y, ky := svg_num(d, &i)
            if !(kx && ky) do break
            if rel { cx += x; cy += y } else { cx = x; cy = y }
            sxp = cx; syp = cy
            append(&sub, [2]f32{cx, cy})
        case 'L', 'l':
            x, kx := svg_num(d, &i); y, ky := svg_num(d, &i)
            if !(kx && ky) do break
            if rel { cx += x; cy += y } else { cx = x; cy = y }
            append(&sub, [2]f32{cx, cy})
        case 'H', 'h':
            x, kx := svg_num(d, &i); if !kx do break
            cx = rel ? cx + x : x
            append(&sub, [2]f32{cx, cy})
        case 'V', 'v':
            y, ky := svg_num(d, &i); if !ky do break
            cy = rel ? cy + y : y
            append(&sub, [2]f32{cx, cy})
        case 'C', 'c':
            x1, k1 := svg_num(d, &i); y1, k2 := svg_num(d, &i)
            x2, k3 := svg_num(d, &i); y2, k4 := svg_num(d, &i)
            x, k5 := svg_num(d, &i);  y, k6 := svg_num(d, &i)
            if !(k1 && k2 && k3 && k4 && k5 && k6) do break
            if rel { x1 += cx; y1 += cy; x2 += cx; y2 += cy; x += cx; y += cy }
            svg_cubic(&sub, cx, cy, x1, y1, x2, y2, x, y, seg)
            pcx = x2; pcy = y2; cx = x; cy = y
        case 'S', 's':
            x2, k3 := svg_num(d, &i); y2, k4 := svg_num(d, &i)
            x, k5 := svg_num(d, &i);  y, k6 := svg_num(d, &i)
            if !(k3 && k4 && k5 && k6) do break
            if rel { x2 += cx; y2 += cy; x += cx; y += cy }
            // 1º controle = reflexão do anterior se o cmd anterior foi C/S
            x1, y1 := cx, cy
            if prev_cmd == 'C' || prev_cmd == 'c' || prev_cmd == 'S' || prev_cmd == 's' {
                x1 = 2 * cx - pcx; y1 = 2 * cy - pcy
            }
            svg_cubic(&sub, cx, cy, x1, y1, x2, y2, x, y, seg)
            pcx = x2; pcy = y2; cx = x; cy = y
        case 'Q', 'q':
            x1, k1 := svg_num(d, &i); y1, k2 := svg_num(d, &i)
            x, k5 := svg_num(d, &i);  y, k6 := svg_num(d, &i)
            if !(k1 && k2 && k5 && k6) do break
            if rel { x1 += cx; y1 += cy; x += cx; y += cy }
            svg_quad(&sub, cx, cy, x1, y1, x, y, seg)
            pcx = x1; pcy = y1; cx = x; cy = y
        case 'T', 't':
            x, k5 := svg_num(d, &i); y, k6 := svg_num(d, &i)
            if !(k5 && k6) do break
            if rel { x += cx; y += cy }
            x1, y1 := cx, cy
            if prev_cmd == 'Q' || prev_cmd == 'q' || prev_cmd == 'T' || prev_cmd == 't' {
                x1 = 2 * cx - pcx; y1 = 2 * cy - pcy
            }
            svg_quad(&sub, cx, cy, x1, y1, x, y, seg)
            pcx = x1; pcy = y1; cx = x; cy = y
        case 'A', 'a':
            rx, k1 := svg_num(d, &i); ry, k2 := svg_num(d, &i)
            rot, k3 := svg_num(d, &i)
            large, k4 := svg_flag(d, &i); sweep, k5 := svg_flag(d, &i)
            x, k6 := svg_num(d, &i); y, k7 := svg_num(d, &i)
            if !(k1 && k2 && k3 && k4 && k5 && k6 && k7) do break
            if rel { x += cx; y += cy }
            svg_arc(&sub, cx, cy, rx, ry, rot, large, sweep, x, y, seg)
            cx = x; cy = y
        case 'Z', 'z':
            flush(&subs, &closed, &sub, true)
            cx = sxp; cy = syp
        case:
            // comando desconhecido: aborta (evita loop infinito)
            i = len(d)
        }
        prev_cmd = cmd
    }
    flush(&subs, &closed, &sub, false)
    if len(subs) > 0 do svg_emit_multi(pt, subs[:], closed[:], ctx, t, savg)
}

@(private="file")
svg_cubic :: proc(out: ^[dynamic][2]f32, x0, y0, x1, y1, x2, y2, x3, y3: f32, seg: int) {
    for k in 1 ..= seg {
        u := f32(k) / f32(seg); v := 1 - u
        a := v*v*v; b := 3*v*v*u; c := 3*v*u*u; e := u*u*u
        append(out, [2]f32{ a*x0 + b*x1 + c*x2 + e*x3, a*y0 + b*y1 + c*y2 + e*y3 })
    }
}

@(private="file")
svg_quad :: proc(out: ^[dynamic][2]f32, x0, y0, x1, y1, x2, y2: f32, seg: int) {
    for k in 1 ..= seg {
        u := f32(k) / f32(seg); v := 1 - u
        a := v*v; b := 2*v*u; c := u*u
        append(out, [2]f32{ a*x0 + b*x1 + c*x2, a*y0 + b*y1 + c*y2 })
    }
}

// Arco elíptico (SVG impl notes F.6): endpoint → centro, depois amostra.
@(private="file")
svg_arc :: proc(out: ^[dynamic][2]f32, x0, y0, rx_in, ry_in, phi_deg, large, sweep, x1, y1: f32, seg: int) {
    if rx_in == 0 || ry_in == 0 { append(out, [2]f32{x1, y1}); return }
    rx := abs(rx_in); ry := abs(ry_in)
    phi := phi_deg * math.PI / 180
    cosp := f32(math.cos(phi)); sinp := f32(math.sin(phi))
    // passo 1: (x0,y0) e (x1,y1) → sistema primo
    dx := (x0 - x1) / 2; dy := (y0 - y1) / 2
    x1p :=  cosp*dx + sinp*dy
    y1p := -sinp*dx + cosp*dy
    // corrige raios pequenos demais
    lam := x1p*x1p/(rx*rx) + y1p*y1p/(ry*ry)
    if lam > 1 { s := f32(math.sqrt(f64(lam))); rx *= s; ry *= s }
    // passo 2: centro no sistema primo
    num := rx*rx*ry*ry - rx*rx*y1p*y1p - ry*ry*x1p*x1p
    den := rx*rx*y1p*y1p + ry*ry*x1p*x1p
    co := f32(0)
    if den > 0 { co = f32(math.sqrt(f64(max(num, 0) / den))) }
    if (large != 0) == (sweep != 0) do co = -co
    cxp :=  co * rx * y1p / ry
    cyp := -co * ry * x1p / rx
    // passo 3: centro real
    cx := cosp*cxp - sinp*cyp + (x0 + x1) / 2
    cy := sinp*cxp + cosp*cyp + (y0 + y1) / 2
    // ângulos
    ang :: proc(ux, uy, vx, vy: f32) -> f32 {
        dot := ux*vx + uy*vy
        len := f32(math.sqrt(f64((ux*ux+uy*uy)*(vx*vx+vy*vy))))
        a := f32(math.acos(f64(clamp(len > 0 ? dot/len : 0, -1, 1))))
        if ux*vy - uy*vx < 0 do a = -a
        return a
    }
    theta0 := ang(1, 0, (x1p-cxp)/rx, (y1p-cyp)/ry)
    dtheta := ang((x1p-cxp)/rx, (y1p-cyp)/ry, (-x1p-cxp)/rx, (-y1p-cyp)/ry)
    if sweep == 0 && dtheta > 0 do dtheta -= 2*math.PI
    if sweep != 0 && dtheta < 0 do dtheta += 2*math.PI
    N := max(2, int(abs(dtheta) / (math.PI/8)) + 1)
    for k in 1 ..= N {
        th := theta0 + dtheta * f32(k) / f32(N)
        ex := rx * f32(math.cos(f64(th))); ey := ry * f32(math.sin(f64(th)))
        append(out, [2]f32{ cx + cosp*ex - sinp*ey, cy + sinp*ex + cosp*ey })
    }
}

// ── scanners de número ──────────────────────────────────────────────────────
@(private="file")
svg_skip_sep :: proc(s: string, i: ^int) {
    for i^ < len(s) {
        c := s[i^]
        if c == ' ' || c == ',' || c == '\t' || c == '\n' || c == '\r' { i^ += 1 } else { break }
    }
}

// lê um float a partir de i (com sinal/decimal/expoente). ok=false se não houver.
@(private="file")
svg_num :: proc(s: string, i: ^int) -> (f32, bool) {
    svg_skip_sep(s, i)
    start := i^
    if i^ < len(s) && (s[i^] == '+' || s[i^] == '-') do i^ += 1
    seen := false
    for i^ < len(s) && s[i^] >= '0' && s[i^] <= '9' { i^ += 1; seen = true }
    if i^ < len(s) && s[i^] == '.' {
        i^ += 1
        for i^ < len(s) && s[i^] >= '0' && s[i^] <= '9' { i^ += 1; seen = true }
    }
    if !seen { i^ = start; return 0, false }
    if i^ < len(s) && (s[i^] == 'e' || s[i^] == 'E') {
        j := i^ + 1
        if j < len(s) && (s[j] == '+' || s[j] == '-') do j += 1
        if j < len(s) && s[j] >= '0' && s[j] <= '9' {
            i^ = j + 1
            for i^ < len(s) && s[i^] >= '0' && s[i^] <= '9' do i^ += 1
        }
    }
    v, ok := strconv.parse_f64(s[start:i^])
    return f32(v), ok
}

// flag do arco: exatamente um char '0'/'1' (podem vir grudados: "0130").
@(private="file")
svg_flag :: proc(s: string, i: ^int) -> (f32, bool) {
    svg_skip_sep(s, i)
    if i^ < len(s) && (s[i^] == '0' || s[i^] == '1') {
        v: f32 = s[i^] == '1' ? 1 : 0
        i^ += 1
        return v, true
    }
    return 0, false
}

// ── helpers de teste (lógica pura, sem painter) ─────────────────────────────
// Lê o próximo número a partir de `start`; devolve (valor, novo_i, ok).
test_svg_num :: proc(s: string, start: int) -> (f32, int, bool) {
    i := start
    v, ok := svg_num(s, &i)
    return v, i, ok
}

// Nº de pontos parseados de uma lista "x,y x,y …".
test_svg_points_count :: proc(s: string) -> int {
    return len(svg_points(s))
}

test_svg_viewbox :: proc(node: ^dompkg.Node) -> (f32, f32, f32, f32, bool) {
    return svg_viewbox(node)
}
