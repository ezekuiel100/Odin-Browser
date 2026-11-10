package ui
import "core:testing"
import htmlp "../html"
import csspkg "../css"
import dompkg "../dom"

@(test)
inline_pseudo_inherits_visibility_and_weight :: proc(t: ^testing.T) {
    doc := htmlp.parse_render(`<div style="visibility:hidden;font-weight:bold"><span id="a"></span><span id="b" style="visibility:visible"></span></div>`)
    defer dompkg.free_tree(doc)
    rules, kf := csspkg.parse(`span::before {content:"generated"} #b::before {font-weight:normal}`)
    defer csspkg.free_rules(&rules)
    defer csspkg.free_keyframes(&kf)
    styles, _ := compute_styles(doc, &rules)
    defer free_styles(styles)
    count := 0
    for n, c in styles {
        if n.attrs["id"] == "a" {
            count += 1
            testing.expect(t, c.before != nil)
            if c.before != nil {
                testing.expect(t, c.before.invisible)
                testing.expect_value(t, fw_class(c.before.weight), Weight_Class.Bold)
            }
        }
        if n.attrs["id"] == "b" {
            count += 1
            testing.expect(t, c.before != nil)
            if c.before != nil {
                testing.expect(t, !c.before.invisible)
                testing.expect_value(t, fw_class(c.before.weight), Weight_Class.Regular)
            }
        }
    }
    testing.expect_value(t, count, 2)
}

@(test)
flattened_inline_pseudo_preserves_box_and_text_style :: proc(t: ^testing.T) {
    doc := htmlp.parse_render(`<div><span id="icon"></span><span id="label"></span></div>`)
    defer dompkg.free_tree(doc)
    rules, kf := csspkg.parse(`#icon::before{content:"";position:absolute;left:12px;top:14px;width:20px;height:22px;background:blue} #label::after{content:"generated";color:red;font-size:30px}`)
    defer csspkg.free_rules(&rules)
    defer csspkg.free_keyframes(&kf)
    styles, _ := compute_styles(doc, &rules)
    defer free_styles(styles)
    root := build_layout(doc, styles, "")
    defer free_layout(root)
    inspect :: proc(b: ^Box, t: ^testing.T, count: ^int) {
        if b.pos == .Absolute {
            count^ += 1
            testing.expect(t, b.has_width && b.width == 20 && b.has_height && b.height == 22)
            testing.expect(t, b.inset[3] == 12 && b.inset[0] == 14)
        }
        for it in b.inlines {
            if it.text == "generated" {
                count^ += 1
                testing.expect(t, it.color == 0xff0000 && it.fsize == 30)
            }
            if it.box != nil do inspect(it.box, t, count)
        }
        for child in b.children do inspect(child, t, count)
    }
    count := 0
    inspect(root, t, &count)
    testing.expect_value(t, count, 2)
}
