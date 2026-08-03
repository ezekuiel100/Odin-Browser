package ui

// Lote 22 — aliases de FORNECEDOR e LEGADOS, guiado pelo gap-report real:
// -webkit-/-moz-/-ms-/-o- de props que já implementamos eram simplesmente
// DESCARTADAS (-webkit-box-sizing aparecia em 95862 ocorrências, -ms-flex-align
// em 30629...). Traduzidos em collect_decls → só testáveis via test_compute_one.

import "core:testing"

@(test)
test_alias_vendor_prefix :: proc(t: ^testing.T) {
    // prefixo genérico: a prop padrão passa a valer
    c := test_compute_one("div{-webkit-box-sizing:border-box}")
    testing.expect(t, c.box_sizing == .Border, "-webkit-box-sizing deveria virar box-sizing")

    c2 := test_compute_one("div{-ms-flex-direction:column}")
    testing.expect(t, c2.flex_dir == .Column, "-ms-flex-direction deveria virar flex-direction")

    c3 := test_compute_one("div{-moz-column-gap:20px}")
    testing.expectf(t, c3.gap == 20, "-moz-column-gap: esperado 20, veio %v", c3.gap)

    c4 := test_compute_one("div{-o-object-fit:cover}")
    testing.expect(t, c4.obj_fit == .Cover, "-o-object-fit deveria virar object-fit")

    c5 := test_compute_one("div{-moz-border-radius:12px}")
    testing.expectf(t, c5.border_radius[0] == 12, "-moz-border-radius: esperado 12, veio %v", c5.border_radius[0])
}

@(test)
test_alias_prefix_nao_sequestra_conhecidas :: proc(t: ^testing.T) {
    // props prefixadas com semântica PRÓPRIA não podem ser aliasadas p/ a base
    // (-webkit-line-clamp ≠ line-clamp genérico; -webkit-mask-image tem parser próprio)
    c := test_compute_one("div{-webkit-line-clamp:3}")
    testing.expectf(t, c.line_clamp == 3, "-webkit-line-clamp: esperado 3, veio %v", c.line_clamp)

    c2 := test_compute_one("div{-webkit-mask-image:linear-gradient(black,transparent)}")
    testing.expect(t, c2.mask_grad.active, "-webkit-mask-image deveria continuar ativando a máscara")
}

@(test)
test_alias_ordem_de_cascata :: proc(t: ^testing.T) {
    // Na MESMA regra não há ordem por-declaração (o `wins` guarda a ordem da
    // REGRA) → empate resolvido a favor do PADRÃO, nas duas ordens de fonte.
    c := test_compute_one("div{-webkit-box-sizing:border-box;box-sizing:content-box}")
    testing.expect(t, c.box_sizing == .Content, "padrão deveria vencer o prefixado no empate")
    c2 := test_compute_one("div{box-sizing:content-box;-webkit-box-sizing:border-box}")
    testing.expect(t, c2.box_sizing == .Content, "empate na mesma regra é sempre do padrão")

    // Entre REGRAS diferentes a ordem de fonte decide normalmente, nos 2 sentidos.
    c3 := test_compute_one("div{-webkit-box-sizing:border-box} div{box-sizing:content-box}")
    testing.expect(t, c3.box_sizing == .Content, "regra posterior (padrão) deveria vencer")
    c4 := test_compute_one("div{box-sizing:content-box} div{-webkit-box-sizing:border-box}")
    testing.expect(t, c4.box_sizing == .Border, "regra posterior (prefixada) deveria vencer")

    // Especificidade maior vence mesmo vindo antes (prefixado em .cls > div).
    c5 := test_compute_one(".c{-webkit-box-sizing:border-box} div{box-sizing:content-box}", "div", "c")
    testing.expect(t, c5.box_sizing == .Border, "alias deveria carregar a spec do seletor original")
}

@(test)
test_alias_flexbox_legado :: proc(t: ^testing.T) {
    // valores legados (start/end/justify) precisam de TRADUÇÃO, não só renome
    c := test_compute_one("div{-webkit-box-align:center}")
    testing.expect(t, c.align_items == .Center, "-webkit-box-align:center → align-items:center")

    c2 := test_compute_one("div{-ms-flex-align:end}")
    testing.expect(t, c2.align_items == .End, "-ms-flex-align:end → align-items:flex-end")

    c3 := test_compute_one("div{-ms-flex-pack:justify}")
    testing.expect(t, c3.justify == .Between, "-ms-flex-pack:justify → justify-content:space-between")

    c4 := test_compute_one("div{-webkit-box-pack:start}")
    testing.expect(t, c4.justify == .Start, "-webkit-box-pack:start → justify-content:flex-start")

    c5 := test_compute_one("div{-ms-flex-negative:0;-ms-flex-positive:2}")
    testing.expectf(t, c5.flex_shrink == 0 && c5.flex_grow == 2,
        "-ms-flex-negative/positive: esperado shrink 0 grow 2, veio %v/%v", c5.flex_shrink, c5.flex_grow)
}

@(test)
test_alias_grid_gap_e_flex_flow :: proc(t: ^testing.T) {
    c := test_compute_one("div{grid-gap:10px 20px}")
    testing.expectf(t, c.row_gap == 10 && c.gap == 20,
        "grid-gap → gap: esperado 10/20, veio %v/%v", c.row_gap, c.gap)

    c2 := test_compute_one("div{grid-column-gap:8px;grid-row-gap:4px}")
    testing.expectf(t, c2.gap == 8 && c2.row_gap == 4,
        "grid-*-gap: esperado col 8 row 4, veio %v/%v", c2.gap, c2.row_gap)

    // flex-flow: ordem livre dos dois componentes
    c3 := test_compute_one("div{flex-flow:column wrap}")
    testing.expect(t, c3.flex_dir == .Column && c3.flex_wrap, "flex-flow:column wrap")

    c4 := test_compute_one("div{flex-flow:wrap-reverse row-reverse}")
    testing.expect(t, c4.flex_dir == .Row && c4.flex_reverse && c4.flex_wrap, "flex-flow ordem invertida")
}

@(test)
test_alias_grid_line_longhands :: proc(t: ^testing.T) {
    // grid-column-start/end existiam no CSS real mas eram descartados; agora
    // viram o shorthand "<start> / <end>" que parse_grid_line já entende.
    c := test_compute_one("div{grid-column-start:2;grid-column-end:4}")
    testing.expectf(t, c.grid_col_start == 2 && c.grid_col_span == 2,
        "grid-column-start/end: esperado start 2 span 2, veio %v/%v", c.grid_col_start, c.grid_col_span)

    // só o start (end ausente = auto → span 1)
    c2 := test_compute_one("div{grid-row-start:3}")
    testing.expectf(t, c2.grid_row_start == 3 && c2.grid_row_span == 1,
        "grid-row-start só: esperado start 3 span 1, veio %v/%v", c2.grid_row_start, c2.grid_row_span)
}

// Lote 25 — sobras de alias que a tabela do lote 22 não pegou (gap-report:
// -webkit-box-flex 6 sites, -webkit-box-direction 4, -webkit-padding-start 3,
// -moz-column-break-inside 3). O bloco de aliases passou a rodar ANTES do de
// props lógicas, então um alias pode virar `padding-inline-start` e ser
// traduzido para o físico em seguida — é o que este teste prova.
@(test)
test_alias_legado_lote25 :: proc(t: ^testing.T) {
    c := test_compute_one("div{-webkit-box-flex:3}")
    testing.expectf(t, c.flex_grow == 3, "-webkit-box-flex → flex-grow: esperado 3, veio %v", c.flex_grow)

    // início/fim lógicos com prefixo → lógica → FÍSICA (ltr: start = esquerda)
    c2 := test_compute_one("div{-webkit-padding-start:24px}")
    testing.expectf(t, c2.padding[3] == 24, "-webkit-padding-start → padding-left: esperado 24, veio %v", c2.padding[3])
    c3 := test_compute_one("div{-moz-margin-end:12px}")
    testing.expectf(t, c3.margin[1] == 12, "-moz-margin-end → margin-right: esperado 12, veio %v", c3.margin[1])

    // box-direction: o EIXO vem do box-orient (que não é aliasado)
    c4 := test_compute_one("div{-webkit-box-direction:reverse}")
    testing.expect(t, c4.flex_dir == .Row && c4.flex_reverse, "box-direction:reverse → row-reverse")
    c5 := test_compute_one("div{-webkit-box-orient:vertical;-webkit-box-direction:reverse}")
    testing.expect(t, c5.flex_dir == .Column && c5.flex_reverse, "com box-orient:vertical → column-reverse")
    // `normal` não deve inverter nada
    c6 := test_compute_one("div{-webkit-box-direction:normal}")
    testing.expect(t, !c6.flex_reverse, "box-direction:normal não deveria inverter")

    // quebra de coluna legada. ⚠️ testo o -before, não o -inside: `break-inside`
    // é RECONHECIDA mas INERTE no motor (só before/after têm efeito), então um
    // assert nele não poderia falhar — e teste que não pode falhar não vale nada.
    c7 := test_compute_one("div{-webkit-column-break-before:avoid}")
    testing.expect(t, c7.break_before_avoid, "-webkit-column-break-before → break-before:avoid")
}
