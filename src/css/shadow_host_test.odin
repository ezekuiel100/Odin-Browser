package css

import "core:testing"

@(test)
shadow_host_preserves_document_selector_list :: proc(t: ^testing.T) {
    testing.expect(t, selectors_valid(":root,:host"))
    sels := parse_selector_list(":root,:host")
    defer { for &s in sels do free_selector(&s); delete(sels) }
    testing.expect_value(t, len(sels), 2)
    if len(sels) != 2 do return
    testing.expect(t, compound_matches(sels[0].parts[0], "html", nil, ""))
    testing.expect(t, !compound_matches(sels[1].parts[0], "html", nil, ""))
    testing.expect(t, !compound_matches(sels[1].parts[0], "div", nil, ""))
}

@(test)
gradient_function_color_adjacent_position :: proc(t: ^testing.T) {
    g, ok := parse_gradient("linear-gradient(to bottom in oklab, oklch(60.6% .25 292.717)0%,oklch(54.1% .281 293.009)100%)")
    testing.expect(t, ok)
    testing.expect_value(t, g.n, 2)
    testing.expect(t, g.pos_set[0] && g.pos_set[1])
    testing.expect_value(t, g.pos[1], f32(1))
}
