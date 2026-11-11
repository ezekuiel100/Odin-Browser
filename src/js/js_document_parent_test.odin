package js

import "core:testing"
import "core:strings"
import dom "../dom"

@(test)
document_parent_node_liveview :: proc(t: ^testing.T) {
    root := dom.make_node(.Document)
    defer dom.free_tree(root)
    dom.append_child(root, dom.make_node(.Comment))
    html := dom.make_node(.Element)
    html.tag = strings.clone("html")
    dom.append_child(root, html)
    dom.append_child(root, dom.make_node(.Comment))
    vm := vm_create_with_dom(root)
    defer vm_destroy(vm)
    vm_run(vm, `
        function isPhxView(el) {
            return el.getAttribute && el.getAttribute("data-phx-session") !== null;
        }
        var ok = document.firstElementChild === document.documentElement &&
            document.lastElementChild === document.documentElement &&
            document.children.length === 1 && document.childElementCount === 1 &&
            document.childNodes.length === 3 && document.firstChild.nodeType === 8 &&
            document.lastChild.nodeType === 8 && !isPhxView(document.firstElementChild);
        var children = document.children;
        var nodes = document.childNodes;
        document.firstElementChild.remove();
        ok = ok && children.length === 0 && nodes.length === 2 &&
            document.firstElementChild === null && document.lastElementChild === null &&
            document.childElementCount === 0;
    `)
    testing.expect(t, vm.uncaught_total == 0, "LiveView document traversal must not throw")
    ok, _ := env_get(vm.global, "ok")
    testing.expect(t, truthy(ok), "Document traversal must filter comments and reflect removals")
}
