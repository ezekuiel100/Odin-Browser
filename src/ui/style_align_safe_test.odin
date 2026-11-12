package ui

import "core:testing"

// `safe`/`unsafe` (overflow-position) nas propriedades de alinhamento, e as
// linhas `auto` de grid-column/grid-row que o filho ABSOLUTO do grid precisa
// distinguir. A geometria fica nos goldens tests/layout/align-safe-unsafe e
// tests/layout/grid-abspos; aqui só o que o parser grava.

@(test)
test_align_safe_unsafe_longhands :: proc(t: ^testing.T) {
    c := test_compute_one("div { justify-content: safe center; align-items: unsafe end; align-content: unsafe flex-end }")
    testing.expect(t, c.justify == .Center && c.justify_ovf == .Safe, "justify-content: safe center")
    testing.expect(t, c.align_items == .End && c.align_items_ovf == .Unsafe, "align-items: unsafe end")
    testing.expect(t, c.align_content == .End && c.align_content_ovf == .Unsafe, "align-content: unsafe flex-end")
    testing.expect(t, !c.ac_stretch, "align-content explícito desliga o stretch das trilhas")

    s := test_compute_one("div { align-self: safe center; justify-self: unsafe end; justify-items: safe end }")
    testing.expect(t, s.has_align_self && s.align_self == .Center && s.align_self_ovf == .Safe, "align-self: safe center")
    testing.expect(t, s.has_justify_self && s.justify_self == .End && s.justify_self_ovf == .Unsafe, "justify-self: unsafe end")
    testing.expect(t, s.justify_items == .End && s.justify_items_ovf == .Safe, "justify-items: safe end")

    // sem a palavra-chave nada muda — e o valor continua sendo lido
    d := test_compute_one("div { justify-content: center; align-items: center }")
    testing.expect(t, d.justify == .Center && d.justify_ovf == .Default, "justify-content: center fica Default")
    testing.expect(t, d.align_items == .Center && d.align_items_ovf == .Default, "align-items: center fica Default")
}

@(test)
test_align_safe_unsafe_place_shorthands :: proc(t: ^testing.T) {
    // UM valor de duas palavras vale para os dois eixos (antes: `safe` ia p/ um
    // eixo e `center` p/ o outro)
    c := test_compute_one("div { place-items: safe center }")
    testing.expect(t, c.align_items == .Center && c.align_items_ovf == .Safe, "place-items: safe center → align-items")
    testing.expect(t, c.justify_items == .Center && c.justify_items_ovf == .Safe, "place-items: safe center → justify-items")

    // dois valores, só o segundo com palavra-chave
    c2 := test_compute_one("div { place-content: center unsafe end }")
    testing.expect(t, c2.align_content == .Center && c2.align_content_ovf == .Default, "place-content: 1º valor sem palavra")
    testing.expect(t, c2.justify == .End && c2.justify_ovf == .Unsafe, "place-content: 2º valor unsafe end")

    c3 := test_compute_one("div { place-self: safe end start }")
    testing.expect(t, c3.has_align_self && c3.align_self == .End && c3.align_self_ovf == .Safe, "place-self: safe end")
    testing.expect(t, c3.has_justify_self && c3.justify_self == .Start && c3.justify_self_ovf == .Default, "place-self: start")
}

@(test)
test_grid_line_auto_bits :: proc(t: ^testing.T) {
    // `2` e `2 / 3` dão o MESMO (start, span) — o bit é o que os separa
    a := test_compute_one("div { grid-column: 2 }")
    testing.expect(t, a.grid_col_start == 2 && !a.grid_col_start_auto && a.grid_col_end_auto, "grid-column: 2 → fim auto")
    b := test_compute_one("div { grid-column: 2 / 3 }")
    testing.expect(t, b.grid_col_start == 2 && !b.grid_col_start_auto && !b.grid_col_end_auto, "grid-column: 2 / 3 → nada auto")
    // início auto ancorado pelo fim: o start é DERIVADO (3 - 1 = 2), mas é auto
    c := test_compute_one("div { grid-row: auto / 3 }")
    testing.expect(t, c.grid_row_start == 2 && c.grid_row_start_auto && !c.grid_row_end_auto, "grid-row: auto / 3 → início auto")
    // grid-area: row-start / col-start / row-end / col-end, partes omitidas = auto
    d := test_compute_one("div { grid-area: 2 / 1 / 3 }")
    testing.expect(t, !d.grid_row_start_auto && !d.grid_row_end_auto, "grid-area: linhas de row dadas")
    testing.expect(t, !d.grid_col_start_auto && d.grid_col_end_auto, "grid-area: col-end omitido = auto")
}
