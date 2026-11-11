package ui

import "core:testing"
import "core:fmt"
import csspkg "../css"
import jspkg "../js"
import dompkg "../dom"
import htmlpkg "../html"

@(test)
css_consistency_value_families :: proc(t: ^testing.T) {
    cases := [][3]string{
        {"font-weight", "700", "heavy"}, {"font-weight", "bold", "1001"},
        {"line-height", "1.5", "-1"}, {"line-height", "20px", "tall"},
        {"letter-spacing", "-2px", "1%"}, {"word-spacing", "normal", "wide"},
        {"text-overflow", "ellipsis", "banana"},
        {"writing-mode", "vertical-rl", "banana"},
        {"display", "grid", "gr/**/id"}, {"width", `1p\78`, "1/**/px"},
        {"display", `\67 rid`, "banana/**/grid"},
        {"color", "red/**/", "red/**/blue"},
        {"width", "1.5px", "1/**/.5px"},
        {"display", "grid", `"var(--x)"`},
    }
    for c in cases {
        for i in 0..<2 {
            v := c[i+1]
            want := i == 0
            testing.expect_value(t, css_supports_decl(c[0], v), want)
            testing.expect_value(t, csspkg.supports_condition(fmt.tprintf("(%s: %s)", c[0], v)), want)
            d := csspkg.parse_decls(fmt.tprintf("%s: %s; %s: %s", c[0], c[1], c[0], v), context.temp_allocator)
            testing.expect_value(t, d[c[0]], csspkg.declaration_text(c[1]))
        }
    }
}

@(test)
css_consistency_cssom :: proc(t: ^testing.T) {
    root := htmlpkg.parse(`<div id="x"></div>`)
    defer dompkg.free_tree(root)
    result := jspkg.run_with_dom(`var s = document.getElementById('x').style;
        s.cssText = 'width: 12px; width: banana; --X: "a;b/*c*/"; color: red';
        var ok = s.width === '12px' && s.getPropertyValue('--X') === '"a;b/*c*/"';
        s.setProperty('WIDTH', '2/**/px');
        ok = ok && s.width === '12px';
        s.setProperty('width', '42px', 'IMPORTANT');
        ok = ok && s.width === '42px' && s.getPropertyPriority('WIDTH') === 'important';
        s.setProperty('width', '99px', 'invalid');
        s.color = 'blue';
        ok = ok && s.width === '42px' && s.getPropertyValue('--X') === '"a;b/*c*/"';
        ok = ok && s.removeProperty('WIDTH') === '42px' && s.width === '';
        ok && CSS.supports('display', '\\67 rid') &&
            CSS.supports('(display: /**/grid)') && CSS.supports('displ\\61 y: grid') &&
            !CSS.supports('width', '1/**/px');`, root)
    ok, _ := result.(bool)
    testing.expect(t, ok, "CSSOM must share parsing, validation and priority rules")
}

@(test)
css_consistency_strings_comments_and_fallback :: proc(t: ^testing.T) {
    d := csspkg.parse_decls(`--x: "a\";b/*c*/"; color: red; color: bogus !important`, context.temp_allocator)
    testing.expect_value(t, d["--x"], `"a\";b/*c*/"`)
    testing.expect_value(t, d["color"], "red")
    testing.expect(t, csspkg.supports_condition(`(--x: "!important")`))
    testing.expect(t, !css_supports_decl("width", "10px\\"))
    c := test_compute_one(`div { font-weight: 700; line-height: 20px; }
        @supports (font-weight: heavy) { div { width: 999px } }
        @supports not (font-weight: heavy) { div { width: 42px } }`)
    testing.expect_value(t, c.width, 42)
}
