package ui

import "core:testing"

@(test)
revert_layer_suppresses_entire_layer :: proc(t: ^testing.T) {
    // O perdedor da MESMA camada nunca deve reaparecer depois do rollback.
    c := test_compute_one("@layer a,b; @layer a{.x{padding-left:3px}} @layer b{.x{padding-left:99px}.x.x{padding-left: ReVeRt-LaYeR }}", "div", "x")
    testing.expect_value(t, c.padding[3], f32(3))
    // Ordem de visita/fonte oposta, mesma especificidade relativa e mesmos ranks.
    d := test_compute_one("@layer a,b; @layer b{.x.x{padding-left:revert-layer}.x{padding-left:99px}} @layer a{.x{padding-left:3px}}", "div", "x")
    testing.expect_value(t, d.padding[3], f32(3))
    // Se revert-layer NÃO vence, ele não pode excluir a camada.
    e := test_compute_one("@layer a,b; @layer a{.x{padding-left:3px}} @layer b{.x{padding-left:revert-layer}.x.x{padding-left:8px}}", "div", "x")
    testing.expect_value(t, e.padding[3], f32(8))
}

@(test)
revert_layer_chained_and_custom_properties :: proc(t: ^testing.T) {
    c := test_compute_one("@layer a,b,c; @layer a{.x{--space:6px}} @layer b{.x{--space:revert-layer}} @layer c{.x{--space:99px}.x.x{--space:revert-layer}} .x{padding-left:var(--space)}", "div", "x")
    testing.expect_value(t, c.padding[3], f32(6))
    // Nenhum candidato: não enviar o token CSS-wide ao parser de valores.
    d := test_compute_one(".x{padding-left:revert-layer}", "div", "x")
    testing.expect_value(t, d.padding[3], f32(0))
}

@(test)
revert_layer_unlayered_and_important :: proc(t: ^testing.T) {
    normal := test_compute_one("@layer a{.x{padding-left:4px}} .x{padding-left:99px}.x.x{padding-left:revert-layer}", "div", "x")
    testing.expect_value(t, normal.padding[3], f32(4))
    // Inversão important: a reverte para b important, não para a normal.
    imp := test_compute_one("@layer a,b; @layer a{.x{padding-left:99px!important}.x.x{padding-left:revert-layer!important}} @layer b{.x{padding-left:5px!important}} .x{padding-left:8px!important}", "div", "x")
    testing.expect_value(t, imp.padding[3], f32(5))
    // Sem important restante, b important pode voltar a a normal. A normal de
    // b e a unlayered estão entre os níveis de b e precisam ser suprimidas.
    fallback := test_compute_one("@layer a,b; @layer a{.x{padding-left:7px}} @layer b{.x{padding-left:99px}.x.x{padding-left:revert-layer!important}} .x{padding-left:88px}", "div", "x")
    testing.expect_value(t, fallback.padding[3], f32(7))
    unlayered := test_compute_one("@layer a{.x{padding-left:2px}} .x{padding-left:revert-layer!important}", "div", "x")
    testing.expect_value(t, unlayered.padding[3], f32(2))
}

@(test)
revert_layer_inline_is_separate_category :: proc(t: ^testing.T) {
    c := test_compute_one(".x{padding-left:9px}", "div", "x", "padding-left:revert-layer")
    testing.expect_value(t, c.padding[3], f32(9))
    d := test_compute_one("@layer a{.x{padding-left:4px!important}} .x{padding-left:9px}", "div", "x", "padding-left:revert-layer!important")
    testing.expect_value(t, d.padding[3], f32(4))
    e := test_compute_one(".x{padding-left:9px}", "div", "x", "padding-left:revert-layer!important")
    testing.expect_value(t, e.padding[3], f32(9))
}

@(test)
revert_layer_resolves_before_alias_translation :: proc(t: ^testing.T) {
    // Mesmo nome original em ambas as camadas: só o resultado resolvido deve
    // entrar na tradução lógica -> física; nunca o token revert-layer.
    c := test_compute_one("@layer a,b; @layer a{.x{padding-inline-start:6px}} @layer b{.x{padding-inline-start:revert-layer}}", "div", "x")
    testing.expect_value(t, c.padding[3], f32(6))
    d := test_compute_one("@layer a,b; @layer a{.x{-webkit-padding-start:5px}} @layer b{.x{-webkit-padding-start:revert-layer}}", "div", "x")
    testing.expect_value(t, d.padding[3], f32(5))
}

