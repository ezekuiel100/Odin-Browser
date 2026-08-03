package ui

// Linha NEGATIVA de grid (`grid-column: 2 / -2`), o bug do hero do stripe.com.
//
// Negativo conta do FIM do grid EXPLICITO: com N tracks ha N+1 linhas, logo
// -1 = N+1 e -2 = N. O motor ignorava o negativo e caia em span 1, entao o <h1>
// do hero (12 colunas, `1 / -1` e depois `2 / -2`) saia com UMA coluna de 86px e
// o texto quebrava uma palavra por linha.
//
// ⚠️ Os testes que importam sao os E2E (test_compute_child): o negativo SO
// resolve contra o nº de tracks do PAI, e foi justamente "onde resolver" que o
// fix teve de decidir. O teste da aritmetica sozinha nao pegaria a resolucao no
// lugar errado.

import "core:testing"

@(test)
test_grid_neg_aritmetica :: proc(t: ^testing.T) {
    // 12 tracks => 13 linhas. -1 = 13, -2 = 12, -3 = 11.
    s, sp := test_grid_resolve_negative(1, 1, -1, 12)
    testing.expect_value(t, s, 1)
    testing.expect_value(t, sp, 12) // 1 -> 13 = 12 colunas

    s, sp = test_grid_resolve_negative(2, 1, -2, 12)
    testing.expect_value(t, s, 2)
    testing.expect_value(t, sp, 10) // 2 -> 12 = 10 colunas

    s, sp = test_grid_resolve_negative(-3, 1, -1, 12)
    testing.expect_value(t, s, 11) // -3 = 11
    testing.expect_value(t, sp, 2) // 11 -> 13

    // `span 2 / -1`: start auto, ancora pelo FIM
    s, sp = test_grid_resolve_negative(0, 2, -1, 12)
    testing.expect_value(t, s, 11)
    testing.expect_value(t, sp, 2)

    // fim POSITIVO tambem ancora, e ai nem precisa do nº de tracks
    s, sp = test_grid_resolve_negative(0, 2, 5, 0)
    testing.expect_value(t, s, 3)
    testing.expect_value(t, sp, 2)
}

// ⚠️ ESTE e o teste que faltava quando eu escrevi a aritmetica: passar pelo PARSER.
// A 1a versao do unitario chamava o helper com (0, 2, -1, 12) e passava, mas o
// `parse_grid_line` JOGAVA FORA o "span 2" da esquerda e nunca produzia span=2 --
// so o golden do fixture pegou. Entrada de teste tem de ser a que o parser gera.
@(test)
test_grid_neg_span_esquerda_pelo_parser :: proc(t: ^testing.T) {
    base :: ".g{display:grid;grid-template-columns:repeat(12,minmax(0,1fr))}"
    c := test_compute_child(base + ".i{grid-column:span 2 / -1}")
    testing.expect_value(t, c.grid_col_start, 11) // 13 - 2
    testing.expect_value(t, c.grid_col_span, 2)

    // sem barra, `span 2` sozinho continua auto-place com span 2 (nao regrediu)
    c2 := test_compute_child(base + ".i{grid-column:span 2}")
    testing.expect_value(t, c2.grid_col_start, 0)
    testing.expect_value(t, c2.grid_col_span, 2)
}

// Sem grid explicito nao existe de onde contar de tras. Tem de degradar para
// AUTO (comportamento anterior) e NUNCA vazar um indice negativo para o layout.
@(test)
test_grid_neg_sem_template_degrada :: proc(t: ^testing.T) {
    s, sp := test_grid_resolve_negative(2, 1, -2, 0)
    testing.expect_value(t, s, 2)
    testing.expect_value(t, sp, 1)

    s, sp = test_grid_resolve_negative(-2, 1, 0, 0)
    testing.expect_value(t, s, 0) // negativo irresolvivel -> auto, nao -2
    testing.expect_value(t, sp, 1)
}

// CONTROLE: valor sem nada negativo tem de sair pelo caminho antigo, intacto.
@(test)
test_grid_neg_positivo_intacto :: proc(t: ^testing.T) {
    s, sp := test_grid_resolve_negative(2, 2, 4, 12)
    testing.expect_value(t, s, 2)
    testing.expect_value(t, sp, 2) // span declarado vence, nao recalcula
    s, sp = test_grid_resolve_negative(0, 1, 0, 12)
    testing.expect_value(t, s, 0)
    testing.expect_value(t, sp, 1)
}

// E2E pela pipeline real, com PAI de 12 tracks.
@(test)
test_grid_neg_e2e_pai_12_tracks :: proc(t: ^testing.T) {
    css := ".g{display:grid;grid-template-columns:repeat(12,minmax(0,1fr))}" +
           ".i{grid-column:2 / -2}"
    c := test_compute_child(css)
    testing.expect_value(t, c.grid_col_start, 2)
    testing.expect_value(t, c.grid_col_span, 10)
    // o campo cru tem de ter sido ZERADO na resolucao (como os nomes de linha)
    testing.expect_value(t, c.grid_col_end_line, 0)
}

// GRAFIA: longhand (o que o stripe usa) e shorthand tem de dar o MESMO resultado.
// E a licao do style_grafia_test: o site real usa a grafia que ninguem testou.
@(test)
test_grid_neg_longhand_igual_shorthand :: proc(t: ^testing.T) {
    // ⚠️ `::` e nao `:=`: em Odin o `+` de string exige operandos CONSTANTES.
    base :: ".g{display:grid;grid-template-columns:repeat(12,minmax(0,1fr))}"
    curto := test_compute_child(base + ".i{grid-column:2 / -2}")
    longo := test_compute_child(base + ".i{grid-column-start:2;grid-column-end:-2}")
    testing.expect_value(t, longo.grid_col_start, curto.grid_col_start)
    testing.expect_value(t, longo.grid_col_span, curto.grid_col_span)
    testing.expect_value(t, longo.grid_col_span, 10)

    // e o mesmo pelo eixo de LINHA, que tem template proprio
    baser :: ".g{display:grid;grid-template-rows:repeat(4,auto)}"
    lr := test_compute_child(baser + ".i{grid-row-start:2;grid-row-end:-1}")
    testing.expect_value(t, lr.grid_row_start, 2)
    testing.expect_value(t, lr.grid_row_span, 3) // 2 -> 5 (4 tracks = 5 linhas)
}

// `grid-area: r1 / c1 / r2 / c2` tinha a MESMA cegueira (`vals[3] > vals[1]`).
@(test)
test_grid_neg_grid_area_shorthand :: proc(t: ^testing.T) {
    css := ".g{display:grid;grid-template-columns:repeat(12,minmax(0,1fr));" +
           "grid-template-rows:repeat(4,auto)}" +
           ".i{grid-area:2 / 2 / -1 / -2}"
    c := test_compute_child(css)
    testing.expect_value(t, c.grid_col_start, 2)
    testing.expect_value(t, c.grid_col_span, 10) // 2 -> 12
    testing.expect_value(t, c.grid_row_start, 2)
    testing.expect_value(t, c.grid_row_span, 3) // 2 -> 5
}
