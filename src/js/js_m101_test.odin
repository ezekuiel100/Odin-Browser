package js

import "core:strings"
import "core:testing"
import dom "../dom"

// M101 — <iframe>.contentWindow / .contentDocument. Libs criam um iframe e acessam
// `iframe.contentWindow.document` (feature-detect/sandbox); contentWindow era
// undefined → "reading 'document' of undefined" — gap #1 do gap-miner (8 sites:
// codepen/medium/discord/wired/stackoverflow/canva/zoom/estadao). Agora o iframe
// expõe uma janela+documento próprios (em branco), com identidade estável.

@(private = "file")
m101_dom :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    body := dom.make_node(.Element); body.tag = strings.clone("body"); body.attrs = make(map[string]string)
    ifr := dom.make_node(.Element); ifr.tag = strings.clone("iframe"); ifr.attrs = make(map[string]string)
    ifr.attrs[strings.clone("id")] = strings.clone("f")
    dom.append_child(body, ifr)
    dom.append_child(root, body)
    return root
}

@(test)
m101_contentwindow_document :: proc(t: ^testing.T) {
    root := m101_dom(); defer dom.free_tree(root)
    // o padrão exato que quebrava os 8 sites
    r := run_with_dom(`
        var f = document.getElementById('f');
        typeof f.contentWindow + ',' + typeof f.contentWindow.document + ',' + f.contentWindow.document.nodeType
    `, root)
    s, _ := r.(string)
    testing.expectf(t, s == "object,object,9", "contentWindow.document: got %v", s)
}

@(test)
m101_contentdocument :: proc(t: ^testing.T) {
    root := m101_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var f = document.getElementById('f');
        typeof f.contentDocument + ',' + (f.contentDocument === f.contentWindow.document)
    `, root)
    s, _ := r.(string)
    testing.expectf(t, s == "object,true", "contentDocument === contentWindow.document: got %v", s)
}

@(test)
m101_contentwindow_identity_stable :: proc(t: ^testing.T) {
    root := m101_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var f = document.getElementById('f');
        f.contentWindow === f.contentWindow
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "iframe.contentWindow deve ter identidade estável (cacheado)")
}

// O documento do iframe é PRÓPRIO (separado do document principal) e utilizável.
@(test)
m101_contentdocument_is_separate_and_usable :: proc(t: ^testing.T) {
    root := m101_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var d = document.getElementById('f').contentWindow.document;
        (d !== document) + ',' + (typeof d.createElement) + ',' + (typeof d.body) + ',' + d.body.tagName
    `, root)
    s, _ := r.(string)
    testing.expectf(t, s == "true,function,object,BODY", "contentDocument separado e usável: got %v", s)
}

// contentWindow herda a API de janela (setTimeout via global, location do main).
@(test)
m101_contentwindow_inherits_window_api :: proc(t: ^testing.T) {
    root := m101_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var w = document.getElementById('f').contentWindow;
        typeof w.setTimeout + ',' + typeof w.location + ',' + typeof w.addEventListener
    `, root)
    s, _ := r.(string)
    testing.expectf(t, s == "function,object,function", "contentWindow herda API de janela: got %v", s)
}

// contentDocument.defaultView aponta de volta p/ contentWindow.
@(test)
m101_contentdocument_defaultview :: proc(t: ^testing.T) {
    root := m101_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var f = document.getElementById('f');
        f.contentDocument.defaultView === f.contentWindow
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "contentDocument.defaultView === contentWindow")
}

// Elementos que NÃO são iframe não têm contentWindow (undefined).
@(test)
m101_non_iframe_has_no_contentwindow :: proc(t: ^testing.T) {
    root := m101_dom(); defer dom.free_tree(root)
    r := run_with_dom(`typeof document.body.contentWindow`, root)
    s, _ := r.(string)
    testing.expectf(t, s == "undefined", "não-iframe não tem contentWindow: got %v", s)
}
