package ui

import "core:testing"

// subgrid (CSS Grid 2): o valor é resolvido contra o PAI em compute_node, então
// só `test_compute_child` (pai + filho, cascata completa) enxerga.

@(test)
test_subgrid_cols_conta_o_span :: proc(t: ^testing.T) {
    c := test_compute_child(`
        .g { display: grid; grid-template-columns: [a] 100px [b] 1fr [c] 50px [d]; }
        .s { display: grid; grid-template-columns: subgrid; grid-column: 2 / 4; }
    `, "g", "s")
    testing.expect(t, c.grid_sub_cols, "grid-template-columns: subgrid liga o flag")
    testing.expect(t, !c.grid_sub_rows, "o eixo de linhas não foi subgridado")
    testing.expect_value(t, c.grid_track_n, 2) // span 2 → 2 trilhas
    // herda os nomes do pai dentro da área: b→1, c→2, d→3 (a fica fora)
    testing.expect_value(t, c.grid_col_line_n, 3)
}

@(test)
test_subgrid_rows_e_nomes_proprios :: proc(t: ^testing.T) {
    c := test_compute_child(`
        .g { display: grid; }
        .s { display: grid; grid-template-rows: subgrid [topo] [meio] [fim]; grid-row: span 3; }
    `, "g", "s")
    testing.expect(t, c.grid_sub_rows, "grid-template-rows: subgrid liga o flag")
    testing.expect_value(t, c.grid_row_track_n, 3)
    testing.expect_value(t, c.grid_row_line_n, 3)
    testing.expect_value(t, c.grid_track_n, 0) // controle: colunas intocadas
}

@(test)
test_subgrid_sem_pai_grid_vira_none :: proc(t: ^testing.T) {
    c := test_compute_child(`
        .s { display: grid; grid-template-columns: subgrid; grid-column: span 3; }
    `, "g", "s")
    testing.expect(t, !c.grid_sub_cols, "sem pai grid o valor usado é none")
    testing.expect_value(t, c.grid_track_n, 0)
}

@(test)
test_subgrid_gap_declarado :: proc(t: ^testing.T) {
    a := test_compute_child(`.g{display:grid} .s{display:grid;grid-template-rows:subgrid}`, "g", "s")
    testing.expect(t, !a.has_gap_row && !a.has_gap_col, "gap normal: herda o gutter do pai")
    b := test_compute_child(`.g{display:grid;gap:20px} .s{display:grid;grid-template-rows:subgrid;row-gap:0}`, "g", "s")
    testing.expect(t, b.has_gap_row && !b.has_gap_col, "row-gap:0 é DECLARADO (≠ normal) e o gap do pai não herda")
}
