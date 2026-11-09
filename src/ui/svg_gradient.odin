package ui

// M225 — `stop-color` / `stop-opacity`: gradientes de SVG.
//
// Antes, `fill="url(#grad)"` não casava nenhuma cor: o `svg_set_paint` tentava
// `parse_color("url(#grad)")`, falhava, e a forma ficava com o fill HERDADO (na
// prática o preto default do SVG) — um ícone/logo com gradiente saía chapado.
// `<linearGradient>` e `<radialGradient>` moram dentro de `<defs>`, que o
// `svg_walk` PULA de propósito (são definições, não desenho), então os `<stop>`
// nunca eram sequer lidos. Daí `stop-color`/`stop-opacity` aparecerem no
// gap-miner: as props existem no CSS de sites, e o motor não tinha onde usá-las.
//
// ── Recorte ─────────────────────────────────────────────────────────────────
// Cobre: `linearGradient` (x1/y1/x2/y2) e `radialGradient` (cx/cy/r),
// `gradientUnits` (objectBoundingBox default e userSpaceOnUse), `offset`,
// `stop-color`/`stop-opacity` (atributo, `style=` e REGRA CSS), e herança de
// stops por `href`/`xlink:href` (um nível — a forma que os exportadores usam).
// FORA: `gradientTransform`, `spreadMethod` (só `pad`), foco `fx/fy`, `pattern`,
// `mask`. Degradação: gradiente que não resolve → a forma cai na cor sólida
// herdada, que é exatamente o comportamento anterior a este marco.

import "core:strings"
import "core:fmt"
import "core:strconv"
import "core:math"
import csspkg "../css"
import dompkg "../dom"

Svg_Stop :: struct {
    off: f32, // 0..1
    col: u32, // 0xRRGGBB (convenção do motor: byte alto = opacidade, 0 = opaco)
    op:  f32, // stop-opacity 0..1
}

Svg_Grad :: struct {
    radial:     bool,
    user_space: bool, // gradientUnits="userSpaceOnUse" (default = objectBoundingBox)
    x1, y1, x2, y2: f32,
    cx, cy, r:  f32,
    stops:      []Svg_Stop,
    ok:         bool,
}

// Gradientes do <svg> em pintura, por `id`. Preenchido no início de
// `paint_svg_node` e válido só durante aquela pintura (usa temp_allocator).
g_svg_grads: map[string]Svg_Grad

// ── coleta ──────────────────────────────────────────────────────────────────

@(private = "file")
num_attr :: proc(n: ^dompkg.Node, name: string, def: f32) -> f32 {
    v, ok := n.attrs[name]
    if !ok do return def
    t := strings.trim_space(v)
    pct := strings.has_suffix(t, "%")
    if pct do t = t[:len(t) - 1]
    f, k := strconv.parse_f64(t)
    if !k do return def
    return pct ? f32(f) / 100 : f32(f)
}

// Lê um `<stop>`: `offset`, `stop-color`, `stop-opacity` — do ATRIBUTO, do
// `style=` e da REGRA CSS (Computed.svg_css / svg_css_get, o caminho pelo qual
// as duas props chegam quando o autor as declara numa folha de estilo).
@(private = "file")
read_stop :: proc(n: ^dompkg.Node, cur: u32) -> Svg_Stop {
    s := Svg_Stop{off = num_attr(n, "offset", 0), col = 0x000000, op = 1}
    set_one :: proc(s: ^Svg_Stop, prop, val: string, cur: u32) {
        switch prop {
        case "stop-color":
            t := strings.trim_space(val)
            if strings.equal_fold(t, "currentcolor") { s.col = cur; return }
            if c, ok := csspkg.parse_color(t); ok do s.col = c
        case "stop-opacity":
            if o, k := svg_opacity(val); k do s.op = o
        }
    }
    if v, ok := n.attrs["stop-color"];   ok do set_one(&s, "stop-color", v, cur)
    if v, ok := n.attrs["stop-opacity"]; ok do set_one(&s, "stop-opacity", v, cur)
    // regra CSS vence o atributo (que tem especificidade zero, per spec)
    if e, ok := svg_css_get(n); ok {
        if e.stop_col_set do s.col = e.stop_col
        if e.stop_op_set  do s.op  = e.stop_op
    }
    // `style=` vence tudo (já é a declaração do próprio elemento)
    if st, ok := n.attrs["style"]; ok {
        for decl in strings.split(st, ";", context.temp_allocator) {
            ci := strings.index_byte(decl, ':')
            if ci < 0 do continue
            set_one(&s, strings.trim_space(strings.to_lower(decl[:ci], context.temp_allocator)),
                    strings.trim_space(decl[ci + 1:]), cur)
        }
    }
    s.off = clamp(s.off, 0, 1)
    return s
}

// Varre a subárvore do <svg> colhendo TODA definição de gradiente (inclusive
// dentro de <defs>, que o painter pula). Chamado 1× por pintura.
svg_collect_gradients :: proc(root: ^dompkg.Node, cur: u32) {
    clear(&g_svg_grads)
    hrefs := make(map[string]string, 8, context.temp_allocator)
    walk(root, cur, &hrefs)

    // herança de stops por href/xlink:href (um nível: o exportador do Figma/
    // Illustrator gera `<linearGradient id=a>` com os stops e `<linearGradient
    // id=b xlink:href="#a" …>` só com a geometria).
    when #config(SVGPROBE, false) { for k, v in hrefs do fmt.eprintfln("[SVG] href %q -> %q", k, v) }
    for id, target in hrefs {
        g, has := &g_svg_grads[id]
        if !has || len(g.stops) > 0 do continue
        if src, ok := g_svg_grads[target]; ok && len(src.stops) > 0 {
            g.stops = src.stops
            g.ok = true
        }
    }

    walk :: proc(n: ^dompkg.Node, cur: u32, hrefs: ^map[string]string) {
        for ch in n.children {
            if ch.kind == .Element {
                lo := strings.to_lower(ch.tag, context.temp_allocator)
                if lo == "lineargradient" || lo == "radialgradient" {
                    if id, ok := ch.attrs["id"]; ok && id != "" {
                        g := Svg_Grad{radial = lo == "radialgradient"}
                        if u, k := ch.attrs["gradientUnits"]; k {
                            g.user_space = strings.equal_fold(strings.trim_space(u), "userSpaceOnUse")
                        } else if u2, k2 := ch.attrs["gradientunits"]; k2 {
                            g.user_space = strings.equal_fold(strings.trim_space(u2), "userSpaceOnUse")
                        }
                        // defaults da spec, em fração da bounding box
                        g.x1 = num_attr(ch, "x1", 0); g.y1 = num_attr(ch, "y1", 0)
                        g.x2 = num_attr(ch, "x2", 1); g.y2 = num_attr(ch, "y2", 0)
                        g.cx = num_attr(ch, "cx", 0.5); g.cy = num_attr(ch, "cy", 0.5)
                        g.r  = num_attr(ch, "r", 0.5)

                        st := make([dynamic]Svg_Stop, context.temp_allocator)
                        for sc in ch.children {
                            if sc.kind != .Element do continue
                            if !strings.equal_fold(sc.tag, "stop") do continue
                            append(&st, read_stop(sc, cur))
                        }
                        if len(st) > 0 {
                            g.stops = st[:]
                            g.ok = true
                        }
                        // ⚠️ o parser de HTML serializa atributo com namespace
                        // trocando ':' por ESPAÇO (treebuild.odin): `xlink:href`
                        // chega como `"xlink href"`. Sem esta grafia, todo SVG de
                        // exportador (Figma/Illustrator) perdia a herança de stops.
                        for k in ([]string{"href", "xlink:href", "xlink href"}) {
                            if h, hk := ch.attrs[k]; hk && strings.has_prefix(h, "#") {
                                hrefs[id] = h[1:]
                            }
                        }
                        when #config(SVGPROBE, false) {
                            fmt.eprintfln("[SVG] grad id=%q radial=%v user=%v x=(%v,%v)-(%v,%v) c=(%v,%v) r=%v stops=%d ok=%v",
                                id, g.radial, g.user_space, g.x1, g.y1, g.x2, g.y2, g.cx, g.cy, g.r, len(g.stops), g.ok)
                            for st in g.stops do fmt.eprintfln("[SVG]    stop off=%v col=%06x op=%v", st.off, st.col, st.op)
                        }
                        g_svg_grads[id] = g
                    }
                }
            }
            walk(ch, cur, hrefs)
        }
    }
}

// O id resolve p/ um gradiente utilizável? (o emit decide por aqui se troca o
// poly-fill de uma cor pela varredura por scanline)
svg_grad_ready :: proc(id: string) -> bool {
    if id == "" do return false
    g, ok := g_svg_grads[id]
    return ok && g.ok && len(g.stops) > 0
}

// `url(#id)` → id. "" quando não é uma referência.
svg_url_ref :: proc(v: string) -> string {
    t := strings.trim_space(v)
    if !strings.has_prefix(t, "url(") || !strings.has_suffix(t, ")") do return ""
    inner := strings.trim_space(t[4 : len(t) - 1])
    inner = strings.trim(inner, "\"'")
    if !strings.has_prefix(inner, "#") do return ""
    return inner[1:]
}

// ── avaliação ───────────────────────────────────────────────────────────────

// Interpola dois 0xAARRGGBB canal a canal (mesma convenção de cor do motor).
@(private = "file")
lerp_rgb :: proc(a, b: u32, t: f32) -> u32 {
    f := clamp(t, 0, 1)
    ch :: proc(a, b: u32, sh: u32, f: f32) -> u32 {
        x := f32((a >> sh) & 0xff); y := f32((b >> sh) & 0xff)
        return (u32(x + (y - x) * f) & 0xff) << sh
    }
    return ch(a, b, 16, f) | ch(a, b, 8, f) | ch(a, b, 0, f)
}

// Cor (RGB) e opacidade do gradiente na fração `t` do eixo. Stops fora de ordem
// são tratados por CLAMP monotônico, como manda a spec.
svg_grad_at :: proc(g: Svg_Grad, t: f32) -> (u32, f32) {
    n := len(g.stops)
    if n == 0 do return 0x000000, 1
    if n == 1 do return g.stops[0].col, g.stops[0].op
    x := clamp(t, 0, 1)
    prev := g.stops[0]
    if x <= prev.off do return prev.col, prev.op
    for i in 1 ..< n {
        s := g.stops[i]
        off := max(s.off, prev.off) // monotônico
        if x <= off {
            span := off - prev.off
            f := span > 1e-6 ? (x - prev.off) / span : 1
            return lerp_rgb(prev.col, s.col, f), prev.op + (s.op - prev.op) * f
        }
        prev = Svg_Stop{off = off, col = s.col, op = s.op}
    }
    last := g.stops[n - 1]
    return last.col, last.op
}

// Fração do eixo do gradiente no ponto (px,py) em coords de USUÁRIO.
// `bb*` é a bounding box da forma, também em coords de usuário — é ela que dá
// sentido ao default `objectBoundingBox`.
svg_grad_frac :: proc(g: Svg_Grad, px, py: f32, bbx, bby, bbw, bbh: f32) -> f32 {
    // ponto no espaço do gradiente
    ux, uy := px, py
    if !g.user_space {
        ux = bbw > 1e-6 ? (px - bbx) / bbw : 0
        uy = bbh > 1e-6 ? (py - bby) / bbh : 0
    }
    if g.radial {
        if g.r <= 1e-6 do return 1
        dx := ux - g.cx; dy := uy - g.cy
        return clamp(math.sqrt(dx * dx + dy * dy) / g.r, 0, 1)
    }
    vx := g.x2 - g.x1; vy := g.y2 - g.y1
    den := vx * vx + vy * vy
    if den <= 1e-9 do return 1 // vetor degenerado: per spec, a cor do ÚLTIMO stop
    return clamp(((ux - g.x1) * vx + (uy - g.y1) * vy) / den, 0, 1)
}
