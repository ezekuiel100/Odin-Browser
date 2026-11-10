package ui

// M238 — a 2ª leva da campanha do M237 (ver [[css-m237-valor-caido]]): os itens
// que ficaram de fora daquele marco. Mesma família — valor escrito pelo autor
// que o motor deixava cair —, agora nas UNIDADES, na GRAFIA da função de cor,
// nas palavras-chave CSS-wide e na borda sem largura.

import "core:testing"
import "core:fmt"

// ── 5. unidades absolutas de comprimento ────────────────────────────────────

@(test)
test_m238_unidades_absolutas :: proc(t: ^testing.T) {
    // Todas ancoradas em 1in = 96px (css-values §5.2) — a definição da spec.
    Caso :: struct { v: string, px: f32 }
    casos := []Caso{
        {"1in",  96},
        {"2in",  192},
        {"1cm",  37.7952},
        {"1mm",  3.77952},
        {"1q",   0.944882},
        {"1pc",  16},
        {"12pt", 16},      // 12pt = 1pc = 16px EXATO (era 15,996 com o fator 1.333)
        {"72pt", 96},
        {"1Q",   0.944882}, // maiúscula é a grafia canônica de Q
    }
    for c in casos {
        px, pct, ok := test_parse_len(c.v)
        d := px - c.px
        if d < 0 do d = -d
        testing.expectf(t, ok && !pct && d < 0.001,
            "parse_len(%q): esperado %v, veio %v (pct=%v ok=%v)", c.v, c.px, px, pct, ok)
    }
    // e chegam mesmo ao Computed pelo pipeline
    c1 := test_compute_one(".i{width: 2in}", "div", "i")
    testing.expectf(t, c1.has_width && c1.width == 192, "width:2in → 192; veio has=%v w=%v", c1.has_width, c1.width)
    c2 := test_compute_one(".i{margin: 1cm}", "div", "i")
    testing.expectf(t, c2.margin[0] > 37.7 && c2.margin[0] < 37.9, "margin:1cm → ~37.8; veio %v", c2.margin[0])
}

@(test)
test_m238_font_size_espelha_parse_len :: proc(t: ^testing.T) {
    // parse_font_size tinha um SEGUNDO switch de unidades, cópia parcial do
    // parse_len — e as duas já tinham divergido. Agora ele delega, então toda
    // unidade de comprimento tem de dar o MESMO número nos dois.
    unidades := []string{"px", "pt", "pc", "in", "cm", "mm", "q", "rem", "em", "ex", "vh", "vw", "vmin", "vmax"}
    for u in unidades {
        val := fmt.tprintf("3%s", u)
        esperado, _, ok1 := test_parse_len(val, 16)
        veio, ok2 := test_parse_font_size(val, 16)
        d := veio - esperado
        if d < 0 do d = -d
        testing.expectf(t, ok1 && ok2 && d < 0.001,
            "font-size %q: parse_len deu %v (ok=%v), parse_font_size deu %v (ok=%v)", val, esperado, ok1, veio, ok2)
    }
    // GANHO DE TABELA: o scanner próprio exigia dígito no 1º byte, então TODA
    // tipografia fluida (`clamp()`, `min()`, `max()`) caía calada em font-size —
    // e é assim que os sites modernos escrevem título. Delegando, funciona.
    fluidos := []string{"clamp(1rem, 2vw, 3rem)", "min(4rem, 5vw)", "max(1rem, 2vw)"}
    for f in fluidos {
        esperado, _, ok1 := test_parse_len(f, 16)
        veio, ok2 := test_parse_font_size(f, 16)
        testing.expectf(t, ok1 && ok2 && veio == esperado,
            "font-size %q: esperado %v (ok=%v), veio %v (ok=%v)", f, esperado, ok1, veio, ok2)
    }

    // % é a diferença de CONTEXTO: razão do PAI, não fração de caixa
    px, ok := test_parse_font_size("50%", 20)
    testing.expectf(t, ok && px == 10, "font-size:50%% de 20px → 10; veio %v (ok=%v)", px, ok)
    // e a palavra-chave que faltava
    px2, ok2 := test_parse_font_size("xxx-large", 16)
    testing.expectf(t, ok2 && px2 == 48, "xxx-large → 48; veio %v (ok=%v)", px2, ok2)
}

@(test)
test_m238_font_size_attr_legado :: proc(t: ^testing.T) {
    // `<font size=N>` (HTML rendering §15.3.2) — o OUTRO lado do par que o reftest
    // css-fonts/font-size-xxx-large compara. Ele passava porque os dois lados
    // caíam em 16px; implementar só `xxx-large` quebrava o par.
    Caso :: struct { attr: string, px: f32 }
    casos := []Caso{
        {"1", 9}, {"2", 13}, {"3", 16}, {"4", 18}, {"5", 24}, {"6", 32}, {"7", 48},
        {"+1", 18},  // relativo ao 3
        {"-1", 13},
        {"9",  48},  // acima de 7 satura
    }
    for k in casos {
        c := test_compute_attr("", "font", "size", k.attr)
        testing.expectf(t, c.font_size == k.px, "<font size=%s> → %vpx; veio %v", k.attr, k.px, c.font_size)
    }
    // e o CSS do autor VENCE o atributo legado
    c := test_compute_attr("font{font-size:20px}", "font", "size", "7")
    testing.expectf(t, c.font_size == 20, "CSS vence <font size>; veio %v", c.font_size)
}

// ── 6. grafia da função de cor ──────────────────────────────────────────────

@(test)
test_m238_cor_funcao_maiuscula :: proc(t: ^testing.T) {
    // Nome de função CSS é case-insensitive (css-syntax §2).
    Caso :: struct { v: string, rgb: u32 }
    casos := []Caso{
        {"RGB(255, 0, 0)",       0xff0000},
        {"Rgb(255 0 0)",         0xff0000},
        {"RGBA(255,0,0,1)",      0xff0000},
        {"HSL(0, 100%, 50%)",    0xff0000},
        {"HSLA(0,100%,50%,1)",   0xff0000},
        {"OKLCH(0.628 0.2577 29.23)", 0xfe0000}, // conversão de espaço: ~vermelho
        {"#FF0000",              0xff0000},
        {"RED",                  0xff0000},
        {"Color-Mix(in srgb, #ff0000 100%, #0000ff 0%)", 0xff0000},
    }
    for k in casos {
        c := test_compute_one(fmt.tprintf(".i{{color: %s}}", k.v), "div", "i")
        got := c.color & 0xffffff
        dr := int((got >> 16) & 0xff) - int((k.rgb >> 16) & 0xff)
        dg := int((got >> 8) & 0xff)  - int((k.rgb >> 8) & 0xff)
        db := int(got & 0xff)         - int(k.rgb & 0xff)
        if dr < 0 do dr = -dr
        if dg < 0 do dg = -dg
        if db < 0 do db = -db
        testing.expectf(t, dr <= 2 && dg <= 2 && db <= 2, "color: %s esperado ~%06x, veio %08x", k.v, k.rgb, c.color)
    }
}

// ── 7. palavras-chave CSS-wide em propriedade que NÃO herda ─────────────────

@(test)
test_m238_inherit_em_prop_que_nao_herda :: proc(t: ^testing.T) {
    // O idioma de reset mais conhecido: `html{box-sizing:border-box} *{box-sizing:inherit}`
    c := test_compute_child(".g{box-sizing: border-box} .i{box-sizing: inherit}")
    testing.expectf(t, c.box_sizing == .Border, "box-sizing:inherit copia do pai; veio %v", c.box_sizing)

    // controle: sem o `inherit` NÃO herda (é prop que não herda)
    c2 := test_compute_child(".g{box-sizing: border-box} .i{}")
    testing.expectf(t, c2.box_sizing == .Content, "box-sizing NÃO herda sozinho; veio %v", c2.box_sizing)

    // e o `inherit` não inventa quando o pai é o default
    c3 := test_compute_child(".i{box-sizing: inherit}")
    testing.expectf(t, c3.box_sizing == .Content, "inherit de pai content-box; veio %v", c3.box_sizing)
}

@(test)
test_m238_initial_em_prop_que_herda :: proc(t: ^testing.T) {
    // `initial` numa prop HERDADA tem de QUEBRAR a herança (voltar ao inicial).
    c := test_compute_child(".g{color:#ff0000} .i{color: initial}")
    testing.expectf(t, (c.color & 0xffffff) != 0xff0000, "color:initial não pode manter o herdado; veio %08x", c.color)

    c2 := test_compute_child(".g{font-weight:700} .i{font-weight: initial}")
    testing.expectf(t, fw_class(c2.weight) == .Regular, "font-weight:initial → normal; veio %v", c2.weight)

    c3 := test_compute_child(".g{text-align:center} .i{text-align: initial}")
    testing.expectf(t, c3.text_align == .Left, "text-align:initial → left; veio %v", c3.text_align)

    // `unset` numa prop que HERDA é igual a `inherit` → mantém o do pai
    c4 := test_compute_child(".g{color:#ff0000} .i{color: unset}")
    testing.expectf(t, (c4.color & 0xffffff) == 0xff0000, "color:unset mantém o herdado; veio %08x", c4.color)
}

// ── 8. borda sem largura explícita ──────────────────────────────────────────

@(test)
test_m238_border_medium :: proc(t: ^testing.T) {
    // largura omitida = `medium` = 3px (css-backgrounds §4.2)
    c := test_compute_one(".i{border: solid red}", "div", "i")
    testing.expectf(t, c.border_w[0] == 3, "border:solid red → 3px; veio %v", c.border_w[0])

    c2 := test_compute_one(".i{border-style: solid; border-color: red}", "div", "i")
    testing.expectf(t, c2.border_w[0] == 3, "border-style:solid sem width → 3px; veio %v", c2.border_w[0])

    c3 := test_compute_one(".i{border-top-style: dashed}", "div", "i")
    testing.expectf(t, c3.border_w[0] == 3 && c3.border_w[1] == 0,
        "border-top-style sozinho só engorda o TOPO; veio %v", c3.border_w)

    // largura EXPLÍCITA continua mandando (inclusive zero)
    c4 := test_compute_one(".i{border: 0 solid red}", "div", "i")
    testing.expectf(t, c4.border_w[0] == 0, "border:0 solid → 0; veio %v", c4.border_w[0])
    c5 := test_compute_one(".i{border: 1px solid red}", "div", "i")
    testing.expectf(t, c5.border_w[0] == 1, "border:1px solid → 1; veio %v", c5.border_w[0])
    c6 := test_compute_one(".i{border-style:solid; border-width:2px}", "div", "i")
    testing.expectf(t, c6.border_w[0] == 2, "border-width vence o medium; veio %v", c6.border_w[0])

    // estilo `none` não ganha largura nenhuma
    c7 := test_compute_one(".i{border: none red}", "div", "i")
    testing.expectf(t, c7.border_w[0] == 0, "border:none → 0; veio %v", c7.border_w[0])
}

@(test)
test_m238_border_sem_estilo_nao_pinta :: proc(t: ^testing.T) {
    // estilo omitido no shorthand = `none` (inicial) → NÃO pinta, como no Chrome
    c := test_compute_one(".i{border: 1px red}", "div", "i")
    testing.expectf(t, c.border_style_none[0], "border:1px red (sem estilo) não deve pintar; none=%v", c.border_style_none[0])
    // controle: com estilo, pinta
    c2 := test_compute_one(".i{border: 1px solid red}", "div", "i")
    testing.expectf(t, !c2.border_style_none[0], "controle: com `solid` pinta; none=%v", c2.border_style_none[0])
}

// ── 10. shorthand RESETA os longhands que cobre ─────────────────────────────

@(test)
test_m238_shorthand_reseta_longhand :: proc(t: ^testing.T) {
    // `background: <cor>` de regra MAIS específica tem de apagar a IMAGEM que veio
    // de outra regra (o shorthand cobre background-image).
    c := test_compute_one(".a{background-image:linear-gradient(#f00,#00f)} .i{background:#00ff00}", "div", "a i")
    testing.expectf(t, !c.grad.active, "shorthand background deveria limpar o gradiente; grad=%v", c.grad.active)

    // …e o inverso: longhand mais específico SOBREVIVE ao shorthand
    c2 := test_compute_one("div{background:#00ff00} .i{background-image:linear-gradient(#f00,#00f)}", "div", "i")
    testing.expectf(t, c2.grad.active, "longhand de spec maior deveria valer; grad=%v", c2.grad.active)

    // `border` shorthand × `border-width` longhand
    c3 := test_compute_one("div{border-width:9px} .i{border:1px solid red}", "div", "i")
    testing.expectf(t, c3.border_w[0] == 1, "shorthand border de spec maior vence; veio %v", c3.border_w[0])
    c4 := test_compute_one("div{border:1px solid red} .i{border-width:9px}", "div", "i")
    testing.expectf(t, c4.border_w[0] == 9, "longhand border-width de spec maior vence; veio %v", c4.border_w[0])
}

// ── 11. computed_initial() bate com o reset das não-herdadas ────────────────

@(test)
test_m238_computed_initial_bate_com_o_reset :: proc(t: ^testing.T) {
    // `all: initial` faz `comp^ = computed_initial()`; se ele divergir do bloco
    // de reset de compute_node, produzimos um estilo que a engine nunca geraria.
    // O elemento SEM declaração nenhuma passa pelo reset — é o oráculo.
    ref := test_compute_one(".i{}", "div", "i")
    ini := test_computed_initial()
    testing.expectf(t, ini.flex_shrink == ref.flex_shrink, "flex_shrink: initial=%v reset=%v", ini.flex_shrink, ref.flex_shrink)
    testing.expectf(t, ini.col_gap     == ref.col_gap,     "col_gap: initial=%v reset=%v", ini.col_gap, ref.col_gap)
    testing.expectf(t, ini.ac_stretch  == ref.ac_stretch,  "ac_stretch: initial=%v reset=%v", ini.ac_stretch, ref.ac_stretch)
    testing.expectf(t, ini.bg_origin   == ref.bg_origin,   "bg_origin: initial=%v reset=%v", ini.bg_origin, ref.bg_origin)
    testing.expectf(t, ini.bg_repeat   == ref.bg_repeat,   "bg_repeat: initial=%v reset=%v", ini.bg_repeat, ref.bg_repeat)
    testing.expectf(t, ini.grid_col_span == ref.grid_col_span, "grid_col_span: initial=%v reset=%v", ini.grid_col_span, ref.grid_col_span)
    testing.expectf(t, ini.grid_row_span == ref.grid_row_span, "grid_row_span: initial=%v reset=%v", ini.grid_row_span, ref.grid_row_span)
    testing.expectf(t, ini.box_sizing  == ref.box_sizing,  "box_sizing: initial=%v reset=%v", ini.box_sizing, ref.box_sizing)
    testing.expectf(t, ini.opacity     == ref.opacity,     "opacity: initial=%v reset=%v", ini.opacity, ref.opacity)
}
