package ui

import "core:testing"
import "core:strings"
import dom "../dom"
import html "../html"
import js "../js"

@(test)
stylesheet_cssom_restyles_existing_page :: proc(t: ^testing.T) {
    doc := html.parse("<html><head><style>div{color:red}</style></head><body><div>hello</div></body></html>")
    defer dom.free_tree(doc)
    vm := js.vm_create_with_dom(doc)
    defer js.vm_free(vm)
    tab := Tab{dom=doc, vm=vm, css_text=strings.clone("div{color:red}")}
    defer {
        free_layout(tab.layout); free_styles(tab.styles); tab_drop_rules(&tab)
        delete(tab.css_text); js_style_source_clear()
    }
    restyle_tab(&tab, 400, 300)
    n := dom.find_first(doc, "div")
    testing.expect_value(t, tab.styles[n].color, u32(0xff0000))
    js.vm_run(vm, `var sh=document.querySelector('style').sheet; sh.insertRule('div{color:blue}',1);`)
    restyle_tab(&tab, 400, 300)
    testing.expect_value(t, tab.styles[n].color, u32(0x0000ff))
    js.vm_run(vm, `sh.deleteRule(1)`)
    restyle_tab(&tab, 400, 300)
    testing.expect_value(t, tab.styles[n].color, u32(0xff0000))
    testing.expect_value(t, vm.uncaught_total, 0)
}
