package ui

import "core:testing"
import "core:fmt"
import htmlp "../html"
import dompkg "../dom"
import csspkg "../css"

@(private="file")
svg_dimension_layout :: proc(source: string) -> ^Box {
    doc := htmlp.parse(source)
    rules, kf := csspkg.parse("")
    styles, _ := compute_styles(doc, &rules, 800, 600)
    root := build_layout(doc, styles, "")
    csspkg.free_rules(&rules); csspkg.free_keyframes(&kf)
    layout_box(root, 0, 0, 800)
    return root
}

@(private="file")
svg_dimension_icon :: proc(b: ^Box) -> ^Box {
    if b == nil do return nil
    if b.is_svg do return b
    for c in b.children {
        if found := svg_dimension_icon(c); found != nil do return found
    }
    for it in b.inlines {
        if found := svg_dimension_icon(it.box); found != nil do return found
    }
    return nil
}

// The Google keyboard uses 24px attributes with a 960-unit viewBox.
// Exercise layout, not just the numeric parser: this used to become 960x960.
@(test)
svg_pixel_attributes_size_inline_and_block_icons :: proc(t: ^testing.T) {
    displays := []string{"inline", "block"}
    units := []string{"", "px"}
    for display in displays {
        for unit in units {
            root := svg_dimension_layout(fmt.tprintf(`<body style="margin:0"><span><svg style="display:%s"
                width="24%s" height="24%s" viewBox="0 -960 960 960">
                <path d="M0-960H960V0H0Z"/></svg></span></body>`, display, unit, unit))
            defer free_layout(root)
            icon := svg_dimension_icon(root)
            testing.expect(t, icon != nil)
            if icon == nil do continue
            testing.expect_value(t, icon.img_dw, f32(24))
            testing.expect_value(t, icon.img_dh, f32(24))
        }
    }
}

@(test)
svg_css_dimensions_override_pixel_attributes :: proc(t: ^testing.T) {
    root := svg_dimension_layout(`<body style="margin:0"><svg width="24px" height="24px"
        style="width:48px;height:32px" viewBox="0 -960 960 960"></svg></body>`)
    defer free_layout(root)
    icon := svg_dimension_icon(root)
    testing.expect(t, icon != nil)
    if icon == nil do return
    testing.expect_value(t, icon.img_dw, f32(48))
    testing.expect_value(t, icon.img_dh, f32(32))
}

@(test)
svg_external_pixel_dimensions_use_display_size :: proc(t: ^testing.T) {
    doc := htmlp.parse(`<svg width="24px" height="18px" viewBox="0 0 960 720"></svg>`)
    svg := dompkg.find_first(doc, "svg")
    testing.expect(t, svg != nil)
    if svg == nil do return
    w, h := svg_intrinsic_size(svg)
    testing.expect_value(t, w, f32(24))
    testing.expect_value(t, h, f32(18))
}
