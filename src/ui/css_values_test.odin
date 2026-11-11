package ui

import "core:testing"
import "core:fmt"
import csspkg "../css"
import jspkg "../js"
import dompkg "../dom"
import htmlpkg "../html"

@(test)
css_values_reject_invalid :: proc(t: ^testing.T) {
    cases := [][2]string{
        {"width", "banana"}, {"width", "12"}, {"width", "10 px"},
        {"width", "-1px"}, {"width", "1fr"}, {"width", "1bogus"},
        {"width", "10px 20px"}, {"width", "min(10px,)"},
        {"width", "calc(10px + )"}, {"width", "calc(10px"},
        {"padding", "auto"}, {"padding", "1px -2px"},
        {"padding", "1px 2px 3px 4px 5px"}, {"margin", "0 bogus"},
        {"opacity", "NaN"}, {"opacity", "infinity"}, {"opacity", "1px"},
        {"z-index", "1.5"}, {"order", "1px"}, {"column-count", "0"},
        {"flex-grow", "-1"}, {"flex-shrink", "1 2"},
        {"display", "banana"}, {"position", "floating"},
        {"overflow", "auto nonsense"}, {"box-sizing", "padding-box"},
        {"color", "not-a-color"}, {"color", "#xyz"},
        {"border-color", "red bogus"}, {"border-width", "2px -1px"},
        {"border-style", "solid banana"}, {"aspect-ratio", "1/2/3"},
        {"aspect-ratio", "-1/2"}, {"width", "10px; color:red"},
    }
    for c in cases {
        testing.expectf(t, !css_supports_decl(c[0], c[1]), "%s:%s must not claim support", c[0], c[1])
        d := csspkg.parse_decls(fmt.tprintf("%s: %s", c[0], c[1]), context.temp_allocator)
        // Semicolon starts a new declaration in a stylesheet, unlike supports.
        if c[1] != "10px; color:red" {
            _, found := d[c[0]]
            testing.expectf(t, !found, "invalid declaration survived: %v", c)
        }
    }
}

@(test)
css_values_accept_valid :: proc(t: ^testing.T) {
    cases := [][2]string{
        {"width", "0"}, {"width", "-0px"}, {"width", "1e2px"},
        {"width", "calc(100% - 2rem)"}, {"width", "clamp(1rem, 2vw, 4rem)"},
        {"width", "max-content"}, {"width", "auto"}, {"max-width", "none"},
        {"margin", "-10px auto 5% 0"}, {"padding", "1px 2% 3rem"},
        {"gap", "normal 2px"}, {"opacity", "75%"}, {"opacity", "2"},
        {"z-index", "-3"}, {"display", "initial"}, {"position", "inherit"},
        {"overflow", "hidden auto"}, {"color", "currentColor"}, {"color", "transparent"},
        {"border-width", "thin 2px"}, {"border-style", "solid dashed"},
        {"aspect-ratio", "auto 16 / 9"}, {"width", "var(--w, 1px)"},
        {"--x", "'a;!b'"},
    }
    for c in cases do testing.expectf(t, css_supports_decl(c[0], c[1]), "valid value rejected: %v", c)
}

@(test)
css_values_fallback_across_rules :: proc(t: ^testing.T) {
    c := test_compute_one(`div { width: 123px; color: red; padding: 9px }
        div { width: nonsense !important; color: not-a-color; padding: 1px bogus }`)
    testing.expect_value(t, c.width, 123)
    testing.expect_value(t, c.color, 0xff0000)
    testing.expect_value(t, c.padding[0], 9)
}

@(test)
css_values_fallback_same_block :: proc(t: ^testing.T) {
    c := test_apply("width: 123px; width: nonsense; opacity: .5; opacity: 1; padding: 9px; padding: 1px bogus")
    testing.expect_value(t, c.width, 123)
    testing.expect_value(t, c.opacity, 1)
    testing.expect_value(t, c.padding[0], 9)
    d := csspkg.parse_decls("width: 10px !important; width: 20px", context.temp_allocator)
    testing.expect_value(t, d["width"], "10px !important")
}

@(test)
css_values_support_queries_agree :: proc(t: ^testing.T) {
    values := []string{"10px", "banana", "-1px", "calc(100% - 1px)", "initial"}
    for v in values {
        expected := css_supports_decl("width", v)
        testing.expect_value(t, csspkg.supports_condition(fmt.tprintf("(width: %s)", v)), expected)
        testing.expect_value(t, sup_js(t, fmt.tprintf(`CSS.supports('width', '%s')`, v)), expected)
        testing.expect_value(t, sup_js(t, fmt.tprintf(`CSS.supports('(width: %s)')`, v)), expected)
    }
    c := test_compute_one(`div { width: 123px }
        @supports (width: banana) { div { width: 500px } }
        @supports not (width: banana) { div { color: red } }`)
    testing.expect_value(t, c.width, 123)
    testing.expect_value(t, c.color, 0xff0000)
}

@(test)
css_values_inert_features :: proc(t: ^testing.T) {
    testing.expect(t, !css_supports_decl("touch-action", "none"))
    testing.expect(t, css_supports_decl("writing-mode", "vertical-rl"))
    testing.expect(t, !css_supports_decl("scroll-snap-type", "x mandatory"))
    testing.expect(t, css_supports_decl("writing-mode", "horizontal-tb"))
}

@(test)
css_values_style_setters_keep_previous :: proc(t: ^testing.T) {
    root := htmlpkg.parse(`<div id="x" style="width: 123px; padding: 9px"></div>`)
    defer dompkg.free_tree(root)
    result := jspkg.run_with_dom(`var s = document.getElementById('x').style;
        s.width = 'banana'; s.setProperty('padding', '1px bogus');
        var kept = s.width === '123px' && s.getPropertyValue('padding') === '9px';
        s.width = '42px'; kept && s.width === '42px';`, root)
    ok, _ := result.(bool)
    testing.expect(t, ok, "invalid CSSOM writes must preserve the previous declaration")
}

@(test)
css_values_var_invalidates_whole_shorthand :: proc(t: ^testing.T) {
    c := test_compute_one(`div { padding: 9px; --p: 1px bogus; padding: var(--p) }`)
    testing.expect_value(t, c.padding[0], 0)
    testing.expect_value(t, c.padding[1], 0)
}

@(test)
css_values_unknown_support_conditions :: proc(t: ^testing.T) {
    values := []string{"future-feature(x)", "(future-feature)", "(width: 1px) and future-feature(x)", "",
        "(width: 1px) or garbage", "(width: 1px) or (width: 2px) and (width: 3px)", "not (width: bogus) and (width: 1px)"}
    for v in values {
        testing.expect(t, !csspkg.supports_condition(v))
        testing.expect(t, !sup_js(t, fmt.tprintf(`CSS.supports('%s')`, v)))
    }
    testing.expect(t, csspkg.supports_condition("not future-feature(x)"))
    testing.expect(t, sup_js(t, `CSS.supports('not future-feature(x)')`))
}
