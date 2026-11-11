package ui

import "core:testing"
import dompkg "../dom"
import csspkg "../css"

// ── Fase 2 do registro: palavras-chave CSS-wide e pseudo-elementos ──────────
// Cada caso tem o CONTROLE ao lado (a mesma situação sem a palavra-chave), para
// o teste não passar por um motivo que não é o que ele afirma.

// `background-color: inherit` não pintava: o filho recebia o pai com
// has_bg zerado e copiava a cor com has_bg=false.
@(test)
test_wide_kw_background_color_inherit_pinta :: proc(t: ^testing.T) {
    c := test_compute_child(".g{background-color:#c00} .i{background-color:inherit}")
    testing.expectf(t, c.has_bg && c.bg == 0xcc0000, "inherit deveria pintar a cor do pai; veio has_bg=%v bg=%x", c.has_bg, c.bg)
    ctl := test_compute_child(".g{background-color:#c00}")
    testing.expect(t, !ctl.has_bg, "controle: sem `inherit`, fundo não herda")
}

// Propriedade NÃO-herdada que antes ignorava `inherit` por não estar na lista.
@(test)
test_wide_kw_inherit_generico_em_nao_herdada :: proc(t: ^testing.T) {
    c := test_compute_child(".g{padding:5px 6px;border-radius:4px;position:relative} .i{padding:inherit;border-radius:inherit;position:inherit}")
    testing.expectf(t, c.padding == [4]f32{5, 6, 5, 6}, "padding:inherit; veio %v", c.padding)
    testing.expectf(t, c.border_radius[0] == 4, "border-radius:inherit; veio %v", c.border_radius)
    testing.expectf(t, c.position == .Relative, "position:inherit; veio %v", c.position)
    // controle negativo: longhand cujo grupo é MAIS LARGO (as 4 margens) não pode
    // arrastar as irmãs — `margin-top: inherit` segue sem efeito, como antes.
    m := test_compute_child(".g{margin:1px 2px 3px 4px} .i{margin-top:inherit}")
    testing.expectf(t, m.margin[1] == 0 && m.margin[3] == 0, "margin-top:inherit levou outras margens: %v", m.margin)
}

// Os casos que eram escritos à mão continuam valendo pelo caminho genérico.
@(test)
test_wide_kw_casos_antigos :: proc(t: ^testing.T) {
    bs := test_compute_child(".g{box-sizing:border-box} .i{box-sizing:inherit}")
    testing.expect(t, bs.box_sizing == .Border, "box-sizing:inherit")
    z := test_compute_child(".g{z-index:7;position:relative} .i{--z:inherit;z-index:var(--z)}")
    testing.expectf(t, z.z_index == 7 && z.z_index_set, "z-index via var() = inherit; veio %v %v", z.z_index, z.z_index_set)
    bc := test_compute_child(".g{background-clip:content-box} .i{-webkit-background-clip:inherit}")
    testing.expectf(t, bc.bg_clip == .Content, "alias -webkit-background-clip:inherit; veio %v", bc.bg_clip)
    col := test_compute_child(".g{color:#f00} .i{color:initial}")
    testing.expectf(t, col.color == DEFAULT_TEXT, "color:initial quebra a herança; veio %x", col.color)
    ww := test_compute_child(".g{overflow-wrap:anywhere} .i{word-wrap:initial}")
    testing.expect(t, !ww.break_word && !ww.wrap_anywhere, "alias word-wrap:initial")
}

// `font-weight: inherit` desfaz o negrito do UA no h1 (preflight do Tailwind).
@(test)
test_wide_kw_h1_font_weight_inherit :: proc(t: ^testing.T) {
    h := test_compute_one("h1{font-weight:inherit}", "h1")
    testing.expectf(t, fw_css(h.weight) == 400, "h1 com inherit deveria sair 400; veio %v", fw_css(h.weight))
    ctl := test_compute_one("", "h1")
    testing.expectf(t, fw_css(ctl.weight) == 700, "controle: h1 do UA é 700; veio %v", fw_css(ctl.weight))
}

// `initial`/`unset` em propriedade NÃO-herdada descartam o default do UA. Antes o
// reset rodava ANTES do UA, então `button{padding:initial}` mantinha o do UA.
@(test)
test_wide_kw_initial_vence_o_ua :: proc(t: ^testing.T) {
    ctl := test_compute_one("", "button")
    testing.expectf(t, ctl.padding[1] > 0, "pré-condição: o UA dá padding ao <button>; veio %v", ctl.padding)
    b := test_compute_one("button{padding:initial}", "button")
    testing.expectf(t, b.padding == [4]f32{}, "padding:initial; veio %v", b.padding)
    u := test_compute_one("button{padding:unset}", "button")
    testing.expectf(t, u.padding == [4]f32{}, "padding:unset (não herda = initial); veio %v", u.padding)
}

// Grupo com ponteiro DONO fica fora do genérico: `transform: inherit` não pode
// copiar o XList do pai (alias → double free no x_free_styles).
@(test)
test_wide_kw_transform_inherit_nao_faz_alias :: proc(t: ^testing.T) {
    // ⚠️ o filho pode ter um XList PRÓPRIO (o parse_transform aloca um vazio ao
    // ler a string "inherit" — comportamento antigo); o que não pode é ser o DO PAI.
    rules, _ := csspkg.parse(".g{transform:rotate(10deg)} .i{transform:inherit}")
    pai := dompkg.make_node(.Element); pai.tag = "div"
    pai.attrs = make(map[string]string, context.temp_allocator); pai.attrs["class"] = "g"
    filho := dompkg.make_node(.Element); filho.tag = "div"
    filho.attrs = make(map[string]string, context.temp_allocator); filho.attrs["class"] = "i"
    dompkg.append_child(pai, filho)
    styles, _ := compute_styles(pai, &rules)
    p, c := styles[pai], styles[filho]
    testing.expect(t, p.xform != nil, "pré-condição: o pai tem transform")
    testing.expect(t, c.xform != p.xform, "transform:inherit copiou o ponteiro do pai (alias → double free)")
}

// ── pseudo-elementos ──

@(test)
test_pseudo_nao_herdadas_no_inicial :: proc(t: ^testing.T) {
    c := test_compute_one(".i::before{content:'x'}", "div", "i")
    testing.expect(t, c.before != nil, "pré-condição: ::before existe")
    if c.before == nil do return
    b := c.before^
    testing.expectf(t, b.flex_shrink == 1, "flex-shrink do ::before deveria ser 1 (inicial); veio %v", b.flex_shrink)
    testing.expect(t, b.bg_repeat, "background-repeat do ::before deveria ser repeat")
    testing.expectf(t, b.grid_col_span == 1, "grid span do ::before deveria ser 1; veio %v", b.grid_col_span)
    testing.expectf(t, b.opacity == 1 && b.transform_sx == 1 && b.xf_a == 1, "transform/opacidade neutros")
}

@(test)
test_pseudo_herda_tudo_que_herda :: proc(t: ^testing.T) {
    css := ".i{text-shadow:1px 1px red;cursor:pointer;word-break:break-all;margin:9px} .i::before{content:'x'}"
    c := test_compute_one(css, "div", "i")
    if c.before == nil do testing.fail_now(t, "::before ausente")
    b := c.before^
    testing.expectf(t, b.text_shadow_n == 1, "text-shadow herda p/ o ::before; veio %v", b.text_shadow_n)
    testing.expectf(t, b.cursor == .Pointer, "cursor herda p/ o ::before; veio %v", b.cursor)
    testing.expect(t, b.break_all, "word-break herda p/ o ::before")
    testing.expectf(t, b.margin[0] == 0, "controle: margin NÃO herda p/ o ::before; veio %v", b.margin[0])
}
