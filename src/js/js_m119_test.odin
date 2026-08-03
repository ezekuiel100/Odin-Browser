package js

import "core:strings"
import "core:testing"
import dom "../dom"

// M119 — gaps concretos do gap-report agregado (voltar ao agregado pós M116-M118):
//  (1) document.location === window.location (era undefined → `document.location.search`
//      lançava; cluster `reading 'search'`: discord/wired/mercadolivre/terra).
//  (2) Event/CustomEvent/XMLHttpRequest ganham `.prototype` (polyfills leem
//      `Ctor.prototype.metodo`; cluster `reading 'prototype'`: soundcloud/mercadolivre).

@(private = "file")
m119_dom :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    body := dom.make_node(.Element); body.tag = strings.clone("body"); body.attrs = make(map[string]string)
    dom.append_child(root, body)
    return root
}

@(test)
m119_document_location :: proc(t: ^testing.T) {
    root := m119_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        (typeof document.location === 'object') &&
        (document.location === window.location) &&
        (typeof document.location.search === 'string')
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "document.location === window.location e tem .search")
}

@(test)
m119_event_prototype :: proc(t: ^testing.T) {
    root := m119_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        (typeof Event.prototype === 'object') &&
        (typeof Event.prototype.preventDefault === 'function') &&
        (typeof Event.prototype.stopPropagation === 'function') &&
        (Event.prototype.constructor === Event)
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "Event.prototype existe com métodos + constructor")
}

@(test)
m119_event_instance_methods :: proc(t: ^testing.T) {
    root := m119_dom(); defer dom.free_tree(root)
    // instância de new Event herda os métodos do prototype (não lança).
    r := run_with_dom(`
        var e = new Event('click');
        var ok = true;
        try { e.preventDefault(); e.stopPropagation(); } catch(x){ ok = false; }
        ok && e.type === 'click' && (e instanceof Event)
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "new Event herda preventDefault/stopPropagation e é instanceof Event")
}

@(test)
m119_xhr_prototype :: proc(t: ^testing.T) {
    root := m119_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        (typeof XMLHttpRequest.prototype === 'object') &&
        (typeof XMLHttpRequest.prototype.setRequestHeader === 'function') &&
        (typeof XMLHttpRequest.prototype.open === 'function')
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "XMLHttpRequest.prototype expõe setRequestHeader/open")
}

@(test)
m119_customevent_extends_event :: proc(t: ^testing.T) {
    root := m119_dom(); defer dom.free_tree(root)
    // CustomEvent.prototype herda de Event.prototype (composedPath vem de lá).
    r := run_with_dom(`
        (typeof CustomEvent.prototype.preventDefault === 'function') &&
        (typeof KeyboardEvent.prototype.stopPropagation === 'function')
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "CustomEvent/KeyboardEvent.prototype herdam de Event.prototype")
}
