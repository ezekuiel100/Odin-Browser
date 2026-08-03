package js

import "core:strings"
import "core:testing"
import dom "../dom"

// M112 — APIs DOM padrão de inserção que faltavam (gap-miner: navPrimary.
// insertAdjacentElement, mainContent.insertAdjacentHTML, parentNode.replaceChild):
// insertAdjacentElement/Text/HTML + replaceChild. Sem interação com polyfill
// (DOM puro), testáveis em isolamento.

@(private = "file")
m112_dom :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    head := dom.make_node(.Element); head.tag = strings.clone("head"); head.attrs = make(map[string]string)
    body := dom.make_node(.Element); body.tag = strings.clone("body"); body.attrs = make(map[string]string)
    dom.append_child(root, head); dom.append_child(root, body)
    return root
}

@(test)
m112_replace_child :: proc(t: ^testing.T) {
    root := m112_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var old = document.createElement('span'); document.body.appendChild(old);
        var neu = document.createElement('div');
        var ret = document.body.replaceChild(neu, old);
        document.body.children.length === 1 &&
        document.body.children[0].tagName === 'DIV' &&
        ret.tagName === 'SPAN'
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "replaceChild troca oldChild por newChild e devolve oldChild")
}

@(test)
m112_insert_adjacent_element :: proc(t: ^testing.T) {
    root := m112_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var ref = document.createElement('div'); document.body.appendChild(ref);
        ref.insertAdjacentElement('afterbegin',  document.createElement('a'));
        ref.insertAdjacentElement('beforeend',   document.createElement('b'));
        ref.insertAdjacentElement('beforebegin', document.createElement('i'));
        ref.insertAdjacentElement('afterend',    document.createElement('u'));
        // ref.children = [a, b]; body.children = [i, div, u]
        ref.children.length === 2 && ref.children[0].tagName === 'A' && ref.children[1].tagName === 'B' &&
        document.body.children.length === 3 &&
        document.body.children[0].tagName === 'I' &&
        document.body.children[1].tagName === 'DIV' &&
        document.body.children[2].tagName === 'U'
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "insertAdjacentElement cobre as 4 posições")
}

@(test)
m112_insert_adjacent_html_order :: proc(t: ^testing.T) {
    root := m112_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var ref = document.createElement('div'); document.body.appendChild(ref);
        ref.insertAdjacentHTML('beforeend', '<p>1</p><span>2</span>');
        ref.children.length === 2 &&
        ref.children[0].tagName === 'P' && ref.children[1].tagName === 'SPAN'
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "insertAdjacentHTML parseia e preserva a ordem dos nós")
}

@(test)
m112_insert_adjacent_text :: proc(t: ^testing.T) {
    root := m112_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var ref = document.createElement('div'); document.body.appendChild(ref);
        ref.insertAdjacentText('beforeend', 'olá');
        ref.textContent === 'olá'
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "insertAdjacentText insere um nó de texto")
}
