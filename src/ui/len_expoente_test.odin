package ui

// NOTAÇÃO CIENTÍFICA em <length> — `3.40282e38px`, `1e3px`, `1e-2px`.
//
// Por que existe: o **Tailwind v4 emite `rounded-full` como
// `border-radius: 3.40282e38px`** (o máximo do f32, escrito por extenso — não
// `9999px`, não `50%`). O scanner de número parava no `e`, a unidade virava
// "e38px", nenhum `case` casava e a declaração era IGNORADA: a badge "MAIS
// POPULAR" do ultra-photo.com saía com canto RETO onde o Chrome mostra pílula.
//
// ⚠️ A armadilha do conserto é a UNIDADE: `3em` e `2ex` também têm `e` depois do
// número. O expoente só vale com `e` + sinal opcional + ao menos um DÍGITO — por
// isso os testes de não-regressão de `em`/`ex` abaixo valem tanto quanto os do
// expoente. Sem eles, "consertar" o expoente comeria toda unidade que começa com e.

import "core:testing"

@(private = "file")
larg :: proc(decl: string) -> f32 {
    c := test_apply(decl)
    return c.width
}

@(test)
expoente_positivo :: proc(t: ^testing.T) {
    testing.expect_value(t, larg("width: 1e3px"), f32(1000))
    testing.expect_value(t, larg("width: 1E3px"), f32(1000))
    testing.expect_value(t, larg("width: 2.5e2px"), f32(250))
    testing.expect_value(t, larg("width: 1e+3px"), f32(1000))
}

@(test)
expoente_negativo :: proc(t: ^testing.T) {
    w := larg("width: 5e-1px")
    testing.expectf(t, w > 0.49 && w < 0.51, "5e-1px = 0.5px, veio %v", w)
}

// O valor REAL do `rounded-full` do Tailwind v4: tem de parsear (o limite p/ meia
// altura da caixa é do paint, não do parse) e NÃO pode virar 0 nem 3.4.
@(test)
rounded_full_do_tailwind_parseia :: proc(t: ^testing.T) {
    c := test_apply("border-radius: 3.40282e38px")
    testing.expectf(t, c.border_radius[0] > 1e30,
        "o raio tem de ser gigante (o clamp e do paint), veio %v", c.border_radius[0])
    // o modo antigo de falhar: parar no 'e' e ler 3.40282
    testing.expect(t, c.border_radius[0] != 3.40282, "nao pode parar no expoente")
}

// ⚠️ NÃO-REGRESSÃO: unidade que COMEÇA com 'e' continua sendo unidade.
@(test)
em_e_ex_nao_sao_expoente :: proc(t: ^testing.T) {
    // font-size default 16px ⇒ 3em = 48px, 2ex = 2 * 16 * 0.5 = 16px
    testing.expect_value(t, larg("width: 3em"), f32(48))
    testing.expect_value(t, larg("width: 2ex"), f32(16))
    // 'e' sem dígito nenhum depois não é expoente — e sem unidade válida a
    // declaracao cai fora (largura fica no default 0)
    testing.expect_value(t, larg("width: 5epx"), f32(0))
}

// O raio chega aos 4 cantos (o shorthand continua inteiro depois da mudança
// p/ split_top_level).
@(test)
rounded_full_nos_quatro_cantos :: proc(t: ^testing.T) {
    c := test_apply("border-radius: 3.40282e38px")
    for i in 0 ..< 4 {
        testing.expectf(t, c.border_radius[i] > 1e30, "canto %d sem raio: %v", i, c.border_radius[i])
    }
}
