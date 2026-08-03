package js

import "core:strings"
import "core:testing"
import dom "../dom"

// M99 — interfaces DOM globais (Element/Node/HTMLElement/Document/EventTarget/…).
// Eram undefined → `Element.prototype.matches = …` (polyfills), `x instanceof
// HTMLElement`, `Node.prototype`, feature-detects batiam em "Cannot read properties
// of undefined (reading 'prototype')" → bundle abortava → PÁGINA EM BRANCO
// (archive.org e cia., topo do gap-miner). Agora existem como construtores globais
// com `.prototype` encadeado; HTMLElement.prototype é o proto dos wrappers de elemento.

@(private = "file")
m99_dom :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    div := dom.make_node(.Element)
    div.tag = strings.clone("div")
    div.attrs = make(map[string]string)
    div.attrs[strings.clone("id")] = strings.clone("x")
    dom.append_child(root, div)
    return root
}

@(test)
m99_interface_globals_exist :: proc(t: ^testing.T) {
    root := m99_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        [typeof Element, typeof Node, typeof HTMLElement, typeof Document,
         typeof EventTarget, typeof DocumentFragment, typeof HTMLDivElement].join(',')
    `, root)
    s, _ := r.(string)
    testing.expectf(t, s == "function,function,function,function,function,function,function",
        "todas as interfaces devem existir: got %v", s)
}

@(test)
m99_interface_prototype_is_object :: proc(t: ^testing.T) {
    root := m99_dom(); defer dom.free_tree(root)
    r := run_with_dom(`typeof Element.prototype + ',' + typeof Node.prototype + ',' + typeof HTMLElement.prototype`, root)
    s, _ := r.(string)
    testing.expectf(t, s == "object,object,object", "X.prototype deve ser objeto: got %v", s)
}

@(test)
m99_prototype_chain :: proc(t: ^testing.T) {
    root := m99_dom(); defer dom.free_tree(root)
    // HTMLElement.prototype → Element.prototype → Node.prototype → EventTarget.prototype
    r := run_with_dom(`
        (Object.getPrototypeOf(HTMLElement.prototype) === Element.prototype) + ',' +
        (Object.getPrototypeOf(Element.prototype) === Node.prototype) + ',' +
        (Object.getPrototypeOf(Node.prototype) === EventTarget.prototype)
    `, root)
    s, _ := r.(string)
    testing.expectf(t, s == "true,true,true", "cadeia de protótipos: got %v", s)
}

@(test)
m99_element_instanceof :: proc(t: ^testing.T) {
    root := m99_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var el = document.getElementById('x');
        [el instanceof HTMLElement, el instanceof Element, el instanceof Node, el instanceof EventTarget].join(',')
    `, root)
    s, _ := r.(string)
    testing.expectf(t, s == "true,true,true,true", "el instanceof cadeia: got %v", s)
}

@(test)
m99_document_instanceof :: proc(t: ^testing.T) {
    root := m99_dom(); defer dom.free_tree(root)
    r := run_with_dom(`(document instanceof Document) + ',' + (document instanceof Node)`, root)
    s, _ := r.(string)
    testing.expectf(t, s == "true,true", "document instanceof: got %v", s)
}

// O padrão que quebrava os sites: polyfill grava em Element.prototype e é chamado
// via el.metodo(). O get-hook nativo tem prioridade; a cadeia preenche a lacuna.
@(test)
m99_polyfill_on_prototype_reachable :: proc(t: ^testing.T) {
    root := m99_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        Element.prototype.__polyTest = function(){ return 'poly:' + this.id; };
        document.getElementById('x').__polyTest()
    `, root)
    s, _ := r.(string)
    testing.expectf(t, s == "poly:x", "método poly-preenchido em Element.prototype: got %v", s)
}

@(test)
m99_element_constructor_is_htmlelement :: proc(t: ^testing.T) {
    root := m99_dom(); defer dom.free_tree(root)
    r := run_with_dom(`document.getElementById('x').constructor === HTMLElement`, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "el.constructor === HTMLElement")
}
