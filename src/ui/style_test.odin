package ui

// Testes do motor de estilo: CSS -> Computed.
// Rodar:  odin test src/ui  (a partir da raiz do projeto)
//
// Cobrem o parsing de comprimentos (parse_len: calc/vw/vh/%/rem/em),
// font-size, e o pipeline apply_decls (cores, flex, overflow, var(), etc).

import "core:testing"
import "core:math"
import "core:strings"
import csspkg "../css"
import dompkg "../dom"
import htmlp  "../html"

// tolerância p/ comparação de floats
@(private="file")
near :: proc(a, b: f32, eps: f32 = 0.01) -> bool {
    return math.abs(a - b) <= eps
}

// ── parse_len ────────────────────────────────────────────────────────────────

@(test)
test_len_px :: proc(t: ^testing.T) {
    px, pct, ok := test_parse_len("100px")
    testing.expect(t, ok,  "100px deve parsear")
    testing.expect(t, !pct, "100px não é porcentagem")
    testing.expect(t, near(px, 100), "100px == 100")
}

@(test)
test_len_zero :: proc(t: ^testing.T) {
    px, _, ok := test_parse_len("0")
    testing.expect(t, ok, "0 deve parsear")
    testing.expect(t, near(px, 0), "0 == 0")
}

@(test)
test_len_percent :: proc(t: ^testing.T) {
    px, pct, ok := test_parse_len("50%")
    testing.expect(t, ok,  "50% deve parsear")
    testing.expect(t, pct, "50% é porcentagem")
    testing.expect(t, near(px, 0.5), "50% == fração 0.5")
}

@(test)
test_len_rem :: proc(t: ^testing.T) {
    px, _, ok := test_parse_len("2rem")
    testing.expect(t, ok, "2rem deve parsear")
    testing.expect(t, near(px, 32), "2rem == 32px (16*2)")
}

@(test)
test_len_em :: proc(t: ^testing.T) {
    px, _, ok := test_parse_len("1.5em", 20)
    testing.expect(t, ok, "1.5em deve parsear")
    testing.expect(t, near(px, 30), "1.5em com fs=20 == 30")
}

@(test)
test_len_vw :: proc(t: ^testing.T) {
    px, _, ok := test_parse_len("10vw")
    testing.expect(t, ok, "10vw deve parsear")
    testing.expect(t, near(px, 128), "10vw == 128 (10% de 1280)")
}

@(test)
test_len_ex :: proc(t: ^testing.T) {
    // ex ≈ 0.5em → padding:0.7ex 1.4ex do menu do sqlite.org deixa de virar 0.
    px, _, ok := test_parse_len("1.4ex", 20)
    testing.expect(t, ok, "1.4ex deve parsear")
    testing.expect(t, near(px, 14), "1.4ex com fs=20 == 14 (0.5em)")
}

@(test)
test_len_ch_nao_suportado :: proc(t: ^testing.T) {
    // ch fica de fora de propósito (casa mal com reftests de font-size-adjust).
    _, _, ok := test_parse_len("2ch", 16)
    testing.expect(t, !ok, "2ch NÃO deve parsear (ch fora de escopo)")
}

@(test)
test_len_vmin_vmax :: proc(t: ^testing.T) {
    a, _, ok1 := test_parse_len("10vmin", 16, 1280, 720)
    testing.expect(t, ok1 && near(a, 72), "10vmin == 72 (10% de min(1280,720))")
    b, _, ok2 := test_parse_len("10vmax", 16, 1280, 720)
    testing.expect(t, ok2 && near(b, 128), "10vmax == 128 (10% de max(1280,720))")
}

@(test)
test_len_vh :: proc(t: ^testing.T) {
    px, _, ok := test_parse_len("10vh")
    testing.expect(t, ok, "10vh deve parsear")
    testing.expect(t, near(px, 72), "10vh == 72 (10% de 720)")
}

@(test)
test_len_auto_falha :: proc(t: ^testing.T) {
    _, _, ok := test_parse_len("auto")
    testing.expect(t, !ok, "auto não deve parsear como comprimento")
}

// ── calc() ───────────────────────────────────────────────────────────────────

@(test)
test_calc_soma :: proc(t: ^testing.T) {
    px, _, ok := test_parse_len("calc(50px + 20px)")
    testing.expect(t, ok, "calc soma deve parsear")
    testing.expect(t, near(px, 70), "calc(50px + 20px) == 70")
}

@(test)
test_calc_sub :: proc(t: ^testing.T) {
    px, _, ok := test_parse_len("calc(100px - 30px)")
    testing.expect(t, ok, "calc sub deve parsear")
    testing.expect(t, near(px, 70), "calc(100px - 30px) == 70")
}

@(test)
test_calc_mult :: proc(t: ^testing.T) {
    px, _, ok := test_parse_len("calc(2 * 10px)")
    testing.expect(t, ok, "calc mult deve parsear")
    testing.expect(t, near(px, 20), "calc(2 * 10px) == 20")
}

@(test)
test_calc_div :: proc(t: ^testing.T) {
    px, _, ok := test_parse_len("calc(100px / 4)")
    testing.expect(t, ok, "calc div deve parsear")
    testing.expect(t, near(px, 25), "calc(100px / 4) == 25")
}

@(test)
test_calc_precedencia :: proc(t: ^testing.T) {
    // soma tem menor precedência: 10 + (2*5) = 20
    px, _, ok := test_parse_len("calc(10px + 2 * 5px)")
    testing.expect(t, ok, "calc com precedência deve parsear")
    testing.expect(t, near(px, 20), "calc(10px + 2 * 5px) == 20")
}

// ── font-size ────────────────────────────────────────────────────────────────

@(test)
test_fs_palavra :: proc(t: ^testing.T) {
    px, ok := test_parse_font_size("large")
    testing.expect(t, ok, "large deve parsear")
    testing.expect(t, near(px, 18), "large == 18")
}

@(test)
test_fs_rem :: proc(t: ^testing.T) {
    px, ok := test_parse_font_size("1.5rem")
    testing.expect(t, ok, "1.5rem deve parsear")
    testing.expect(t, near(px, 24), "1.5rem == 24")
}

@(test)
test_fs_calc :: proc(t: ^testing.T) {
    px, ok := test_parse_font_size("calc(1rem * 2)")
    testing.expect(t, ok, "calc font-size deve parsear")
    testing.expect(t, near(px, 32), "calc(1rem * 2) == 32")
}

// ── apply_decls (pipeline completo) ──────────────────────────────────────────

@(test)
test_apply_width_calc :: proc(t: ^testing.T) {
    c := test_apply("width: calc(50px + 20px)")
    testing.expect(t, c.has_width, "width deve estar definida")
    testing.expect(t, near(c.width, 70), "width == 70")
}

@(test)
test_apply_color :: proc(t: ^testing.T) {
    c := test_apply("color: red")
    testing.expect_value(t, c.color, u32(0xff0000))
}

@(test)
test_apply_color_hex :: proc(t: ^testing.T) {
    c := test_apply("color: #00ff00")
    testing.expect_value(t, c.color, u32(0x00ff00))
}

@(test)
test_apply_bg :: proc(t: ^testing.T) {
    c := test_apply("background-color: #123456")
    testing.expect(t, c.has_bg, "has_bg deve estar definido")
    testing.expect_value(t, c.bg, u32(0x123456))
}

@(test)
test_apply_display_flex :: proc(t: ^testing.T) {
    c := test_apply("display: flex")
    testing.expect(t, c.display_flex, "display:flex deve setar display_flex")
}

@(test)
test_apply_grid_template_areas :: proc(t: ^testing.T) {
    c := test_apply("grid-template-areas: 'h h' 's c'")
    testing.expect(t, c.grid_area_n == 3, "3 áreas: h, s, c")
    found_h, found_s, found_c: bool
    for i in 0 ..< c.grid_area_n {
        a := c.grid_areas[i]
        if a.name == "h" { found_h = true; testing.expect(t, a.col == 0 && a.col_span == 2 && a.row == 0 && a.row_span == 1, "h: col=0 span=2 row=0 span=1") }
        if a.name == "s" { found_s = true; testing.expect(t, a.col == 0 && a.col_span == 1 && a.row == 1 && a.row_span == 1, "s: col=0 span=1 row=1 span=1") }
        if a.name == "c" { found_c = true; testing.expect(t, a.col == 1 && a.col_span == 1 && a.row == 1 && a.row_span == 1, "c: col=1 span=1 row=1 span=1") }
    }
    testing.expect(t, found_h && found_s && found_c, "encontrou todas as áreas")
}

@(test)
test_apply_grid_area_name :: proc(t: ^testing.T) {
    c := test_apply("grid-area: sidebar")
    testing.expect(t, c.grid_area_name == "sidebar", "grid-area:sidebar armazena o nome")
}

@(test)
test_grid_template_shorthand_areas_rows_cols :: proc(t: ^testing.T) {
    c := test_apply("grid-template: 'h h' 50px 's c' 1fr / 100px 200px")
    testing.expect(t, c.grid_area_n == 3, "3 áreas via shorthand")
    testing.expect(t, c.grid_track_n == 2, "2 colunas")
    testing.expect(t, c.grid_row_track_n == 2, "2 linhas")
    testing.expect(t, near(c.grid_tracks[0].value, 100), "col 1 = 100px")
    testing.expect(t, near(c.grid_tracks[1].value, 200), "col 2 = 200px")
    testing.expect(t, near(c.grid_row_tracks[0].value, 50), "row 1 = 50px")
    testing.expect(t, c.grid_row_tracks[1].kind == .Fr, "row 2 = 1fr")
}

@(test)
test_grid_template_shorthand_rows_cols :: proc(t: ^testing.T) {
    c := test_apply("grid-template: auto 1fr / 200px 1fr")
    testing.expect(t, c.grid_area_n == 0, "sem áreas")
    testing.expect(t, c.grid_track_n == 2, "2 colunas")
    testing.expect(t, c.grid_row_track_n == 2, "2 linhas")
    testing.expect(t, c.grid_row_tracks[0].kind == .Auto, "row 1 = auto")
    testing.expect(t, c.grid_row_tracks[1].kind == .Fr, "row 2 = 1fr")
}

@(test)
test_grid_template_named_lines :: proc(t: ^testing.T) {
    // Nomes de linha [foo] NÃO são trilhas — antes cada um virava uma trilha
    // Auto fantasma (padrão MDN: 3 trilhas reais viravam 7, roubando largura).
    c := test_apply("grid-template-columns: [full-start] minmax(1rem, 1fr) [content-start] minmax(0, 800px) [content-end] minmax(1rem, 1fr) [full-end]")
    testing.expect(t, c.grid_track_n == 3, "3 trilhas (nomes de linha ignorados)")
    testing.expect(t, c.grid_tracks[0].kind == .Fr, "col 1 = fr (max de minmax)")
    testing.expect(t, near(c.grid_tracks[1].value, 800), "col 2 = 800px")
    testing.expect(t, c.grid_tracks[2].kind == .Fr, "col 3 = fr")
}

@(test)
test_grid_template_multi_name_bracket :: proc(t: ^testing.T) {
    // [a b] (múltiplos nomes num colchete) fica 1 token — senão "b]" viraria trilha.
    c := test_apply("grid-template-columns: [a b] 100px [c] 200px")
    testing.expect(t, c.grid_track_n == 2, "2 trilhas apesar de nomes múltiplos")
    testing.expect(t, near(c.grid_tracks[0].value, 100), "col 1 = 100px")
    testing.expect(t, near(c.grid_tracks[1].value, 200), "col 2 = 200px")
}

@(test)
test_grid_template_repeat_named :: proc(t: ^testing.T) {
    // repeat com nome de linha no padrão: [col] dentro não conta como trilha.
    c := test_apply("grid-template-columns: repeat(3, [col] 100px)")
    testing.expect(t, c.grid_track_n == 3, "repeat(3, [col] 100px) = 3 trilhas")
    testing.expect(t, near(c.grid_tracks[0].value, 100), "cada trilha = 100px")
    testing.expect(t, near(c.grid_tracks[2].value, 100), "3ª trilha = 100px")
}

@(test)
test_line_clamp :: proc(t: ^testing.T) {
    c := test_apply("-webkit-line-clamp: 3")
    testing.expect(t, c.line_clamp == 3, "-webkit-line-clamp: 3")
    c2 := test_apply("line-clamp: 2")
    testing.expect(t, c2.line_clamp == 2, "line-clamp: 2 (sem prefixo)")
    c3 := test_apply("-webkit-line-clamp: none")
    testing.expect(t, c3.line_clamp == 0, "none => 0")
    c4 := test_apply("color: red")
    testing.expect(t, c4.line_clamp == 0, "sem a prop => 0 (padrão)")
}

@(test)
test_grid_template_line_names :: proc(t: ^testing.T) {
    // Nomes de linha viram tabela no container (não trilhas). [b c] = 2 nomes na
    // mesma linha; nome após a última trilha refere a linha final.
    c := test_apply("grid-template-columns: [a] 100px [b c] 1fr [d]")
    testing.expect(t, c.grid_track_n == 2, "2 trilhas")
    testing.expect(t, c.grid_col_line_n == 4, "4 nomes de linha: a,b,c,d")
    // a@1, b@2, c@2, d@3
    got := map[string]int{}
    defer delete(got)
    for i in 0 ..< c.grid_col_line_n do got[c.grid_col_lines[i].name] = c.grid_col_lines[i].line
    testing.expect(t, got["a"] == 1, "a na linha 1")
    testing.expect(t, got["b"] == 2 && got["c"] == 2, "b,c na linha 2")
    testing.expect(t, got["d"] == 3, "d na linha 3")
}

@(test)
test_grid_column_name_capture :: proc(t: ^testing.T) {
    c := test_apply("grid-column: main-start / main-end")
    testing.expect(t, c.grid_col_start_name == "main-start", "captura nome de início")
    testing.expect(t, c.grid_col_end_name == "main-end", "captura nome de fim")
    c2 := test_apply("grid-column: content")
    testing.expect(t, c2.grid_col_start_name == "content", "nome único")
    testing.expect(t, c2.grid_col_end_name == "", "sem nome de fim")
}

@(test)
test_grid_named_placement_resolve :: proc(t: ^testing.T) {
    // Tabela de linhas MDN-like: sidebar-start@1, sidebar-end/main-start@2,
    // main-end/toc-start@3, toc-end@4.
    names := []string{"sidebar-start", "sidebar-end", "main-start", "main-end", "toc-start", "toc-end"}
    at    := []int{1, 2, 2, 3, 3, 4}
    // grid-column: main -> área implícita main-start/main-end -> col 2, span 1
    s, sp, ok := test_grid_resolve_named(names, at, "main", "")
    testing.expect(t, ok && s == 2 && sp == 1, "nome único 'main' resolve p/ col 2 span 1")
    // grid-column: sidebar-start / toc-end -> linha 1..4 -> col 1, span 3
    s2, sp2, ok2 := test_grid_resolve_named(names, at, "sidebar-start", "toc-end")
    testing.expect(t, ok2 && s2 == 1 && sp2 == 3, "start/end explícitos: col 1 span 3")
    // nome inexistente -> ok=false (cai p/ auto-place)
    _, _, ok3 := test_grid_resolve_named(names, at, "inexistente", "")
    testing.expect(t, !ok3, "nome ausente nao resolve")
}

@(test)
test_apply_border_collapse :: proc(t: ^testing.T) {
    c := test_apply("border-collapse: collapse")
    testing.expect(t, c.border_collapse, "border-collapse:collapse")
    c2 := test_apply("border-collapse: separate")
    testing.expect(t, !c2.border_collapse, "border-collapse:separate => false")
}

@(test)
test_apply_display_none :: proc(t: ^testing.T) {
    c := test_apply("display: none")
    testing.expect(t, c.display_none, "display:none deve setar display_none")
}

@(test)
test_will_change_cb :: proc(t: ^testing.T) {
    // position → só absolute
    pos := test_apply("will-change: position")
    testing.expect(t, pos.cb_abs && !pos.cb_fixed, "will-change:position cria CB só p/ absolute")
    // transform/filter/perspective/contain/offset-path → absolute E fixed
    tf := test_apply("will-change: transform")
    testing.expect(t, tf.cb_abs && tf.cb_fixed, "will-change:transform cria CB p/ absolute e fixed")
    fl := test_apply("will-change: filter")
    testing.expect(t, fl.cb_abs && fl.cb_fixed, "will-change:filter cria CB p/ absolute e fixed")
    // lista com múltiplos props
    multi := test_apply("will-change: opacity, contain")
    testing.expect(t, multi.cb_abs && multi.cb_fixed, "will-change:...,contain cria CB (ignora opacity)")
    // height (e outros que não criam CB) → nenhum
    h := test_apply("will-change: height")
    testing.expect(t, !h.cb_abs && !h.cb_fixed, "will-change:height NÃO cria CB")
    // ausente → nenhum
    none := test_apply("color: red")
    testing.expect(t, !none.cb_abs && !none.cb_fixed, "sem will-change não cria CB")
}

@(test)
test_apply_overflow :: proc(t: ^testing.T) {
    c := test_apply("overflow: hidden")
    testing.expect(t, c.overflow_hidden, "overflow:hidden deve setar overflow_hidden")
}

@(test)
test_overflow_por_eixo :: proc(t: ^testing.T) {
    // ⚠️ ATUALIZADO no M239. Este teste afirmava "overflow-y:hidden clipa SÓ o eixo
    // y" — e isso está errado: pela blockificação do css-overflow-3 §3.1 o eixo
    // `visible` vira `auto` quando o outro é hidden/scroll/auto, logo clipa também.
    // MEDIDO no Chrome headless (fixture com filho 300x150 numa caixa 120x50):
    // `overflow-x:hidden` corta o transbordo NOS DOIS eixos.
    // `clip` é a exceção da spec: não arrasta o outro eixo.
    cx := test_apply("overflow-x: clip")
    testing.expect(t, cx.ovf_clip_x && !cx.ovf_clip_y, "overflow-x:clip clipa só o eixo x (clip não blockifica)")
    cy := test_apply("overflow-y: hidden")
    testing.expect(t, cy.ovf_clip_x && cy.ovf_clip_y, "overflow-y:hidden → o x vira auto e clipa também")
    both := test_apply("overflow: clip")
    testing.expect(t, both.ovf_clip_x && both.ovf_clip_y, "overflow:clip clipa ambos os eixos")
    vis := test_apply("overflow-x: visible")
    testing.expect(t, !vis.ovf_clip_x && !vis.ovf_clip_y, "overflow-x:visible não clipa")
}

@(test)
test_apply_multicol :: proc(t: ^testing.T) {
    c := test_apply("column-count: 3")
    testing.expect_value(t, c.col_count, 3)
    cw := test_apply("column-width: 200px")
    testing.expect(t, near(cw.col_width, 200), "column-width:200")
    sh := test_apply("columns: 3 180px")
    testing.expect(t, sh.col_count == 3 && near(sh.col_width, 180), "shorthand columns count+width")
    sh2 := test_apply("columns: 200px auto")
    testing.expect(t, sh2.col_count == 0 && near(sh2.col_width, 200), "shorthand só width (auto ignorado)")
}

@(test)
test_apply_object_fit :: proc(t: ^testing.T) {
    c := test_apply("object-fit: cover")
    testing.expect(t, c.obj_fit == .Cover, "object-fit:cover")
}

@(test)
test_apply_font_weight :: proc(t: ^testing.T) {
    c := test_apply("font-weight: bold")
    testing.expect(t, c.weight == .Bold, "font-weight:bold deve setar bold")
    c2 := test_apply("font-weight: 700")
    testing.expect(t, c2.weight == .Bold, "font-weight:700 deve setar bold")
}

@(test)
test_apply_position :: proc(t: ^testing.T) {
    c := test_apply("position: absolute")
    testing.expect(t, c.position == .Absolute, "position:absolute")
}

@(test)
test_apply_border_radius :: proc(t: ^testing.T) {
    c := test_apply("border-radius: 12px")
    for i in 0 ..< 4 do testing.expect(t, near(c.border_radius[i], 12), "border-radius == 12 nos 4 cantos")
}

@(test)
test_border_radius_por_canto :: proc(t: ^testing.T) {
    // shorthand 2 valores: tl=br=10, tr=bl=4
    c := test_apply("border-radius: 10px 4px")
    testing.expect(t, near(c.border_radius[0], 10) && near(c.border_radius[2], 10), "tl/br = 10")
    testing.expect(t, near(c.border_radius[1], 4) && near(c.border_radius[3], 4), "tr/bl = 4")
    // longhand por canto
    c2 := test_apply("border-top-left-radius: 8px; border-bottom-right-radius: 3px")
    testing.expect(t, near(c2.border_radius[0], 8), "top-left = 8")
    testing.expect(t, near(c2.border_radius[2], 3), "bottom-right = 3")
    testing.expect(t, c2.border_radius[1] == 0 && c2.border_radius[3] == 0, "outros cantos = 0")
}

@(test)
test_border_por_lado :: proc(t: ^testing.T) {
    c := test_apply("border: 1px solid black; border-bottom-width: 5px")
    testing.expect(t, near(c.border_w[0], 1) && near(c.border_w[2], 5), "top=1, bottom=5")
    // border-bottom shorthand com cor própria
    c2 := test_apply("border-bottom: 2px solid red")
    testing.expect(t, near(c2.border_w[2], 2) && c2.border_c[2] == 0xff0000, "border-bottom cor/largura")
    testing.expect(t, c2.border_w[0] == 0, "top sem borda")
}

@(test)
test_border_style_none :: proc(t: ^testing.T) {
    // border-width sozinho + style none em um lado zera esse lado na pintura
    c := test_apply("border-width: 3px; border-top-style: none")
    testing.expect(t, c.border_style_none[0], "top marcado none")
    testing.expect(t, !c.border_style_none[2], "bottom não é none")
    // border shorthand none
    c2 := test_apply("border: 2px solid red; border-left: none")
    testing.expect(t, c2.border_style_none[3], "left none via shorthand")
}

@(test)
test_border_width_keywords :: proc(t: ^testing.T) {
    c := test_apply("border: thin solid black")
    testing.expect(t, near(c.border_w[0], 1), "thin = 1px")
    c2 := test_apply("border-width: medium")
    testing.expect(t, near(c2.border_w[0], 3), "medium = 3px")
}

@(test)
test_apply_margin :: proc(t: ^testing.T) {
    c := test_apply("margin: 10px 20px")
    testing.expect(t, near(c.margin[0], 10), "margin top == 10")
    testing.expect(t, near(c.margin[1], 20), "margin right == 20")
    testing.expect(t, near(c.margin[2], 10), "margin bottom == 10")
    testing.expect(t, near(c.margin[3], 20), "margin left == 20")
}

@(test)
test_apply_align_self :: proc(t: ^testing.T) {
    c := test_apply("align-self: flex-end")
    testing.expect(t, c.has_align_self, "has_align_self deve estar definido")
    testing.expect(t, c.align_self == .End, "align-self:flex-end == End")
    c2 := test_apply("align-self: auto")
    testing.expect(t, !c2.has_align_self, "align-self:auto nao marca has_align_self")
}

@(test)
test_apply_min_width :: proc(t: ^testing.T) {
    c := test_apply("min-width: 100px")
    testing.expect(t, c.has_minw, "has_minw deve estar definido")
    testing.expect(t, near(c.minw, 100), "min-width == 100")
}

@(test)
test_apply_min_height :: proc(t: ^testing.T) {
    c := test_apply("min-height: 80px")
    testing.expect(t, c.has_minh, "has_minh deve estar definido")
    testing.expect(t, near(c.minh, 80), "min-height == 80")
}

@(test)
test_apply_max_height :: proc(t: ^testing.T) {
    c := test_apply("max-height: 50px")
    testing.expect(t, c.has_maxh, "has_maxh deve estar definido")
    testing.expect(t, near(c.maxh, 50), "max-height == 50")
}

// ── var() (custom properties) ────────────────────────────────────────────────

@(test)
test_var_simples :: proc(t: ^testing.T) {
    c := test_apply("width: var(--w)", "--w: 50px")
    testing.expect(t, c.has_width, "width via var deve estar definida")
    testing.expect(t, near(c.width, 50), "var(--w) == 50px")
}

@(test)
test_var_em_calc :: proc(t: ^testing.T) {
    // padrão Tailwind v4: calc(var(--spacing) * 4)
    c := test_apply("height: calc(var(--spacing) * 4)", "--spacing: 8px")
    testing.expect(t, c.has_height, "height via calc+var deve estar definida")
    testing.expect(t, near(c.height, 32), "calc(var(--spacing) * 4) == 32")
}

@(test)
test_var_fallback :: proc(t: ^testing.T) {
    // sem a var definida, usa o fallback
    c := test_apply("width: var(--missing, 64px)")
    testing.expect(t, c.has_width, "width via fallback deve estar definida")
    testing.expect(t, near(c.width, 64), "var fallback == 64")
}

@(test)
test_var_color :: proc(t: ^testing.T) {
    c := test_apply("color: var(--primary)", "--primary: #ff6b35")
    testing.expect_value(t, c.color, u32(0xff6b35))
}

// var(--x) onde --x vale `initial` = valor garantido-inválido → usa o fallback.
// Padrão Tailwind v4 (`--tw-shadow-color: initial`). Sem o fix, o literal "initial"
// entrava na cor da sombra → sombra inválida → cards chapados.
@(test)
test_var_initial_usa_fallback :: proc(t: ^testing.T) {
    // fallback usado quando a var é `initial`
    ci := test_apply("box-shadow: 0 25px 50px -12px var(--tw-shadow-color, #00000040)", "--tw-shadow-color: initial")
    cd := test_apply("box-shadow: 0 25px 50px -12px #00000040")
    testing.expect(t, ci.shadow_n == 1, "sombra parseia com initial→fallback")
    testing.expect(t, ci.shadow_n == 1 && cd.shadow_n == 1 && ci.shadows[0].color == cd.shadows[0].color, "cor via fallback == cor literal direta")
    testing.expect(t, ci.shadow_n == 1 && near(ci.shadows[0].dy, 25) && near(ci.shadows[0].blur, 50) && near(ci.shadows[0].spread, -12), "geometria da sombra preservada")
    // var DEFINIDA (não-initial) → usa o valor definido, não o fallback
    cv := test_apply("color: var(--c, #ffffff)", "--c: #ff0000")
    testing.expect_value(t, cv.color, u32(0xff0000))
}

// A cadeia composta do Tailwind v4: box-shadow com 5 camadas por var, 4 delas
// `0 0 #0000` (default) + a real por último. Pular geometria-zero + MAX_SHADOWS≥5
// garantem que a sombra REAL sobreviva.
@(test)
test_box_shadow_tailwind_chain :: proc(t: ^testing.T) {
    vars := "--tw-inset-shadow: 0 0 #0000; --tw-inset-ring-shadow: 0 0 #0000; --tw-ring-offset-shadow: 0 0 #0000; --tw-ring-shadow: 0 0 #0000; --tw-shadow-color: initial; --tw-shadow: 0 25px 50px -12px var(--tw-shadow-color, #00000040)"
    c := test_apply("box-shadow: var(--tw-inset-shadow), var(--tw-inset-ring-shadow), var(--tw-ring-offset-shadow), var(--tw-ring-shadow), var(--tw-shadow)", vars)
    // as 4 camadas `0 0 #0000` são puladas; sobra 1 sombra REAL, visível
    testing.expect(t, c.shadow_n == 1, "cadeia Tailwind → 1 sombra visível (ruído-zero pulado)")
    testing.expect(t, c.shadow_n == 1 && near(c.shadows[0].dy, 25) && near(c.shadows[0].spread, -12), "sombra real da cadeia preservada")
}

// PONTA-A-PONTA pela pipeline real: os --tw-* precisam CHEGAR ao elemento — do
// seletor universal `*` (defaults) E da classe utilitária (override). Reproduz o
// Tailwind v4: `.shadow-2xl` sobrescreve --tw-shadow; box-shadow compõe a cadeia.
@(test)
test_box_shadow_tailwind_e2e :: proc(t: ^testing.T) {
    css := `* { --tw-shadow: 0 0 #0000; --tw-inset-shadow: 0 0 #0000; --tw-inset-ring-shadow: 0 0 #0000; --tw-ring-offset-shadow: 0 0 #0000; --tw-ring-shadow: 0 0 #0000; --tw-shadow-color: initial }
    .shadow-2xl { --tw-shadow: 0 25px 50px -12px var(--tw-shadow-color, #00000040); box-shadow: var(--tw-inset-shadow), var(--tw-inset-ring-shadow), var(--tw-ring-offset-shadow), var(--tw-ring-shadow), var(--tw-shadow) }`
    c := test_compute_one(css, "div", "shadow-2xl")
    testing.expect(t, c.shadow_n == 1, "e2e: --tw-* do * + classe chegam → 1 sombra visível")
    testing.expect(t, c.shadow_n == 1 && near(c.shadows[0].dy, 25), "e2e: sombra real (dy=25)")
}

// ── inset shorthand ───────────────────────────────────────────────────────────

@(test)
test_inset_1val :: proc(t: ^testing.T) {
    c := test_apply("position: absolute; inset: 0")
    testing.expect(t, c.inset_has[0] && c.inset_has[1] && c.inset_has[2] && c.inset_has[3], "inset:0 seta os 4 lados")
    testing.expect(t, near(c.inset[0], 0) && near(c.inset[2], 0), "top/bottom == 0")
}

@(test)
test_inset_2val :: proc(t: ^testing.T) {
    c := test_apply("position: absolute; inset: 10px 20px")
    testing.expect(t, near(c.inset[0], 10) && near(c.inset[2], 10), "top/bottom == 10")
    testing.expect(t, near(c.inset[1], 20) && near(c.inset[3], 20), "right/left == 20")
}

@(test)
test_inset_4val :: proc(t: ^testing.T) {
    c := test_apply("position: absolute; inset: 5px 10px 15px 20px")
    testing.expect(t, near(c.inset[0], 5),  "top == 5")
    testing.expect(t, near(c.inset[1], 10), "right == 10")
    testing.expect(t, near(c.inset[2], 15), "bottom == 15")
    testing.expect(t, near(c.inset[3], 20), "left == 20")
}

@(test)
test_inset_overridden_by_top :: proc(t: ^testing.T) {
    // top explícito deve sobrescrever o inset
    c := test_apply("position: absolute; inset: 10px; top: 99px")
    testing.expect(t, near(c.inset[0], 99), "top explícito sobrescreve inset")
    testing.expect(t, near(c.inset[2], 10), "bottom continua do inset")
}

// ── z-index ───────────────────────────────────────────────────────────────────

@(test)
test_z_index_valor :: proc(t: ^testing.T) {
    c := test_apply("position: absolute; z-index: 10")
    testing.expect_value(t, c.z_index, 10)
}

@(test)
test_z_index_negativo :: proc(t: ^testing.T) {
    c := test_apply("position: absolute; z-index: -1")
    testing.expect_value(t, c.z_index, -1)
}

@(test)
test_z_index_auto :: proc(t: ^testing.T) {
    c := test_apply("position: absolute; z-index: auto")
    testing.expect_value(t, c.z_index, 0)
}

@(test)
test_z_index_padrao :: proc(t: ^testing.T) {
    c := test_apply("display: block")
    testing.expect_value(t, c.z_index, 0)
}

// ── opacity ───────────────────────────────────────────────────────────────────

@(test)
test_opacity_decimal :: proc(t: ^testing.T) {
    c := test_apply("opacity: 0.5")
    testing.expect(t, near(c.opacity, 0.5), "opacity:0.5")
}

@(test)
test_opacity_pct :: proc(t: ^testing.T) {
    c := test_apply("opacity: 75%")
    testing.expect(t, near(c.opacity, 0.75), "opacity:75% == 0.75")
}

@(test)
test_opacity_zero :: proc(t: ^testing.T) {
    c := test_apply("opacity: 0")
    testing.expect(t, near(c.opacity, 0), "opacity:0")
}

@(test)
test_opacity_padrao :: proc(t: ^testing.T) {
    c := test_apply("display: block")
    testing.expect(t, near(c.opacity, 1.0), "opacity padrão == 1.0")
}

// ── transform: translate ──────────────────────────────────────────────────────

@(test)
test_transform_translatex :: proc(t: ^testing.T) {
    c := test_apply("transform: translateX(10px)")
    testing.expect(t, c.has_transform, "has_transform setado")
    testing.expect(t, near(c.transform_tx, 10), "tx == 10")
    testing.expect(t, near(c.transform_ty, 0),  "ty == 0")
    testing.expect(t, !c.transform_tx_pct, "tx não é pct")
}

@(test)
test_transform_translatey :: proc(t: ^testing.T) {
    c := test_apply("transform: translateY(-20px)")
    testing.expect(t, near(c.transform_ty, -20), "ty == -20")
    testing.expect(t, near(c.transform_tx, 0),   "tx == 0")
}

@(test)
test_transform_translate_2d :: proc(t: ^testing.T) {
    c := test_apply("transform: translate(15px, 30px)")
    testing.expect(t, near(c.transform_tx, 15), "tx == 15")
    testing.expect(t, near(c.transform_ty, 30), "ty == 30")
}

@(test)
test_transform_translate_pct :: proc(t: ^testing.T) {
    // padrão de centralização absoluta mais comum no CSS
    c := test_apply("transform: translate(-50%, -50%)")
    testing.expect(t, c.transform_tx_pct, "tx é pct")
    testing.expect(t, c.transform_ty_pct, "ty é pct")
    testing.expect(t, near(c.transform_tx, -0.5), "tx == -0.5 (fração)")
    testing.expect(t, near(c.transform_ty, -0.5), "ty == -0.5 (fração)")
}

@(test)
test_transform_padrao :: proc(t: ^testing.T) {
    c := test_apply("display: block")
    testing.expect(t, !c.has_transform, "sem transform: has_transform=false")
    testing.expect(t, near(c.transform_tx, 0), "tx == 0")
    testing.expect(t, near(c.transform_sx, 1) && near(c.transform_sy, 1), "escala neutra 1")
}

@(test)
test_transform_rotate :: proc(t: ^testing.T) {
    c := test_apply("transform: rotate(90deg)")
    testing.expect(t, c.has_transform, "has_transform")
    testing.expect(t, near(c.transform_rot, 1.5708, 0.001), "90deg == PI/2 rad")
    c2 := test_apply("transform: rotate(0.5turn)")
    testing.expect(t, near(c2.transform_rot, 3.14159, 0.001), "0.5turn == PI rad")
}

@(test)
test_transform_scale :: proc(t: ^testing.T) {
    c := test_apply("transform: scale(1.5)")
    testing.expect(t, near(c.transform_sx, 1.5) && near(c.transform_sy, 1.5), "scale(1.5) x=y=1.5")
    c2 := test_apply("transform: scale(2, 3)")
    testing.expect(t, near(c2.transform_sx, 2) && near(c2.transform_sy, 3), "scale(2,3)")
    c3 := test_apply("transform: scaleX(4)")
    testing.expect(t, near(c3.transform_sx, 4) && near(c3.transform_sy, 1), "scaleX(4)")
}

// ── Propriedades individuais translate/rotate/scale (CSS Transforms 2) ─────────

@(test)
test_prop_appearance :: proc(t: ^testing.T) {
    c := test_apply("appearance: none")
    testing.expect(t, c.appearance_none, "appearance:none")
    c2 := test_apply("-webkit-appearance: none")
    testing.expect(t, c2.appearance_none, "-webkit-appearance:none")
    c3 := test_apply("appearance: auto")
    testing.expect(t, !c3.appearance_none, "appearance:auto → false")
}

@(test)
test_prop_background_origin :: proc(t: ^testing.T) {
    c := test_apply("background-origin: content-box")
    testing.expect(t, c.bg_origin == .Content, "background-origin:content-box")
    c2 := test_apply("background-origin: border-box")
    testing.expect(t, c2.bg_origin == .Border, "background-origin:border-box")
    c3 := test_compute_one("div { color: red }") // default via pipeline real (reset)
    testing.expect(t, c3.bg_origin == .Padding, "default background-origin = padding-box")
}

// Geometria do clip-path: caixa 100x100 na origem (0,0). Usa o parser real p/
// montar a forma e testa dentro/fora ponto a ponto.
@(test)
test_clip_path_geometry :: proc(t: ^testing.T) {
    hit :: proc(css: string, px, py: f32) -> bool {
        c := test_apply(css)
        return test_clip_hit(c.clip_path, px, py, 0, 0, 100, 100)
    }
    // inset(10px) → retângulo 10..90
    testing.expect(t, !hit("clip-path: inset(10px)", 5, 5),   "inset: canto fora")
    testing.expect(t,  hit("clip-path: inset(10px)", 50, 50), "inset: centro dentro")
    testing.expect(t,  hit("clip-path: inset(10px)", 11, 11), "inset: dentro da borda")
    testing.expect(t, !hit("clip-path: inset(10px)", 95, 50), "inset: direita fora")
    // inset com round: o canto do retângulo é cortado pelo raio
    testing.expect(t, !hit("clip-path: inset(0px round 20px)", 2, 2),   "inset round: canto cortado")
    testing.expect(t,  hit("clip-path: inset(0px round 20px)", 50, 2),  "inset round: meio do topo dentro")
    // circle(50% at 50% 50%): raio = 50% de sqrt((100²+100²)/2) = 50 → círculo r=50 no centro
    testing.expect(t,  hit("clip-path: circle(50%)", 50, 50), "circle: centro dentro")
    testing.expect(t, !hit("clip-path: circle(50%)", 5, 5),   "circle: canto fora")
    testing.expect(t,  hit("clip-path: circle(50%)", 50, 5),  "circle: topo-centro dentro (r=50)")
    // circle(30px at 0 0): quarto de círculo no canto superior esquerdo
    testing.expect(t,  hit("clip-path: circle(30px at 0% 0%)", 5, 5),   "circle at 0 0: perto do canto dentro")
    testing.expect(t, !hit("clip-path: circle(30px at 0% 0%)", 50, 50), "circle at 0 0: centro fora")
    // ellipse(50% 25%): rx=50, ry=25 no centro
    testing.expect(t,  hit("clip-path: ellipse(50% 25%)", 50, 50), "ellipse: centro dentro")
    testing.expect(t, !hit("clip-path: ellipse(50% 25%)", 50, 10), "ellipse: acima do ry fora")
    testing.expect(t,  hit("clip-path: ellipse(50% 25%)", 90, 50), "ellipse: dentro do rx")
    // polygon triângulo: (50,0) (100,100) (0,100)
    tri :: "clip-path: polygon(50% 0%, 100% 100%, 0% 100%)"
    testing.expect(t,  hit(tri, 50, 80), "polygon: base do triângulo dentro")
    testing.expect(t, !hit(tri, 5, 5),   "polygon: canto sup-esq fora")
    testing.expect(t, !hit(tri, 95, 5),  "polygon: canto sup-dir fora")
    testing.expect(t,  hit(tri, 50, 50), "polygon: centro dentro")
    // none → tudo dentro
    testing.expect(t, hit("clip-path: none", 0, 0), "none: sem recorte")
}

@(test)
test_prop_clip_path_parse :: proc(t: ^testing.T) {
    // inset: 1 valor → todos os lados
    c := test_apply("clip-path: inset(10px)")
    testing.expect(t, c.clip_path.kind == .Inset, "inset kind")
    testing.expect(t, near(c.clip_path.inset[0].v, 10) && !c.clip_path.inset[0].pct, "inset 10px topo")
    testing.expect(t, near(c.clip_path.inset[3].v, 10), "inset 10px esquerda")
    // inset: 2 valores (t/b, l/r) + round
    c2 := test_apply("clip-path: inset(10% 20% round 5px)")
    testing.expect(t, c2.clip_path.inset[0].pct && near(c2.clip_path.inset[0].v, 0.1), "inset t=10%")
    testing.expect(t, near(c2.clip_path.inset[1].v, 0.2), "inset r=20%")
    testing.expect(t, near(c2.clip_path.inset[2].v, 0.1), "inset b=10%")
    testing.expect(t, near(c2.clip_path.round.v, 5), "inset round 5px")
    // circle com centro
    c3 := test_apply("clip-path: circle(40% at 30% 70%)")
    testing.expect(t, c3.clip_path.kind == .Circle, "circle kind")
    testing.expect(t, near(c3.clip_path.rx.v, 0.4) && c3.clip_path.rx.pct, "circle r=40%")
    testing.expect(t, near(c3.clip_path.cx.v, 0.3) && near(c3.clip_path.cy.v, 0.7), "circle centro 30%/70%")
    // circle default (sem args) → r=50%, centro 50%/50%
    c4 := test_apply("clip-path: circle()")
    testing.expect(t, near(c4.clip_path.rx.v, 0.5) && near(c4.clip_path.cx.v, 0.5), "circle default")
    // ellipse com keywords de posição
    c5 := test_apply("clip-path: ellipse(30% 50% at left top)")
    testing.expect(t, c5.clip_path.kind == .Ellipse, "ellipse kind")
    testing.expect(t, near(c5.clip_path.rx.v, 0.3) && near(c5.clip_path.ry.v, 0.5), "ellipse raios")
    testing.expect(t, near(c5.clip_path.cx.v, 0) && near(c5.clip_path.cy.v, 0), "ellipse at left top")
    // polygon
    c6 := test_apply("clip-path: polygon(50% 0%, 100% 100%, 0% 100%)")
    testing.expect(t, c6.clip_path.kind == .Polygon && c6.clip_path.n_pts == 3, "polygon 3 pontos")
    testing.expect(t, near(c6.clip_path.pts[0][0].v, 0.5) && near(c6.clip_path.pts[0][1].v, 0), "polygon p0")
    testing.expect(t, near(c6.clip_path.pts[1][0].v, 1.0), "polygon p1.x")
    // degenerado e none → sem recorte
    c7 := test_apply("clip-path: polygon(0% 0%, 100% 0%)")
    testing.expect(t, c7.clip_path.kind == .None, "polygon com 2 pontos → None")
    c8 := test_apply("clip-path: none")
    testing.expect(t, c8.clip_path.kind == .None, "none")
    c9 := test_apply("clip-path: url(#m)") // não suportado → None
    testing.expect(t, c9.clip_path.kind == .None, "url() → None")
}

// `clip: rect(t r b l)` (legado) — parsing + geometria via kind .Rect.
@(test)
test_prop_clip_rect :: proc(t: ^testing.T) {
    // sintaxe com vírgulas
    c := test_apply("clip: rect(10px, 90px, 80px, 20px)")
    testing.expect(t, c.clip_path.kind == .Rect, "clip rect kind")
    testing.expect(t, near(c.clip_path.inset[0].v, 10) && !c.clip_path.inset[0].pct, "rect top=10")
    testing.expect(t, near(c.clip_path.inset[1].v, 90), "rect right=90")
    testing.expect(t, near(c.clip_path.inset[2].v, 80), "rect bottom=80")
    testing.expect(t, near(c.clip_path.inset[3].v, 20), "rect left=20")
    // sintaxe com espaços (sem vírgulas) — legado aceita ambas
    c2 := test_apply("clip: rect(10px 90px 80px 20px)")
    testing.expect(t, c2.clip_path.kind == .Rect && near(c2.clip_path.inset[1].v, 90), "rect por espaços")
    // geometria: visível x∈[20,90], y∈[10,80] numa caixa 100x100
    hit :: proc(css: string, px, py: f32) -> bool {
        c := test_apply(css)
        return test_clip_hit(c.clip_path, px, py, 0, 0, 100, 100)
    }
    R :: "clip: rect(10px, 90px, 80px, 20px)"
    testing.expect(t,  hit(R, 50, 50), "rect: centro dentro")
    testing.expect(t, !hit(R, 5, 50),  "rect: à esquerda de left fora")
    testing.expect(t, !hit(R, 95, 50), "rect: à direita de right fora")
    testing.expect(t, !hit(R, 50, 5),  "rect: acima de top fora")
    testing.expect(t, !hit(R, 50, 90), "rect: abaixo de bottom fora")
    testing.expect(t,  hit(R, 20, 10), "rect: canto sup-esq na borda dentro")
    // auto: rect(auto, auto, auto, auto) → sem recorte (kind fica None)
    c3 := test_apply("clip: rect(auto, auto, auto, auto)")
    testing.expect(t, c3.clip_path.kind == .None, "rect todo-auto → None")
    // auto parcial: rect(0, auto, auto, 0) → visível é a caixa toda (0..bw, 0..bh)
    ca :: "clip: rect(0px, auto, auto, 0px)"
    testing.expect(t,  hit(ca, 99, 99), "rect auto right/bottom → borda da caixa dentro")
    testing.expect(t,  hit(ca, 1, 1),   "rect auto: top-left dentro")
    // o padrão .sr-only: rect(0 0 0 0) esconde tudo (x1<=x0, y1<=y0)
    testing.expect(t, !hit("clip: rect(0px 0px 0px 0px)", 0, 0), "sr-only rect(0 0 0 0) esconde")
    // clip-path vence clip quando ambos presentes (spec)
    c4 := test_apply("clip: rect(0px 0px 0px 0px); clip-path: circle(50%)")
    testing.expect(t, c4.clip_path.kind == .Circle, "clip-path vence clip")
    // valor inválido → sem recorte
    c5 := test_apply("clip: auto")
    testing.expect(t, c5.clip_path.kind == .None, "clip:auto → None")
}

// mask-image: <gradient> — parsing + fator de alpha por pixel (test_mask_alpha).
// Caixa 100x100 na origem. black=opaco(255), transparent=alpha 0.
@(test)
test_prop_mask_image :: proc(t: ^testing.T) {
    alpha :: proc(css: string, px, py: f32) -> u32 {
        c := test_apply(css)
        return test_mask_alpha(c.mask_grad, px, py, 0, 0, 100, 100)
    }
    near_a :: proc(v, target: u32) -> bool { d := int(v) - int(target); return d >= -6 && d <= 6 }
    // parsing: mask-image liga o gradiente
    c := test_apply("mask-image: linear-gradient(to bottom, black, transparent)")
    testing.expect(t, c.mask_grad.active && c.mask_grad.n == 2, "mask-image gradiente ativo")
    // -webkit-mask-image também
    c2 := test_apply("-webkit-mask-image: linear-gradient(black, transparent)")
    testing.expect(t, c2.mask_grad.active, "-webkit-mask-image ativo")
    // none / url() → sem máscara
    c3 := test_apply("mask-image: none")
    testing.expect(t, !c3.mask_grad.active, "mask-image:none → inativo")
    c4 := test_apply("mask-image: url(#m)")
    testing.expect(t, !c4.mask_grad.active, "mask-image:url() → inativo")
    // shorthand `mask` com gradiente + extras (size/repeat) → extrai o gradiente
    c5 := test_apply("mask: linear-gradient(to right, black, transparent) center / cover no-repeat")
    testing.expect(t, c5.mask_grad.active && c5.mask_grad.n == 2, "shorthand mask extrai gradiente")

    // geometria vertical (to bottom): topo opaco, base transparente, meio ~127
    VB :: "mask-image: linear-gradient(to bottom, black, transparent)"
    testing.expect(t, near_a(alpha(VB, 50, 1),  255), "to bottom: topo opaco")
    testing.expect(t, near_a(alpha(VB, 50, 99), 0),   "to bottom: base transparente")
    testing.expect(t, near_a(alpha(VB, 50, 50), 127), "to bottom: meio ~127")
    // horizontal (to right): esquerda opaca, direita transparente
    HR :: "mask-image: linear-gradient(to right, black, transparent)"
    testing.expect(t, near_a(alpha(HR, 1, 50),  255), "to right: esquerda opaca")
    testing.expect(t, near_a(alpha(HR, 99, 50), 0),   "to right: direita transparente")
    // stops posicionados: black 20% .. transparent 80% → 0..20 opaco, 80..100 transp.
    ST :: "mask-image: linear-gradient(to bottom, black 20%, transparent 80%)"
    testing.expect(t, near_a(alpha(ST, 50, 5),  255), "stop: antes de 20% opaco")
    testing.expect(t, near_a(alpha(ST, 50, 95), 0),   "stop: depois de 80% transparente")
    testing.expect(t, near_a(alpha(ST, 50, 50), 127), "stop: meio ~127")
    // repeating-linear com faixas em px: período 20px numa linha de 100px (to bottom)
    // = fração 0.2 → 5 repetições. 0..10px opaco, 10..20px transparente, e repete.
    RP :: "mask-image: repeating-linear-gradient(to bottom, black 0, black 10px, transparent 10px, transparent 20px)"
    testing.expect(t, near_a(alpha(RP, 50, 5),  255), "repeating: faixa 0 opaca")
    testing.expect(t, near_a(alpha(RP, 50, 15), 0),   "repeating: faixa 1 transparente")
    testing.expect(t, near_a(alpha(RP, 50, 25), 255), "repeating: faixa 2 opaca (repetiu)")
    testing.expect(t, near_a(alpha(RP, 50, 35), 0),   "repeating: faixa 3 transparente (repetiu)")
    // radial: centro opaco, cantos transparentes
    RD :: "mask-image: radial-gradient(black, transparent)"
    testing.expect(t, near_a(alpha(RD, 50, 50), 255), "radial: centro opaco")
    testing.expect(t, alpha(RD, 50, 50) > alpha(RD, 50, 5), "radial: centro mais opaco que borda")
    // color interpolation hint: hint a 30% desloca o ponto de 50% da mistura p/ y=30%.
    // Sem hint, alpha(t=0.3)=178 (linear); COM hint, alpha(t=0.3)=127 (é o meio agora).
    HT :: "mask-image: linear-gradient(to bottom, black, 30%, transparent)"
    testing.expect(t, near_a(alpha(HT, 50, 30), 127), "hint: 50% da mistura em y=30%")
    testing.expect(t, alpha(HT, 50, 30) < 160, "hint acelera a transição vs. linear (178)")
    testing.expect(t, alpha(HT, 50, 5) > alpha(HT, 50, 30), "hint: monotônico opaco→transparente")
    testing.expect(t, near_a(alpha(HT, 50, 99), 0),   "hint: base ainda transparente")
}

// backdrop-filter: reusa a gramática de filter num campo SEPARADO (não mistura
// com o `filter` próprio). Frosted glass = blur.
// scanner de números do parser de path SVG: sinais, decimais, expoente e
// separadores IMPLÍCITOS (o caso capcioso: "10-5" = 10 e -5; "1.5.5" = 1.5 e .5).
@(test)
test_svg_number_scanner :: proc(t: ^testing.T) {
    v, i, ok := test_svg_num("12.5 -3", 0)
    testing.expect(t, ok && near(v, 12.5), "12.5")
    v2, i2, ok2 := test_svg_num("12.5 -3", i)
    testing.expect(t, ok2 && near(v2, -3), "espaço+negativo")
    _ = i2
    // separador implícito por sinal: "10-5"
    a, ja, _ := test_svg_num("10-5", 0)
    b, _, _  := test_svg_num("10-5", ja)
    testing.expect(t, near(a, 10) && near(b, -5), "10-5 → 10, -5")
    // decimais grudados: "1.5.5" → 1.5 e .5
    c, jc, _ := test_svg_num("1.5.5", 0)
    dd, _, _ := test_svg_num("1.5.5", jc)
    testing.expect(t, near(c, 1.5) && near(dd, 0.5), "1.5.5 → 1.5, .5")
    // expoente
    e, _, oke := test_svg_num("1e3", 0)
    testing.expect(t, oke && near(e, 1000), "1e3")
    // vírgula como separador
    f, jf, _ := test_svg_num("3,4", 0)
    g, _, _  := test_svg_num("3,4", jf)
    testing.expect(t, near(f, 3) && near(g, 4), "3,4")
    // pontos de polyline
    testing.expect(t, test_svg_points_count("22 7 13.5 15.5 8.5 10.5 2 17") == 4, "4 pontos")
    testing.expect(t, test_svg_points_count("1,2 3,4 5,6") == 3, "3 pontos por vírgula")
}

// content: SEQUÊNCIA de componentes (strings + attr() + aspas). Regressão do bug
// que renderizava `"<" attr(href) ">"` como o texto literal `<" attr(href) ">`.
@(test)
test_content_attr_sequence :: proc(t: ^testing.T) {
    n := dompkg.make_node(.Element)
    n.tag = "a"
    n.attrs = make(map[string]string, context.temp_allocator)
    n.attrs["href"] = "https://x.com"
    TA := context.temp_allocator
    r := resolve_content_counters("\"<\" attr(href) \">\"", nil, n, TA)
    testing.expect_value(t, r, "<https://x.com>")
    testing.expect_value(t, resolve_content_counters("\"a\" \"b\"", nil, n, TA), "ab")
    testing.expect_value(t, resolve_content_counters("attr(title, \"n/d\")", nil, n, TA), "n/d")
    n.attrs["title"] = "Oi"
    testing.expect_value(t, resolve_content_counters("attr(title, \"x\")", nil, n, TA), "Oi")
    testing.expect_value(t, resolve_content_counters("attr(data-x)", nil, n, TA), "")
    // fallback com espaço + parênteses no texto (reproduz o caso da página manual)
    testing.expect_value(t, resolve_content_counters("attr(data-missing, \" (sem dado)\")", nil, n, TA), " (sem dado)")
    testing.expect_value(t, resolve_content_counters("\"so texto\"", nil, n, TA), "so texto")
    testing.expect_value(t, resolve_content_counters("open-quote \"oi\" close-quote", nil, n, TA), "“oi”")
}

@(test)
test_prop_backdrop_filter :: proc(t: ^testing.T) {
    c := test_apply("backdrop-filter: blur(12px)")
    testing.expect(t, c.n_backdrop == 1, "backdrop-filter: 1 função")
    testing.expect(t, c.n_backdrop == 1 && c.backdrop_filters[0].kind == .Blur, "backdrop = blur")
    testing.expect(t, c.n_backdrop == 1 && near(c.backdrop_filters[0].amount, 12), "blur 12px")
    testing.expect(t, c.n_filters == 0, "backdrop-filter NÃO preenche o filter próprio")
    // -webkit- + múltiplas funções
    c2 := test_apply("-webkit-backdrop-filter: blur(8px) brightness(1.2)")
    testing.expect(t, c2.n_backdrop == 2, "-webkit-backdrop-filter: 2 funções")
    // filter e backdrop-filter coexistem, separados
    c3 := test_apply("filter: grayscale(1); backdrop-filter: blur(4px)")
    testing.expect(t, c3.n_filters == 1 && c3.backdrop_filters[0].kind == .Blur, "filter e backdrop separados")
    // none → vazio
    c4 := test_apply("backdrop-filter: none")
    testing.expect(t, c4.n_backdrop == 0, "backdrop-filter:none → 0")
}

@(test)
test_prop_logical_radii :: proc(t: ^testing.T) {
    // raios lógicos → cantos físicos (horizontal-tb ltr). border_radius = [tl tr br bl]
    c := test_compute_one("div { border-start-start-radius: 4px; border-start-end-radius: 8px; border-end-start-radius: 12px; border-end-end-radius: 16px }")
    testing.expect(t, near(c.border_radius[0], 4),  "start-start → top-left 4")
    testing.expect(t, near(c.border_radius[1], 8),  "start-end → top-right 8")
    testing.expect(t, near(c.border_radius[3], 12), "end-start → bottom-left 12")
    testing.expect(t, near(c.border_radius[2], 16), "end-end → bottom-right 16")
    // precedência por CASCATA: o físico numa regra de spec MAIOR vence o lógico.
    // (na MESMA regra o lógico sobrepõe — não guardamos ordem por-declaração; é a
    // limitação conhecida do mapeamento lógico→físico, igual às demais props lógicas)
    c2 := test_compute_one("div { border-start-start-radius: 4px } .x { border-top-left-radius: 99px }", "div", "x")
    testing.expect(t, near(c2.border_radius[0], 99), "border-top-left-radius de spec maior vence")
}

@(test)
test_prop_logical_overflow :: proc(t: ^testing.T) {
    // O que este teste garante é o ALIASING lógico→físico (overflow-block → -y,
    // overflow-inline → -x). O "só um eixo" saiu no M239: com `hidden` os dois
    // clipam pela blockificação (ver test_overflow_por_eixo). Para continuar
    // provando o aliasing sem depender disso, uso `clip`, que NÃO blockifica.
    c := test_compute_one("div { overflow-block: clip }")
    testing.expect(t, c.ovf_clip_y && !c.ovf_clip_x, "overflow-block:clip → clipa só Y")
    c2 := test_compute_one("div { overflow-inline: clip }")
    testing.expect(t, c2.ovf_clip_x && !c2.ovf_clip_y, "overflow-inline:clip → clipa só X")
    // e o alias segue valendo com `hidden` (aí os dois clipam)
    c3 := test_compute_one("div { overflow-block: hidden }")
    testing.expect(t, c3.ovf_clip_y && c3.ovf_clip_x, "overflow-block:hidden → blockifica o outro eixo")
}

@(test)
test_prop_place_shorthands :: proc(t: ^testing.T) {
    // place-items: 1 valor → align-items E justify-items
    c := test_apply("place-items: center")
    testing.expect(t, c.align_items == .Center, "place-items center → align-items")
    testing.expect(t, c.justify_items == .Center, "place-items center → justify-items")
    // place-items: 2 valores
    c2 := test_apply("place-items: start end")
    testing.expect(t, c2.align_items == .Start, "place-items start end → align-items start")
    testing.expect(t, c2.justify_items == .End, "place-items start end → justify-items end")
    // place-content
    c3 := test_apply("place-content: center space-between")
    testing.expect(t, c3.align_content == .Center, "place-content → align-content center")
    testing.expect(t, c3.justify == .Between, "place-content → justify-content space-between")
    // place-self
    c4 := test_apply("place-self: center end")
    testing.expect(t, c4.has_align_self && c4.align_self == .Center, "place-self → align-self center")
    testing.expect(t, c4.has_justify_self && c4.justify_self == .End, "place-self → justify-self end")
    // longhand explícito vence o shorthand
    c5 := test_apply("place-items: center; align-items: start")
    testing.expect(t, c5.align_items == .Start, "align-items explícito vence place-items")
}

@(test)
test_prop_overscroll_behavior :: proc(t: ^testing.T) {
    c := test_apply("overscroll-behavior: contain")
    testing.expect(t, c.overscroll_contain, "overscroll-behavior:contain")
    c2 := test_apply("overscroll-behavior-y: none")
    testing.expect(t, c2.overscroll_contain, "overscroll-behavior-y:none")
    c3 := test_apply("overscroll-behavior: auto")
    testing.expect(t, !c3.overscroll_contain, "overscroll-behavior:auto → false")
}

@(test)
test_prop_tab_size :: proc(t: ^testing.T) {
    c := test_apply("tab-size: 4")
    testing.expect(t, c.tab_size == 4, "tab-size 4")
    c2 := test_apply("-moz-tab-size: 2")
    testing.expect(t, c2.tab_size == 2, "-moz-tab-size 2")
    c3 := test_apply("color: red") // sem a prop: 0 (= default 8 no uso)
    testing.expect(t, c3.tab_size == 0, "tab-size default = 0 (usa 8)")
}

@(test)
test_prop_scroll_offsets :: proc(t: ^testing.T) {
    c := test_apply("scroll-margin-top: 80px")
    testing.expect(t, near(c.scroll_margin_top, 80), "scroll-margin-top 80px")
    c2 := test_apply("scroll-margin: 10px 20px 30px 40px") // topo = 1º token
    testing.expect(t, near(c2.scroll_margin_top, 10), "scroll-margin shorthand → top 10")
    c3 := test_apply("scroll-padding-top: 2em")
    testing.expect(t, near(c3.scroll_padding_top, 32), "scroll-padding-top 2em = 32px")
    c4 := test_apply("scroll-padding: 5px")
    testing.expect(t, near(c4.scroll_padding_top, 5), "scroll-padding shorthand → top 5")
}

@(test)
test_prop_scroll_behavior :: proc(t: ^testing.T) {
    c := test_apply("scroll-behavior: smooth")
    testing.expect(t, c.scroll_smooth, "scroll-behavior:smooth")
    c2 := test_apply("scroll-behavior: auto")
    testing.expect(t, !c2.scroll_smooth, "scroll-behavior:auto → false")
}

@(test)
test_prop_underline_deco :: proc(t: ^testing.T) {
    c := test_apply("text-underline-offset: 3px")
    testing.expect(t, near(c.underline_offset, 3), "text-underline-offset 3px")
    c2 := test_apply("text-underline-offset: auto")
    testing.expect(t, near(c2.underline_offset, 0), "text-underline-offset auto = 0")
    c3 := test_apply("text-underline-position: under")
    testing.expect(t, c3.underline_under, "text-underline-position:under")
    c4 := test_apply("text-underline-position: auto")
    testing.expect(t, !c4.underline_under, "text-underline-position:auto → false")
    c5 := test_apply("text-decoration-skip-ink: none")
    testing.expect(t, c5.skip_ink_none, "text-decoration-skip-ink:none")
}

@(test)
test_prop_accent_color :: proc(t: ^testing.T) {
    c := test_apply("accent-color: #ff0000")
    testing.expect(t, c.has_accent && c.accent_color == 0xff0000, "accent-color vermelho")
    c2 := test_apply("accent-color: auto")
    testing.expect(t, !c2.has_accent, "accent-color:auto → sem override")
}

@(test)
test_prop_text_align_last :: proc(t: ^testing.T) {
    c := test_apply("text-align-last: right")
    testing.expect(t, c.has_text_align_last && c.text_align_last == .Right, "text-align-last:right")
    c2 := test_apply("text-align-last: center")
    testing.expect(t, c2.text_align_last == .Center, "text-align-last:center")
    c3 := test_apply("text-align-last: auto")
    testing.expect(t, !c3.has_text_align_last, "text-align-last:auto → sem override")
}

@(test)
test_prop_isolation :: proc(t: ^testing.T) {
    c := test_apply("isolation: isolate")
    testing.expect(t, c.isolate, "isolation:isolate")
    c2 := test_apply("isolation: auto")
    testing.expect(t, !c2.isolate, "isolation:auto → false")
}

@(test)
test_prop_table_props :: proc(t: ^testing.T) {
    c := test_apply("table-layout: fixed")
    testing.expect(t, c.table_fixed, "table-layout:fixed")
    c2 := test_apply("table-layout: auto")
    testing.expect(t, !c2.table_fixed, "table-layout:auto → false")
    c3 := test_apply("empty-cells: hide")
    testing.expect(t, c3.empty_cells_hide, "empty-cells:hide")
    c4 := test_apply("empty-cells: show")
    testing.expect(t, !c4.empty_cells_hide, "empty-cells:show → false")
    c5 := test_apply("caption-side: bottom")
    testing.expect(t, c5.caption_side_bottom, "caption-side:bottom")
    c6 := test_apply("caption-side: top")
    testing.expect(t, !c6.caption_side_bottom, "caption-side:top → false")
}

@(test)
test_prop_pointer_events :: proc(t: ^testing.T) {
    c := test_apply("pointer-events: none")
    testing.expect(t, c.pe_none, "pointer-events:none → pe_none true")
    c2 := test_apply("pointer-events: auto")
    testing.expect(t, !c2.pe_none, "pointer-events:auto → pe_none false")
    c3 := test_apply("display: block")
    testing.expect(t, !c3.pe_none, "default → pe_none false")
}

@(test)
test_prop_user_select :: proc(t: ^testing.T) {
    c := test_apply("user-select: none")
    testing.expect(t, c.user_select_none, "user-select:none")
    c2 := test_apply("-webkit-user-select: none")
    testing.expect(t, c2.user_select_none, "-webkit-user-select:none")
    c3 := test_apply("user-select: text")
    testing.expect(t, !c3.user_select_none, "user-select:text → false")
}

@(test)
test_prop_word_spacing :: proc(t: ^testing.T) {
    c := test_apply("word-spacing: 5px")
    testing.expect(t, near(c.word_spacing, 5), "word-spacing 5px")
    c2 := test_apply("word-spacing: 0.5em")
    testing.expect(t, near(c2.word_spacing, 8), "word-spacing 0.5em = 8px")
    c3 := test_apply("word-spacing: normal")
    testing.expect(t, near(c3.word_spacing, 0), "word-spacing normal = 0")
}

@(test)
test_prop_text_shadow :: proc(t: ^testing.T) {
    // cor + offset + blur
    c := test_apply("color: black; text-shadow: red 2px 3px 4px")
    testing.expect(t, c.text_shadow_n == 1, "1 text-shadow")
    testing.expect(t, near(c.text_shadows[0].dx, 2) && near(c.text_shadows[0].dy, 3), "offset 2,3")
    testing.expect(t, near(c.text_shadows[0].blur, 4), "blur 4")
    testing.expect(t, c.text_shadows[0].color == 0xff0000, "cor vermelha")
    // cor ausente → currentColor (cor do texto)
    c2 := test_apply("color: #112233; text-shadow: 1px 1px")
    testing.expect(t, c2.text_shadows[0].color == 0x112233, "sem cor → cor do texto")
    // lista de 2 sombras
    c3 := test_apply("text-shadow: 1px 1px blue, 2px 2px lime")
    testing.expect(t, c3.text_shadow_n == 2, "2 sombras")
    testing.expect(t, c3.text_shadows[1].color == 0x00ff00, "2ª sombra verde")
    // none zera (sobrepõe herança)
    c4 := test_apply("text-shadow: none")
    testing.expect(t, c4.text_shadow_n == 0, "none = sem sombra")
}

@(test)
test_prop_text_indent :: proc(t: ^testing.T) {
    c := test_apply("text-indent: 2em")
    testing.expect(t, near(c.text_indent, 32) && !c.text_indent_pct, "text-indent 2em = 32px")
    c2 := test_apply("text-indent: 10%")
    testing.expect(t, c2.text_indent_pct && near(c2.text_indent, 0.1), "text-indent 10% = fração 0.1")
    c3 := test_apply("text-indent: 40px")
    testing.expect(t, near(c3.text_indent, 40) && !c3.text_indent_pct, "text-indent 40px")
}

@(test)
test_prop_bg_position_axis :: proc(t: ^testing.T) {
    c := test_apply("background-position-x: right")
    testing.expect(t, near(c.bg_pos_x, 1), "bg-position-x right = 1")
    c2 := test_apply("background-position-y: 25%")
    testing.expect(t, near(c2.bg_pos_y, 0.25), "bg-position-y 25% = 0.25")
    c3 := test_apply("background-position-x: center; background-position-y: bottom")
    testing.expect(t, near(c3.bg_pos_x, 0.5) && near(c3.bg_pos_y, 1), "center/bottom")
}

@(test)
test_prop_translate :: proc(t: ^testing.T) {
    c := test_apply("translate: 15px 30px")
    testing.expect(t, c.has_transform, "translate seta has_transform")
    testing.expect(t, near(c.transform_tx, 15), "translate tx == 15")
    testing.expect(t, near(c.transform_ty, 30), "translate ty == 30")
    c2 := test_apply("translate: -50% -50%")
    testing.expect(t, c2.transform_tx_pct && near(c2.transform_tx, -0.5), "translate pct")
    c3 := test_apply("translate: 40px")
    testing.expect(t, near(c3.transform_tx, 40) && near(c3.transform_ty, 0), "translate 1 valor → ty 0")
}

@(test)
test_prop_rotate :: proc(t: ^testing.T) {
    c := test_apply("rotate: 90deg")
    testing.expect(t, c.has_transform && near(c.transform_rot, 1.5708, 0.001), "rotate 90deg")
    c2 := test_apply("rotate: z 0.5turn")
    testing.expect(t, near(c2.transform_rot, 3.14159, 0.001), "rotate z 0.5turn")
    c3 := test_apply("rotate: x 90deg") // eixo x não gira no plano 2D
    testing.expect(t, near(c3.transform_rot, 0), "rotate eixo x → sem rotação 2D")
}

@(test)
test_prop_scale :: proc(t: ^testing.T) {
    c := test_apply("scale: 1.5")
    testing.expect(t, near(c.transform_sx, 1.5) && near(c.transform_sy, 1.5), "scale 1 valor uniforme")
    c2 := test_apply("scale: 2 3")
    testing.expect(t, near(c2.transform_sx, 2) && near(c2.transform_sy, 3), "scale 2 valores")
    c3 := test_apply("scale: 50%")
    testing.expect(t, near(c3.transform_sx, 0.5), "scale % → fração")
}

@(test)
test_prop_transform_compose :: proc(t: ^testing.T) {
    // prop `transform` compõe por cima das individuais: rot soma, scale multiplica
    c := test_apply("rotate: 45deg; transform: rotate(45deg) scale(2)")
    testing.expect(t, near(c.transform_rot, 1.5708, 0.001), "rotate prop + transform rotate = 90deg")
    testing.expect(t, near(c.transform_sx, 2), "scale do transform aplica")
}

@(test)
test_animation_transform :: proc(t: ^testing.T) {
    // spinner: @keyframes com transform:rotate — os stops guardam has_rot
    css := ".s{animation:spin 1s infinite}" +
           "@keyframes spin{from{transform:rotate(0deg)}to{transform:rotate(360deg)}}"
    c := test_compute_anim(css, "div", "s")
    testing.expect(t, c.anim.active, "spinner ativo")
    testing.expect(t, c.anim.stops[1].has_rot, "stop 'to' tem rotação")
    testing.expect(t, near(c.anim.stops[1].rot, 6.2832, 0.01), "360deg == 2PI")
}

// ── propriedades lógicas → físicas (collect_decls) ─────────────────────────────

@(test)
test_logical_padding_longhands :: proc(t: ^testing.T) {
    c := test_compute_one("div { padding-inline-start: 10px; padding-inline-end: 20px; padding-block-start: 5px; padding-block-end: 15px }")
    testing.expect(t, near(c.padding[0], 5),  "padding-block-start -> top == 5")
    testing.expect(t, near(c.padding[1], 20), "padding-inline-end -> right == 20")
    testing.expect(t, near(c.padding[2], 15), "padding-block-end -> bottom == 15")
    testing.expect(t, near(c.padding[3], 10), "padding-inline-start -> left == 10")
}

@(test)
test_logical_size :: proc(t: ^testing.T) {
    // inline-size/block-size → width/height (horizontal-tb)
    c := test_compute_one("div { inline-size: 100px; block-size: 20px }")
    testing.expect(t, c.has_width && near(c.width, 100), "inline-size -> width 100")
    testing.expect(t, c.has_height && near(c.height, 20), "block-size -> height 20")
    // cascata: físico com especificidade MAIOR (id) vence o lógico (classe)
    c2 := test_compute_one("#h { width: 10px } .l { inline-size: 100px }", "div", "l", "")
    _ = c2 // sem id no nó, só a classe casa → width 100
    testing.expect(t, near(c2.width, 100), ".l inline-size aplica quando é a única regra")
}

@(test)
test_logical_float :: proc(t: ^testing.T) {
    // float lógico resolve por direção: LTR start=left/end=right; RTL invertido.
    testing.expect_value(t, test_compute_one("div { float: inline-start }").float, Float_Side.Left)
    testing.expect_value(t, test_compute_one("div { float: inline-end }").float, Float_Side.Right)
    testing.expect_value(t, test_compute_one("div { float: inline-start; direction: rtl }").float, Float_Side.Right)
    testing.expect_value(t, test_compute_one("div { clear: inline-end; direction: rtl }").clear, Clear_Side.Left)
}

@(test)
test_logical_margin_longhands :: proc(t: ^testing.T) {
    c := test_compute_one("div { margin-block-start: 8px; margin-inline-end: 12px }")
    testing.expect(t, c.has_margin, "margin lógico marca has_margin")
    testing.expect(t, near(c.margin[0], 8),  "margin-block-start -> top == 8")
    testing.expect(t, near(c.margin[1], 12), "margin-inline-end -> right == 12")
}

@(test)
test_logical_axis_shorthand :: proc(t: ^testing.T) {
    // padding-block: 1 valor -> top e bottom; padding-inline: 2 valores -> left/right
    c := test_compute_one("div { padding-block: 6px; padding-inline: 10px 30px }")
    testing.expect(t, near(c.padding[0], 6),  "padding-block top == 6")
    testing.expect(t, near(c.padding[2], 6),  "padding-block bottom == 6")
    testing.expect(t, near(c.padding[3], 10), "padding-inline start -> left == 10")
    testing.expect(t, near(c.padding[1], 30), "padding-inline end -> right == 30")
}

@(test)
test_logical_inset :: proc(t: ^testing.T) {
    c := test_compute_one("div { position: absolute; inset-block-start: 4px; inset-inline-start: 7px }")
    testing.expect(t, c.inset_has[0] && near(c.inset[0], 4), "inset-block-start -> top == 4")
    testing.expect(t, c.inset_has[3] && near(c.inset[3], 7), "inset-inline-start -> left == 7")
}

@(test)
test_logical_physical_wins_by_specificity :: proc(t: ^testing.T) {
    // físico mais específico (.x) deve vencer o lógico (div), via consider()
    c := test_compute_one("div { padding-inline-start: 10px } .x { padding-left: 99px }", "div", "x")
    testing.expect(t, near(c.padding[3], 99), "padding-left mais específico vence o lógico")
}

@(test)
test_logical_border_longhands :: proc(t: ^testing.T) {
    // border-{inline,block}-{start,end}-{width,color} → lados físicos
    c := test_compute_one("div { border-block-end-width: 3px; border-block-end-style: solid; border-inline-start-width: 5px; border-inline-start-style: solid; border-inline-start-color: red }")
    testing.expect(t, near(c.border_w[2], 3), "border-block-end-width -> bottom == 3")
    testing.expect(t, near(c.border_w[3], 5), "border-inline-start-width -> left == 5")
    testing.expect(t, c.border_c[3] == 0xff0000, "border-inline-start-color -> left vermelho")
}

@(test)
test_logical_border_side_shorthand :: proc(t: ^testing.T) {
    // border-block-end: 2px solid blue → border-bottom
    c := test_compute_one("div { border-block-end: 2px solid blue }")
    testing.expect(t, near(c.border_w[2], 2) && c.border_c[2] == 0x0000ff, "border-block-end -> bottom 2px azul")
    testing.expect(t, c.border_w[0] == 0, "topo sem borda")
}

@(test)
test_logical_border_axis :: proc(t: ^testing.T) {
    // border-inline: valor inteiro nos dois lados; border-block-width: 2 valores
    c := test_compute_one("div { border-inline: 4px solid green; border-block-width: 1px 7px; border-block-style: solid }")
    testing.expect(t, near(c.border_w[3], 4) && c.border_c[3] == 0x008000, "border-inline -> left 4px verde")
    testing.expect(t, near(c.border_w[1], 4) && c.border_c[1] == 0x008000, "border-inline -> right 4px verde")
    testing.expect(t, near(c.border_w[0], 1), "border-block-width start -> top == 1")
    testing.expect(t, near(c.border_w[2], 7), "border-block-width end -> bottom == 7")
}

// ── !important ────────────────────────────────────────────────────────────────

@(test)
test_important_vence_especificidade :: proc(t: ^testing.T) {
    // !important em seletor fraco (div) vence seletor mais forte (.x) sem a flag
    c := test_compute_one("div { color: red !important } .x { color: blue }", "div", "x")
    testing.expect(t, c.color == 0xff0000, "!important vence especificidade maior")
}

@(test)
test_important_vence_inline :: proc(t: ^testing.T) {
    // regra !important vence style="" inline sem a flag
    c := test_compute_one("div { color: red !important }", "div", "", "color: blue")
    testing.expect(t, c.color == 0xff0000, "regra !important vence inline normal")
}

@(test)
test_important_inline_vence_tudo :: proc(t: ^testing.T) {
    // inline !important vence regra !important
    c := test_compute_one("div { color: red !important }", "div", "", "color: blue !important")
    testing.expect(t, c.color == 0x0000ff, "inline !important vence regra !important")
}

@(test)
test_important_empate_ordem :: proc(t: ^testing.T) {
    // dois !important de mesma spec: a última regra vence (ordem de origem)
    c := test_compute_one("div { color: red !important } div { color: blue !important }")
    testing.expect(t, c.color == 0x0000ff, "entre !important iguais, o último vence")
}

// ── @layer (cascade layers) ───────────────────────────────────────────────────

@(test)
test_layer_sem_layer_vence :: proc(t: ^testing.T) {
    // regra EM @layer vem DEPOIS (maior ordem de fonte) mas PERDE p/ a sem-layer.
    // (é o caso do Tailwind v4: utilitários em @layer, componente sem layer vence.)
    c := test_compute_one(".b{color:green} @layer u{ .b{color:red} }", "div", "b")
    testing.expect(t, c.color == 0x008000, "sem-layer vence @layer apesar de vir antes")
}

@(test)
test_layer_sem_layer_vence_controle :: proc(t: ^testing.T) {
    // controle: SEM @layer, a 2ª regra (vermelha) venceria por ordem de fonte.
    c := test_compute_one(".b{color:green} .b{color:red}", "div", "b")
    testing.expect(t, c.color == 0xff0000, "sem @layer: ordem de fonte, a 2ª vence")
}

@(test)
test_layer_important_vence_sem_layer :: proc(t: ^testing.T) {
    // !important em @layer vence regra normal sem-layer (importância > layer).
    c := test_compute_one(".b{color:green} @layer u{ .b{color:red !important} }", "div", "b")
    testing.expect(t, c.color == 0xff0000, "!important em @layer vence normal sem-layer")
}

@(test)
test_important_valor_limpo :: proc(t: ^testing.T) {
    // o sufixo não pode vazar para o parser de valor (antes a declaração era perdida)
    c := test_compute_one("div { width: 100px !important }")
    testing.expect(t, c.has_width && near(c.width, 100), "valor com !important parseia limpo")
}

// ── seletores de atributo (pipeline completo) ──────────────────────────────────

@(test)
test_attr_seletor_pipeline :: proc(t: ^testing.T) {
    rules, _ := csspkg.parse(`input[type="text"] { color: red } input[type="password"] { color: blue }`)
    n := dompkg.make_node(.Element)
    n.tag = "input"
    n.attrs = make(map[string]string, context.temp_allocator)
    n.attrs["type"] = "text"
    styles, _ := compute_styles(n, &rules)
    c := styles[n]
    testing.expect(t, c.color == 0xff0000, "input[type=text] recebe a regra certa via compute_styles")
}

// ── combinadores de irmão e pseudo-classes estruturais (pipeline) ──────────────

// coleta os elementos com esta tag em pré-ordem
@(private="file")
find_elems :: proc(n: ^dompkg.Node, tag: string, out: ^[dynamic]^dompkg.Node) {
    if n.kind == .Element && n.tag == tag do append(out, n)
    for c in n.children do find_elems(c, tag, out)
}

@(test)
test_estruturais_pipeline :: proc(t: ^testing.T) {
    dom := htmlp.parse("<ul><li>a</li><li>b</li><li>c</li><li>d</li></ul>")
    rules, _ := csspkg.parse(`li { color: black }
        li:first-child { color: red }
        li:nth-child(even) { color: lime }
        li:last-child { color: blue }`)
    styles, _ := compute_styles(dom, &rules)
    lis: [dynamic]^dompkg.Node
    defer delete(lis)
    find_elems(dom, "li", &lis)
    testing.expect(t, len(lis) == 4, "4 <li> no DOM")
    testing.expect(t, styles[lis[0]].color == 0xff0000, "1º li: :first-child (vermelho)")
    testing.expect(t, styles[lis[1]].color == 0x00ff00, "2º li: :nth-child(even) (lime)")
    testing.expect(t, styles[lis[2]].color == 0x000000, "3º li: só a regra base (preto)")
    testing.expect(t, styles[lis[3]].color == 0x0000ff, "4º li: :last-child vence even pela ordem")
}

@(test)
test_combinador_irmao_pipeline :: proc(t: ^testing.T) {
    dom := htmlp.parse("<div><h1>t</h1><p>a</p><p>b</p></div>")
    rules, _ := csspkg.parse("h1 + p { color: red } h1 ~ p { font-weight: bold }")
    styles, _ := compute_styles(dom, &rules)
    ps: [dynamic]^dompkg.Node
    defer delete(ps)
    find_elems(dom, "p", &ps)
    testing.expect(t, len(ps) == 2, "2 <p> no DOM")
    testing.expect(t, styles[ps[0]].color == 0xff0000, "h1 + p casa só o primeiro p")
    testing.expect(t, styles[ps[1]].color != 0xff0000, "h1 + p NÃO casa o segundo p")
    testing.expect(t, styles[ps[0]].weight == .Bold && styles[ps[1]].weight == .Bold, "h1 ~ p casa os dois")
}

// ── :not() (pipeline) ───────────────────────────────────────────────────────────

@(test)
test_not_pipeline :: proc(t: ^testing.T) {
    dom := htmlp.parse(`<ul><li>a</li><li class="skip">b</li><li>c</li></ul>`)
    rules, _ := csspkg.parse("li:not(.skip) { color: red }")
    styles, _ := compute_styles(dom, &rules)
    lis: [dynamic]^dompkg.Node
    defer delete(lis)
    find_elems(dom, "li", &lis)
    testing.expect(t, len(lis) == 3, "3 <li>")
    testing.expect(t, styles[lis[0]].color == 0xff0000, "li sem .skip casa")
    testing.expect(t, styles[lis[1]].color != 0xff0000, "li.skip é negado")
    testing.expect(t, styles[lis[2]].color == 0xff0000, "li sem .skip casa")
}

// ── :dir() ──────────────────────────────────────────────────────────────────────

@(test)
test_dir_pseudo_matching :: proc(t: ^testing.T) {
    dom := htmlp.parse(
        `<div dir="ltr" id="a"></div>` +
        `<div dir="rtl" id="b"></div>` +
        `<div id="c"></div>` +               // default → ltr
        `<div dir="foopy" id="d"></div>` +   // inválido → default ltr
        `<div dir="rtl"><span id="e">x</span></div>` + // herda rtl
        `<div dir="auto" id="f">שלום</div>`) // auto: 1º forte hebraico → rtl
    rules, _ := csspkg.parse(":dir(ltr){color:red} :dir(rtl){color:blue}")
    styles, _ := compute_styles(dom, &rules)
    get :: proc(n: ^dompkg.Node, id: string) -> ^dompkg.Node {
        if n.kind == .Element && n.attrs["id"] == id do return n
        for c in n.children {
            if r := get(c, id); r != nil do return r
        }
        return nil
    }
    RED :: u32(0xff0000); BLUE :: u32(0x0000ff)
    testing.expect(t, styles[get(dom,"a")].color == RED,  "dir=ltr → :dir(ltr)")
    testing.expect(t, styles[get(dom,"b")].color == BLUE, "dir=rtl → :dir(rtl)")
    testing.expect(t, styles[get(dom,"c")].color == RED,  "default → ltr")
    testing.expect(t, styles[get(dom,"d")].color == RED,  "dir inválido → default ltr")
    testing.expect(t, styles[get(dom,"e")].color == BLUE, "herda rtl do pai")
    testing.expect(t, styles[get(dom,"f")].color == BLUE, "dir=auto texto hebraico → rtl")
}

// ── @import ─────────────────────────────────────────────────────────────────────

@(test)
test_import_stmt :: proc(t: ^testing.T) {
    u, c := parse_import_stmt(` url("a.css") screen`)
    testing.expect_value(t, u, "a.css")
    testing.expect_value(t, c, "screen")
    u, c = parse_import_stmt(` 'b.css'`)
    testing.expect_value(t, u, "b.css")
    testing.expect_value(t, c, "")
    u, _ = parse_import_stmt(` url(c.css)`)
    testing.expect_value(t, u, "c.css")
    u, c = parse_import_stmt(` "d.css" (min-width: 600px)`)
    testing.expect_value(t, u, "d.css")
    testing.expect_value(t, c, "(min-width: 600px)")
}

@(test)
test_import_media_cond :: proc(t: ^testing.T) {
    testing.expect_value(t, import_media_cond("screen"), "screen")
    testing.expect_value(t, import_media_cond("(min-width: 600px)"), "(min-width: 600px)")
    testing.expect_value(t, import_media_cond("layer(base)"), "") // não excluir a folha
    testing.expect_value(t, import_media_cond(""), "")
}

@(test)
test_import_passthrough :: proc(t: ^testing.T) {
    // sem @import: texto intacto; @import não-http: statement removido, resto fica
    // ⚠️ o coletor agora prefixa cada folha com uma MARCA de base (comentário CSS)
    // — é o que faz `url(...)` relativa resolver contra a folha e não contra a
    // página. O texto da folha em si continua intacto DEPOIS dela.
    sb := strings.builder_make(context.temp_allocator)
    count := 0
    seen := make(map[string]bool, 4, context.temp_allocator)
    append_css_with_imports("a { color: red }", "https://ex.com/css/s.css", &sb, &count, &seen)
    saida := strings.to_string(sb)
    testing.expect(t, strings.has_suffix(saida, "a { color: red }"), "a folha entra intacta depois da marca")
    testing.expect(t, strings.contains(saida, CSS_SHEET_MARK), "a marca de base é emitida")
    testing.expect(t, strings.contains(saida, "https://ex.com/css/s.css"), "e carrega a URL da folha")
    // a marca é um COMENTÁRIO: o parser de regras a ignora (senão viraria uma
    // regra fantasma em toda página)
    rr, _ := csspkg.parse(saida)
    defer csspkg.free_rules(&rr)
    testing.expectf(t, len(rr) == 1, "a marca não pode virar regra: esperava 1 regra, veio %v", len(rr))

    // href não-navegável ("#…"): o resolve descarta, nada é baixado
    sb2 := strings.builder_make(context.temp_allocator)
    count = 0
    append_css_with_imports(`@import "#local"; a { color: red }`, "", &sb2, &count, &seen)
    out := strings.to_string(sb2)
    testing.expect(t, !strings.contains(out, "@import"), "statement @import removido")
    testing.expect(t, strings.contains(out, "a { color: red }"), "regras seguintes preservadas")
    testing.expect_value(t, count, 0)
}

// Dedup de folhas de estilo por (URL, media). O teto MAX_SHEETS contava
// ELEMENTO <link>, não URL: app que quebra o CSS em módulos religa a MESMA folha
// uma vez por partial (a home do GitHub: 28 <link> p/ 21 URLs, primer-react-css
// religada 5×) e queimava o teto em downloads repetidos, deixando de fora as
// folhas que de fato estilizam a página.
@(test)
test_sheet_dedup_key :: proc(t: ^testing.T) {
    u := "https://x.com/a.css"
    // repetição pura colapsa
    testing.expect_value(t, sheet_dedup_key(u, ""), u)
    testing.expect_value(t, sheet_dedup_key(u, "all"), u)
    testing.expect_value(t, sheet_dedup_key(u, "ALL"), u)   // media é case-insensitive
    testing.expect_value(t, sheet_dedup_key(u, "  all  "), u) // e tem espaço em volta
    // media restritivo NÃO colapsa com o irrestrito nem com outro media: a mesma
    // folha em `print` e em `screen` são duas folhas (print esconde nav/sidebar)
    testing.expect(t, sheet_dedup_key(u, "print") != sheet_dedup_key(u, ""), "print ≠ irrestrito")
    testing.expect(t, sheet_dedup_key(u, "print") != sheet_dedup_key(u, "screen"), "print ≠ screen")
    testing.expect_value(t, sheet_dedup_key(u, "print"), sheet_dedup_key(u, " print ")) // mesmo media colapsa
    // URLs distintas nunca colapsam
    testing.expect(t, sheet_dedup_key(u, "") != sheet_dedup_key("https://x.com/b.css", ""), "URL distinta")
}

// ── CSS nesting (pipeline) ──────────────────────────────────────────────────────

@(test)
test_nesting_pipeline :: proc(t: ^testing.T) {
    dom := htmlp.parse(`<div class="card"><p class="title">t</p></div><p class="title">fora</p>`)
    rules, _ := csspkg.parse(".card { color: red; .title { color: blue } }")
    styles, _ := compute_styles(dom, &rules)
    ps: [dynamic]^dompkg.Node
    defer delete(ps)
    find_elems(dom, "p", &ps)
    testing.expect(t, len(ps) == 2, "2 <p>")
    testing.expect(t, styles[ps[0]].color == 0x0000ff, ".title dentro de .card recebe a regra aninhada")
    testing.expect(t, styles[ps[1]].color != 0x0000ff, ".title fora de .card não recebe")
    card := dompkg.find_first(dom, "div")
    testing.expect(t, styles[card].color == 0xff0000, "declarações próprias do pai aplicam")
}

// ── :is() (pipeline) ────────────────────────────────────────────────────────────

@(test)
test_is_pipeline :: proc(t: ^testing.T) {
    dom := htmlp.parse("<div><h1>a</h1><h2>b</h2><h3>c</h3></div>")
    rules, _ := csspkg.parse(":is(h1, h2) { color: red }")
    styles, _ := compute_styles(dom, &rules)
    h1 := dompkg.find_first(dom, "h1")
    h2 := dompkg.find_first(dom, "h2")
    h3 := dompkg.find_first(dom, "h3")
    testing.expect(t, styles[h1].color == 0xff0000, ":is casa h1")
    testing.expect(t, styles[h2].color == 0xff0000, ":is casa h2")
    testing.expect(t, styles[h3].color != 0xff0000, ":is não casa h3")
}

@(test)
test_where_complexo_nao_borda_tudo :: proc(t: ^testing.T) {
    // regressão: :where(.divide-y > :not(:last-child)) do Tailwind não pode
    // aplicar border-bottom a elementos fora de .divide-y
    dom := htmlp.parse("<div><h1>a</h1><p>b</p></div>")
    rules, _ := csspkg.parse("* { border: 0 solid } :where(.divide-y > :not(:last-child)) { border-bottom: 3px solid red }")
    styles, _ := compute_styles(dom, &rules)
    h1 := dompkg.find_first(dom, "h1")
    p := dompkg.find_first(dom, "p")
    testing.expect(t, styles[h1].border_w[2] == 0, "h1 sem border-bottom (fora de .divide-y)")
    testing.expect(t, styles[p].border_w[2] == 0, "p sem border-bottom")
}

@(test)
test_divide_y_aplica_nos_filhos_certos :: proc(t: ^testing.T) {
    // com .divide-y, o :where(.divide-y > :not(:last-child)) aplica a borda aos
    // filhos NÃO-últimos, e não ao último nem a elementos fora do container.
    dom := htmlp.parse(`<div class="divide-y"><p>a</p><p>b</p><p>c</p></div><p>fora</p>`)
    rules, _ := csspkg.parse("* { border: 0 solid } :where(.divide-y > :not(:last-child)) { border-bottom: 2px solid red }")
    styles, _ := compute_styles(dom, &rules)
    ps: [dynamic]^dompkg.Node
    defer delete(ps)
    find_elems(dom, "p", &ps)
    testing.expect(t, len(ps) == 4, "4 <p>")
    testing.expect(t, near(styles[ps[0]].border_w[2], 2), "1º filho: divisor")
    testing.expect(t, near(styles[ps[1]].border_w[2], 2), "2º filho: divisor")
    testing.expect(t, styles[ps[2]].border_w[2] == 0, "último filho: sem divisor (:not(:last-child))")
    testing.expect(t, styles[ps[3]].border_w[2] == 0, "<p> fora do .divide-y: sem divisor")
}

// ── outline ─────────────────────────────────────────────────────────────────────

@(test)
test_outline :: proc(t: ^testing.T) {
    c := test_apply("outline: 2px solid red")
    testing.expect(t, near(c.outline_w, 2) && c.outline_c == 0xff0000, "outline shorthand")
    c2 := test_apply("outline: none")
    testing.expect(t, c2.outline_w == 0, "outline: none")
    c3 := test_apply("color: teal; outline: 3px solid")
    testing.expect(t, c3.outline_c == 0x008080, "sem cor explícita assume a cor do texto")
    c4 := test_apply("outline: 1px solid blue; outline-offset: 2px")
    testing.expect(t, near(c4.outline_off, 2) && c4.outline_c == 0x0000ff, "outline-offset")
    c5 := test_apply("color: red; outline: 2px solid currentColor")
    testing.expect(t, c5.outline_c == 0xff0000, "outline currentColor")
}

@(test)
test_not_complexo_pipeline :: proc(t: ^testing.T) {
    // p:not(.card p) — parágrafos que NÃO são descendentes de .card
    dom := htmlp.parse(`<div class="card"><p>dentro</p></div><p>fora</p>`)
    rules, _ := csspkg.parse("p:not(.card p) { color: red }")
    styles, _ := compute_styles(dom, &rules)
    ps: [dynamic]^dompkg.Node
    defer delete(ps)
    find_elems(dom, "p", &ps)
    testing.expect(t, len(ps) == 2, "2 <p>")
    testing.expect(t, styles[ps[0]].color != 0xff0000, "p dentro de .card é negado")
    testing.expect(t, styles[ps[1]].color == 0xff0000, "p fora de .card casa")
}

// ── :has() (pipeline) ─────────────────────────────────────────────────────────────

@(test)
test_has_descendant_child :: proc(t: ^testing.T) {
    // .card:has(img) casa só os cards com <img>; :has(> .badge) só filho direto
    dom := htmlp.parse(`<div class="card"><p><img></p></div><div class="card"><p>texto</p></div><div class="card"><span class="badge">b</span></div>`)
    rules, _ := csspkg.parse(".card:has(img) { color: red } .card:has(> .badge) { color: blue }")
    styles, _ := compute_styles(dom, &rules)
    cards: [dynamic]^dompkg.Node
    defer delete(cards)
    find_elems(dom, "div", &cards)
    testing.expect(t, styles[cards[0]].color == 0xff0000, "card com <img> descendente → vermelho")
    testing.expect(t, styles[cards[1]].color != 0xff0000, "card sem img não casa")
    testing.expect(t, styles[cards[2]].color == 0x0000ff, "card com .badge filho direto → azul")
}

@(test)
test_has_child_nao_casa_neto :: proc(t: ^testing.T) {
    // :has(> .badge) NÃO deve casar se .badge for neto (não filho direto)
    dom := htmlp.parse(`<div class="card"><p><span class="badge">b</span></p></div>`)
    rules, _ := csspkg.parse(".card:has(> .badge) { color: blue }")
    styles, _ := compute_styles(dom, &rules)
    card := dompkg.find_first(dom, "div")
    testing.expect(t, styles[card].color != 0x0000ff, ":has(> .badge) não casa neto")
}

@(test)
test_has_sibling :: proc(t: ^testing.T) {
    // h2:has(+ p) — h2 seguido imediatamente por <p>
    dom := htmlp.parse(`<div><h2>a</h2><p>x</p><h2>b</h2><span>y</span></div>`)
    rules, _ := csspkg.parse("h2:has(+ p) { color: red }")
    styles, _ := compute_styles(dom, &rules)
    h2s: [dynamic]^dompkg.Node
    defer delete(h2s)
    find_elems(dom, "h2", &h2s)
    testing.expect(t, styles[h2s[0]].color == 0xff0000, "h2 seguido de p → casa")
    testing.expect(t, styles[h2s[1]].color != 0xff0000, "h2 seguido de span → não casa")
}

@(test)
test_has_encadeado :: proc(t: ^testing.T) {
    // :has(.a .b) — cadeia interna: existe .b descendente de .a descendente do escopo
    dom := htmlp.parse(`<section><div class="a"><span class="b">x</span></div></section><section><div class="a">y</div></section>`)
    rules, _ := csspkg.parse("section:has(.a .b) { color: red }")
    styles, _ := compute_styles(dom, &rules)
    secs: [dynamic]^dompkg.Node
    defer delete(secs)
    find_elems(dom, "section", &secs)
    testing.expect(t, styles[secs[0]].color == 0xff0000, "section com .a .b → casa")
    testing.expect(t, styles[secs[1]].color != 0xff0000, "section só com .a → não casa")
}

// ── currentColor ────────────────────────────────────────────────────────────────

@(test)
test_current_color :: proc(t: ^testing.T) {
    c := test_apply("color: red; border: 2px solid currentColor")
    testing.expect(t, c.has_border && c.border_c == 0xff0000, "border currentColor = cor do elemento")
    c2 := test_apply("color: blue; background-color: currentColor")
    testing.expect(t, c2.has_bg && c2.bg == 0x0000ff, "background currentColor")
    c3 := test_apply("color: teal; border-color: currentColor; border-width: 1px")
    testing.expect(t, c3.border_c == 0x008080, "border-color currentColor")
}

// ── min()/max()/clamp() ─────────────────────────────────────────────────────────

@(test)
test_min_max_clamp :: proc(t: ^testing.T) {
    px, pct, ok := test_parse_len("min(50px, 30px)")
    testing.expect(t, ok && !pct && near(px, 30), "min(50px, 30px) == 30")
    px, _, ok = test_parse_len("max(2rem, 20px)")
    testing.expect(t, ok && near(px, 32), "max(2rem, 20px) == 32")
    px, _, ok = test_parse_len("clamp(10px, 5px, 20px)")
    testing.expect(t, ok && near(px, 10), "clamp aplica o piso")
    px, _, ok = test_parse_len("clamp(10px, 50px, 20px)")
    testing.expect(t, ok && near(px, 20), "clamp aplica o teto")
    px, _, ok = test_parse_len("clamp(10px, 15px, 20px)")
    testing.expect(t, ok && near(px, 15), "clamp mantém o valor no meio")
    px, _, ok = test_parse_len("min(100px - 30px, 90px)")
    testing.expect(t, ok && near(px, 70), "argumento com expressão calc")
    px, pct, ok = test_parse_len("min(50%, 25%)")
    testing.expect(t, ok && pct && near(px, 0.25), "min de porcentagens devolve fração")
    _, _, ok = test_parse_len("min(50%, 300px)")
    testing.expect(t, !ok, "misto %/px não é resolvível — falha")
}

// ── pseudos de estado (pipeline) ──────────────────────────────────────────────────

@(test)
test_ui_state_pipeline :: proc(t: ^testing.T) {
    // regras sem sobreposição: :checked e :disabled são mutuamente exclusivos aqui
    dom := htmlp.parse(`<form><input type="checkbox" checked><input type="text" disabled><input type="text"></form>`)
    rules, _ := csspkg.parse("input:checked { color: red } input:disabled { color: blue } input:enabled { font-weight: bold }")
    styles, _ := compute_styles(dom, &rules)
    ins: [dynamic]^dompkg.Node
    defer delete(ins)
    find_elems(dom, "input", &ins)
    testing.expect(t, len(ins) == 3, "3 inputs")
    testing.expect(t, styles[ins[0]].color == 0xff0000, "checkbox[checked] → :checked (vermelho)")
    testing.expect(t, styles[ins[1]].color == 0x0000ff, "input[disabled] → :disabled (azul)")
    testing.expect(t, styles[ins[0]].weight == .Bold, "checkbox não-disabled → :enabled (bold)")
    testing.expect(t, styles[ins[1]].weight != .Bold, "input[disabled] não é :enabled")
    testing.expect(t, styles[ins[2]].weight == .Bold, "input normal → :enabled (bold)")
}

// ── visibility ───────────────────────────────────────────────────────────────────

@(test)
test_visibility_parse :: proc(t: ^testing.T) {
    testing.expect(t, test_apply("visibility: hidden").invisible, "hidden")
    testing.expect(t, test_apply("visibility: collapse").invisible, "collapse ≈ hidden")
    testing.expect(t, !test_apply("visibility: visible").invisible, "visible")
    testing.expect(t, !test_apply("color: red").invisible, "padrão visível")
}

@(test)
test_visibility_heranca_e_override :: proc(t: ^testing.T) {
    // pai hidden esconde o filho; um filho visible reexibe
    dom := htmlp.parse(`<div style="visibility:hidden"><p>a</p><span style="visibility:visible">b</span></div>`)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules)
    div := dompkg.find_first(dom, "div")
    p := dompkg.find_first(dom, "p")
    sp := dompkg.find_first(dom, "span")
    testing.expect(t, styles[div].invisible, "div hidden")
    testing.expect(t, styles[p].invisible, "p herda hidden")
    testing.expect(t, !styles[sp].invisible, "span reexibe (visibility:visible)")
}

// ── list-style ───────────────────────────────────────────────────────────────────

@(test)
test_list_style_parse :: proc(t: ^testing.T) {
    testing.expect(t, test_apply("list-style: none").list_style == .None, "list-style:none")
    testing.expect(t, test_apply("list-style-type: none").list_style == .None, "list-style-type:none")
    testing.expect(t, test_apply("list-style-type: square").list_style == .Square, "square")
    testing.expect(t, test_apply("list-style: decimal").list_style == .Decimal, "decimal via shorthand")
    testing.expect(t, test_apply("list-style: lower-roman inside").list_style == .Lower_Roman, "shorthand com position")
    testing.expect(t, test_apply("color: red").list_style == .Auto, "padrão Auto")
}

@(test)
test_list_style_none_pipeline :: proc(t: ^testing.T) {
    // list-style:none no <ul> herda ao <li> e suprime o marcador
    dom := htmlp.parse(`<ul class="nav" style="list-style:none"><li>a</li><li>b</li></ul>`)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules)
    li := dompkg.find_first(dom, "li")
    testing.expect(t, styles[li].list_style == .None, "<li> herda list-style:none do <ul>")
}

// ── white-space ────────────────────────────────────────────────────────────────

@(test)
test_white_space_valores :: proc(t: ^testing.T) {
    testing.expect(t, test_apply("white-space: nowrap").white_space == .Nowrap, "nowrap")
    testing.expect(t, test_apply("white-space: pre").white_space == .Pre, "pre")
    testing.expect(t, test_apply("white-space: pre-wrap").white_space == .Pre_Wrap, "pre-wrap")
    testing.expect(t, test_apply("white-space: pre-line").white_space == .Pre_Line, "pre-line")
    testing.expect(t, test_apply("color: red").white_space == .Normal, "padrão Normal")
}

// ── font-family (genéricas) ────────────────────────────────────────────────────

@(test)
test_family_padrao_sans :: proc(t: ^testing.T) {
    c := test_compute_one("div { color: red }")
    testing.expect(t, c.font_family == .Sans, "sem font-family => Sans")
}

@(test)
test_family_monospace :: proc(t: ^testing.T) {
    c := test_compute_one("div { font-family: monospace }")
    testing.expect(t, c.font_family == .Mono, "monospace => Mono")
}

@(test)
test_family_serif :: proc(t: ^testing.T) {
    c := test_compute_one("div { font-family: Georgia, serif }")
    testing.expect(t, c.font_family == .Serif, "Georgia => Serif")
}

@(test)
test_family_stack_fallback :: proc(t: ^testing.T) {
    // família específica desconhecida (Poppins=sans) seguida de genérica
    c := test_compute_one(`div { font-family: "Unknown Display", monospace }`)
    testing.expect(t, c.font_family == .Mono, "desconhecida pula p/ monospace")
}

@(test)
test_family_unknown_keeps_sans :: proc(t: ^testing.T) {
    // nada reconhecido => mantém Sans (herdado), não vira lixo
    c := test_compute_one(`div { font-family: "Totally Made Up" }`)
    testing.expect(t, c.font_family == .Sans, "stack irreconhecível => Sans")
}

@(test)
test_family_shorthand_font :: proc(t: ^testing.T) {
    // família embutida no shorthand `font`
    c := test_compute_one("div { font: italic bold 14px/1.4 Consolas, monospace }")
    testing.expect(t, c.font_family == .Mono, "shorthand font com Consolas => Mono")
}

// ── font-style ─────────────────────────────────────────────────────────────────

@(test)
test_font_style_italic :: proc(t: ^testing.T) {
    c := test_apply("font-style: italic")
    testing.expect(t, c.italic, "font-style:italic => italic")
    c2 := test_apply("font-style: oblique")
    testing.expect(t, c2.italic, "oblique aproxima como italic")
    c3 := test_apply("font-style: normal")
    testing.expect(t, !c3.italic, "normal => reto")
}

@(test)
test_em_italico_por_padrao :: proc(t: ^testing.T) {
    // stylesheet do UA: <em>/<i>/<cite> são itálicos; autor pode desligar
    c := test_compute_one("", "em")
    testing.expect(t, c.italic, "<em> é itálico por padrão")
    c2 := test_compute_one("em { font-style: normal }", "em")
    testing.expect(t, !c2.italic, "font-style:normal desliga o itálico do <em>")
}

@(test)
test_position_sticky :: proc(t: ^testing.T) {
    c := test_apply("position: sticky; top: 0")
    testing.expect(t, c.position == .Sticky, "position:sticky vira .Sticky")
    testing.expect(t, c.inset_has[0], "top:0 registrado como inset")
    c2 := test_apply("position: -webkit-sticky")
    testing.expect(t, c2.position == .Sticky, "-webkit-sticky idem")
}

// ── overflow-wrap / word-break / text-overflow ─────────────────────────────────

@(test)
test_overflow_wrap :: proc(t: ^testing.T) {
    c := test_apply("overflow-wrap: break-word")
    testing.expect(t, c.break_word, "overflow-wrap:break-word")
    c2 := test_apply("word-wrap: break-word")
    testing.expect(t, c2.break_word, "word-wrap (alias legado) idem")
    c3 := test_apply("word-break: break-all")
    testing.expect(t, c3.break_all, "word-break:break-all")
    c4 := test_apply("word-break: break-word")
    testing.expect(t, c4.break_word, "word-break:break-word = overflow-wrap:break-word")
}

@(test)
test_text_overflow_ellipsis :: proc(t: ^testing.T) {
    c := test_apply("text-overflow: ellipsis")
    testing.expect(t, c.ellipsis, "text-overflow:ellipsis")
    c2 := test_apply("text-overflow: clip")
    testing.expect(t, !c2.ellipsis, "clip = sem ellipsis")
}

@(test)
test_font_shorthand_italic :: proc(t: ^testing.T) {
    c := test_compute_one("div { font: italic bold 14px/1.4 Consolas, monospace }")
    testing.expect(t, c.italic, "italic embutido no shorthand font")
    // "italic" DEPOIS do font-size é nome de família, não estilo
    c2 := test_compute_one(`div { font: 14px Consolas, monospace }`)
    testing.expect(t, !c2.italic, "shorthand sem italic => reto")
}

// ── box-shadow ─────────────────────────────────────────────────────────────────

@(test)
test_shadow_basico :: proc(t: ^testing.T) {
    c := test_apply("box-shadow: 0 8px 24px rgba(0,0,0,0.18)")
    testing.expect_value(t, c.shadow_n, 1)
    testing.expect(t, near(c.shadows[0].dx, 0),   "dx == 0")
    testing.expect(t, near(c.shadows[0].dy, 8),   "dy == 8")
    testing.expect(t, near(c.shadows[0].blur, 24),"blur == 24")
    testing.expect(t, ((c.shadows[0].color >> 24) & 0xff) != 0, "rgba => alpha no byte alto")
}

@(test)
test_shadow_spread :: proc(t: ^testing.T) {
    c := test_apply("box-shadow: 2px 4px 6px 3px black")
    testing.expect_value(t, c.shadow_n, 1)
    testing.expect(t, near(c.shadows[0].spread, 3), "spread == 3")
}

@(test)
test_shadow_multiplas :: proc(t: ^testing.T) {
    // vírgula dentro de rgba() não pode quebrar o split
    c := test_apply("box-shadow: 0 4px 6px rgba(0,0,0,0.1), 0 12px 28px rgba(0,0,0,0.15)")
    testing.expect_value(t, c.shadow_n, 2)
    testing.expect(t, near(c.shadows[1].dy, 12), "segunda sombra dy == 12")
}

@(test)
test_shadow_inset :: proc(t: ^testing.T) {
    c := test_apply("box-shadow: inset 0 2px 4px black")
    testing.expect_value(t, c.shadow_n, 1)
    testing.expect(t, c.shadows[0].inset, "flag inset marcada")
    testing.expect(t, near(c.shadows[0].dy, 2) && near(c.shadows[0].blur, 4), "dx/dy/blur parseados após 'inset'")
}

@(test)
test_shadow_inset_e_externa :: proc(t: ^testing.T) {
    // lista mista: uma externa e uma inset, ambas guardadas com a flag correta
    c := test_apply("box-shadow: 0 4px 6px black, inset 0 0 8px red")
    testing.expect_value(t, c.shadow_n, 2)
    testing.expect(t, !c.shadows[0].inset, "primeira é externa")
    testing.expect(t, c.shadows[1].inset,  "segunda é inset")
}

@(test)
test_shadow_none :: proc(t: ^testing.T) {
    c := test_apply("box-shadow: none")
    testing.expect_value(t, c.shadow_n, 0)
}

@(test)
test_transform_skew :: proc(t: ^testing.T) {
    c := test_apply("transform: skewX(45deg)")
    testing.expect(t, c.has_transform && c.has_xform_matrix, "skewX marca has_xform_matrix")
    // skewX(45): tan(45)=1 → [1 1; 0 1]
    testing.expect(t, near(c.xf_a, 1) && near(c.xf_b, 1) && near(c.xf_c, 0) && near(c.xf_d, 1), "skewX(45deg) = [1,1;0,1]")
    cy := test_apply("transform: skewY(45deg)")
    testing.expect(t, near(cy.xf_a, 1) && near(cy.xf_b, 0) && near(cy.xf_c, 1) && near(cy.xf_d, 1), "skewY(45deg) = [1,0;1,1]")
}

@(test)
test_transform_matrix :: proc(t: ^testing.T) {
    c := test_apply("transform: matrix(2, 0, 0, 3, 10, 20)")
    testing.expect(t, c.has_xform_matrix, "matrix() marca has_xform_matrix")
    // coluna-maior: linear = [a c; b d] = [2 0; 0 3]; translate (e,f)=(10,20)
    testing.expect(t, near(c.xf_a, 2) && near(c.xf_b, 0) && near(c.xf_c, 0) && near(c.xf_d, 3), "matrix linear [2,0;0,3]")
    testing.expect(t, near(c.transform_tx, 10) && near(c.transform_ty, 20), "matrix translate (10,20)")
}

@(test)
test_transform_scale_sem_matriz :: proc(t: ^testing.T) {
    // rotate/scale puros NÃO marcam has_xform_matrix (caminho animável por transition)
    c := test_apply("transform: scale(2)")
    testing.expect(t, !c.has_xform_matrix, "scale puro não usa a matriz (fica no caminho rot/scale)")
    testing.expect(t, near(c.transform_sx, 2) && near(c.transform_sy, 2), "scale preenche sx/sy")
}

@(test)
test_transform_origin :: proc(t: ^testing.T) {
    ox, oy := parse_transform_origin("top left")
    testing.expect(t, near(ox, 0) && near(oy, 0), "top left reordena p/ (0,0)")
    ox, oy = parse_transform_origin("right")
    testing.expect(t, near(ox, 1) && near(oy, 0.5), "só x → y=center")
    ox, oy = parse_transform_origin("25% 75%")
    testing.expect(t, near(ox, 0.25) && near(oy, 0.75), "porcentagens viram frações")
    // default via apply
    c := test_apply("transform: rotate(10deg)")
    testing.expect(t, near(c.transform_ox, 0.5) && near(c.transform_oy, 0.5), "sem origin = centro (0.5,0.5)")
}

// ── background-clip:text + -webkit-text-fill-color ─────────────────────────────

@(test)
test_gradient_text :: proc(t: ^testing.T) {
    c := test_apply("background:linear-gradient(to right,#ff0000,#0000ff);-webkit-background-clip:text;background-clip:text;-webkit-text-fill-color:transparent")
    // O gradiente PERMANECE no Computed (é ele que vai colorir os glifos), mas
    // marcado com grad_clip_text — é essa flag que faz o paint da CAIXA pulá-lo.
    // Antes o gradiente era zerado aqui e o texto saía numa cor sólida só.
    testing.expect(t, c.grad.active, "o gradiente tem de sobreviver p/ colorir o texto")
    testing.expect(t, c.grad_clip_text, "e vir marcado como clipado ao texto (a caixa nao o pinta)")
    // media de #ff0000 e #0000ff = (127,0,127) — cor sólida de FALLBACK, usada
    // por qualquer caminho de texto que não passe pelo sombreamento de vértices.
    testing.expect_value(t, c.color, u32(0x7f007f))
}

@(test)
test_text_fill_color :: proc(t: ^testing.T) {
    c := test_apply("color: black; -webkit-text-fill-color: #4fc3f7")
    testing.expect_value(t, c.color, u32(0x4fc3f7))
}

@(test)
test_text_fill_transparent_sem_clip :: proc(t: ^testing.T) {
    // transparent sem background-clip:text mantém a cor normal (não some)
    c := test_apply("color: #112233; -webkit-text-fill-color: transparent")
    testing.expect_value(t, c.color, u32(0x112233))
}

// ── letter-spacing ─────────────────────────────────────────────────────────────

@(test)
test_letter_spacing_px :: proc(t: ^testing.T) {
    c := test_apply("letter-spacing: 2px")
    testing.expect(t, near(c.letter_spacing, 2), "letter-spacing 2px")
}

@(test)
test_letter_spacing_em :: proc(t: ^testing.T) {
    // 0.1em com font-size 20 => 2px
    c := test_apply("font-size: 20px; letter-spacing: 0.1em")
    testing.expect(t, near(c.letter_spacing, 2), "0.1em com fs=20 => 2px")
}

@(test)
test_letter_spacing_normal :: proc(t: ^testing.T) {
    c := test_apply("letter-spacing: normal")
    testing.expect(t, near(c.letter_spacing, 0), "normal => 0")
}

// ── text-transform (parse) ─────────────────────────────────────────────────────

@(test)
test_text_transform_parse :: proc(t: ^testing.T) {
    testing.expect(t, test_apply("text-transform: uppercase").text_transform  == .Upper,      "uppercase")
    testing.expect(t, test_apply("text-transform: lowercase").text_transform  == .Lower,      "lowercase")
    testing.expect(t, test_apply("text-transform: capitalize").text_transform == .Capitalize, "capitalize")
    testing.expect(t, test_apply("color: red").text_transform                 == .None,       "padrao None")
}

// ── ::before / ::after (pseudo-elementos) ──────────────────────────────────────

@(test)
test_pseudo_before_gera :: proc(t: ^testing.T) {
    c := test_compute_one("div::before{content:\"X\";width:99px}", "div", "")
    testing.expect(t, c.before != nil, "::before com content gera pseudo")
    if c.before != nil {
        testing.expect(t, c.before.content == "X", "content do pseudo == X")
        testing.expect(t, c.before.has_width && near(c.before.width, 99), "width vai pro pseudo")
    }
    // e NÃO vaza pro elemento (regressão do .section-title:before quebrando o h2)
    testing.expect(t, !c.has_width, "width do ::before nao vaza pro elemento")
}

@(test)
test_pseudo_sem_content_nao_gera :: proc(t: ^testing.T) {
    c := test_compute_one("div::before{color:red}", "div", "")
    testing.expect(t, c.before == nil, "::before sem content nao gera pseudo")
}

@(test)
test_pseudo_after :: proc(t: ^testing.T) {
    c := test_compute_one("p::after{content:\" *\"}", "p", "")
    testing.expect(t, c.after != nil, "::after com content gera pseudo")
    testing.expect(t, c.before == nil, "sem ::before")
}

@(test)
test_pseudo_content_unescape :: proc(t: ^testing.T) {
    // \2192 = seta →
    c := test_compute_one("a::after{content:\"\\2192\"}", "a", "")
    testing.expect(t, c.after != nil, "gera pseudo")
    if c.after != nil do testing.expect(t, c.after.content == "→", "escape hex \\2192 vira seta")
}

// ── float / clear ────────────────────────────────────────────────────────────

@(test)
test_float_parse :: proc(t: ^testing.T) {
    testing.expect(t, test_compute_one("div{float:left}").float  == .Left,  "float:left")
    testing.expect(t, test_compute_one("div{float:right}").float == .Right, "float:right")
    testing.expect(t, test_compute_one("div{clear:both}").clear  == .Both,  "clear:both")
    testing.expect(t, test_compute_one("div{color:red}").float   == .None,  "sem float => None")
}

// ── animation / @keyframes ───────────────────────────────────────────────────

@(test)
test_animation_resolve :: proc(t: ^testing.T) {
    css := ".b{animation:pulse 2s infinite}" +
           "@keyframes pulse{0%{opacity:1}50%{opacity:0.2}100%{opacity:1}}"
    c := test_compute_anim(css, "div", "b")
    testing.expect(t, c.anim.active, "animation ativa")
    testing.expect(t, near(c.anim.dur, 2), "dur 2s")
    testing.expect(t, near(c.anim.iter, 0), "infinite => iter 0")
    testing.expect_value(t, c.anim.n, 3)
    testing.expect(t, c.anim.stops[1].has_opacity && near(c.anim.stops[1].opacity, 0.2), "50% opacity 0.2")
}

@(test)
test_animation_from_to_cor :: proc(t: ^testing.T) {
    // from/to + background-color; conta iterações e nome via longhand
    css := ".x{animation-name:fade;animation-duration:0.5s}" +
           "@keyframes fade{from{background-color:#ff0000}to{background-color:#0000ff}}"
    c := test_compute_anim(css, "div", "x")
    testing.expect(t, c.anim.active, "ativa via longhands")
    testing.expect(t, near(c.anim.dur, 0.5), "0.5s")
    testing.expect_value(t, c.anim.n, 2)
    testing.expect(t, c.anim.stops[0].has_bg && c.anim.stops[0].bg == 0xff0000, "from vermelho")
    testing.expect(t, c.anim.stops[1].has_bg && c.anim.stops[1].bg == 0x0000ff, "to azul")
}

@(test)
test_animation_sem_keyframes :: proc(t: ^testing.T) {
    // animation apontando p/ nome inexistente => não ativa
    c := test_compute_anim(".y{animation:naoexiste 1s}", "div", "y")
    testing.expect(t, !c.anim.active, "sem @keyframes correspondente => inativa")
}

// ── transition ───────────────────────────────────────────────────────────────

@(test)
test_transition_dur :: proc(t: ^testing.T) {
    // A duração deixou de ser um escalar por elemento e virou tabela por CANAL
    // (M223) — `transition: 0.3s` sem nome de prop equivale a `all`.
    testing.expect(t, near(test_apply("transition: 0.3s").trans[.Bg].dur, 0.3),                  "0.3s (all)")
    testing.expect(t, near(test_apply("transition: background 200ms ease").trans[.Bg].dur, 0.2), "200ms + nome/timing")
    testing.expect(t, near(test_apply("transition-duration: 0.5s").trans[.Opacity].dur, 0.5),    "transition-duration")
    testing.expect(t, near(test_apply("color: red").trans[.Bg].dur, 0),                          "sem transition => 0")
    // e o nome agora RESTRINGE: `background` não pode animar o transform
    testing.expect(t, near(test_apply("transition: background 200ms").trans[.Transform].dur, 0), "nome restringe o canal")
}

@(test)
test_lerp_color_meio :: proc(t: ^testing.T) {
    // preto -> branco a 0.5 = cinza ~0x7f7f7f
    c := test_lerp_color(0x000000, 0xffffff, 0.5)
    testing.expect_value(t, c, u32(0x7f7f7f))
    // t=0 e t=1 devolvem os extremos
    testing.expect_value(t, test_lerp_color(0x112233, 0xaabbcc, 0), u32(0x112233))
    testing.expect_value(t, test_lerp_color(0x112233, 0xaabbcc, 1), u32(0xaabbcc))
}

// ── quick wins: -webkit-text-decoration / cursor / object-position ───────────

@(test)
test_webkit_text_decoration :: proc(t: ^testing.T) {
    // prefixo do Safari cai no mesmo caminho de text-decoration
    c := test_apply("-webkit-text-decoration: underline")
    testing.expect(t, c.underline, "-webkit-text-decoration:underline sublinha")
    c2 := test_apply("-webkit-text-decoration: line-through")
    testing.expect(t, c2.strike, "-webkit-text-decoration:line-through risca")
}

@(test)
test_fmt_counter :: proc(t: ^testing.T) {
    testing.expect(t, fmt_counter(7, "decimal") == "7", "decimal")
    testing.expect(t, fmt_counter(5, "decimal-leading-zero") == "05", "leading-zero <10")
    testing.expect(t, fmt_counter(42, "decimal-leading-zero") == "42", "leading-zero >=10")
    testing.expect(t, fmt_counter(4, "lower-roman") == "iv", "lower-roman")
    testing.expect(t, fmt_counter(1994, "upper-roman") == "MCMXCIV", "upper-roman")
    testing.expect(t, fmt_counter(9, "georgian") == "9", "estilo não suportado → decimal")
}

@(test)
test_counters_resolve :: proc(t: ^testing.T) {
    // pilha de counters + counter()/counters() sobre ela
    cs := make(map[string]^[dynamic]int); defer { for _, st in cs { delete(st^); free(st) }; delete(cs) }
    append(counter_get(&cs, "c"), 3)
    testing.expect(t, resolve_content_counters(`counter(c)`, &cs) == "3", "counter simples")
    testing.expect(t, resolve_content_counters(`"[" counter(c, decimal-leading-zero) "]"`, &cs) == "[03]", "mistura string+counter")
    append(counter_get(&cs, "c"), 5) // aninha: pilha = [3,5]
    testing.expect(t, resolve_content_counters(`counters(c, ".")`, &cs) == "3.5", "counters junta a pilha")
    testing.expect(t, resolve_content_counters(`counter(c)`, &cs) == "5", "counter = innermost")
}

@(test)
test_counter_set :: proc(t: ^testing.T) {
    cs := make(map[string]^[dynamic]int); defer { for _, st in cs { delete(st^); free(st) }; delete(cs) }
    pushed: [dynamic]string; defer delete(pushed)
    // counter-set num counter inexistente: cria no escopo com o valor dado
    counter_apply_set("c 7", &cs, &pushed)
    testing.expect(t, counter_top(&cs, "c") == 7, "counter-set cria com valor 7")
    // counter-set sobrescreve o topo existente (não empilha)
    counter_apply_set("c 2", &cs, &pushed)
    testing.expect(t, counter_top(&cs, "c") == 2, "counter-set sobrescreve para 2")
    testing.expect(t, len(cs["c"]) == 1, "counter-set não empilha novo nível")
    // valor default = 0
    counter_apply_set("d", &cs, &pushed)
    testing.expect(t, counter_top(&cs, "d") == 0, "counter-set sem valor = 0")
}

@(test)
test_quote_mark :: proc(t: ^testing.T) {
    // default por idioma (sem prop `quotes`)
    testing.expect(t, quote_mark("", "en-US", 0, true)  == "“", "en aspa dupla abre")
    testing.expect(t, quote_mark("", "en-US", 0, false) == "”", "en aspa dupla fecha")
    testing.expect(t, quote_mark("", "en-US", 1, true)  == "‘", "en aspa simples aninhada")
    testing.expect(t, quote_mark("", "fr", 0, true)     == "«", "fr guillemet")
    testing.expect(t, quote_mark("", "el", 1, false)    == "”", "el nível interno = curly")
    testing.expect(t, quote_mark("", "fa", 0, true)     == "«", "persa guillemet")
    // prop `quotes` explícita sobrepõe o idioma
    testing.expect(t, quote_mark(`"<" ">"`, "en", 0, true)  == "<", "quotes prop abre")
    testing.expect(t, quote_mark(`"<" ">"`, "en", 0, false) == ">", "quotes prop fecha")
    // profundidade além dos pares definidos usa o último par
    testing.expect(t, quote_mark(`"<" ">"`, "en", 5, true) == "<", "clampa ao último par")
    testing.expect(t, quote_mark(`"a" "b" "c" "d"`, "en", 1, true) == "c", "2º par")
    // none = sem marca; auto = default do idioma
    testing.expect(t, quote_mark("none", "en", 0, true) == "", "quotes:none = vazio")
    testing.expect(t, quote_mark("auto", "fr", 0, true) == "«", "quotes:auto = idioma")
}

@(test)
test_text_decoration_overline_color_style :: proc(t: ^testing.T) {
    // overline (linha nova), estilo e cor juntos no shorthand
    c := test_apply("text-decoration: overline dotted blue")
    testing.expect(t, c.overline, "overline liga a linha de cima")
    testing.expect(t, !c.underline && !c.strike, "só overline")
    testing.expect(t, c.deco_style == .Dotted, "estilo dotted do shorthand")
    testing.expect_value(t, c.deco_color, u32(0x0000ff))
    // longhands independentes
    c2 := test_apply("text-decoration-line: underline; text-decoration-color: green; text-decoration-style: wavy; text-decoration-thickness: 3px")
    testing.expect(t, c2.underline, "line longhand")
    testing.expect_value(t, c2.deco_color, u32(0x008000))
    testing.expect(t, c2.deco_style == .Wavy, "style longhand")
    testing.expect(t, abs(c2.deco_thick - 3) < 0.01, "thickness longhand em px")
    // sem cor explícita → DECO_UNSET (usa a cor do texto no paint)
    c3 := test_apply("text-decoration: underline")
    testing.expect_value(t, c3.deco_color, DECO_UNSET)
}

@(test)
test_cursor_parse :: proc(t: ^testing.T) {
    testing.expect(t, test_apply("cursor: pointer").cursor     == .Pointer,    "pointer")
    testing.expect(t, test_apply("cursor: text").cursor        == .Text,       "text")
    testing.expect(t, test_apply("cursor: not-allowed").cursor == .NotAllowed, "not-allowed")
    testing.expect(t, test_apply("cursor: grab").cursor        == .Move,       "grab => move")
    testing.expect(t, test_apply("color: red").cursor          == .Auto,       "padrao Auto")
}

@(test)
test_object_position :: proc(t: ^testing.T) {
    c := test_apply("object-position: 25% 75%")
    testing.expect(t, near(c.obj_pos_x, 0.25), "object-position x 25%")
    testing.expect(t, near(c.obj_pos_y, 0.75), "object-position y 75%")
    d := test_apply("object-position: left top")
    testing.expect(t, near(d.obj_pos_x, 0) && near(d.obj_pos_y, 0), "left top => 0,0")
    e := test_apply("color: red")
    testing.expect(t, near(e.obj_pos_x, 0.5) && near(e.obj_pos_y, 0.5), "padrao centro 0.5,0.5")
}

// ── :hover ─────────────────────────────────────────────────────────────────

@(test)
test_hover_color :: proc(t: ^testing.T) {
    c := test_compute_one("a{color:blue} a:hover{color:red}", "a")
    testing.expect_value(t, c.color, u32(0x0000ff))       // normal: azul (hover NÃO vaza)
    testing.expect(t, c.hover.active, "tem regra :hover")
    testing.expect(t, c.hover.has_color, "hover define cor")
    testing.expect_value(t, c.hover.color, u32(0xff0000)) // hover: vermelho
}

@(test)
test_hover_bg :: proc(t: ^testing.T) {
    c := test_compute_one(".btn:hover{background:#00ff00}", "div", "btn")
    testing.expect(t, !c.has_bg, "sem fundo no estado normal")
    testing.expect(t, c.hover.has_bg, "hover define fundo")
    testing.expect_value(t, c.hover.bg, u32(0x00ff00))
}

@(test)
test_hover_nao_vaza :: proc(t: ^testing.T) {
    // REGRESSÃO: antes o pass normal aceitava .Other, então :hover era aplicado
    // SEMPRE. Agora o estado normal ignora regras :hover.
    c := test_compute_one("div{color:black} div:hover{color:red}", "div")
    testing.expect_value(t, c.color, u32(0x000000))
    testing.expect(t, c.hover.has_color && c.hover.color == 0xff0000, "vermelho fica no hover")
}

@(test)
test_hover_ausente :: proc(t: ^testing.T) {
    c := test_compute_one("div{color:red}", "div")
    testing.expect(t, !c.hover.active, "sem :hover => hover.active false")
}

@(test)
test_pseudo_nao_aliasa_em_filhos :: proc(t: ^testing.T) {
    // REGRESSÃO do crash de navegação: um elemento com ::before/::after e um
    // filho de texto NÃO pode fazer o filho herdar o ponteiro ^Computed do
    // pseudo — senão o mapa tem o mesmo ponteiro em 2 entradas e free_styles
    // dá double free (só disparava na 2ª navegação). Deve haver 0 compartilhados.
    _, shared := test_pseudo_alias("div::before{content:\"x\"} div::after{content:\"y\"}", "div")
    testing.expect_value(t, shared, 0)
}

// `background-clip` NÃO herda (CSS Backgrounds §2.3), mas era o único campo de
// fundo que ficava de fora do bloco de reset de não-herdadas em compute_node —
// `bg_origin`, `bg_size`, `bg_repeat`, `bg_fixed`, `grad`, `bg_img`, `has_bg` e
// `bg` são todos zerados ali, `bg_clip` não era. Efeito: um ancestral com
// `background-clip: content-box` recortava também o fundo PRÓPRIO de qualquer
// descendente. Achado diffando os campos do Computed contra o bloco de reset.
@(test)
test_background_clip_nao_herda :: proc(t: ^testing.T) {
    dom := htmlp.parse(`<div class="pai"><span class="filho">x</span><b class="neto">y</b></div>`)
    rules, _ := csspkg.parse(`.pai   { background: red; background-clip: content-box }
                              .filho { background: blue }`)
    styles, _ := compute_styles(dom, &rules)

    pais:   [dynamic]^dompkg.Node; defer delete(pais)
    filhos: [dynamic]^dompkg.Node; defer delete(filhos)
    netos:  [dynamic]^dompkg.Node; defer delete(netos)
    find_elems(dom, "div",  &pais)
    find_elems(dom, "span", &filhos)
    find_elems(dom, "b",    &netos)
    testing.expect(t, len(pais) == 1 && len(filhos) == 1 && len(netos) == 1, "DOM esperado")
    if len(pais) != 1 || len(filhos) != 1 || len(netos) != 1 do return

    // o próprio elemento continua honrando a propriedade (o teste PODE falhar
    // nos dois sentidos: se o reset for exagerado, esta expectativa quebra)
    testing.expectf(t, styles[pais[0]].bg_clip == .Content,
        "quem declarou deveria ficar com content-box, veio %v", styles[pais[0]].bg_clip)
    // descendentes voltam ao valor inicial (border-box), tendo fundo próprio ou não
    testing.expectf(t, styles[filhos[0]].bg_clip == .Border,
        "background-clip NÃO herda: filho com fundo próprio deveria ser border-box, veio %v",
        styles[filhos[0]].bg_clip)
    testing.expectf(t, styles[netos[0]].bg_clip == .Border,
        "background-clip NÃO herda: irmão sem fundo deveria ser border-box, veio %v",
        styles[netos[0]].bg_clip)
}

// A palavra-chave `inherit` (CSS Values §4.4) continua pegando o valor do pai —
// isto é DIFERENTE de herdar implicitamente. Enquanto bg_clip vazava, este caso
// "funcionava" por acidente; o wpt css-backgrounds/background-clip-006 é
// exatamente ele, e foi o que quebrou quando o vazamento parou.
@(test)
test_background_clip_palavra_inherit :: proc(t: ^testing.T) {
    dom := htmlp.parse(`<div class="pai"><span class="ex">x</span><b class="im">y</b></div>`)
    rules, _ := csspkg.parse(`.pai { background-clip: content-box }
                              .ex  { background-clip: inherit }`)
    styles, _ := compute_styles(dom, &rules)
    ex: [dynamic]^dompkg.Node; defer delete(ex)
    im: [dynamic]^dompkg.Node; defer delete(im)
    find_elems(dom, "span", &ex)
    find_elems(dom, "b", &im)
    testing.expect(t, len(ex) == 1 && len(im) == 1, "DOM esperado")
    if len(ex) != 1 || len(im) != 1 do return
    testing.expectf(t, styles[ex[0]].bg_clip == .Content,
        "`background-clip: inherit` deveria pegar o content-box do pai, veio %v", styles[ex[0]].bg_clip)
    testing.expectf(t, styles[im[0]].bg_clip == .Border,
        "sem `inherit` explícito NÃO herda, veio %v", styles[im[0]].bg_clip)
}
