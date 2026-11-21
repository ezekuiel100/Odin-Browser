package ui

import "core:strings"
import "core:testing"
import csspkg "../css"
import dompkg "../dom"

@(test)
shadow_page_css_host_and_isolation :: proc(t: ^testing.T) {
    root := dompkg.make_node(.Document)
    defer dompkg.free_tree(root)
    host := dompkg.make_node(.Element)
    host.tag = strings.clone("x-tooltip")
    dompkg.append_child(root, host)
    shadow := dompkg.make_node(.Element)
    shadow.tag = strings.clone("#shadow")
    dompkg.append_child(host, shadow)
    style := dompkg.make_node(.Element)
    style.tag = strings.clone("style")
    dompkg.append_child(shadow, style)
    text := dompkg.make_node(.Text)
    text.text = strings.clone(`:host{color:red} :host(:not([open])) > :is(.popup,.other){display:none}`)
    dompkg.append_child(style, text)
    inside := dompkg.make_node(.Element)
    inside.tag = strings.clone("div")
    dompkg.set_attr(inside, strings.clone("class"), strings.clone("popup"))
    dompkg.append_child(shadow, inside)
    outside := dompkg.make_node(.Element)
    outside.tag = strings.clone("div")
    dompkg.set_attr(outside, strings.clone("class"), strings.clone("popup"))
    dompkg.append_child(root, outside)

    rules, _ := csspkg.parse(collect_page_css(root, "https://example.test/"))
    defer csspkg.free_rules(&rules)
    styles, _ := compute_styles(root, &rules)
    defer free_styles(styles)
    testing.expect_value(t, styles[host].color & 0xffffff, u32(0xff0000))
    testing.expect(t, styles[inside].display_none)
    testing.expect(t, !styles[outside].display_none)
}
