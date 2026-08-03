package ui

// Interpolação de cor em alpha PREMULTIPLICADO (css-images-3 §3.4.3).
//
// Interpolando canal a canal SEM premultiplicar, o lado transparente arrasta a
// COR junto — e `transparent` é PRETO com alpha 0. No meio de um fade
// `azul → transparent` o RGB já estava 50% preto com alpha ainda em 50%, o que
// desenha um halo cinza-escuro em volta de todo glow (as bolhas do hero do
// getbootstrap). Premultiplicado, o stop transparente não contribui com cor
// nenhuma: o azul só perde alpha.
//
// ⚠️ com os dois lados OPACOS o resultado é idêntico ao do jeito antigo — é por
// isso que o bug ficou invisível na maioria dos gradientes.

import "core:testing"
import csspkg "../css"

@(private = "file")
chans :: proc(c: u32) -> (r, g, b, a: int) {
    return int(c & 0xFF), int((c >> 8) & 0xFF), int((c >> 16) & 0xFF), int((c >> 24) & 0xFF)
}

@(test)
test_lerp_meio_do_fade_p_transparent_mantem_a_cor :: proc(t: ^testing.T) {
    // ImGui empacota ABGR: 0xAABBGGRR. Azul puro opaco e "transparent".
    AZUL  :: u32(0xFFFF0000) // a=255, b=255, g=0, r=0
    TRANSP :: u32(0x00000000)
    mid := test_lerp_color_premul(AZUL, TRANSP, 0.5)
    r, g, b, a := chans(mid)
    testing.expectf(t, a >= 120 && a <= 136, "alpha no meio ~128, veio %d", a)
    // premultiplicado: o AZUL segue cheio; sem premultiplicar viria b≈128 (cinza-azul escuro)
    testing.expectf(t, b >= 250, "azul preservado (b>=250), veio %d", b)
    testing.expectf(t, r <= 4 && g <= 4, "sem contaminação r/g, veio r=%d g=%d", r, g)
}

@(test)
test_lerp_opacos_nao_muda :: proc(t: ^testing.T) {
    // dois lados opacos: continua a média canal a canal (comportamento antigo)
    A :: u32(0xFF0000FF) // opaco, r=255
    B :: u32(0xFFFF0000) // opaco, b=255
    mid := test_lerp_color_premul(A, B, 0.5)
    r, g, b, a := chans(mid)
    testing.expect_value(t, a, 255)
    testing.expectf(t, r >= 126 && r <= 130, "r ~128, veio %d", r)
    testing.expectf(t, b >= 126 && b <= 130, "b ~128, veio %d", b)
    testing.expectf(t, g <= 2, "g ~0, veio %d", g)
}

@(test)
test_lerp_extremos_intactos :: proc(t: ^testing.T) {
    A :: u32(0xFFFF0000)
    B :: u32(0x00000000)
    testing.expect_value(t, test_lerp_color_premul(A, B, 0), A)
    e := test_lerp_color_premul(A, B, 1)
    _, _, _, a := chans(e)
    testing.expect_value(t, a, 0) // t=1 → totalmente transparente
}

// O mesmo pelo caminho REAL do gradiente: a cor no meio de um
// `linear-gradient(azul, transparent)` não pode escurecer.
@(test)
test_gradiente_fade_p_transparent_nao_escurece :: proc(t: ^testing.T) {
    g, ok := csspkg.parse_gradient("linear-gradient(to right, #0000ff, transparent)")
    testing.expect(t, ok && g.n == 2, "gradiente parseado")
    mid := test_grad_color_at(g, 0.5)
    r, gg, b, a := chans(mid)
    testing.expectf(t, a >= 120 && a <= 136, "alpha ~128, veio %d", a)
    testing.expectf(t, b >= 250, "azul preservado no meio (b>=250), veio %d", b)
    testing.expectf(t, r <= 4 && gg <= 4, "sem cinza (r=%d g=%d)", r, gg)
}
