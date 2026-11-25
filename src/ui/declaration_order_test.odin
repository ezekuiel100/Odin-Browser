package ui

import "core:testing"
import "core:strings"
import css "../css"
import dom "../dom"
import html "../html"
import js "../js"

// Exercise the real cascade, with explicit ownership of the parsed page/rules.
declaration_order_compute :: proc(sheet: string, inline := "") -> Computed {
    root := html.parse(`<div class="x"></div>`)
    defer dom.free_tree(root)
    n := dom.find_first(root, "div")
    if inline != "" do n.attrs[strings.clone("style")] = strings.clone(inline)
    rules, keys := css.parse(sheet)
    defer css.free_rules(&rules)
    defer css.free_keyframes(&keys)
    styles, _ := compute_styles(root, &rules)
    defer free_styles(styles)
    return styles[n]
}

@(test)
declaration_order_physical_logical_and_aliases :: proc(t: ^testing.T) {
    for inline in ([]bool{false, true}) {
        for c in ([][2]string{
            {"margin-left: 7px; margin-inline-start: 19px", "19px"},
            {"margin-inline-start: 19px; margin-left: 7px", "7px"},
            {"margin-left: 7px; margin-inline-start: 19px; margin-left: 23px", "23px"},
            {"margin-left: 7px !important; margin-inline-start: 19px", "7px"},
            {"margin-left: 7px; margin-inline-start: 19px !important", "19px"},
            {"margin-left: 7px; -webkit-margin-start: 19px", "19px"},
            {"-webkit-margin-start: 19px; margin-left: 7px", "7px"},
        }) {
            sheet := strings.concatenate({".x {", c[0], "}"}, context.temp_allocator)
            computed := inline ? declaration_order_compute("", c[0]) : declaration_order_compute(sheet)
            expected, _, _ := test_parse_len(c[1], 16)
            testing.expectf(t, computed.margin[3] == expected, "inline=%v: %s", inline, c[0])
        }
    }
    a := declaration_order_compute(".x { box-sizing: border-box; -webkit-box-sizing: content-box }")
    b := declaration_order_compute(".x { -webkit-box-sizing: content-box; box-sizing: border-box }")
    testing.expect(t, a.box_sizing == .Content && b.box_sizing == .Border)
    rtl := declaration_order_compute(".x { direction: rtl; margin-right: 7px; margin-inline-start: 19px }")
    testing.expect_value(t, rtl.margin[1], 19)
}

@(test)
declaration_order_shorthands_and_border_atoms :: proc(t: ^testing.T) {
    a := declaration_order_compute(".x { margin-left: 7px; margin: 19px; padding-left: 3px; padding: 11px }")
    b := declaration_order_compute(".x { margin: 19px; margin-left: 7px; padding: 11px; padding-left: 3px }")
    testing.expect_value(t, a.margin[3], 19)
    testing.expect_value(t, b.margin[3], 7)
    testing.expect_value(t, a.padding[3], 11)
    testing.expect_value(t, b.padding[3], 3)
    c := declaration_order_compute(".x { border-top: 2px solid red; border: 9px solid blue }")
    d := declaration_order_compute(".x { border: 9px solid blue; border-top: 2px solid red }")
    testing.expect_value(t, c.border_w[0], 9)
    testing.expect_value(t, c.border_c[0], 0x0000ff)
    testing.expect_value(t, d.border_w[0], 2)
    testing.expect_value(t, d.border_c[0], 0xff0000)
    e := declaration_order_compute(".x { border-width: 3px; border-top-width: 7px; border-width: 11px }")
    testing.expect_value(t, e.border_w[0], 11)
}

@(test)
declaration_order_nesting_interleaved :: proc(t: ^testing.T) {
    for body in ([]string{
        "color: red; & { color: blue } color: green;",
        "color: red; @media (min-width: 1px) { color: blue } color: green;",
        "color: red; @supports (display: grid) { color: blue } color: green;",
        "& { color: blue } color: red; & { color: green }",
        "@media (min-width: 1px) { & { color: blue } color: green; }",
    }) {
        c := declaration_order_compute(strings.concatenate({".x {", body, "}"}, context.temp_allocator))
        testing.expectf(t, c.color == 0x008000, "%s: got %x", body, c.color)
    }
    important := declaration_order_compute(".x { color: red !important; & { color: blue } color: green }")
    testing.expect_value(t, important.color, 0xff0000)
    more_specific := declaration_order_compute(".x { &.x { color: blue } color: green }")
    testing.expect_value(t, more_specific.color, 0x0000ff)
    parent_list := declaration_order_compute(".x, #unused { & { color:blue } color:green }")
    testing.expect_value(t, parent_list.color, 0x0000ff)
    direct_decls := declaration_order_compute(".x, #unused { color:red; @media (min-width:1px) { color:green } }")
    testing.expect_value(t, direct_decls.color, 0x008000)
    dynamic_parent := declaration_order_compute(".x:hover, .y:hover { & { color:red } }")
    testing.expect(t, dynamic_parent.color != 0xff0000)
    testing.expect(t, dynamic_parent.hover.has_color && dynamic_parent.hover.color == 0xff0000)
}

@(test)
declaration_order_nesting_keeps_complex_parent_scope :: proc(t: ^testing.T) {
    root := html.parse(`<div class="a c"><span class="b">text</span></div>`)
    defer dom.free_tree(root)
    rules, keys := css.parse(`.a .b { .c & { color:red } }`)
    defer css.free_rules(&rules)
    defer css.free_keyframes(&keys)
    styles, _ := compute_styles(root, &rules)
    defer free_styles(styles)
    testing.expect_value(t, styles[dom.find_first(root, "span")].color, 0xff0000)
}

@(test)
declaration_order_cssom_preserves_cascade :: proc(t: ^testing.T) {
    root := html.parse(`<div id="x"></div>`)
    defer dom.free_tree(root)
    js.run_with_dom(`
        var s = document.getElementById('x').style;
        s.cssText = 'margin-left: 7px; margin-inline-start: 19px; padding-left: 3px; padding: 11px';
        s.color = 'red';
    `, root)
    rules, keys := css.parse("")
    defer css.free_rules(&rules)
    defer css.free_keyframes(&keys)
    styles, _ := compute_styles(root, &rules)
    defer free_styles(styles)
    c := styles[dom.find_first(root, "div")]
    testing.expect_value(t, c.margin[3], 19)
    testing.expect_value(t, c.padding[3], 11)
}

@(test)
declaration_order_other_shorthand_families :: proc(t: ^testing.T) {
    a := declaration_order_compute(`.x {
        flex-grow:7; flex:2 3 10px; column-count:7; columns:2;
        font-size:31px; font:16px monospace; align-items:end; place-items:center;
        list-style-type:decimal; list-style:square;
    }`)
    b := declaration_order_compute(`.x {
        flex:2 3 10px; flex-grow:7; columns:2; column-count:7;
        font:16px monospace; font-size:31px; place-items:center; align-items:end;
        list-style:square; list-style-type:decimal;
    }`)
    testing.expect_value(t, a.flex_grow, 2)
    testing.expect_value(t, b.flex_grow, 7)
    testing.expect_value(t, a.col_count, 2)
    testing.expect_value(t, b.col_count, 7)
    testing.expect_value(t, a.font_size, 16)
    testing.expect_value(t, b.font_size, 31)
    testing.expect(t, a.align_items == .Center)
    testing.expect(t, b.align_items == .End)
    testing.expect(t, a.list_style == .Square)
    testing.expect(t, b.list_style == .Decimal)
}

@(test)
declaration_order_all_priority_and_exclusions :: proc(t: ^testing.T) {
    a := declaration_order_compute(".x { color:red; width:77px; all:initial }")
    b := declaration_order_compute(".x { all:initial; color:red; width:77px }")
    testing.expect(t, a.color != 0xff0000 && a.width != 77)
    testing.expect(t, b.color == 0xff0000 && b.width == 77)
    important := declaration_order_compute(".x { color:red !important; all:initial }")
    testing.expect_value(t, important.color, 0xff0000)
    excluded := declaration_order_compute(".x { direction:rtl; --space:19px; all:initial; margin-inline-start:var(--space) }")
    testing.expect(t, excluded.direction == .Rtl)
    testing.expect_value(t, excluded.margin[1], 19)
    layer := declaration_order_compute("@layer a,b; @layer b { .x { margin-left:31px } } @layer a { .x { margin-inline-start:17px } }")
    testing.expect_value(t, layer.margin[3], 31)
}
