package ui

import "core:testing"
import "core:fmt"
import "core:strings"
import css "../css"
import dom "../dom"
import html "../html"
import js "../js"

@(test)
css_variables_reject_malformed_references :: proc(t: ^testing.T) {
    for value in ([]string{"var()", "var(color)", "var(--)", "var(--x --y)", "var(--x, var())", "VAR(--x, var(nope))"}) {
        testing.expectf(t, !css_supports_decl("width", value), "accepted %s", value)
        testing.expectf(t, !css.supports_condition(fmt.tprintf("(width: %s)", value)), "@supports accepted %s", value)
        d := css.parse_decls(fmt.tprintf("width: 12px; width: %s !important", value), context.temp_allocator)
        testing.expect_value(t, d["width"], "12px")
    }
    root := html.parse(`<div id="x" style="width:12px"></div>`)
    defer dom.free_tree(root)
    r := js.run_with_dom(`var s=document.getElementById('x').style;
        s.width='var(nope)'; s.width==='12px' && !CSS.supports('width','var(--x, var())');`, root)
    testing.expect(t, r == true)
    testing.expect(t, css_supports_decl("width", "var(--x, 1ch)"))
    testing.expect(t, css_supports_decl("width", "var(--x, garbage)"))
}

@(test)
css_variables_cycles_and_fallbacks :: proc(t: ^testing.T) {
    for body in ([]string{
        "--a:var(--a, 3px); width:var(--a, 27px)",
        "--a:var(--b); --b:var(--a); width:var(--a, 27px)",
        "--good:3px; --a:var(--good, var(--a)); width:var(--a,27px)",
        "--a:var(--b,3px); --b:var(--a,4px); --c:var(--a,27px); width:var(--c)",
        "--a:var(--missing); width:var(--a, var(--other, 27px))",
        "--A:27px; --a:3px; width:VAR(--A)",
    }) {
        c := declaration_order_compute(strings.concatenate({".x {", body, "}"}, context.temp_allocator))
        testing.expectf(t, c.has_width && c.width == 27, "%s => %v", body, c.width)
    }
}

@(test)
css_variables_missing_invalidates_whole_value :: proc(t: ^testing.T) {
    c := declaration_order_compute(`.x {padding:9px; padding:1px var(--missing);
        width:30px; width:var(--missing); --empty: ; height:var(--empty,47px);
        --bad:bogus; margin:var(--bad, 15px)}`)
    testing.expect_value(t, c.padding, [4]f32{})
    testing.expect(t, !c.has_width && !c.has_height)
    testing.expect_value(t, c.margin, [4]f32{})
    // A missing reference invalidates even a grammar not yet enumerated.
    d := declaration_order_compute(`.x { transform:translate(17px); transform:translate(3px) var(--absent) }`)
    testing.expect_value(t, d.transform_tx, 0)
}

@(test)
css_variables_resolve_before_inheritance :: proc(t: ^testing.T) {
    root := html.parse(`<section><div class="x"></div></section>`)
    defer dom.free_tree(root)
    rules, keys := css.parse(`section {--base:21px; --alias:var(--base); --bad:var(--missing)}
        .x {--base:7px; --missing:9px; width:var(--alias); height:var(--bad,33px)}`)
    defer css.free_rules(&rules)
    defer css.free_keyframes(&keys)
    styles, _ := compute_styles(root, &rules)
    defer free_styles(styles)
    c := styles[dom.find_first(root, "div")]
    testing.expect_value(t, c.width, 21)
    testing.expect_value(t, c.height, 33)
}

@(test)
css_variables_preserve_tokens_and_long_chains :: proc(t: ^testing.T) {
    for value in ([]string{"var(--n)px", "var(--n)%"}) {
        c := declaration_order_compute(strings.concatenate({".x {--n:12; width:", value, "}"}, context.temp_allocator))
        testing.expectf(t, !c.has_width, "substitution merged tokens: %s", value)
    }
    sheet := ".x {--v0:29px;"
    for i in 1..<40 do sheet = fmt.tprintf("%s --v%d:var(--v%d);", sheet, i, i-1)
    c := declaration_order_compute(fmt.tprintf("%s width:var(--v39)}", sheet))
    testing.expect_value(t, c.width, 29)
    p := make(map[string]string, context.temp_allocator)
    p["--x"] = "red"
    testing.expect_value(t, css.resolve_vars(`"var(--x)" myvar(--x)`, p), `"var(--x)" myvar(--x)`)
    testing.expect_value(t, css.resolve_vars(`var(--missing, "a)b,c")`, p), `"a)b,c"`)
}

@(test)
css_variables_border_and_logical_competition :: proc(t: ^testing.T) {
    c := declaration_order_compute(`.x { --b:8px solid blue; border-top:2px solid red; border:var(--b) }`)
    testing.expect_value(t, c.border_w[0], 8)
    testing.expect_value(t, c.border_c[0], 0x0000ff)
    d := declaration_order_compute(`.x { --p:3px 5px; padding-inline:var(--p); padding-left:7px }`)
    testing.expect_value(t, d.padding[3], 7)
    testing.expect_value(t, d.padding[1], 5)
    e := declaration_order_compute(`.x {padding-left:7px; padding-inline:var(--missing)}`)
    testing.expect_value(t, e.padding[3], 0)
    f := declaration_order_compute(`.x {flex-direction:column; flex-flow:var(--missing)}`)
    testing.expect(t, f.flex_dir == .Row)
}
