package ui

// M225 — `stop-color`/`stop-opacity` e gradientes de SVG.
//
// A geometria e a interpolação são lógica PURA (sem atlas, sem renderer), então
// dão teste de unidade de verdade. O que só o pixel prova — a subdivisão do span
// — está em `tests/manual/svg-gradient.html` e no relato do marco.

import "core:testing"
import htmlp "../html"
import csspkg "../css"
import dompkg "../dom"

@(private = "file")
nearg :: proc(a, b: f32, tol: f32 = 0.01) -> bool { return abs(a - b) <= tol }

// ── url(#id) ────────────────────────────────────────────────────────────────

@(test)
test_m225_url_ref :: proc(t: ^testing.T) {
    testing.expect(t, svg_url_ref("url(#g1)") == "g1", "forma simples")
    testing.expect(t, svg_url_ref(`url("#g1")`) == "g1", "com aspas")
    testing.expect(t, svg_url_ref("  url( #g1 )  ") == "g1", "com espaços")
    testing.expect(t, svg_url_ref("#g1") == "", "sem url() não é referência")
    testing.expect(t, svg_url_ref("red") == "", "cor não é referência")
    testing.expect(t, svg_url_ref("url(foo.svg)") == "", "url externa não é referência local")
}

// ── interpolação dos stops ──────────────────────────────────────────────────

@(test)
test_m225_grad_at_interpola :: proc(t: ^testing.T) {
    g := Svg_Grad{stops = []Svg_Stop{{0, 0xff0000, 1}, {1, 0x0000ff, 1}}, ok = true}
    c0, _ := svg_grad_at(g, 0)
    testing.expectf(t, c0 == 0xff0000, "t=0 é o 1º stop; veio %06x", c0)
    c1, _ := svg_grad_at(g, 1)
    testing.expectf(t, c1 == 0x0000ff, "t=1 é o último; veio %06x", c1)
    cm, _ := svg_grad_at(g, 0.5)
    r := (cm >> 16) & 0xff; b := cm & 0xff
    testing.expectf(t, r > 100 && r < 155 && b > 100 && b < 155, "meio mistura; veio %06x", cm)
    // fora de [0,1] clampa (spreadMethod=pad, o default)
    cb, _ := svg_grad_at(g, -3)
    ca, _ := svg_grad_at(g, 9)
    testing.expect(t, cb == 0xff0000 && ca == 0x0000ff, "clamp nas pontas")
}

@(test)
test_m225_grad_at_opacidade_e_casos_limite :: proc(t: ^testing.T) {
    g := Svg_Grad{stops = []Svg_Stop{{0, 0xc00000, 1}, {1, 0xc00000, 0}}, ok = true}
    _, o0 := svg_grad_at(g, 0)
    _, om := svg_grad_at(g, 0.5)
    _, o1 := svg_grad_at(g, 1)
    testing.expect(t, nearg(o0, 1) && nearg(om, 0.5) && nearg(o1, 0), "stop-opacity interpola junto")

    // um stop só = cor constante; nenhum = preto opaco (não pode explodir)
    g1 := Svg_Grad{stops = []Svg_Stop{{0.3, 0x00ff00, 0.5}}, ok = true}
    c, o := svg_grad_at(g1, 0.9)
    testing.expect(t, c == 0x00ff00 && nearg(o, 0.5), "stop único")
    g0 := Svg_Grad{}
    c2, o2 := svg_grad_at(g0, 0.5)
    testing.expect(t, c2 == 0x000000 && nearg(o2, 1), "sem stops não estoura")

    // offsets FORA DE ORDEM: a spec manda tratar como monotônico (clamp)
    gd := Svg_Grad{stops = []Svg_Stop{{0, 0xff0000, 1}, {0.8, 0x00ff00, 1}, {0.2, 0x0000ff, 1}}, ok = true}
    cx, _ := svg_grad_at(gd, 0.9)
    testing.expectf(t, cx == 0x0000ff, "o 3º stop é empurrado p/ 0.8; t=0.9 dá a cor dele (%06x)", cx)
}

// ── geometria ───────────────────────────────────────────────────────────────

@(test)
test_m225_frac_linear_bbox :: proc(t: ^testing.T) {
    // default da spec: x1=0,y1=0 → x2=1,y2=0 (HORIZONTAL), em fração da bbox
    g := Svg_Grad{x2 = 1, ok = true}
    testing.expect(t, nearg(svg_grad_frac(g, 0,   50, 0, 0, 100, 100), 0),   "borda esquerda")
    testing.expect(t, nearg(svg_grad_frac(g, 50,  50, 0, 0, 100, 100), 0.5), "meio")
    testing.expect(t, nearg(svg_grad_frac(g, 100, 50, 0, 0, 100, 100), 1),   "borda direita")
    // a bbox é que dá sentido ao objectBoundingBox: a MESMA forma deslocada e
    // maior tem de dar as mesmas frações
    testing.expect(t, nearg(svg_grad_frac(g, 220, 99, 200, 40, 40, 80), 0.5), "bbox deslocada/menor")

    v := Svg_Grad{x2 = 0, y2 = 1, ok = true} // vertical
    testing.expect(t, nearg(svg_grad_frac(v, 50, 0,   0, 0, 100, 100), 0), "topo")
    testing.expect(t, nearg(svg_grad_frac(v, 50, 100, 0, 0, 100, 100), 1), "base")
    testing.expect(t, nearg(svg_grad_frac(v, 99, 50,  0, 0, 100, 100), 0.5), "x não importa no vertical")
}

@(test)
test_m225_frac_user_space_e_radial :: proc(t: ^testing.T) {
    // userSpaceOnUse: as coords são de USUÁRIO, a bbox não entra na conta
    u := Svg_Grad{user_space = true, x1 = 0, y1 = 0, x2 = 200, y2 = 0, ok = true}
    testing.expect(t, nearg(svg_grad_frac(u, 100, 7, 0, 0, 50, 50), 0.5), "metade de 200 unidades")
    testing.expect(t, nearg(svg_grad_frac(u, 400, 7, 0, 0, 50, 50), 1), "além do fim clampa")

    r := Svg_Grad{radial = true, cx = 0.5, cy = 0.5, r = 0.5, ok = true}
    testing.expect(t, nearg(svg_grad_frac(r, 50, 50, 0, 0, 100, 100), 0), "centro")
    testing.expect(t, nearg(svg_grad_frac(r, 100, 50, 0, 0, 100, 100), 1), "borda")
    testing.expect(t, nearg(svg_grad_frac(r, 75, 50, 0, 0, 100, 100), 0.5), "meio raio")

    // vetor degenerado (x1==x2, y1==y2): per spec vale a cor do ÚLTIMO stop
    d := Svg_Grad{ok = true}
    testing.expect(t, nearg(svg_grad_frac(d, 10, 10, 0, 0, 100, 100), 1), "vetor nulo ⇒ 1")
}

// ── coleta a partir do DOM ──────────────────────────────────────────────────

@(private = "file")
collect :: proc(html: string, css := "") -> ^dompkg.Node {
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse(css)
    styles, _ := compute_styles(dom, &rules, 800, 600)
    _ = styles
    svg := dompkg.find_first(dom, "svg")
    if svg != nil do svg_collect_gradients(svg, 0x000000)
    return svg
}

@(test)
test_m225_coleta_atributos :: proc(t: ^testing.T) {
    collect(`<svg><defs><linearGradient id="g" x1="0" y1="0" x2="0" y2="1">
        <stop offset="0" stop-color="#ff0000"/>
        <stop offset="0.5" stop-color="#00ff00" stop-opacity="0.25"/>
        <stop offset="1" stop-color="#0000ff"/>
      </linearGradient></defs><rect fill="url(#g)"/></svg>`)
    g, ok := g_svg_grads["g"]
    testing.expect(t, ok && g.ok, "gradiente colhido de dentro do <defs> (que o painter PULA)")
    if !ok do return
    testing.expectf(t, len(g.stops) == 3, "3 stops; veio %d", len(g.stops))
    testing.expect(t, !g.radial && nearg(g.y2, 1) && nearg(g.x2, 0), "vertical")
    testing.expect(t, g.stops[0].col == 0xff0000 && g.stops[2].col == 0x0000ff, "cores")
    testing.expect(t, nearg(g.stops[1].op, 0.25), "stop-opacity do atributo")
}

@(test)
test_m225_stop_color_por_REGRA_CSS :: proc(t: ^testing.T) {
    // É o caso que dá nome ao marco: as duas props declaradas em FOLHA, não em
    // atributo. Passam pela ponte g_svg_css (a mesma do fill/stroke).
    collect(`<svg><defs><linearGradient id="g">
        <stop class="a" offset="0"/><stop class="b" offset="1"/>
      </linearGradient></defs><rect fill="url(#g)"/></svg>`,
      `.a { stop-color: #ff0000 } .b { stop-color: #0000ff; stop-opacity: 0.5 }`)
    g, ok := g_svg_grads["g"]
    testing.expect(t, ok && g.ok && len(g.stops) == 2, "colhido")
    if !ok || len(g.stops) < 2 do return
    testing.expectf(t, g.stops[0].col == 0xff0000, "stop-color de regra CSS; veio %06x", g.stops[0].col)
    testing.expectf(t, g.stops[1].col == 0x0000ff, "idem 2º; veio %06x", g.stops[1].col)
    testing.expect(t, nearg(g.stops[1].op, 0.5), "stop-opacity de regra CSS")
}

// ⚠️ O projeto tem DOIS parsers de HTML e eles guardam o atributo com grafias
// DIFERENTES: o `htmlp.parse` (parser.odin, artesanal) mantém `xlink:href`; o
// `htmlp.parse_render` (treebuild.odin, o de spec) passa pelo
// `foreign_attr_adjust` e guarda `xlink href` — ':' vira ESPAÇO. E o `--render`
// usa um ou outro conforme a origem da página (arquivo local × URL). Por isso a
// lista de grafias em svg_gradient.odin tem as duas.
//
// Este teste roda a coleta pelos DOIS parsers e exige o mesmo resultado. A 1ª
// versão dele olhava só uma grafia e PASSAVA DOS DOIS LADOS da sabotagem — foi a
// sabotagem que expôs isso, e é a razão de o teste ter esta forma.
@(test)
test_m225_href_nos_dois_parsers :: proc(t: ^testing.T) {
    src := `<!doctype html><body><svg><defs>
        <linearGradient id="s"><stop offset="0" stop-color="#000000"/><stop offset="1" stop-color="#00c000"/></linearGradient>
        <linearGradient id="d" xlink:href="#s" x1="0" y1="0" x2="1" y2="1"/>
      </defs><rect fill="url(#d)"/></svg>`
    for usa_spec in ([]bool{false, true}) {
        dom := usa_spec ? htmlp.parse_render(src) : htmlp.parse(src)
        svg := dompkg.find_first(dom, "svg")
        testing.expectf(t, svg != nil, "achou o <svg> (parser de spec=%v)", usa_spec)
        if svg == nil do continue
        svg_collect_gradients(svg, 0x000000)
        g, ok := g_svg_grads["d"]
        testing.expectf(t, ok && g.ok && len(g.stops) == 2,
            "herança de stops por href tem de valer nos DOIS parsers (spec=%v): ok=%v stops=%d",
            usa_spec, ok, ok ? len(g.stops) : -1)
    }
}

@(test)
test_m225_href_herda_stops :: proc(t: ^testing.T) {
    // ⚠️ o parser de HTML serializa `xlink:href` como `"xlink href"` (troca ':'
    // por espaço) — sem essa grafia, todo SVG de exportador perdia a herança.
    collect(`<!doctype html><body><svg><defs>
        <linearGradient id="src"><stop offset="0" stop-color="#000000"/><stop offset="1" stop-color="#00c000"/></linearGradient>
        <linearGradient id="dst" xlink:href="#src" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="100" y2="100"/>
      </defs><rect fill="url(#dst)"/></svg>`)
    g, ok := g_svg_grads["dst"]
    testing.expect(t, ok && g.ok, "o que só tem geometria herda os stops do referido")
    if !ok do return
    testing.expectf(t, len(g.stops) == 2, "2 stops herdados; veio %d", len(g.stops))
    testing.expect(t, g.user_space, "gradientUnits do PRÓPRIO elemento é preservado")
    testing.expect(t, nearg(g.x2, 100), "geometria do próprio, não a do referido")
}

@(test)
test_m225_referencia_quebrada_degrada :: proc(t: ^testing.T) {
    // Degradação: `fill="url(#naoExiste)"` NÃO pode sumir com a forma — ela cai
    // na cor sólida herdada, que é o comportamento anterior ao marco.
    collect(`<svg><rect fill="url(#naoExiste)"/></svg>`)
    testing.expect(t, !svg_grad_ready("naoExiste"), "id inexistente não é utilizável")
    testing.expect(t, !svg_grad_ready(""), "id vazio idem")
    // gradiente SEM stop nenhum também não conta
    collect(`<svg><defs><linearGradient id="vazio"></linearGradient></defs></svg>`)
    testing.expect(t, !svg_grad_ready("vazio"), "gradiente sem stops não é utilizável")
}
