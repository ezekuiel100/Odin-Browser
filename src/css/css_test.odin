package css

// Testes do parser de CSS.
// Rodar:  odin test src/css  (a partir da raiz do projeto)
//
// Cobrem: cores (hex/nome/rgb/hsl), gradientes, @layer transparente,
// resolução de var() e parsing de declarações.
// (@supports tem arquivo próprio: supports_test.odin.)

import "core:testing"
import "core:strings"

// ── cores ────────────────────────────────────────────────────────────────────

@(test)
test_color_nome :: proc(t: ^testing.T) {
    rgb, ok := parse_color("red")
    testing.expect(t, ok, "red deve parsear")
    testing.expect_value(t, rgb, u32(0xff0000))
}

@(test)
test_color_hex6 :: proc(t: ^testing.T) {
    rgb, ok := parse_color("#00ff00")
    testing.expect(t, ok, "#00ff00 deve parsear")
    testing.expect_value(t, rgb, u32(0x00ff00))
}

@(test)
test_color_hex3 :: proc(t: ^testing.T) {
    rgb, ok := parse_color("#fff")
    testing.expect(t, ok, "#fff deve parsear")
    testing.expect_value(t, rgb, u32(0xffffff))
}

@(test)
test_color_rgb :: proc(t: ^testing.T) {
    rgb, ok := parse_color("rgb(255, 107, 53)")
    testing.expect(t, ok, "rgb() deve parsear")
    testing.expect_value(t, rgb, u32(0xff6b35))
}

@(test)
test_color_invalida :: proc(t: ^testing.T) {
    _, ok := parse_color("notacolor")
    testing.expect(t, !ok, "cor inválida não deve parsear")
}

// compara canais RGB com tolerância (conversões de espaço de cor arredondam)
@(private="file")
rgb_near :: proc(got, want: u32, tol: int = 3) -> bool {
    dr := abs(int(got >> 16 & 0xff) - int(want >> 16 & 0xff))
    dg := abs(int(got >> 8  & 0xff) - int(want >> 8  & 0xff))
    db := abs(int(got       & 0xff) - int(want       & 0xff))
    return dr <= tol && dg <= tol && db <= tol
}

@(test)
test_color_oklch_branco_preto :: proc(t: ^testing.T) {
    w, ok := parse_color("oklch(1 0 0)")
    testing.expect(t, ok, "oklch branco deve parsear")
    testing.expect(t, rgb_near(w, 0xffffff), "oklch(1 0 0) == branco")

    b, ok2 := parse_color("oklch(0 0 0)")
    testing.expect(t, ok2, "oklch preto deve parsear")
    testing.expect(t, rgb_near(b, 0x000000), "oklch(0 0 0) == preto")
}

@(test)
test_color_oklch_vermelho :: proc(t: ^testing.T) {
    // vermelho sRGB puro em OKLCH ≈ (0.6280, 0.2577, 29.23°)
    rgb, ok := parse_color("oklch(0.628 0.2577 29.23)")
    testing.expect(t, ok, "oklch deve parsear")
    testing.expect(t, rgb_near(rgb, 0xff0000), "oklch vermelho == #ff0000")
}

@(test)
test_color_oklch_tailwind :: proc(t: ^testing.T) {
    // blue-500 do Tailwind v4 (fora do gamut sRGB): o gamut mapping do CSS
    // Color 4 produz #2b7fff — igual ao fallback que o Chrome renderiza.
    rgb, ok := parse_color("oklch(62.3% 0.214 259.815)")
    testing.expect(t, ok, "oklch com L em % deve parsear")
    testing.expect(t, rgb_near(rgb, 0x2b7fff), "oklch blue-500 == #2b7fff (gamut-mapped)")
}

@(test)
test_color_oklch_fora_do_gamut :: proc(t: ^testing.T) {
    // green-500 e rose-500 do Tailwind v4, ambos fora do gamut sRGB
    // (valores de referência: implementação float64 do algoritmo da spec)
    g, ok1 := parse_color("oklch(0.723 0.219 149.579)")
    testing.expect(t, ok1 && rgb_near(g, 0x00c951), "green-500 == #00c951")
    r, ok2 := parse_color("oklch(0.645 0.246 16.439)")
    testing.expect(t, ok2 && rgb_near(r, 0xff2056), "rose-500 == #ff2056")
}

@(test)
test_color_oklch_alpha :: proc(t: ^testing.T) {
    rgb, ok := parse_color("oklch(1 0 0 / 0.5)")
    testing.expect(t, ok, "oklch com alpha deve parsear")
    testing.expect_value(t, rgb >> 24, u32(128)) // 0.5*255+0.5 = 128
}

@(test)
test_color_function_a98rgb :: proc(t: ^testing.T) {
    // color(a98-rgb ...) do WPT css-color/a98rgb-001: verde sRGB #008000.
    rgb, ok := parse_color("color(a98-rgb 0.281363 0.498012 0.116746)")
    testing.expect(t, ok, "color(a98-rgb) deve parsear")
    testing.expect(t, rgb_near(rgb, 0x008000, 2), "a98-rgb verde == #008000")
}

@(test)
test_color_function_srgb :: proc(t: ^testing.T) {
    // srgb: componentes já gamma-encodados 0..1 → bytes diretos.
    rgb, ok := parse_color("color(srgb 1 0.5 0)")
    testing.expect(t, ok, "color(srgb) deve parsear")
    testing.expect(t, rgb_near(rgb, 0xff8000, 2), "srgb 1 0.5 0 == #ff8000")
    // 100% também aceito
    w, okw := parse_color("color(srgb 100% 100% 100%)")
    testing.expect(t, okw && rgb_near(w, 0xffffff), "srgb 100% == branco")
}

@(test)
test_color_function_srgb_linear :: proc(t: ^testing.T) {
    // srgb-linear: 0.5 linear → ~188 sRGB (0.5^(1/2.4)*1.055-0.055).
    rgb, ok := parse_color("color(srgb-linear 0.5 0.5 0.5)")
    testing.expect(t, ok, "color(srgb-linear) deve parsear")
    testing.expect(t, rgb_near(rgb, 0xbcbcbc, 2), "srgb-linear 0.5 == ~#bcbcbc")
}

@(test)
test_color_function_display_p3 :: proc(t: ^testing.T) {
    // p3 branco → sRGB branco; p3 verde puro → verde sRGB clampado (fora do gamut).
    w, okw := parse_color("color(display-p3 1 1 1)")
    testing.expect(t, okw && rgb_near(w, 0xffffff), "p3 branco == branco sRGB")
    // p3(0 0 0) preto
    b, okb := parse_color("color(display-p3 0 0 0)")
    testing.expect(t, okb && rgb_near(b, 0x000000), "p3 preto == preto")
}

@(test)
test_color_function_xyz_e_desconhecido :: proc(t: ^testing.T) {
    // xyz do branco D65 = (0.9505, 1.0, 1.089) → sRGB branco.
    w, okw := parse_color("color(xyz 0.9505 1.0 1.089)")
    testing.expect(t, okw && rgb_near(w, 0xffffff, 2), "xyz branco D65 == branco")
    // alpha
    a, oka := parse_color("color(srgb 0 0 0 / 0.5)")
    testing.expect(t, oka)
    testing.expect_value(t, a >> 24, u32(128))
    // espaço desconhecido → ok=false (cascata mantém anterior)
    _, ok := parse_color("color(foobar-rgb 1 0 0)")
    testing.expect(t, !ok, "espaço desconhecido não parseia")
}

@(test)
test_color_lab :: proc(t: ^testing.T) {
    // WPT a98rgb-004: lab(83.2141% -129.1072 87.1718) = verde puro #00ff00.
    g, ok := parse_color("lab(83.2141% -129.1072 87.1718)")
    testing.expect(t, ok, "lab() deve parsear")
    testing.expect(t, rgb_near(g, 0x00ff00, 3), "lab verde == #00ff00")
    // branco: lab(100% 0 0) == #ffffff; preto lab(0 0 0) == #000000
    w, okw := parse_color("lab(100% 0 0)")
    testing.expect(t, okw && rgb_near(w, 0xffffff, 2), "lab(100 0 0) == branco")
    bk, okb := parse_color("lab(0 0 0)")
    testing.expect(t, okb && rgb_near(bk, 0x000000, 2), "lab(0 0 0) == preto")
}

@(test)
test_color_lch :: proc(t: ^testing.T) {
    // lch com croma 0 = cinza neutro; L*53.39 ≈ #808080 (mesmo que lab(53.39 0 0)).
    gray, ok := parse_color("lch(53.39% 0 0)")
    testing.expect(t, ok, "lch() deve parsear")
    testing.expect(t, rgb_near(gray, 0x808080, 3), "lch croma 0 == cinza médio ~#808080")
}

@(test)
test_color_oklab :: proc(t: ^testing.T) {
    // cinza médio: oklab(0.5 0 0) → ~#636363
    rgb, ok := parse_color("oklab(0.5 0 0)")
    testing.expect(t, ok, "oklab deve parsear")
    testing.expect(t, rgb_near(rgb, 0x636363), "oklab(0.5 0 0) == cinza ~#636363")
}

// ── gradientes ───────────────────────────────────────────────────────────────

@(test)
test_strip_comments_token_boundary :: proc(t: ^testing.T) {
    // comentário entre tokens de PALAVRA vira separador (não funde)
    r1 := strip_comments("hsl(120/* c */75%/* c */50%)", context.temp_allocator)
    testing.expect(t, strings.contains(r1, "120 75%") && strings.contains(r1, "75% 50%"), "comentário separa tokens de valor")
    // comentário entre não-palavras NÃO insere espaço (seletor composto continua composto)
    r2 := strip_comments(".a/* c */.b", context.temp_allocator)
    testing.expect(t, r2 == ".a.b", "comentário entre '.' não vira descendente")
    // comentário adjacente a delimitador não insere espaço
    r3 := strip_comments("color:red/* c */;", context.temp_allocator)
    testing.expect(t, r3 == "color:red;", "comentário antes de ';' não insere espaço")
}

@(test)
test_hsl_comment_separado :: proc(t: ^testing.T) {
    // o bug que o WPT achou: hsl com comentários como único separador
    ref, ok1 := parse_color("hsl(120, 75%, 50%)")
    got, ok2 := parse_color(strip_comments("hsl(120/* c */75%/* c */50%)", context.temp_allocator))
    testing.expect(t, ok1 && ok2, "ambas parseiam")
    testing.expect_value(t, got, ref) // mesma cor verde
    // e via a cascata completa (parse do CSS já roda strip_comments). O alpha 1.0
    // gera 0xFF no byte alto (vs 0 implícito do hsl sem alpha), então compara só RGB.
    rules, _ := parse("#p{background-color:hsla(120/* x */75%/* x */50%/1.0)}")
    defer free_rules(&rules)
    v := rules[0].decls["background-color"]
    c, ok3 := parse_color(v)
    testing.expect(t, ok3 && (c & 0x00ffffff) == (ref & 0x00ffffff), "hsla com comentário e alpha = mesmo verde (RGB)")
}

@(test)
test_num_prefix_cientifico :: proc(t: ^testing.T) {
    // notação científica (1.2e2 = 120) — usada por refs do WPT
    ref, _  := parse_color("hsl(120, 75%, 50%)")
    sci, _  := parse_color("hsl(1.2e2, 75%, 50%)")
    testing.expect_value(t, sci & 0x00ffffff, ref & 0x00ffffff)
    // não deve comer o 'e' de unidades: "3em" continua 3 (não "3e"→0)
    testing.expect(t, abs(num_prefix("3em") - 3) < 0.001, "num_prefix('3em') = 3, não come o 'e'")
}

@(test)
test_hsl_hue_angulo :: proc(t: ^testing.T) {
    // matiz com unidade de ângulo deve converter p/ graus (bug achado pelo WPT)
    ref, _ := parse_color("hsl(120, 75%, 50%)")
    deg, _  := parse_color("hsl(120deg, 75%, 50%)")
    grad, _ := parse_color("hsl(133.33333333grad, 75%, 50%)")
    turn, _ := parse_color("hsl(0.33333333turn, 75%, 50%)")
    m :: proc(c: u32) -> u32 { return c & 0x00ffffff }
    testing.expect_value(t, m(deg), m(ref))
    testing.expect(t, abs(int(m(grad)) - int(m(ref))) < 0x020202, "grad ≈ mesmo verde")
    testing.expect(t, abs(int(m(turn)) - int(m(ref))) < 0x020202, "turn ≈ mesmo verde")
}

@(test)
test_color_mix_white_transparent :: proc(t: ^testing.T) {
    // Tailwind v4: cor branca com N% de alpha (o caso que quebrava o famososbr)
    c, ok := parse_color("color-mix(in oklab, #ffffff 90%, transparent)")
    testing.expect(t, ok, "color-mix parseia")
    testing.expect_value(t, c & 0x00ffffff, u32(0xffffff)) // RGB branco
    a := (c >> 24) & 0xff
    testing.expect(t, a >= 220 && a <= 235, "alpha ~90% (229)")
}

@(test)
test_color_mix_50_50 :: proc(t: ^testing.T) {
    // sem porcentagens = 50/50; vermelho + azul = roxo (128,0,128)
    c, ok := parse_color("color-mix(in srgb, red, blue)")
    testing.expect(t, ok, "color-mix 50/50 parseia")
    testing.expect(t, ((c >> 16) & 0xff) >= 126 && ((c >> 16) & 0xff) <= 130, "R ~128")
    testing.expect_value(t, (c >> 8) & 0xff, u32(0)) // G = 0
    testing.expect(t, (c & 0xff) >= 126 && (c & 0xff) <= 130, "B ~128")
}

@(test)
test_color_mix_low_alpha :: proc(t: ^testing.T) {
    // branco 10% → alpha baixo (texto sutil do Tailwind)
    c, ok := parse_color("color-mix(in oklab, white 10%, transparent)")
    testing.expect(t, ok, "parseia")
    a := (c >> 24) & 0xff
    testing.expect(t, a >= 20 && a <= 32, "alpha ~10% (25)")
    testing.expect_value(t, c & 0x00ffffff, u32(0xffffff)) // ainda branco
}

@(test)
test_grad_basico :: proc(t: ^testing.T) {
    g, ok := parse_gradient("linear-gradient(to right, red, blue)")
    testing.expect(t, ok, "gradiente deve parsear")
    testing.expect(t, g.active, "gradiente ativo")
    testing.expect(t, g.dir == .Right, "direção to right")
    testing.expect_value(t, g.n, 2)
    testing.expect_value(t, g.cols[0], u32(0xff0000))
    testing.expect_value(t, g.cols[1], u32(0x0000ff))
}

@(test)
test_grad_tres_cores :: proc(t: ^testing.T) {
    g, ok := parse_gradient("linear-gradient(135deg, #ff6b35 0%, #f7931e 50%, #fec601 100%)")
    testing.expect(t, ok, "gradiente 3 cores deve parsear")
    testing.expect_value(t, g.n, 3)
    testing.expect_value(t, g.cols[0], u32(0xff6b35))
    testing.expect_value(t, g.cols[2], u32(0xfec601))
}

@(test)
test_grad_uma_cor_falha :: proc(t: ^testing.T) {
    _, ok := parse_gradient("linear-gradient(red)")
    testing.expect(t, !ok, "gradiente com 1 cor não deve parsear")
}

@(test)
test_grad_angulo_diagonal :: proc(t: ^testing.T) {
    // 135deg é diagonal: guarda o ângulo real e marca diagonal (não faz snap)
    g, ok := parse_gradient("linear-gradient(135deg, red, blue)")
    testing.expect(t, ok && g.active, "gradiente parseia")
    testing.expect(t, g.diagonal, "135deg é diagonal")
    testing.expect(t, abs(g.angle - 135) < 0.01, "ângulo real preservado (135)")
}

@(test)
test_grad_angulo_axial :: proc(t: ^testing.T) {
    // eixos exatos NÃO são diagonais (usam o caminho rápido)
    g1, _ := parse_gradient("linear-gradient(to right, red, blue)")
    testing.expect(t, !g1.diagonal && g1.dir == .Right, "to right = axial Right")
    g2, _ := parse_gradient("linear-gradient(180deg, red, blue)")
    testing.expect(t, !g2.diagonal && g2.dir == .Bottom, "180deg = axial Bottom")
    g3, _ := parse_gradient("linear-gradient(to top left, red, blue)")
    testing.expect(t, g3.diagonal && abs(g3.angle - 315) < 0.01, "to top left = 315 diagonal")
}

@(test)
test_grad_angulo_normaliza :: proc(t: ^testing.T) {
    // ângulos negativos e >360 normalizam p/ [0,360)
    g, ok := parse_gradient("linear-gradient(-90deg, red, blue)")
    testing.expect(t, ok && abs(g.angle - 270) < 0.01 && g.dir == .Left, "-90deg → 270 (to left)")
}

@(test)
test_grad_radial_simples :: proc(t: ^testing.T) {
    g, ok := parse_gradient("radial-gradient(red, blue)")
    testing.expect(t, ok && g.active && g.radial, "radial sem prelúdio parseia")
    testing.expect_value(t, g.n, 2)
    testing.expect_value(t, g.cols[0], u32(0xff0000))
    testing.expect_value(t, g.cols[1], u32(0x0000ff))
}

@(test)
test_grad_radial_prelude :: proc(t: ^testing.T) {
    // prelúdio (forma/posição) é descartado; os stops entram normais
    g, ok := parse_gradient("radial-gradient(circle at center, #fff 0%, #000 100%)")
    testing.expect(t, ok && g.radial, "radial com prelúdio parseia")
    testing.expect_value(t, g.n, 2)
    testing.expect_value(t, g.cols[0], u32(0xffffff))
    testing.expect_value(t, g.cols[1], u32(0x000000))
}

@(test)
test_grad_radial_uma_cor_falha :: proc(t: ^testing.T) {
    _, ok := parse_gradient("radial-gradient(ellipse farthest-side, red)")
    testing.expect(t, !ok, "radial com 1 cor não parseia")
}

@(test)
test_grad_conic_simples :: proc(t: ^testing.T) {
    g, ok := parse_gradient("conic-gradient(red, blue)")
    testing.expect(t, ok && g.active && g.conic, "conic sem prelúdio parseia")
    testing.expect(t, !g.radial && !g.diagonal, "conic não é radial nem diagonal")
    testing.expect_value(t, g.n, 2)
    testing.expect_value(t, g.cols[0], u32(0xff0000))
}

@(test)
test_grad_conic_stops_angulares :: proc(t: ^testing.T) {
    // stops em graus viram fração do giro; 'from' guardado em angle
    g, ok := parse_gradient("conic-gradient(from 90deg, red 0deg, lime 90deg, blue 180deg)")
    testing.expect(t, ok && g.conic, "conic com from+stops parseia")
    testing.expect(t, abs(g.angle - 90) < 0.01, "from 90deg")
    testing.expect_value(t, g.n, 3)
    testing.expect(t, g.pos_set[1] && abs(g.pos[1] - 0.25) < 0.001, "90deg = 0.25 do giro")
    testing.expect(t, abs(g.pos[2] - 0.5) < 0.001, "180deg = 0.5 do giro")
}

@(test)
test_grad_conic_stops_percent :: proc(t: ^testing.T) {
    g, ok := parse_gradient("conic-gradient(#fff 25%, #000 75%)")
    testing.expect(t, ok && g.conic, "conic com % parseia")
    testing.expect(t, abs(g.pos[0] - 0.25) < 0.001 && abs(g.pos[1] - 0.75) < 0.001, "% vira fração")
}

// ── repeating-*-gradient + stops em px ────────────────────────────────────────

@(test)
test_grad_repeating_linear :: proc(t: ^testing.T) {
    g, ok := parse_gradient("repeating-linear-gradient(45deg, #000 0, #000 10px, #fff 10px, #fff 20px)")
    testing.expect(t, ok && g.active, "repeating-linear parseia")
    testing.expect(t, g.repeating, "flag repeating ligada")
    testing.expect_value(t, g.n, 4)
    // padrão de faixas em px: posições guardadas como VALOR px, marcadas pos_px
    testing.expect(t, g.pos_px[1] && abs(g.pos[1] - 10) < 0.001, "10px guardado cru")
    testing.expect(t, g.pos_px[3] && abs(g.pos[3] - 20) < 0.001, "20px guardado cru")
    testing.expect(t, g.pos_px[0] && abs(g.pos[0]) < 0.001, "0 sem unidade = 0px")
}

@(test)
test_grad_repeating_percent :: proc(t: ^testing.T) {
    g, ok := parse_gradient("repeating-linear-gradient(#f00, #f00 10%, #00f 10%, #00f 20%)")
    testing.expect(t, ok && g.repeating, "repeating com % parseia")
    testing.expect(t, !g.pos_px[1] && abs(g.pos[1] - 0.1) < 0.001, "10% = fração 0.1")
}

@(test)
test_grad_repeating_radial :: proc(t: ^testing.T) {
    g, ok := parse_gradient("repeating-radial-gradient(circle, #fff 0, #000 8px, #fff 16px)")
    testing.expect(t, ok && g.radial && g.repeating, "repeating-radial parseia")
    testing.expect(t, g.pos_px[1] && abs(g.pos[1] - 8) < 0.001, "8px cru")
}

@(test)
test_grad_repeating_conic :: proc(t: ^testing.T) {
    g, ok := parse_gradient("repeating-conic-gradient(red 0deg, blue 30deg)")
    testing.expect(t, ok && g.conic && g.repeating, "repeating-conic parseia")
    testing.expect(t, abs(g.pos[1] - (30.0/360.0)) < 0.001, "30deg = fração do giro")
}

@(test)
test_grad_nao_repeating :: proc(t: ^testing.T) {
    g, ok := parse_gradient("linear-gradient(to right, red, blue)")
    testing.expect(t, ok && !g.repeating, "gradiente normal não é repeating")
}

@(test)
test_grad_double_position :: proc(t: ^testing.T) {
    // sintaxe canônica de faixas: "cor A B" = a mesma cor de A a B (2 stops = hard-stop)
    g, ok := parse_gradient("repeating-linear-gradient(45deg, #333 0 12px, #777 12px 24px)")
    testing.expect(t, ok && g.repeating, "faixas com dupla posição parseiam")
    testing.expect_value(t, g.n, 4) // #333@0, #333@12, #777@12, #777@24
    testing.expect(t, g.pos_px[0] && abs(g.pos[0]) < 0.001, "stop0 = 0px")
    testing.expect(t, g.pos_px[1] && abs(g.pos[1] - 12) < 0.001, "stop1 = 12px")
    testing.expect(t, g.cols[0] == g.cols[1], "dupla posição = mesma cor nos 2 stops")
    testing.expect(t, g.pos_px[3] && abs(g.pos[3] - 24) < 0.001, "stop3 = 24px")
}

@(test)
test_grad_double_position_percent :: proc(t: ^testing.T) {
    g, ok := parse_gradient("repeating-linear-gradient(red 0 25%, blue 25% 50%)")
    testing.expect(t, ok && g.n == 4, "dupla posição em %")
    testing.expect(t, !g.pos_px[1] && abs(g.pos[1] - 0.25) < 0.001, "25% = fração 0.25")
}

@(test)
test_grad_stop_px_normal :: proc(t: ^testing.T) {
    // px também é válido em gradiente não-repeating
    g, ok := parse_gradient("linear-gradient(to right, red 0, blue 50px)")
    testing.expect(t, ok, "stops em px num linear normal parseiam")
    testing.expect(t, g.pos_px[1] && abs(g.pos[1] - 50) < 0.001, "50px cru")
}

// ── color interpolation hints ────────────────────────────────────────────────

@(test)
test_grad_hint_linear_percent :: proc(t: ^testing.T) {
    // posição solitária entre 2 stops = hint (não é stop): n continua 2
    g, ok := parse_gradient("linear-gradient(red, 30%, blue)")
    testing.expect(t, ok && g.active, "linear com hint parseia")
    testing.expect_value(t, g.n, 2)
    testing.expect(t, g.hint_set[0] && !g.hint_px[0] && abs(g.hint_pos[0] - 0.3) < 0.001, "hint 30% no segmento 0")
    testing.expect(t, g.cols[0] == 0xff0000 && g.cols[1] == 0x0000ff, "cores certas (hint não virou stop)")
}

@(test)
test_grad_hint_linear_px :: proc(t: ^testing.T) {
    g, ok := parse_gradient("linear-gradient(to right, red, 40px, blue)")
    testing.expect(t, ok && g.n == 2, "hint px não conta como stop")
    testing.expect(t, g.hint_set[0] && g.hint_px[0] && abs(g.hint_pos[0] - 40) < 0.001, "hint 40px cru")
}

@(test)
test_grad_hint_conic :: proc(t: ^testing.T) {
    g, ok := parse_gradient("conic-gradient(red, 90deg, blue)")
    testing.expect(t, ok && g.conic && g.n == 2, "conic com hint angular")
    testing.expect(t, g.hint_set[0] && abs(g.hint_pos[0] - 0.25) < 0.001, "hint 90deg = 0.25 do giro")
}

@(test)
test_grad_hint_multi :: proc(t: ^testing.T) {
    // hint em cada um dos 2 segmentos de um gradiente de 3 cores
    g, ok := parse_gradient("linear-gradient(red, 20%, lime, 70%, blue)")
    testing.expect(t, ok && g.n == 3, "3 stops + 2 hints")
    testing.expect(t, g.hint_set[0] && abs(g.hint_pos[0] - 0.2) < 0.001, "hint seg 0 = 20%")
    testing.expect(t, g.hint_set[1] && abs(g.hint_pos[1] - 0.7) < 0.001, "hint seg 1 = 70%")
}

@(test)
test_grad_no_hint :: proc(t: ^testing.T) {
    g, _ := parse_gradient("linear-gradient(red, blue)")
    testing.expect(t, !g.hint_set[0], "sem hint = flag off")
}

// ── calc() em ângulos de gradiente ───────────────────────────────────────────

@(test)
test_grad_conic_calc_stop :: proc(t: ^testing.T) {
    // calc() misturando ângulo e %: em conic 100% = 360deg = 1 giro.
    g, ok := parse_gradient("conic-gradient(lime calc(90deg + 0%), blue 0)")
    testing.expect(t, ok && g.conic, "conic com calc() no stop parseia")
    testing.expect(t, g.pos_set[0] && abs(g.pos[0] - 0.25) < 0.001, "calc(90deg+0%) = 0.25 do giro")
}

@(test)
test_grad_conic_calc_angle_percent :: proc(t: ^testing.T) {
    g, ok := parse_gradient("conic-gradient(lime calc(0deg + 100%), blue)")
    testing.expect(t, ok, "conic calc angle+percent parseia")
    testing.expect(t, abs(g.pos[0] - 1.0) < 0.001, "calc(0deg + 100%) = 1.0 (360deg)")
}

@(test)
test_grad_conic_calc_from :: proc(t: ^testing.T) {
    // 'from calc(...)' com espaços internos DEVE sobreviver ao tokenizador
    g, ok := parse_gradient("conic-gradient(from calc(45deg + 45deg), red, blue)")
    testing.expect(t, ok && g.conic, "conic from calc() parseia")
    testing.expect(t, abs(g.angle - 90) < 0.01, "from calc(45deg+45deg) = 90deg")
}

@(test)
test_grad_conic_calc_turn :: proc(t: ^testing.T) {
    g, ok := parse_gradient("conic-gradient(red calc(0.25turn), blue)")
    testing.expect(t, ok && abs(g.pos[0] - 0.25) < 0.001, "calc(0.25turn) = 0.25 do giro")
}

@(test)
test_grad_linear_calc_angle :: proc(t: ^testing.T) {
    // direção do linear como calc() → eixo axial (180deg = to bottom)
    g, ok := parse_gradient("linear-gradient(calc(90deg + 90deg), red, blue)")
    testing.expect(t, ok, "linear com direção calc() parseia")
    testing.expect(t, abs(g.angle - 180) < 0.01, "calc(90deg+90deg) = 180deg")
    testing.expect(t, g.dir == .Bottom, "180deg → eixo Bottom")
}

@(test)
test_grad_conic_calc_nested :: proc(t: ^testing.T) {
    // parênteses aninhados + multiplicação
    g, ok := parse_gradient("conic-gradient(red calc((0.5turn) / 2), blue)")
    testing.expect(t, ok && abs(g.pos[0] - 0.25) < 0.001, "calc((0.5turn)/2) = 0.25")
}

// ── @layer / @supports (transparência) ───────────────────────────────────────

@(test)
test_layer_transparente :: proc(t: ^testing.T) {
    // Tailwind v4 envolve TODAS as regras em @layer — precisam ser processadas.
    rules, _ := parse("@layer base { p { color: red } }")
    defer free_rules(&rules)
    found := false
    for r in rules {
        if v, ok := r.decls["color"]; ok && v == "red" do found = true
    }
    testing.expect(t, found, "regra dentro de @layer deve ser coletada")
}

@(test)
test_layer_aninhado :: proc(t: ^testing.T) {
    rules, _ := parse("@layer a { @layer b { div { display: flex } } }")
    defer free_rules(&rules)
    found := false
    for r in rules {
        if v, ok := r.decls["display"]; ok && v == "flex" do found = true
    }
    testing.expect(t, found, "regra em @layer aninhado deve ser coletada")
}

// @supports deixou de ser transparente (a condição é AVALIADA — supports.odin
// e supports_test.odin). Este teste continua valendo como o caso VERDADEIRO:
// nos testes do pacote css o hook do motor é nil ⇒ permissivo, e `display` é
// conhecida no motor real de qualquer forma.
@(test)
test_supports_condicao_verdadeira_entra :: proc(t: ^testing.T) {
    rules, _ := parse("@supports (display: grid) { div { display: grid } }")
    defer free_rules(&rules)
    found := false
    for r in rules {
        if v, ok := r.decls["display"]; ok && v == "grid" do found = true
    }
    testing.expect(t, found, "regra em @supports deve ser coletada")
}

// ── seletores só-pseudo não podem casar com tudo ────────────────────────────────

@(test)
test_pseudo_solto_nao_casa_tudo :: proc(t: ^testing.T) {
    // ::-webkit-datetime-edit{display:inline-flex} do reset do Tailwind casaria
    // com TODO elemento (compound vazio) e viraria a página inteira flex.
    rules, _ := parse("::-webkit-datetime-edit{display:inline-flex}")
    defer free_rules(&rules)
    testing.expect(t, len(rules) == 1, "regra parseada")
    c := rules[0].selectors[0].parts[0]
    testing.expect(t, !compound_matches(c, "div",  []string{}, ""), "pseudo solto nao casa div")
    testing.expect(t, !compound_matches(c, "body", []string{}, ""), "pseudo solto nao casa body")
}

@(test)
test_root_casa_html :: proc(t: ^testing.T) {
    rules, _ := parse(":root{--primary:#fff}")
    defer free_rules(&rules)
    c := rules[0].selectors[0].parts[0]
    testing.expect(t, compound_matches(c, "html", []string{}, ""),  ":root casa html")
    testing.expect(t, !compound_matches(c, "div", []string{}, ""),  ":root nao casa div")
}

@(test)
test_media_minificado_sem_espaco :: proc(t: ^testing.T) {
    // CSS minificado cola a condição na keyword: `@media(min-width:64rem)`. Sem
    // parar a keyword no '(', a keyword virava "media(min-width:64rem)", kw=="media"
    // falhava e o bloco @media INTEIRO era pulado (regressão famososbr: os
    // utilitários responsivos sm:/lg: sumiam → grid ficava com menos colunas).
    rules, _ := parse("@media(min-width:64rem){.x{color:red}}")
    defer free_rules(&rules)
    found := false
    for &r in rules {
        if v, ok := r.decls["color"]; ok && v == "red" {
            found = true
            testing.expect(t, r.media_min > 1000 && r.media_min < 1100, "media_min ~1024px (64rem)")
        }
    }
    testing.expect(t, found, "regra dentro de @media(...) minificado é parseada")
}

@(test)
test_selector_classe_escapada :: proc(t: ^testing.T) {
    // Tailwind escapa `:` `/` em classes utilitárias: `.lg\:grid-cols-4` deve casar
    // a classe LITERAL `lg:grid-cols-4` do DOM. Guardamos o nome DESESCAPADO — sem
    // isto o parser parava no `:` e a classe virava `lg\` (+ pseudo bogus) → sem match.
    rules, _ := parse(".lg\\:grid-cols-4{display:grid}")
    defer free_rules(&rules)
    testing.expect(t, len(rules) == 1, "1 regra")
    c := rules[0].selectors[0].parts[0]
    testing.expect(t, len(c.classes) == 1 && c.classes[0] == "lg:grid-cols-4", "classe desescapada")
    testing.expect(t, compound_matches(c, "div", []string{"lg:grid-cols-4"}, ""), "casa a classe literal do DOM")
    testing.expect(t, !compound_matches(c, "div", []string{"lg"}, ""), "nao casa fragmento parcial")
}

@(test)
test_seletor_normal_ainda_casa :: proc(t: ^testing.T) {
    rules, _ := parse(".card{color:red}")
    defer free_rules(&rules)
    c := rules[0].selectors[0].parts[0]
    testing.expect(t, compound_matches(c, "div", []string{"card"}, ""), ".card casa div.card")
    testing.expect(t, !compound_matches(c, "div", []string{}, ""),      ".card nao casa div puro")
}

// ── seletores de atributo ───────────────────────────────────────────────────────

// atributos de teste como mapa temp
@(private="file")
tattrs :: proc(pairs: ..string) -> map[string]string {
    m := make(map[string]string, context.temp_allocator)
    for i := 0; i + 1 < len(pairs); i += 2 do m[pairs[i]] = pairs[i + 1]
    return m
}

@(test)
test_attr_equals :: proc(t: ^testing.T) {
    rules, _ := parse(`input[type="text"]{color:red}`)
    defer free_rules(&rules)
    testing.expect(t, len(rules) == 1, "regra parseada")
    c := rules[0].selectors[0].parts[0]
    testing.expect(t, compound_matches(c, "input", {}, "", tattrs("type", "text")),
        `input[type="text"] casa input type=text`)
    testing.expect(t, !compound_matches(c, "input", {}, "", tattrs("type", "password")),
        "nao casa type=password")
    testing.expect(t, !compound_matches(c, "input", {}, "", tattrs()),
        "nao casa sem o atributo")
}

@(test)
test_attr_exists :: proc(t: ^testing.T) {
    rules, _ := parse("[hidden]{display:none}")
    defer free_rules(&rules)
    c := rules[0].selectors[0].parts[0]
    testing.expect(t, compound_matches(c, "div", {}, "", tattrs("hidden", "")),
        "[hidden] casa com o atributo presente (mesmo vazio)")
    testing.expect(t, !compound_matches(c, "div", {}, "", tattrs()),
        "[hidden] nao casa sem o atributo")
}

@(test)
test_attr_operadores :: proc(t: ^testing.T) {
    rules, _ := parse(`a[href^="https"]{} a[href$=".pdf"]{} a[href*="docs"]{} p[lang|="pt"]{} div[class~="b"]{}`)
    defer free_rules(&rules)
    testing.expect(t, len(rules) == 5, "5 regras parseadas")
    pre := rules[0].selectors[0].parts[0]
    testing.expect(t, compound_matches(pre, "a", {}, "", tattrs("href", "https://x.com")), "^= prefixo")
    testing.expect(t, !compound_matches(pre, "a", {}, "", tattrs("href", "http://x.com")), "^= rejeita")
    suf := rules[1].selectors[0].parts[0]
    testing.expect(t, compound_matches(suf, "a", {}, "", tattrs("href", "/m.pdf")), "$= sufixo")
    sub := rules[2].selectors[0].parts[0]
    testing.expect(t, compound_matches(sub, "a", {}, "", tattrs("href", "/docs/x")), "*= contém")
    dash := rules[3].selectors[0].parts[0]
    testing.expect(t, compound_matches(dash, "p", {}, "", tattrs("lang", "pt-BR")), "|= pt-BR")
    testing.expect(t, compound_matches(dash, "p", {}, "", tattrs("lang", "pt")), "|= pt exato")
    testing.expect(t, !compound_matches(dash, "p", {}, "", tattrs("lang", "ptx")), "|= rejeita ptx")
    inc := rules[4].selectors[0].parts[0]
    testing.expect(t, compound_matches(inc, "div", {}, "", tattrs("class", "a b c")), "~= palavra")
    testing.expect(t, !compound_matches(inc, "div", {}, "", tattrs("class", "ab")), "~= rejeita substring")
}

@(test)
test_attr_espaco_no_valor :: proc(t: ^testing.T) {
    // espaço dentro de [..] não pode separar compostos do seletor
    rules, _ := parse(`div[title="a b"]{color:red}`)
    defer free_rules(&rules)
    testing.expect(t, len(rules) == 1, "regra parseada")
    sel := rules[0].selectors[0]
    testing.expect(t, len(sel.parts) == 1, "um único composto")
    c := sel.parts[0]
    testing.expect(t, compound_matches(c, "div", {}, "", tattrs("title", "a b")), "valor com espaço casa")
}

@(test)
test_attr_especificidade :: proc(t: ^testing.T) {
    // [attr] conta como classe (10); input[type=text] = 1 + 10
    rules, _ := parse("input[type=text]{color:red}")
    defer free_rules(&rules)
    testing.expect_value(t, rules[0].selectors[0].spec, 11)
}

@(test)
test_attr_flag_case :: proc(t: ^testing.T) {
    // flag " i" após o valor é removida (tratada como sensitive)
    rules, _ := parse(`a[href^="https" i]{color:red}`)
    defer free_rules(&rules)
    c := rules[0].selectors[0].parts[0]
    testing.expect(t, compound_matches(c, "a", {}, "", tattrs("href", "https://x.com")),
        "flag i não quebra o parse do valor")
}

// ── combinadores de irmão e pseudo-classes estruturais ──────────────────────────

@(test)
test_parse_combinadores_irmao :: proc(t: ^testing.T) {
    rules, _ := parse("h1 + p{color:red} h1 ~ p{color:blue}")
    defer free_rules(&rules)
    testing.expect(t, rules[0].selectors[0].combs[0] == .Adjacent, "+ vira Adjacent")
    testing.expect(t, !rules[0].selectors[0].loose, "+ não é mais aproximação (loose)")
    testing.expect(t, rules[1].selectors[0].combs[0] == .Sibling, "~ vira Sibling")
}

@(test)
test_parse_estruturais :: proc(t: ^testing.T) {
    rules, _ := parse("li:first-child{} li:nth-child(2n+1){} li:nth-child(odd){} tr:nth-child(-n + 3){} p:only-child{}")
    defer free_rules(&rules)
    testing.expect(t, len(rules) == 5, "5 regras parseadas")
    c0 := rules[0].selectors[0].parts[0]
    testing.expect(t, c0.nth_kind == .Child && c0.nth_a == 0 && c0.nth_b == 1, "first-child ≡ 0n+1")
    c1 := rules[1].selectors[0].parts[0]
    testing.expect(t, c1.nth_kind == .Child && c1.nth_a == 2 && c1.nth_b == 1, "nth-child(2n+1)")
    c2 := rules[2].selectors[0].parts[0]
    testing.expect(t, c2.nth_a == 2 && c2.nth_b == 1, "odd ≡ 2n+1")
    c3 := rules[3].selectors[0].parts[0]
    testing.expect(t, len(rules[3].selectors[0].parts) == 1, "espaço no An+B não fatia o seletor")
    testing.expect(t, c3.nth_a == -1 && c3.nth_b == 3, "-n + 3")
    testing.expect(t, rules[4].selectors[0].parts[0].nth_kind == .Only, "only-child")
    testing.expect_value(t, rules[0].selectors[0].spec, 11) // tag(1) + pseudo-classe(10)
}

@(test)
test_nth_matches_anb :: proc(t: ^testing.T) {
    testing.expect(t, nth_matches(0, 3, 3) && !nth_matches(0, 3, 4), "0n+3 = só o 3º")
    testing.expect(t, nth_matches(2, 1, 1) && nth_matches(2, 1, 3) && !nth_matches(2, 1, 2), "odd")
    testing.expect(t, nth_matches(2, 0, 2) && !nth_matches(2, 0, 3), "even")
    testing.expect(t, nth_matches(-1, 3, 1) && nth_matches(-1, 3, 3) && !nth_matches(-1, 3, 4), "-n+3 = três primeiros")
    testing.expect(t, nth_matches(3, 1, 4) && !nth_matches(3, 1, 3), "3n+1")
}

// ── pseudos de estado de formulário ──────────────────────────────────────────────

@(test)
test_ui_state_checked_disabled :: proc(t: ^testing.T) {
    rules, _ := parse("input:checked{} input:disabled{} input:enabled{}")
    defer free_rules(&rules)
    chk := rules[0].selectors[0].parts[0]
    testing.expect(t, .Checked in chk.ui_states, ":checked marcado")
    testing.expect(t, compound_matches(chk, "input", {}, "", tattrs("checked", "")), "casa input[checked]")
    testing.expect(t, !compound_matches(chk, "input", {}, "", tattrs()), "não casa input sem checked")
    dis := rules[1].selectors[0].parts[0]
    testing.expect(t, compound_matches(dis, "input", {}, "", tattrs("disabled", "")), ":disabled casa")
    en := rules[2].selectors[0].parts[0]
    testing.expect(t, compound_matches(en, "input", {}, "", tattrs()), ":enabled casa sem disabled")
    testing.expect(t, !compound_matches(en, "input", {}, "", tattrs("disabled", "")), ":enabled não casa disabled")
}

@(test)
test_ui_state_readonly_required :: proc(t: ^testing.T) {
    rules, _ := parse("input:read-only{} input:required{} input:optional{}")
    defer free_rules(&rules)
    ro := rules[0].selectors[0].parts[0]
    testing.expect(t, compound_matches(ro, "input", {}, "", tattrs("readonly", "")), ":read-only casa")
    req := rules[1].selectors[0].parts[0]
    testing.expect(t, compound_matches(req, "input", {}, "", tattrs("required", "")), ":required casa")
    opt := rules[2].selectors[0].parts[0]
    testing.expect(t, !compound_matches(opt, "input", {}, "", tattrs("required", "")), ":optional não casa required")
    // especificidade: input(1) + :checked(10) = 11
    r2, _ := parse("input:checked{}")
    defer free_rules(&r2)
    testing.expect_value(t, r2[0].selectors[0].spec, 11)
}

// ── :not() ───────────────────────────────────────────────────────────────────

@(test)
test_parse_not :: proc(t: ^testing.T) {
    rules, _ := parse(".x:not(.y){} li:not([hidden], .skip){} a:not(:hover){}")
    defer free_rules(&rules)
    c0 := rules[0].selectors[0].parts[0]
    testing.expect(t, len(c0.nots) == 1 && len(c0.nots[0].parts[0].classes) == 1, ":not(.y) guarda o seletor negado")
    testing.expect_value(t, rules[0].selectors[0].spec, 20) // .x (10) + :not(.y) (10)
    c1 := rules[1].selectors[0].parts[0]
    testing.expect(t, len(c1.nots) == 2, ":not(a, b) com lista guarda os dois")
    c2 := rules[2].selectors[0].parts[0]
    testing.expect(t, len(c2.nots) == 0, ":not(:hover) não suportado é ignorado (regra fica ativa)")
}

@(test)
test_parse_dir :: proc(t: ^testing.T) {
    // ltr/rtl válidos; espaços em volta do argumento ignorados; argumentos
    // inválidos (desconhecido, vazio, múltiplo) → Never (casa nada).
    rules, _ := parse("div:dir(ltr){} div:dir(rtl){} div:dir( ltr ){} div:dir(foopy){} div:dir(){} div:dir(ltr, rtl){}")
    defer free_rules(&rules)
    testing.expect_value(t, rules[0].selectors[0].parts[0].dir_req, Dir_Req.Ltr)
    testing.expect_value(t, rules[1].selectors[0].parts[0].dir_req, Dir_Req.Rtl)
    testing.expect_value(t, rules[2].selectors[0].parts[0].dir_req, Dir_Req.Ltr) // whitespace trim
    testing.expect_value(t, rules[3].selectors[0].parts[0].dir_req, Dir_Req.Never) // :dir(foopy)
    testing.expect_value(t, rules[4].selectors[0].parts[0].dir_req, Dir_Req.Never) // :dir()
    testing.expect_value(t, rules[5].selectors[0].parts[0].dir_req, Dir_Req.Never) // :dir(ltr, rtl)
    // :not(:dir(ltr)) guarda a negação (não é descartada como "insegura")
    r2, _ := parse(":not(:dir(ltr)) + div{}")
    defer free_rules(&r2)
    c := r2[0].selectors[0].parts[0]
    testing.expect(t, len(c.nots) == 1 && c.nots[0].parts[0].dir_req == .Ltr, ":not(:dir(ltr)) preservado")
}

@(test)
test_not_complexo :: proc(t: ^testing.T) {
    // :not() com seletor complexo (combinador) agora é suportado
    rules, _ := parse(".x:not(.a > .b){color:red}")
    defer free_rules(&rules)
    c := rules[0].selectors[0].parts[0]
    testing.expect(t, len(c.nots) == 1, ":not(complexo) guardado")
    testing.expect(t, len(c.nots[0].parts) == 2 && c.nots[0].combs[0] == .Child, ".a > .b")
}

// ── :has() ───────────────────────────────────────────────────────────────────────

@(test)
test_parse_has :: proc(t: ^testing.T) {
    rules, _ := parse("div:has(.x){} li:has(> img){} h2:has(+ p){} a:has(~ .y){}")
    defer free_rules(&rules)
    c0 := rules[0].selectors[0].parts[0]
    testing.expect(t, len(c0.has) == 1 && c0.has[0].lead == .Descendant, ":has(.x) descendente")
    c1 := rules[1].selectors[0].parts[0]
    testing.expect(t, c1.has[0].lead == .Child, ":has(> img) filho")
    c2 := rules[2].selectors[0].parts[0]
    testing.expect(t, c2.has[0].lead == .Adjacent, ":has(+ p) irmão adjacente")
    c3 := rules[3].selectors[0].parts[0]
    testing.expect(t, c3.has[0].lead == .Sibling, ":has(~ .y) irmão geral")
    // especificidade: div(1) + :has(.x)(10) = 11
    testing.expect_value(t, rules[0].selectors[0].spec, 11)
}

// ── :is() / :where() ────────────────────────────────────────────────────────────

@(test)
test_parse_is_where :: proc(t: ^testing.T) {
    rules, _ := parse(":is(.a, #b){} :where(.a, .b){} h1:is(.x){} :is(:hover){} :is(div p){}")
    defer free_rules(&rules)
    c0 := rules[0].selectors[0].parts[0]
    testing.expect(t, len(c0.ors) == 2, ":is(.a, #b) guarda os dois compostos")
    testing.expect_value(t, rules[0].selectors[0].spec, 100) // máx(.a=10, #b=100)
    testing.expect_value(t, rules[1].selectors[0].spec, 0)   // :where não pontua
    testing.expect(t, len(rules[1].selectors[0].parts[0].ors) == 2, ":where guarda os compostos")
    testing.expect_value(t, rules[2].selectors[0].spec, 11)  // h1(1) + :is(.x)(10)
    testing.expect(t, len(rules[3].selectors[0].parts[0].ors) == 0, ":is(:hover) sem restrição vira não-resolvido")
    // :is(div p) é um seletor complexo AGORA suportado → guarda 1 seletor de 2 partes
    c4 := rules[4].selectors[0].parts[0]
    testing.expect(t, len(c4.ors) == 1 && len(c4.ors[0].parts) == 2, ":is(div p) resolve como seletor complexo")
}

@(test)
test_where_complexo_resolve :: proc(t: ^testing.T) {
    // :where(.divide-y > :not(:last-child)) do Tailwind é um seletor complexo
    // avaliável → guarda o seletor (não é pseudo_only nem is_unresolved).
    rules, _ := parse(":where(.divide-y > :not(:last-child)){border-bottom:1px solid red}")
    defer free_rules(&rules)
    c := rules[0].selectors[0].parts[0]
    testing.expect(t, !c.is_unresolved && !c.pseudo_only, ":where(complexo) resolve")
    testing.expect(t, len(c.ors) == 1, "guarda 1 seletor")
    sel := c.ors[0]
    testing.expect(t, len(sel.parts) == 2 && sel.combs[0] == .Child, ".divide-y > alvo")
    testing.expect(t, len(sel.parts[1].nots) == 1, "alvo é :not(:last-child)")
    testing.expect_value(t, rules[0].selectors[0].spec, 0) // :where não pontua
    // argumento trivial (:where(:hover)) sem restrição → casa nada
    rules2, _ := parse(":where(:hover){color:red}")
    defer free_rules(&rules2)
    c2 := rules2[0].selectors[0].parts[0]
    testing.expect(t, c2.is_unresolved && c2.pseudo_only, ":where(:hover) solto casa nada")
}

@(test)
test_is_vazio_casa_nada :: proc(t: ^testing.T) {
    // `:is()`/`:where()` VAZIO é válido (forgiving-selector-list) e casa NADA.
    // O CSS minificado do github.com emitia `:is(){position:absolute;...}` (a lista
    // sumiu na purga); sem tratar isso, o composto ficava universal-vazio e casava
    // html/body/todo elemento → position:absolute na página inteira, page_h=0.
    rules, _ := parse(":is(){position:absolute} :where(){color:red}")
    defer free_rules(&rules)
    ci := rules[0].selectors[0].parts[0]
    testing.expect(t, ci.is_unresolved && ci.pseudo_only, ":is() vazio casa nada")
    testing.expect(t, !compound_matches(ci, "html", []string{}, ""), ":is() vazio NAO casa html")
    testing.expect(t, !compound_matches(ci, "body", []string{}, ""), ":is() vazio NAO casa body")
    testing.expect(t, !compound_matches(ci, "div",  []string{"x"}, "id"), ":is() vazio NAO casa div")
    cw := rules[1].selectors[0].parts[0]
    testing.expect(t, cw.is_unresolved && cw.pseudo_only, ":where() vazio casa nada")
}

@(test)
test_seletores_degenerados :: proc(t: ^testing.T) {
    // Rede ESTRUTURAL da classe "composto degenerado casa a página inteira".
    // Cada string é um seletor que NÃO pode aplicar suas declarações a um elemento
    // arbitrário: ou o parser o rejeita (nenhuma regra), ou o composto-alvo casa
    // NADA (pseudo_only). Nasce do bug do `:is()` vazio do github.com (M90) — um
    // composto sem restrição casava html/body/tudo → position:absolute na página
    // inteira → layout colapsado (page_h=0). O CSS minificado de sites reais emite
    // essas formas como artefato de purga/minificação; testamos a classe toda, não
    // um caso por vez. (Todas estas formas produzem seletor de 1 composto, então o
    // composto-alvo = o seletor inteiro.)
    degenerados := []string{
        ":is()",       // :is() vazio (o bug real do github)
        ":where()",    // :where() vazio
        ":is(  )",     // só espaço dentro
        ":where(,)",   // membros vazios (só vírgula)
        ":not()",      // :not() vazio
        ":not(,)",     // :not() com vírgula solta
        "[]",          // seletor de atributo vazio
        "::selection",          // pseudo-elemento que não renderizamos
        "::-webkit-scrollbar",  // pseudo-elemento vendor
        ":is(:hover)",          // :is() de argumento não restritivo
        ":where(:focus)",
    }
    // {tag, classe, id} de elementos comuns que JAMAIS podem ser casados por eles.
    plain := [?][3]string{
        {"html", "", ""}, {"body", "", ""}, {"div", "wrapper", "app"}, {"span", "x", ""},
    }
    for sel_src in degenerados {
        css := strings.concatenate({sel_src, "{position:absolute}"}, context.temp_allocator)
        rules, _ := parse(css)
        defer free_rules(&rules)
        for &r in rules {
            for &sel in r.selectors {
                if len(sel.parts) == 0 do continue
                tgt := sel.parts[len(sel.parts) - 1] // alvo = composto à direita
                for el in plain {
                    classes := el[1] != "" ? []string{el[1]} : []string{}
                    matched := compound_matches(tgt, el[0], classes, el[2])
                    testing.expectf(t, !matched, "seletor degenerado %q casou <%s> (deveria casar NADA)", sel_src, el[0])
                }
            }
        }
    }
    // Assimetria PROPOSITAL: `::before`/`::after` "soltos" DEVEM casar todo elemento
    // (só geram caixa se tiverem `content`) — não são degenerados. Guarda contra uma
    // "correção" excessiva que passasse a marcá-los pseudo_only.
    rb, _ := parse("::before{content:\"x\"}")
    defer free_rules(&rb)
    cb := rb[0].selectors[0].parts[0]
    testing.expect(t, compound_matches(cb, "div", []string{}, ""), "::before solto casa todo elemento (por design)")

    // `::placeholder` ENTROU nesta lista no M218 (antes era degenerado): passou a ter
    // Pseudo_Kind próprio, então o composto casa o elemento e quem impede o
    // vazamento p/ o estilo do <input> é o ROTEAMENTO POR PASSE do collect_decls
    // (`tp == want`), igual a ::before/::after. A garantia de não-vazamento tem teste
    // próprio em `src/ui/style_m218_test.odin`.
    rp, _ := parse("::placeholder{opacity:0}")
    defer free_rules(&rp)
    cp := rp[0].selectors[0].parts[0]
    testing.expect(t, compound_matches(cp, "input", []string{}, ""), "::placeholder solto casa o elemento (o passe é que filtra)")
    testing.expect(t, cp.pseudo == .Placeholder, "e o alvo é o pseudo Placeholder, não Other")
}

// ── CSS nesting ─────────────────────────────────────────────────────────────────

// acha a 1ª regra cujo mapa de declarações contém prop=val
@(private="file")
find_rule :: proc(rules: []Rule, prop, val: string) -> (Rule, bool) {
    for r in rules {
        if v, ok := r.decls[prop]; ok && v == val do return r, true
    }
    return {}, false
}

@(test)
test_nesting_descendente :: proc(t: ^testing.T) {
    rules, _ := parse(".card { color: red; .title { font-weight: bold } }")
    defer free_rules(&rules)
    pai, ok1 := find_rule(rules[:], "color", "red")
    testing.expect(t, ok1, "regra do pai emitida com as declarações próprias")
    testing.expect(t, len(pai.selectors[0].parts) == 1, ".card é um composto")
    filho, ok2 := find_rule(rules[:], "font-weight", "bold")
    testing.expect(t, ok2, "regra aninhada emitida")
    testing.expect(t, len(filho.selectors[0].parts) == 2, ".card .title = dois compostos")
    testing.expect(t, pai.order < filho.order, "declarações do pai vêm antes na cascata")
}

@(test)
test_nesting_ampersand :: proc(t: ^testing.T) {
    rules, _ := parse(".btn { &.primary { color: blue } &:hover { color: red } }")
    defer free_rules(&rules)
    comb, ok := find_rule(rules[:], "color", "blue")
    testing.expect(t, ok, "&.primary emitida")
    c := comb.selectors[0].parts[0]
    testing.expect(t, len(comb.selectors[0].parts) == 1 && len(c.classes) == 2,
        "&.primary = um composto .btn.primary")
    hov, ok2 := find_rule(rules[:], "color", "red")
    testing.expect(t, ok2 && hov.selectors[0].parts[0].state == .Hover, "&:hover vira .btn:hover")
}

@(test)
test_nesting_combinador_e_lista :: proc(t: ^testing.T) {
    rules, _ := parse("a, b { > .x { color: red } }")
    defer free_rules(&rules)
    r, ok := find_rule(rules[:], "color", "red")
    testing.expect(t, ok, "regra aninhada emitida")
    testing.expect(t, len(r.selectors) == 2, "lista do pai expande (a > .x, b > .x)")
    testing.expect(t, len(r.selectors[0].combs) == 1 && r.selectors[0].combs[0] == .Child,
        "> .x vira combinador filho")
}

@(test)
test_nesting_media_aninhada :: proc(t: ^testing.T) {
    rules, _ := parse(".card { color: red; @media (min-width: 600px) { color: blue } }")
    defer free_rules(&rules)
    base, ok1 := find_rule(rules[:], "color", "red")
    testing.expect(t, ok1 && base.media_min < 0, "regra base sem condição de media")
    cond, ok2 := find_rule(rules[:], "color", "blue")
    testing.expect(t, ok2 && cond.media_min == 600, "@media aninhado herda o seletor e ganha a condição")
}

@(test)
test_prefers_color_scheme :: proc(t: ^testing.T) {
    rules, _ := parse(
        "body { color: black }" +
        "@media (prefers-color-scheme: dark) { body { color: white } }" +
        "@media (prefers-color-scheme: light) { body { color: navy } }")
    defer free_rules(&rules)
    base, _  := find_rule(rules[:], "color", "black")
    dark, _  := find_rule(rules[:], "color", "white")
    light, _ := find_rule(rules[:], "color", "navy")
    testing.expect(t, base.media_scheme == .Any,  "regra base é indiferente ao esquema")
    testing.expect(t, dark.media_scheme == .Dark,  "bloco dark marcado como Dark")
    testing.expect(t, light.media_scheme == .Light, "bloco light marcado como Light")
    // matching por esquema
    testing.expect(t, media_matches(base, 800, 720, true) && media_matches(base, 800, 720, false), "base casa nos dois esquemas")
    testing.expect(t, media_matches(dark, 800, 720, true)  && !media_matches(dark, 800, 720, false),  "dark só no escuro")
    testing.expect(t, media_matches(light, 800, 720, false) && !media_matches(light, 800, 720, true),  "light só no claro")
}

@(test)
test_media_aspect_ratio :: proc(t: ^testing.T) {
    // viewport 800x600 → razão 1.333.
    r1, _ := parse("@media (min-aspect-ratio: 59/79) { a { color: red } }")
    defer free_rules(&r1)
    rr, _ := find_rule(r1[:], "color", "red")
    testing.expect(t, media_matches(rr, 800, 600), "1.333 >= 0.747 casa")
    testing.expect(t, !media_matches(rr, 600, 900), "0.667 < 0.747 reprova") // 600/900=0.667
    // max-aspect-ratio
    r2, _ := parse("@media (max-aspect-ratio: 1280/720) { a { color: red } }")
    defer free_rules(&r2)
    rr2, _ := find_rule(r2[:], "color", "red")
    testing.expect(t, media_matches(rr2, 800, 600), "1.333 <= 1.778 casa")
    testing.expect(t, !media_matches(rr2, 800, 400), "2.0 > 1.778 reprova")
    // 0/0 → 1/0 = +Inf: min nunca casa (razão finita), max sempre casa
    rmin, _ := parse("@media (min-aspect-ratio: 0/0) { a { color: red } }")
    defer free_rules(&rmin)
    rrmin, _ := find_rule(rmin[:], "color", "red")
    testing.expect(t, !media_matches(rrmin, 800, 600), "min 0/0 (=inf) não casa")
    rmax, _ := parse("@media (max-aspect-ratio: 0/0) { a { color: red } }")
    defer free_rules(&rmax)
    rrmax, _ := find_rule(rmax[:], "color", "red")
    testing.expect(t, media_matches(rrmax, 800, 600), "max 0/0 (=inf) sempre casa")
    // razão de número único (sem /) e device-aspect-ratio
    r3, _ := parse("@media (min-device-aspect-ratio: 0.2) { a { color: red } }")
    defer free_rules(&r3)
    rr3, _ := find_rule(r3[:], "color", "red")
    testing.expect(t, media_matches(rr3, 800, 600), "1.333 >= 0.2 casa (num único)")
}

@(test)
test_media_type :: proc(t: ^testing.T) {
    // Tipo de mídia + `not` + <general-enclosed> (lógica de 3 valores da MQ4).
    // Somos "screen": all/screen casam; print/tipo-desconhecido não.
    applies :: proc(css: string) -> bool {
        rules, _ := parse(css)
        defer free_rules(&rules)
        rr, ok := find_rule(rules[:], "color", "red")
        if !ok do return false
        return media_matches(rr, 800, 600)
    }
    testing.expect(t,  applies("@media all { a { color: red } }"),            "all casa")
    testing.expect(t,  applies("@media screen { a { color: red } }"),         "screen casa")
    testing.expect(t, !applies("@media print { a { color: red } }"),          "print não casa (somos screen)")
    testing.expect(t, !applies("@media unknown { a { color: red } }"),        "tipo desconhecido não casa")
    testing.expect(t, !applies("@media not all { a { color: red } }"),        "not all não casa")
    testing.expect(t,  applies("@media not unknown { a { color: red } }"),    "not <tipo-desconhecido> casa")
    testing.expect(t,  applies("@media not print { a { color: red } }"),      "not print casa (somos screen)")
    // <general-enclosed>: feature desconhecida = U; not U = U; ambos NÃO aplicam.
    testing.expect(t, !applies("@media (unknown) { a { color: red } }"),      "(feature-desconhecida) não casa")
    testing.expect(t, !applies("@media not (unknown) { a { color: red } }"),  "not (feature-desconhecida) tb não casa (U)")
    // features conhecidas seguem funcionando (não regride)
    testing.expect(t,  applies("@media (min-width: 100px) { a { color: red } }"), "min-width conhecida casa a 800")
    testing.expect(t,  applies("@media all and (min-width: 100px) { a { color: red } }"), "all and feature casa")
}

// As strings de um Rule (tag, id, nome/valor de seletor de atributo, cq_name)
// eram FATIAS do `src` que o parse deixa na arena TEMP (strip_comments). Isso
// fazia as rules morrerem no primeiro free_all(context.temp_allocator) — e era a
// razão de o restyle_tab ter de RE-PARSEAR a folha inteira a cada mutação do
// DOM / zoom / tick de timer em vez de cachear as rules.
//
// Este teste LÊ as strings DEPOIS de matar a arena temp: na versão antiga ele lê
// memória liberada (falha ou devolve lixo). É o que prova que a posse foi
// corrigida — sem ele, a mudança seria indistinguível de não ter feito nada.
@(test)
test_posse_seletores_sobrevive_free_all_temp :: proc(t: ^testing.T) {
    css := `div#hero.card[data-k="v"] { color: red }
            @container sidebar (min-width: 100px) { .x { color: blue } }
            :root { color: green }`
    rules, kf := parse(css)
    defer free_rules(&rules)
    defer free_keyframes(&kf)

    free_all(context.temp_allocator) // mata a arena onde o `src` do parse vivia

    testing.expectf(t, len(rules) == 3, "esperava 3 regras, veio %d", len(rules))
    if len(rules) < 3 do return
    c := rules[0].selectors[0].parts[0]
    testing.expectf(t, c.tag == "div",  "tag deveria sobreviver ao free_all, veio %q", c.tag)
    testing.expectf(t, c.id  == "hero", "id deveria sobreviver, veio %q", c.id)
    testing.expect(t, len(c.classes) == 1 && c.classes[0] == "card", "classe deveria sobreviver")
    testing.expect(t, len(c.attrs) == 1, "seletor de atributo deveria existir")
    if len(c.attrs) == 1 {
        testing.expectf(t, c.attrs[0].name == "data-k" && c.attrs[0].val == "v",
            "nome/valor do atributo deveriam sobreviver, veio %q=%q", c.attrs[0].name, c.attrs[0].val)
    }
    testing.expectf(t, rules[1].cq_name == "sidebar", "cq_name deveria sobreviver, veio %q", rules[1].cq_name)
    // `:root` vira tag "html": um LITERAL, que precisou ser clonado também —
    // senão o free_rules tentaria liberar memória estática.
    testing.expect(t, rules[2].selectors[0].parts[0].tag == "html", ":root deveria virar tag html (owned)")
}

@(test)
test_container_query :: proc(t: ^testing.T) {
    // @container era descartado inteiro (skip_at_rule) → regras perdidas. Depois
    // passou a reusar a máquina de @media, avaliando contra o VIEWPORT (proxy).
    // Agora a condição vive em campos PRÓPRIOS (cq_*) e quem avalia é o ui
    // (container_matches, contra a largura MEDIDA do contêiner) — com fallback p/
    // o viewport enquanto não houver medida. Aqui testamos só o PARSING.
    // O Rule devolvido FATIA o `rules` que o parse alocou (e desde a correção de
    // posse, cq_name é uma string OWNED dele) — então guardamos os donos e só
    // liberamos no fim, depois da última leitura. Antes este era o único teste do
    // pacote que vazava tudo o que o parse alocava.
    owners: [dynamic][dynamic]Rule
    defer { for &rs in owners do free_rules(&rs); delete(owners) }
    rule_of :: proc(css: string, owners: ^[dynamic][dynamic]Rule) -> (Rule, bool) {
        rules, kf := parse(css)
        free_keyframes(&kf)
        append(owners, rules)
        rr, ok := find_rule(rules[:], "grid-column", "5")
        return rr, ok
    }
    r1, ok1 := rule_of("@container (min-width: 100px) { .toc { grid-column: 5 } }", &owners)
    testing.expect(t, ok1, "regra em @container é coletada (antes sumia)")
    testing.expect(t, r1.cq_active, "deveria ficar marcada como regra de @container")
    testing.expectf(t, r1.cq_min == 100, "cq_min esperado 100, veio %v", r1.cq_min)
    testing.expect(t, r1.cq_name == "", "sem nome no prelúdio → qualquer contêiner")
    // a condição NÃO pode mais virar @media: senão o viewport a filtraria cedo
    testing.expect(t, media_matches(r1, 50, 600), "condição de contêiner não é condição de MEDIA")

    r2, ok2 := rule_of("@container sidebar (min-width: 100px) { .toc { grid-column: 5 } }", &owners)
    testing.expect(t, ok2 && r2.cq_name == "sidebar", "nome do contêiner deveria ser guardado")

    r3, ok3 := rule_of("@container (max-width: 400px) { .toc { grid-column: 5 } }", &owners)
    testing.expectf(t, ok3 && r3.cq_max == 400, "cq_max esperado 400, veio %v", r3.cq_max)

    // só-nome, sem condição → casa sempre (sem limites)
    r4, ok4 := rule_of("@container layout { .toc { grid-column: 5 } }", &owners)
    testing.expect(t, ok4 && r4.cq_active && r4.cq_min < 0 && r4.cq_max < 0, "@container só-nome: sem limites")

    // inline-size é traduzido p/ width (o motor só consulta largura)
    r5, ok5 := rule_of("@container (min-inline-size: 300px) { .toc { grid-column: 5 } }", &owners)
    testing.expectf(t, ok5 && r5.cq_min == 300, "min-inline-size deveria virar min-width, veio %v", r5.cq_min)
}

@(test)
test_media_calc_len :: proc(t: ^testing.T) {
    // calc() em valor de media length: unidades absolutas e aritmética.
    v, ok := parse_media_len("calc(100in)")
    testing.expect(t, ok && abs(v - 9600) < 0.5, "calc(100in)=9600px (in≠px)")
    v, ok = parse_media_len("calc(1px - 1px)")
    testing.expect(t, ok && abs(v) < 0.001, "calc(1px - 1px)=0")
    v, ok = parse_media_len("calc(2 * (3px + 1px))")
    testing.expect(t, ok && abs(v - 8) < 0.001, "precedência com parênteses = 8")
    v, ok = parse_media_len("100in") // sem calc: unidade absoluta direta
    testing.expect(t, ok && abs(v - 9600) < 0.5, "100in=9600px")
    _, ok = parse_media_len("calc(1px +)") // malformado
    testing.expect(t, !ok, "calc malformado reprova")
}

@(test)
test_prefers_scheme_combinado_width :: proc(t: ^testing.T) {
    // prefers-color-scheme combinado com min-width numa mesma query
    rules, _ := parse("@media (min-width: 600px) and (prefers-color-scheme: dark) { a { color: red } }")
    defer free_rules(&rules)
    r, ok := find_rule(rules[:], "color", "red")
    testing.expect(t, ok && r.media_min == 600 && r.media_scheme == .Dark, "min-width e esquema combinam")
    testing.expect(t, media_matches(r, 800, 720, true),  "casa com largura e escuro")
    testing.expect(t, !media_matches(r, 500, 720, true), "largura insuficiente reprova")
    testing.expect(t, !media_matches(r, 800, 720, false), "esquema claro reprova")
}

@(test)
test_nesting_profundo :: proc(t: ^testing.T) {
    rules, _ := parse(".a { .b { .c { color: red } } }")
    defer free_rules(&rules)
    r, ok := find_rule(rules[:], "color", "red")
    testing.expect(t, ok, "aninhamento de 3 níveis")
    testing.expect(t, len(r.selectors[0].parts) == 3, ".a .b .c = três compostos")
}

@(test)
test_nesting_nao_quebra_plano :: proc(t: ^testing.T) {
    // CSS sem nesting continua idêntico (decls com url(); e regra vazia)
    rules, _ := parse(`.x { background: url(data:image/png;base64,AA==); color: red } .y {}`)
    defer free_rules(&rules)
    testing.expect(t, len(rules) == 2, "duas regras")
    _, tem := rules[0].decls["color"]
    testing.expect(t, tem, "decls planas intactas")
}

// ── var() ────────────────────────────────────────────────────────────────────

@(test)
test_resolve_var :: proc(t: ^testing.T) {
    props := make(map[string]string, context.temp_allocator)
    props["--x"] = "5px"
    out := resolve_vars("var(--x)", props)
    testing.expect_value(t, out, "5px")
}

@(test)
test_resolve_var_fallback :: proc(t: ^testing.T) {
    props := make(map[string]string, context.temp_allocator)
    out := resolve_vars("var(--missing, 10px)", props)
    testing.expect_value(t, out, "10px")
}

@(test)
test_resolve_var_em_calc :: proc(t: ^testing.T) {
    props := make(map[string]string, context.temp_allocator)
    props["--spacing"] = "8px"
    out := resolve_vars("calc(var(--spacing) * 4)", props)
    testing.expect_value(t, out, "calc(8px * 4)")
}

// ── declarações / custom props ───────────────────────────────────────────────

@(test)
test_decls_basico :: proc(t: ^testing.T) {
    d := parse_decls("color: red; width: 100px", context.temp_allocator)
    testing.expect_value(t, d["color"], "red")
    testing.expect_value(t, d["width"], "100px")
}

@(test)
test_decls_data_uri :: proc(t: ^testing.T) {
    // ';' e ':' dentro de url(data:...) não podem quebrar a declaração
    d := parse_decls(`background: url(data:image/svg+xml;charset=utf-8,<svg xmlns="http://x"/>); color: red`, context.temp_allocator)
    testing.expect_value(t, d["background"], `url(data:image/svg+xml;charset=utf-8,<svg xmlns="http://x"/>)`)
    testing.expect_value(t, d["color"], "red")
    _, lixo := d["charset=utf-8,<svg xmlns"]
    testing.expect(t, !lixo, "nenhuma propriedade lixo vazou")
}

@(test)
test_decls_url_http :: proc(t: ^testing.T) {
    // o ':' de http:// está dentro de url() → não separa prop/valor
    d := parse_decls("background: url(http://example.com/a.png) no-repeat", context.temp_allocator)
    testing.expect_value(t, d["background"], "url(http://example.com/a.png) no-repeat")
}

// ── !important ───────────────────────────────────────────────────────────────

@(test)
test_important_basico :: proc(t: ^testing.T) {
    v, imp := split_important("red !important")
    testing.expect(t, imp, "!important deve ser detectado")
    testing.expect_value(t, v, "red")
}

@(test)
test_important_variantes :: proc(t: ^testing.T) {
    // sem espaço antes do '!', espaço depois do '!', case misto
    v, imp := split_important("red!important")
    testing.expect(t, imp, "red!important deve ser detectado")
    testing.expect_value(t, v, "red")

    v, imp = split_important("10px ! IMPORTANT")
    testing.expect(t, imp, "'! IMPORTANT' deve ser detectado")
    testing.expect_value(t, v, "10px")
}

@(test)
test_important_ausente :: proc(t: ^testing.T) {
    v, imp := split_important("red")
    testing.expect(t, !imp, "valor sem !important")
    testing.expect_value(t, v, "red")

    // "important" sem '!' não é a flag
    v, imp = split_important("very important")
    testing.expect(t, !imp, "'important' sem '!' não é a flag")
    testing.expect_value(t, v, "very important")
}

@(test)
test_decls_preserva_case_custom :: proc(t: ^testing.T) {
    // custom props são case-sensitive; props normais viram minúsculas
    d := parse_decls("--myVar: 5px; COLOR: RED", context.temp_allocator)
    _, tem_custom := d["--myVar"]
    testing.expect(t, tem_custom, "--myVar deve preservar o case")
    _, tem_color := d["color"]
    testing.expect(t, tem_color, "COLOR deve virar minúsculo")
}
