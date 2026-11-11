package ui

import "core:testing"
import "core:fmt"
import csspkg "../css"
import jspkg "../js"
import dompkg "../dom"
import htmlpkg "../html"

@(test)
css_family_invalid_values :: proc(t: ^testing.T) {
    cases := [][2]string{
        {"border", "1px solid red garbage"}, {"border", "solid dashed"},
        {"border", "red blue"}, {"border", "-1px solid"}, {"border", "inherit solid"},
        {"outline", "hidden"}, {"column-rule", "1% solid red"},
        {"column-rule-width", "-2px"}, {"column-rule-style", "banana"},
        {"border-radius", "1px /"}, {"border-radius", "1px / 2px / 3px"},
        {"border-radius", "1px -2px"}, {"border-radius", "1px 2px 3px 4px 5px"},
        {"border-top-left-radius", "1px / 2px"}, {"border-top-left-radius", "1px 2px 3px"},
        {"border-spacing", "10%"}, {"border-spacing", "1px -2px"},
        {"columns", "2 3"}, {"columns", "10px 20px"}, {"column-width", "20%"},
        {"flex", "-1"}, {"flex", "1 2 3"}, {"flex", "1 auto 2"},
        {"flex", "auto auto"}, {"flex-flow", "row column"}, {"flex-flow", "wrap nowrap"},
        {"align-items", "space-between"}, {"align-items", "first"},
        {"align-items", "safe baseline"}, {"justify-content", "baseline"},
        {"align-content", "self-start"}, {"place-items", "center bogus"},
        {"place-self", "center center center"}, {"font-size", "-1px"},
        {"font-size", "10"}, {"vertical-align", "auto"}, {"outline-offset", "5%"},
        {"scroll-margin", "auto"}, {"scroll-margin", "10%"},
        {"scroll-padding", "-1px"}, {"scroll-padding-inline", "1px 2px 3px"},
        {"transition-duration", "-1s"}, {"animation-duration", "100"},
        {"animation-delay", "1s,"}, {"animation-iteration-count", "-1"},
        {"animation-direction", "alternate normal"}, {"animation-fill-mode", "garbage"},
        {"animation-play-state", "paused,"}, {"transition-timing-function", "steps(1, jump-none)"},
        {"transition-timing-function", "steps(2, bogus)"},
        {"transition-timing-function", "steps(2, end, start)"},
        {"animation-timing-function", "cubic-bezier(2, 0, 0, 1)"},
        {"animation-timing-function", "cubic-bezier(0, NaN, 1, 1)"},
        {"caption-side", "banana"}, {"resize", "auto"}, {"text-decoration-thickness", "-2px"},
        {"text-decoration-line", "none underline"}, {"text-decoration-line", "underline underline"},
    }
    for c in cases {
        valid, checked := css_value_valid(c[0], c[1])
        testing.expectf(t, checked && !valid, "invalid family value: %v", c)
        testing.expectf(t, !css_supports_decl(c[0], c[1]), "support false positive: %v", c)
        testing.expect(t, !csspkg.supports_condition(fmt.tprintf("(%s: %s)", c[0], c[1])))
        testing.expect(t, !sup_js(t, fmt.tprintf(`CSS.supports('%s', '%s')`, c[0], c[1])))
        // Invalid duplicates, including important ones, cannot replace a valid
        // declaration, whether in the same block or a later rule.
        d := csspkg.parse_decls(fmt.tprintf("%s: initial; %s: %s !important", c[0], c[0], c[1]), context.temp_allocator)
        testing.expect_value(t, d[c[0]], "initial")
        root := htmlpkg.parse(fmt.tprintf(`<div id="x" style="%s: initial"></div>`, c[0]))
        result := jspkg.run_with_dom(fmt.tprintf(`var s = document.getElementById('x').style;
            s.setProperty('%s', '%s'); s.getPropertyValue('%s') === 'initial';`, c[0], c[1], c[0]), root)
        ok, _ := result.(bool)
        testing.expectf(t, ok, "CSSOM replaced valid declaration: %v", c)
        dompkg.free_tree(root)
    }
}

@(test)
css_family_valid_values :: proc(t: ^testing.T) {
    cases := [][2]string{
        {"border", "solid"}, {"border", "red 2px dashed"}, {"outline", "auto red"},
        {"column-rule", "thin solid currentColor"}, {"column-rule-width", "2px"},
        {"border-radius", "1px 20% / 3px 4px"}, {"border-radius", "calc(10px / 2)"},
        {"border-top-left-radius", "10% 2px"}, {"border-spacing", "1px 2rem"},
        {"columns", "auto auto"}, {"columns", "12em 3"}, {"columns", "2 auto"},
        {"flex", "1 1 0"}, {"flex", "0 0 auto"}, {"flex", "10px 1 2"},
        {"flex", "1 2 calc(100% - 1px)"}, {"flex-flow", "wrap column-reverse"},
        {"align-items", "first baseline"}, {"justify-self", "safe end"},
        {"justify-items", "legacy center"}, {"place-items", "first baseline safe center"},
        {"place-content", "baseline"}, {"place-self", "auto center"},
        {"font-size", "larger"}, {"font-size", "125%"}, {"vertical-align", "-10%"},
        {"outline-offset", "-2px"}, {"scroll-margin", "-1px 2rem"},
        {"scroll-padding-inline", "auto 10%"}, {"text-decoration-thickness", "from-font"},
        {"transition-duration", "0s, 250ms"}, {"animation-delay", "-1s, 0ms"},
        {"animation-iteration-count", "infinite, 2.5"}, {"animation-direction", "normal, alternate"},
        {"animation-fill-mode", "both, none"}, {"animation-play-state", "paused, running"},
        {"transition-timing-function", "steps(2, jump-none), cubic-bezier(0, -2, 1, 3)"},
        {"resize", "inline"}, {"caption-side", "bottom"},
        {"text-decoration-line", "underline overline line-through"},
    }
    for c in cases {
        valid, checked := css_value_valid(c[0], c[1])
        testing.expectf(t, valid && checked, "valid family value rejected: %v", c)
        testing.expectf(t, css_supports_decl(c[0], c[1]), "valid support rejected: %v", c)
        d := csspkg.parse_decls(fmt.tprintf("%s: %s", c[0], c[1]), context.temp_allocator)
        _, found := d[c[0]]
        testing.expectf(t, found, "valid declaration discarded: %v", c)
    }
}

@(test)
css_family_cascade_fallback :: proc(t: ^testing.T) {
    same := test_apply("border: 3px solid red; border: 5px solid garbage !important; flex-grow: 2; flex: 1 auto 2")
    rules := test_compute_one(`div { border: 3px solid red; flex-grow: 2 }
        div { border: 5px solid garbage !important; flex: 1 auto 2 !important }
        @supports (border: solid dashed) { div { border: 8px solid blue } }`)
    for c in ([]Computed{same, rules}) {
        testing.expect_value(t, c.border_w[0], 3)
        testing.expect_value(t, c.flex_grow, 2)
    }
}
