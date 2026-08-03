package css

// `light-dark(<claro>, <escuro>)` não era reconhecida: caía no fim de
// parse_color, em named_color, e o valor virava inválido — na prática a cor
// saía PRETA (foi o que a sonda de sintaxes de cor mostrou).
//
// ⚠️ a spec resolve contra o `color-scheme` USADO DO ELEMENTO; aproximamos pelo
// esquema da PÁGINA (`g_dark_scheme`, espelho do prefers-color-scheme).

import "core:testing"

@(test)
test_light_dark_escolhe_o_braco_do_esquema :: proc(t: ^testing.T) {
    old := g_dark_scheme
    defer g_dark_scheme = old

    g_dark_scheme = false
    c, ok := parse_color("light-dark(#0d6efd, #000000)")
    testing.expect(t, ok, "parseou no esquema claro")
    testing.expect_value(t, c, 0x0d6efd)

    g_dark_scheme = true
    c2, ok2 := parse_color("light-dark(#0d6efd, #101820)")
    testing.expect(t, ok2, "parseou no esquema escuro")
    testing.expect_value(t, c2, 0x101820)
}

@(test)
test_light_dark_aceita_funcao_dentro :: proc(t: ^testing.T) {
    old := g_dark_scheme
    defer g_dark_scheme = old
    g_dark_scheme = false
    // a vírgula de dentro do rgb() não pode dividir os braços
    c, ok := parse_color("light-dark(rgb(13, 110, 253), #000)")
    testing.expect(t, ok, "parseou")
    testing.expect_value(t, c, 0x0d6efd)
}

@(test)
test_light_dark_caixa_alta_e_malformada :: proc(t: ^testing.T) {
    old := g_dark_scheme
    defer g_dark_scheme = old
    g_dark_scheme = false
    c, ok := parse_color("LIGHT-DARK(#112233, #000)") // CSS é case-insensitive
    testing.expect(t, ok && c == 0x112233, "caixa alta tambem")

    _, bad := parse_color("light-dark(#112233)") // falta o 2o braço
    testing.expect(t, !bad, "com um braço só é inválida")
}
