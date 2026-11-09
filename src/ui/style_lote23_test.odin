package ui

// Lote 23 — `fill`/`stroke`/`stroke-width` vindos de REGRA CSS.
// Era o maior gap do gap-report por nº de SITES (fill: 57 sites / 31659 ocorr.):
// o painter de SVG só lia o ATRIBUTO de apresentação e o `style=""` do elemento,
// então `.icon path { fill: currentColor }` — o padrão de todo icon-set moderno —
// não pintava nada. A cascata agora é gravada em Computed.svg_css na resolução
// de estilo (M246: saiu do mapa global g_svg_css, que corrompia com o tracking
// allocator do runner — len=1, iteração vazia).

import "core:testing"
import htmlp "../html"
import csspkg "../css"
import dompkg "../dom"

@(private = "file")
svg_css_of :: proc(html, css: string, tag: string) -> (Svg_Css, bool) {
    svg_css_clear()
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse(css)
    styles, _ := compute_styles(dom, &rules, 800, 600)
    defer free_styles(styles) // copia o Svg_Css abaixo; o ^ é do mapa
    n := dompkg.find_first(dom, tag)
    if n == nil do return {}, false
    return svg_css_get(n)
}

@(test)
test_svg_css_paint :: proc(t: ^testing.T) {
    // 1. fill por REGRA (antes só o atributo de apresentação era lido)
    e1, ok1 := svg_css_of(`<svg class="i"><path d="M0 0L9 9"/></svg>`, `.i path{fill:#ff0000}`, "path")
    testing.expect(t, ok1, "regra CSS em <path> deveria gravar entrada de fill")
    testing.expectf(t, e1.fill_set && !e1.fill_none && e1.fill == 0xff0000,
        "fill esperado #ff0000, veio set=%v none=%v col=%x", e1.fill_set, e1.fill_none, e1.fill)

    // 2. currentColor = a cor HERDADA pelo próprio elemento (padrão dos icon-sets)
    e2, ok2 := svg_css_of(`<div style="color:#00ff00"><svg><path d="M0 0"/></svg></div>`,
                          `path{fill:currentColor}`, "path")
    testing.expect(t, ok2, "fill:currentColor deveria gravar entrada")
    testing.expectf(t, e2.fill_set && e2.fill == 0x00ff00,
        "currentColor deveria resolver p/ a cor herdada #00ff00, veio %x", e2.fill)

    // 3. fill:none (DISTINTO de "não declarado") + stroke + stroke-width
    e3, ok3 := svg_css_of(`<svg><path d="M0 0"/></svg>`,
                          `path{fill:none;stroke:blue;stroke-width:2.5px}`, "path")
    testing.expect(t, ok3, "fill/stroke/stroke-width deveriam gravar entrada")
    testing.expect(t, e3.fill_set && e3.fill_none, "fill:none precisa ser DISTINTO de 'não declarado'")
    testing.expectf(t, e3.stroke_set && e3.stroke == 0x0000ff, "stroke esperado azul, veio %x", e3.stroke)
    testing.expectf(t, e3.sw_set && e3.sw == 2.5, "stroke-width esperado 2.5, veio %v", e3.sw)

    // 4. ESPARSO: sem nenhuma das 3 props o nó não entra no mapa (atributo manda)
    _, ok4 := svg_css_of(`<svg><path fill="red" d="M0 0"/></svg>`, `path{opacity:.5}`, "path")
    testing.expect(t, !ok4, "nó sem fill/stroke/stroke-width em CSS não deveria entrar no mapa")

    // 5. a cascata normal decide o que é gravado (classe vence tag)
    e5, ok5 := svg_css_of(`<svg><path class="a" d="M0 0"/></svg>`,
                          `path{fill:#111111} .a{fill:#222222}`, "path")
    testing.expect(t, ok5, "entrada deveria existir")
    testing.expectf(t, e5.fill == 0x222222, "a regra de classe deveria vencer, veio %x", e5.fill)
    // ── Lote 27: resto da família de pintura (mesmo proc por causa do global) ──
    e6, ok6 := svg_css_of(`<svg><path d="M0 0"/></svg>`,
        `path{fill-opacity:.25;stroke-opacity:50%;stroke-linecap:round;stroke-linejoin:bevel;fill-rule:nonzero}`, "path")
    testing.expect(t, ok6, "as 5 props da família deveriam gravar entrada")
    testing.expectf(t, e6.fill_op_set && e6.fill_op == 0.25, "fill-opacity .25, veio %v", e6.fill_op)
    testing.expectf(t, e6.stroke_op_set && e6.stroke_op == 0.5, "stroke-opacity 50%% = .5, veio %v", e6.stroke_op)
    testing.expectf(t, e6.cap_set && e6.cap == 1, "linecap round = 1, veio %v", e6.cap)
    testing.expectf(t, e6.join_set && e6.join == 2, "linejoin bevel = 2, veio %v", e6.join)
    testing.expect(t, e6.rule_set && !e6.evenodd, "fill-rule:nonzero deveria DESligar o even-odd")

    e7, _ := svg_css_of(`<svg><path d="M0 0"/></svg>`, `path{fill-rule:evenodd}`, "path")
    testing.expect(t, e7.rule_set && e7.evenodd, "fill-rule:evenodd")

    // opacidade fora de [0,1] é CLAMPADA (spec), não descartada
    e8, _ := svg_css_of(`<svg><path d="M0 0"/></svg>`, `path{fill-opacity:1.8;stroke-opacity:-3}`, "path")
    testing.expectf(t, e8.fill_op == 1 && e8.stroke_op == 0,
        "opacidade deveria ser clampada a [0,1], veio %v/%v", e8.fill_op, e8.stroke_op)

    // valor inválido não pode "declarar" nada (o atributo do elemento tem de valer)
    e9, ok9 := svg_css_of(`<svg><path d="M0 0"/></svg>`, `path{stroke-linecap:banana}`, "path")
    testing.expect(t, !ok9 || !e9.cap_set, "valor inválido não deveria marcar linecap como declarado")

    // ── stroke-dasharray / stroke-dashoffset por REGRA CSS (mesmo proc: global) ──
    e10, ok10 := svg_css_of(`<svg><path d="M0 0"/></svg>`,
        `path{stroke-dasharray:4 2;stroke-dashoffset:3}`, "path")
    testing.expect(t, ok10, "dasharray/dashoffset de regra deveriam gravar entrada")
    testing.expectf(t, e10.dash_set && e10.dash_n == 2 && e10.dash[0] == 4 && e10.dash[1] == 2,
        "dasharray `4 2`; veio set=%v n=%d", e10.dash_set, e10.dash_n)
    testing.expectf(t, e10.doff_set && e10.doff == 3, "dashoffset 3; veio %v", e10.doff)

    // a lista ÍMPAR é normalizada no MESMO parser do painter (uma regra só p/ os
    // dois caminhos) — aqui prova-se que a regra CSS passa por ele também
    e11, _ := svg_css_of(`<svg><path d="M0 0"/></svg>`, `path{stroke-dasharray:5}`, "path")
    testing.expectf(t, e11.dash_n == 2 && e11.dash[1] == 5, "`5` vira `5 5`; veio n=%d", e11.dash_n)

    // `none` é DECLARADO (n=0), não ausente: precisa CANCELAR o dasharray que o
    // <g> pai herdou. Se virasse "não declarado", o herdado continuaria valendo.
    e12, ok12 := svg_css_of(`<svg><path d="M0 0"/></svg>`, `path{stroke-dasharray:none}`, "path")
    testing.expect(t, ok12 && e12.dash_set && e12.dash_n == 0, "`none` = declarado sólido")

    // unidade CSS: o caminho de REGRA passa pelo parse_len, então `em` resolve
    // contra o font-size (o de ATRIBUTO é número cru — convenções distintas de
    // propósito, cada uma igual à do stroke-width irmão)
    e13, _ := svg_css_of(`<svg style="font-size:10px"><path d="M0 0"/></svg>`,
        `path{stroke-dasharray:1em 0.5em}`, "path")
    testing.expectf(t, e13.dash_n == 2 && e13.dash[0] == 10 && e13.dash[1] == 5,
        "`1em 0.5em` com font-size 10 = 10/5; veio %v/%v", e13.dash[0], e13.dash[1])

    // valor inválido não declara nada (o atributo tem de continuar valendo)
    e14, ok14 := svg_css_of(`<svg><path d="M0 0"/></svg>`, `path{stroke-dasharray:4 banana}`, "path")
    testing.expect(t, !ok14 || !e14.dash_set, "lista inválida não pode marcar dasharray como declarado")

    // ── stroke-miterlimit / shape-rendering por REGRA CSS (mesmo proc: global) ──
    e15, ok15 := svg_css_of(`<svg><path d="M0 0"/></svg>`,
        `path{stroke-miterlimit:8;shape-rendering:crispEdges}`, "path")
    testing.expect(t, ok15, "miterlimit/shape-rendering de regra deveriam gravar entrada")
    testing.expectf(t, e15.mlim_set && e15.mlim == 8, "miterlimit 8; veio set=%v %v", e15.mlim_set, e15.mlim)
    testing.expect(t, e15.shape_set && e15.no_aa && e15.seg_mul == 1, "crispEdges desliga o AA")

    e16, _ := svg_css_of(`<svg><path d="M0 0"/></svg>`, `path{shape-rendering:geometricPrecision}`, "path")
    testing.expectf(t, e16.shape_set && !e16.no_aa && e16.seg_mul == 3,
        "geometricPrecision refina sem desligar o AA; veio no_aa=%v seg=%v", e16.no_aa, e16.seg_mul)

    // miterlimit é RAZÃO (número puro), não comprimento: `8px` não é válido…
    e17, ok17 := svg_css_of(`<svg><path d="M0 0"/></svg>`, `path{stroke-miterlimit:8px}`, "path")
    testing.expect(t, !ok17 || !e17.mlim_set, "miterlimit com unidade não é razão válida")
    // …e < 1 é ERRO per-spec (a declaração cai; o herdado continua valendo)
    e18, ok18 := svg_css_of(`<svg><path d="M0 0"/></svg>`, `path{stroke-miterlimit:0.5}`, "path")
    testing.expect(t, !ok18 || !e18.mlim_set, "miterlimit < 1 é inválido per-spec")
}

// M246 — dono de Svg_Css é o Computed, não um mapa global.
// Sabotagem: duas passadas sequenciais (como o runner faz entre testes) NÃO
// podem vazar fill do documento A para o B; free_styles num pai+filho com
// svg_css só no pai não double-free (o ponteiro NÃO herda).
@(test)
test_svg_css_dono_e_o_computed :: proc(t: ^testing.T) {
    // 50×: o flake antigo aparecia em rajadas; uma passada verde não prova nada.
    for i in 0 ..< 50 {
        e, ok := svg_css_of(`<svg><path d="M0 0"/></svg>`, `path{fill:#ff0000}`, "path")
        testing.expectf(t, ok && e.fill_set && e.fill == 0xff0000,
            "passada %d: fill vermelho tem de gravar (ok=%v col=%x)", i, ok, e.fill)
        e2, ok2 := svg_css_of(`<svg><path d="M0 0"/></svg>`, `path{opacity:.5}`, "path")
        testing.expectf(t, !ok2 && !e2.fill_set,
            "passada %d: o 2º documento NÃO herda o fill do 1º (ok=%v set=%v col=%x)",
            i, ok2, e2.fill_set, e2.fill)
    }

    // pai declara fill, filho não: o ^Svg_Css é do PAI. Se o inherit vazasse o
    // ponteiro, free_styles liberaria duas vezes e isto crasharia.
    html := `<svg class="i"><g><path d="M0 0"/></g></svg>`
    css  := `.i{fill:#00ff00}`
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse(css)
    styles, _ := compute_styles(dom, &rules, 800, 600)
    svg := dompkg.find_first(dom, "svg")
    g   := dompkg.find_first(dom, "g")
    p   := dompkg.find_first(dom, "path")
    testing.expect(t, svg != nil && g != nil && p != nil, "árvore svg>g>path")
    if svg != nil {
        testing.expect(t, styles[svg].svg_css != nil, "o seletor .i grava no <svg>")
    }
    if g != nil {
        testing.expect(t, styles[g].svg_css == nil, "filho <g> NÃO herda o ponteiro")
    }
    if p != nil {
        testing.expect(t, styles[p].svg_css == nil, "neto <path> NÃO herda o ponteiro")
    }
    free_styles(styles) // crash aqui = ponteiro aliased (a lição do before/after)
}
