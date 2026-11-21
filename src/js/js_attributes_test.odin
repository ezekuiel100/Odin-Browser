package js

// el.attributes (NamedNodeMap) + Attr — dom_attributes.odin.
// Cada caso devolve BOOL calculado dentro do script (o vm morre no run_with_dom).

import "core:strings"
import "core:testing"
import dom "../dom"

@(private = "file")
doc_com_div :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    html := dom.make_node(.Element); html.tag = strings.clone("html"); html.attrs = make(map[string]string)
    body := dom.make_node(.Element); body.tag = strings.clone("body"); body.attrs = make(map[string]string)
    dom.append_child(root, html)
    dom.append_child(html, body)
    return root
}

@(private = "file")
expect_true :: proc(t: ^testing.T, src: string, msg: string) {
    root := doc_com_div(); defer dom.free_tree(root)
    r := run_with_dom(src, root)
    ok, _ := r.(bool)
    testing.expectf(t, ok, "%s (veio %v)", msg, r)
}

@(test)
attributes_teste_de_suporte_do_jquery_1_9 :: proc(t: ^testing.T) {
    // O caso real: books.toscrape.com morria aqui com "reading 'onsubmit' of undefined"
    // e o jQuery inteiro não chegava a definir window.jQuery.
    expect_true(t, `
        var d = document.createElement('div');
        d.setAttribute('onsubmit', 't');
        var r = ('onsubmit' in window) || d.attributes['onsubmit'].expando === false;
        r === false && d.attributes.onsubmit.value === 't'
    `, "attributes[nome] devolve o Attr")
}

@(test)
attributes_indice_length_ordem :: proc(t: ^testing.T) {
    expect_true(t, `
        var d = document.createElement('div');
        d.setAttribute('b', '1'); d.setAttribute('a', '2');
        var m = d.attributes;
        m.length === 2 && m[0].name === 'b' && m[1].value === '2' &&
        m[2] === undefined && m.item(2) === null && m.item(0).name === 'b'
    `, "índice segue a ordem de documento; fora do intervalo undefined/null")
}

@(test)
attributes_viva_e_identidade :: proc(t: ^testing.T) {
    expect_true(t, `
        var d = document.createElement('div');
        var m = d.attributes;
        d.setAttribute('title', 'x');
        m === d.attributes && m.length === 1 && m.title.value === 'x'
    `, "a mesma NamedNodeMap, viva")
}

@(test)
attributes_attr_value_escreve_no_elemento :: proc(t: ^testing.T) {
    expect_true(t, `
        var d = document.createElement('div');
        d.setAttribute('title', 'x');
        var a = d.attributes[0];
        a.value = 'y';
        d.getAttribute('title') === 'y' && a.ownerElement === d && a.nodeType === 2
    `, "Attr.value escreve via setAttribute")
}

@(test)
attributes_proto_vence_atributo_homonimo :: proc(t: ^testing.T) {
    // NamedNodeMap não tem [LegacyOverrideBuiltIns]: um atributo "item" não esconde item().
    expect_true(t, `
        var d = document.createElement('div');
        d.setAttribute('item', 'z');
        typeof d.attributes.item === 'function' && d.attributes.getNamedItem('ITEM').value === 'z'
    `, "método do prototype vence; getNamedItem rebaixa a caixa")
}

@(test)
attributes_iteravel_e_remove :: proc(t: ^testing.T) {
    expect_true(t, `
        var d = document.createElement('div');
        d.setAttribute('a', '1'); d.setAttribute('b', '2');
        var nomes = [...d.attributes].map(function (x) { return x.name; }).join(',');
        var tirado = d.attributes.removeNamedItem('a');
        nomes === 'a,b' && tirado.value === '1' && !d.hasAttribute('a') &&
        d.attributes instanceof NamedNodeMap && d.attributes[0] instanceof Attr
    `, "spread, removeNamedItem e instanceof")
}
