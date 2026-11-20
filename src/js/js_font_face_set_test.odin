package js

import "core:testing"
import dom "../dom"

// document.fonts (font_face_set.odin). Caso real: a home do github.com faz
// `await document.fonts.ready` antes de montar a animação que revela o bloco
// principal; sem `document.fonts` a promise morria e o meio ficava em branco.

@(test)
document_fonts_ready_resolve :: proc(t: ^testing.T) {
    root := dom.make_node(.Document)
    defer dom.free_tree(root)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var passos = [];
        (async function prepare(){
            var r = await document.fonts.ready;
            passos.push(r === document.fonts, document.fonts.status);
            var carregadas = await document.fonts.load("16px Mona Sans");
            passos.push(Array.isArray(carregadas), document.fonts.check("16px x"));
        })();
    `)
    r := vm_run(vm, `passos.join(",")`)
    s, _ := r.(string)
    testing.expect_value(t, s, "true,loaded,true,true")
    testing.expect_value(t, vm.uncaught_total, 0)
    r2 := vm_run(vm, `[typeof document.fonts.addEventListener, document.fonts.size, Object.keys(document.fonts).indexOf("check")].join(",")`)
    s2, _ := r2.(string)
    testing.expect_value(t, s2, "function,0,-1")
}
