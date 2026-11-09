package ui

import "core:testing"
import csspkg "../css"

@(test)
cascade_priority_inline_and_registered :: proc(t: ^testing.T) {
    inline := Cascade_Priority{important = true, inline = true, layer = csspkg.LAYER_UNLAYERED}
    layered := Cascade_Priority{important = true, layer = 0, specificity = {99, 99, 99}}
    testing.expect(t, cascade_priority_compare(inline, layered) > 0)
    inline.important = false
    testing.expect(t, cascade_priority_compare(inline, layered) < 0)
    fallback := Cascade_Priority{important = true, layer = csspkg.LAYER_REGISTERED}
    testing.expect(t, cascade_priority_compare(fallback, inline) < 0)
}

@(test)
cascade_collect_tuple_and_selector_list :: proc(t: ^testing.T) {
    // Onze tipos não passam uma classe; a lista usa o maior seletor que CASOU.
    c := test_compute_one(".x, div{padding:3px} :is(div):is(div):is(div):is(div):is(div):is(div):is(div):is(div):is(div):is(div):is(div){padding:9px}", "div", "x")
    testing.expect_value(t, c.padding[0], f32(3))
}

@(test)
cascade_collect_layers_and_inline :: proc(t: ^testing.T) {
    normal := test_compute_one("@layer a,b; @layer a{.x.x{padding:9px}} @layer b{.x{padding:4px}}", "div", "x")
    testing.expect_value(t, normal.padding[0], f32(4))
    important := test_compute_one("@layer a,b; @layer a{.x{padding:3px!important}} @layer b{.x.x{padding:8px!important}} .x{padding:9px!important}", "div", "x")
    testing.expect_value(t, important.padding[0], f32(3))
    inline := test_compute_one("@layer a{.x{padding:9px!important}}", "div", "x", "padding:2px!important")
    testing.expect_value(t, inline.padding[0], f32(2))
    normal_inline := test_compute_one("@layer a{.x{padding:9px!important}}", "div", "x", "padding:2px")
    testing.expect_value(t, normal_inline.padding[0], f32(9))
}

@(test)
cascade_collect_alias_logical_shorthand_and_border :: proc(t: ^testing.T) {
    alias := test_compute_one("@layer a,b; @layer a{.x{-webkit-padding-start:3px!important}} @layer b{.x.x{padding-left:9px!important}}", "div", "x")
    testing.expect_value(t, alias.padding[3], f32(3))
    shorthand := test_compute_one("@layer a,b; @layer a{.x{padding:2px!important}} @layer b{.x.x{padding-left:9px!important}}", "div", "x")
    testing.expect_value(t, shorthand.padding[3], f32(2))
    border := test_compute_one("@layer a,b; @layer a{.x{border-top:7px solid red!important}} @layer b{.x.x{border-width:2px!important}}", "div", "x")
    testing.expect_value(t, border.border_w[0], f32(7))
    testing.expect_value(t, border.border_w[3], f32(2))
}
