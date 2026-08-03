package ui

// Lote 31 — shorthand `grid` (2 sites, 578 ocorrências: NÃO era reconhecido) +
// aliases lógicos legados do WebKit/Gecko (-webkit-margin-after etc.).
// Testes com CONTROLE (o mesmo HTML sem a prop), disciplina do lote 24.

import "core:testing"

@(test)
test_grid_shorthand :: proc(t: ^testing.T) {
    // 1. forma simples `<linhas> / <colunas>` (delega ao grid-template)
    c := test_compute_one("div{display:grid;grid:60px 40px / 100px 200px}")
    testing.expectf(t, c.grid_row_track_n == 2 && c.grid_track_n == 2,
        "esperadas 2 linhas e 2 colunas, veio %d/%d", c.grid_row_track_n, c.grid_track_n)
    testing.expectf(t, c.grid_row_tracks[0].value == 60 && c.grid_tracks[1].value == 200,
        "valores das trilhas: veio linha0=%v col1=%v", c.grid_row_tracks[0].value, c.grid_tracks[1].value)

    // 2. `auto-flow` à ESQUERDA = fluxo por LINHA, e a sobra são as linhas implícitas
    c2 := test_compute_one("div{display:grid;grid:auto-flow 80px / 1fr 1fr}")
    testing.expect(t, !c2.grid_flow_col, "auto-flow à esquerda = fluxo por LINHA")
    testing.expectf(t, c2.grid_auto_row_n == 1 && c2.grid_auto_rows[0].value == 80,
        "trilha implícita de linha 80px, veio n=%d v=%v", c2.grid_auto_row_n, c2.grid_auto_rows[0].value)
    testing.expectf(t, c2.grid_track_n == 2, "as colunas explícitas deveriam vir do outro lado, veio %d", c2.grid_track_n)

    // 3. `auto-flow` à DIREITA = fluxo por COLUNA (o espelho)
    c3 := test_compute_one("div{display:grid;grid:1fr 1fr / auto-flow 120px}")
    testing.expect(t, c3.grid_flow_col, "auto-flow à direita = fluxo por COLUNA")
    testing.expectf(t, c3.grid_auto_col_n == 1 && c3.grid_auto_cols[0].value == 120,
        "trilha implícita de coluna 120px, veio n=%d v=%v", c3.grid_auto_col_n, c3.grid_auto_cols[0].value)
    testing.expectf(t, c3.grid_row_track_n == 2, "as linhas explícitas vêm da esquerda, veio %d", c3.grid_row_track_n)

    // 4. `dense`
    c4 := test_compute_one("div{display:grid;grid:auto-flow dense 40px / 1fr}")
    testing.expect(t, c4.grid_flow_dense, "dense deveria ser reconhecido no shorthand")

    // CONTROLE: sem a prop, nada disso pode estar ligado (senão o teste não prova nada)
    c5 := test_compute_one("div{display:grid}")
    testing.expect(t, c5.grid_track_n == 0 && c5.grid_auto_row_n == 0 && !c5.grid_flow_col && !c5.grid_flow_dense,
        "controle: sem `grid` nada deveria estar configurado")
}

@(test)
test_alias_logico_legado :: proc(t: ^testing.T) {
    // -webkit-margin-after → margin-block-end → (horizontal-tb) margin-bottom
    c := test_compute_one("div{-webkit-margin-after:18px}")
    testing.expectf(t, c.margin[2] == 18, "-webkit-margin-after → margin-bottom 18, veio %v", c.margin[2])
    c2 := test_compute_one("div{-webkit-margin-before:7px}")
    testing.expectf(t, c2.margin[0] == 7, "-webkit-margin-before → margin-top 7, veio %v", c2.margin[0])
    c3 := test_compute_one("div{-webkit-padding-after:9px}")
    testing.expectf(t, c3.padding[2] == 9, "-webkit-padding-after → padding-bottom 9, veio %v", c3.padding[2])
}
