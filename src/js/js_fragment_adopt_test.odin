package js

import "core:strings"
import "core:testing"
import dom "../dom"

// adoptNode MOVE (não clona raso) e DocumentFragment entra pelos FILHOS em
// replaceWith/before/after/prepend. Os dois juntos são o streaming SSR do reddit:
//     t.replaceWith(document.adoptNode(template.content))
// Antes: adoptNode devolvia um fragmento VAZIO e o replaceWith enfiava o próprio
// nó-fragmento na árvore — o feed sumia.

@(private = "file")
roda_html :: proc(body_html, src: string) -> string {
    root := dom.make_node(.Document)
    html := dom.make_node(.Element); html.tag = strings.clone("html"); html.attrs = make(map[string]string)
    body := dom.make_node(.Element); body.tag = strings.clone("body"); body.attrs = make(map[string]string)
    dom.append_child(root, html)
    dom.append_child(html, body)
    defer dom.free_tree(root)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, strings.concatenate({"document.body.innerHTML = '", body_html, "';"}, context.temp_allocator))
    r := vm_run(vm, src)
    s, _ := r.(string)
    return strings.clone(s, context.temp_allocator)
}

// O padrão EXATO do reddit (suspense-replace), com o template de verdade.
@(test)
fragment_streaming_ssr_do_reddit :: proc(t: ^testing.T) {
    got := roda_html(
        `<main id="m"><suspense-placeholder id="s_0"><div>ph</div></suspense-placeholder></main><template for="s_0"><p>A</p><span>B</span></template>`,
        `var t=document.getElementsByTagName("template")[0]; // querySelector depende do hook do ui
         var r=document.adoptNode(t.content);
         var n=r.childNodes.length;
         document.getElementById("s_0").replaceWith(r);
         n+"|"+document.getElementById("m").innerHTML`)
    testing.expect_value(t, got, "2|<p>A</p><span>B</span>")
}

@(test)
adopt_node_move_e_devolve_o_mesmo :: proc(t: ^testing.T) {
    got := roda_html(`<div id="a"><b id="x">1</b></div>`,
        `var x=document.getElementById("x"); var y=document.adoptNode(x);
         [y===x, x.parentNode===null, document.getElementById("a").innerHTML===""].join("|")`)
    testing.expect_value(t, got, "true|true|true")
}

@(test)
fragment_em_before_after_prepend :: proc(t: ^testing.T) {
    got := roda_html(`<ul id="u"><li id="m">m</li></ul>`,
        `function f(a,b){var g=document.createDocumentFragment();var x=document.createElement("i");x.textContent=a;var y=document.createElement("i");y.textContent=b;g.append(x,y);return g}
         var m=document.getElementById("m");
         m.before(f("1","2")); m.after(f("3","4")); document.getElementById("u").prepend(f("0a","0b"));
         // textContent NÃO serve: leria o texto ATRAVÉS de um nó-fragmento enfiado
         // na árvore (a sabotagem passava). Conta os filhos e o HTML.
         var u=document.getElementById("u"); u.children.length+"|"+u.innerHTML`)
    testing.expect_value(t, got, "7|<i>0a</i><i>0b</i><i>1</i><i>2</i><li id=\"m\">m</li><i>3</i><i>4</i>")
}

// Mover um irmão que estava ANTES do ponto: o índice tem de compensar a remoção.
@(test)
after_movendo_irmao_anterior :: proc(t: ^testing.T) {
    got := roda_html(`<p id="p"><i id="a">a</i><i id="b">b</i><i id="c">c</i></p>`,
        `document.getElementById("b").after(document.getElementById("a"));
         document.getElementById("p").textContent`)
    testing.expect_value(t, got, "bac")
}
