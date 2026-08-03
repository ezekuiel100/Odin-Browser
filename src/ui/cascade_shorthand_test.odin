package ui

// M241 — SHORTHAND × LONGHAND competindo na cascata.
//
// O `wins` do collect_decls é um mapa chaveado pelo NOME da propriedade, então
// `padding` e `padding-left` nunca se comparavam: cada um vencia a SUA chave e
// quem decidia de fato era a ordem fixa de aplicação em apply_decls. Só três
// shorthands tinham desempate explícito (`background`, `font`, `border`), com
// listas parciais.
//
// Origem: o "Skip to content" do github, achado pela sonda de CASCATA
// (CASCADEPROBE). `.show-on-focus:not(:focus){padding:0!important}` (spec 20
// depois do M240) perdia para `.px-2{padding-left:8px!important}` (spec 10) e
// para `.tmp-py-4{padding-top:24px!important}` — três "vencedores" ao mesmo
// tempo, cada um na sua chave.
//
// ⚠️ Precisa do M240 junto: sem a especificidade do `:not(:focus)`, o
// `.tmp-py-4` (ordem 4146) venceria o `padding:0` (ordem 2398) por ordem de
// fonte, e a expansão sozinha não salvaria o caso.

import "core:testing"
import "core:fmt"

// ── o caso do github, reduzido ──────────────────────────────────────────────

@(test)
m241_shorthand_mais_especifico_apaga_longhand :: proc(t: ^testing.T) {
    // `.a.b` (20) declara o shorthand; `.p` (10) declara o longhand DEPOIS.
    // Antes: os dois sobreviviam e o longhand, aplicado por último, vencia.
    c := test_compute_one(".a.b{padding:0} .p{padding-left:8px}", "div", "a b p")
    testing.expectf(t, c.padding[3] == 0,
        "shorthand de spec MAIOR tem de apagar o longhand: padding-left esperava 0, veio %v", c.padding[3])
    testing.expect_value(t, c.padding[0], f32(0))
}

@(test)
m241_a_forma_exata_do_github :: proc(t: ^testing.T) {
    // Três regras !important, o shorthand com spec 20 e os dois longhands com 10,
    // ambos DEPOIS na fonte — que é o que a sonda de cascata imprimiu na página
    // real (ordens 2398 / 1878 / 4146).
    css := ".px-2{padding-left:8px !important}" +
           ".show-on-focus:not(:focus){padding:0 !important}" +
           ".tmp-py-4{padding-top:24px !important}"
    c := test_compute_one(css, "a", "px-2 show-on-focus tmp-py-4")
    testing.expectf(t, c.padding == [4]f32{0, 0, 0, 0},
        "os 4 lados vêm do shorthand mais específico; veio %v", c.padding)
}

// ── o caminho INVERSO tem de continuar funcionando ──────────────────────────
//
// Quando o LONGHAND vence, guardamos os dois: o shorthand roda primeiro em
// apply_decls e o longhand sobrescreve só o seu lado. É por isso que cada par da
// tabela exige a ordem shorthand-antes-de-longhand no fonte.

@(test)
m241_longhand_mais_especifico_sobrevive :: proc(t: ^testing.T) {
    c := test_compute_one(".p.q{padding-left:8px} .a{padding:0}", "div", "a p q")
    testing.expectf(t, c.padding[3] == 8,
        "longhand de spec MAIOR tem de vencer o seu lado: esperava 8, veio %v", c.padding[3])
    testing.expectf(t, c.padding[0] == 0,
        "…e os OUTROS lados seguem vindo do shorthand: topo esperava 0, veio %v", c.padding[0])
}

@(test)
m241_empate_desempata_por_ordem_de_fonte :: proc(t: ^testing.T) {
    // Mesma especificidade: quem vem depois vence. Nos DOIS sentidos.
    c1 := test_compute_one(".a{padding:0} .b{padding-left:8px}", "div", "a b")
    testing.expectf(t, c1.padding[3] == 8, "longhand DEPOIS vence o empate; veio %v", c1.padding[3])

    c2 := test_compute_one(".b{padding-left:8px} .a{padding:0}", "div", "a b")
    testing.expectf(t, c2.padding[3] == 0, "shorthand DEPOIS vence o empate; veio %v", c2.padding[3])
}

// ── as outras famílias que entraram ─────────────────────────────────────────

@(test)
m241_margin_e_inset :: proc(t: ^testing.T) {
    m := test_compute_one(".a.b{margin:0} .p{margin-top:9px}", "div", "a b p")
    testing.expectf(t, m.margin[0] == 0, "margin shorthand mais específico apaga margin-top; veio %v", m.margin[0])

    // `inset` no Computed é [4]f32 na ordem t r b l — o `left` é o índice 3.
    i := test_compute_one(".a.b{inset:5px} .p{left:40px}", "div", "a b p")
    testing.expectf(t, i.inset[3] == 5, "inset mais específico apaga `left`; veio %v", i.inset[3])
}

@(test)
m241_overflow_e_gap :: proc(t: ^testing.T) {
    // ⚠️ overflow tem blockificação (um eixo hidden arrasta o outro), então aqui
    // o que se afirma é o efeito do DESEMPATE: `visible` do shorthand vencendo.
    o := test_compute_one(".a.b{overflow:visible} .p{overflow-x:hidden}", "div", "a b p")
    testing.expectf(t, !o.ovf_clip_x && !o.ovf_clip_y,
        "overflow:visible mais específico apaga overflow-x:hidden; veio x=%v y=%v", o.ovf_clip_x, o.ovf_clip_y)

    g := test_compute_one(".a.b{gap:0} .p{row-gap:30px}", "div", "a b p")
    testing.expectf(t, g.row_gap == 0, "gap mais específico apaga row-gap; veio %v", g.row_gap)
}

@(test)
m241_border_alcanca_a_subarvore_inteira :: proc(t: ^testing.T) {
    // `border` é ancestral TRANSITIVO de border-top-width (border → border-top →
    // border-top-width e border → border-width → border-top-width). Listar só os
    // descendentes diretos deixaria este caso passar batido.
    c := test_compute_one(".a.b{border:1px solid red} .p{border-top-width:20px}", "div", "a b p")
    testing.expectf(t, c.border_w[0] == 1,
        "border mais específico apaga border-top-width; esperava 1, veio %v", c.border_w[0])

    // e o box4 intermediário
    c2 := test_compute_one(".a.b{border-width:1px} .p{border-left-width:20px}", "div", "a b p")
    testing.expectf(t, c2.border_w[3] == 1,
        "border-width mais específico apaga border-left-width; esperava 1, veio %v", c2.border_w[3])
}

@(test)
m241_border_radius :: proc(t: ^testing.T) {
    c := test_compute_one(".a.b{border-radius:0} .p{border-top-left-radius:12px}", "div", "a b p")
    testing.expectf(t, c.border_radius[0] == 0,
        "border-radius mais específico apaga o canto; veio %v", c.border_radius[0])
}

// ── CONTROLES: o que esta mudança NÃO pode ter quebrado ─────────────────────

@(test)
m241_longhand_sozinho_intocado :: proc(t: ^testing.T) {
    // Sem shorthand concorrente nada é apagado — o caminho comum segue igual.
    c := test_compute_one(".p{padding-left:8px;padding-top:4px}", "div", "p")
    testing.expect_value(t, c.padding[3], f32(8))
    testing.expect_value(t, c.padding[0], f32(4))
}

@(test)
m241_shorthand_sozinho_intocado :: proc(t: ^testing.T) {
    c := test_compute_one(".a{padding:3px 5px}", "div", "a")
    testing.expectf(t, c.padding == [4]f32{3, 5, 3, 5}, "shorthand sozinho segue expandindo; veio %v", c.padding)
}

@(test)
m241_props_de_familias_diferentes_nao_se_apagam :: proc(t: ^testing.T) {
    // `padding` não pode encostar em `margin-left` — teste que pega tabela
    // escrita com a lista de longhands da família errada (copiar-e-colar).
    c := test_compute_one(".a.b{padding:0} .p{margin-left:8px}", "div", "a b p")
    testing.expectf(t, c.margin[3] == 8, "margin-left não é longhand de padding; veio %v", c.margin[3])
}

// ── IRMÃOS sobrepostos — era a degradação declarada do M241, FECHADA no M243 ──
//
// `border-top` e `border-width` não são ancestral/descendente: nenhum contém o
// outro, mas os dois escrevem `border-top-width`. Enquanto o desempate era
// pairwise, quem decidia era a ordem fixa do apply_decls (border-<lado> antes de
// border-<sub>) e um dos dois sentidos saía errado. O M243 resolve a família no
// nível do ÁTOMO. Ver cascade_border_atom_test.odin para o conjunto completo.

@(test)
m241_irmaos_sobrepostos :: proc(t: ^testing.T) {
    ok_ := test_compute_one(".a{border-top:9px solid red} .b{border-width:2px}", "div", "a b")
    testing.expectf(t, ok_.border_w[0] == 2,
        "border-width DEPOIS vence o topo: esperava 2, veio %v", ok_.border_w[0])

    // O sentido que a ordem fixa errava: border-top vem depois e TEM de vencer.
    inv := test_compute_one(".a{border-width:2px} .b{border-top:9px solid red}", "div", "a b")
    testing.expectf(t, inv.border_w[0] == 9,
        "border-top DEPOIS vence o topo: esperava 9, veio %v (era 2 antes do M243)", inv.border_w[0])
    testing.expectf(t, inv.border_w[1] == 2,
        "…e os outros lados seguem com border-width: direita esperava 2, veio %v", inv.border_w[1])
}
