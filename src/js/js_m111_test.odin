package js

import "core:strings"
import "core:testing"
import dom "../dom"

// M111 — lote de APIs DOM/JS concretas faltando, achadas pelo gap-miner nos sites
// BLANK (--diagnose): matchesSelector (alias de matches), Image(), createEvent+
// initEvent, createTreeWalker+nextNode (archive.org/mercadolivre), hasFocus,
// Date.toGMTString. Verificação real (un-blank) fica p/ um rebuild do browser.exe.

@(private = "file")
m111_dom :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    head := dom.make_node(.Element); head.tag = strings.clone("head"); head.attrs = make(map[string]string)
    body := dom.make_node(.Element); body.tag = strings.clone("body"); body.attrs = make(map[string]string)
    dom.append_child(root, head); dom.append_child(root, body)
    return root
}

@(test)
m111_matches_selector_alias :: proc(t: ^testing.T) {
    root := m111_dom(); defer dom.free_tree(root)
    // Os 4 aliases são o MESMO native_matches; aqui só garantimos que existem e são
    // chamáveis (o matching real exige o motor de seletores da UI, ausente no harness
    // de JS puro — g_dom_query==nil → matches devolve false sem lançar).
    r := run_with_dom(`
        var d = document.createElement('div'); document.body.appendChild(d);
        typeof d.matchesSelector === 'function' && typeof d.webkitMatchesSelector === 'function' &&
        typeof d.mozMatchesSelector === 'function' && typeof d.msMatchesSelector === 'function' &&
        d.matchesSelector('.x') === false
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "aliases matchesSelector/webkit/moz/ms existem e são chamáveis")
}

@(test)
m111_image_constructor :: proc(t: ^testing.T) {
    root := m111_dom(); defer dom.free_tree(root)
    r := run_with_dom(`var i = new Image(); i.tagName`, root)
    s, _ := r.(string)
    testing.expectf(t, s == "IMG", "new Image().tagName == 'IMG' (MAIÚSCULO, spec HTML): got %v", r)
}

@(test)
m111_create_event_init :: proc(t: ^testing.T) {
    root := m111_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var e = document.createEvent('Event');
        e.initEvent('click', true, false);
        e.type === 'click' && e.bubbles === true && e.cancelable === false
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "createEvent + initEvent devem inicializar type/bubbles/cancelable")
}

@(test)
m111_tree_walker_next_node :: proc(t: ^testing.T) {
    root := m111_dom(); defer dom.free_tree(root)
    // body > div > span ; nextNode c/ SHOW_ELEMENT deve visitar div e span (não o root)
    r := run_with_dom(`
        var a = document.createElement('div');  document.body.appendChild(a);
        var b = document.createElement('span'); a.appendChild(b);
        var w = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT);
        var count = 0, n;
        while (n = w.nextNode()) count++;
        count
    `, root)
    testing.expectf(t, as_number(r) == 2, "TreeWalker.nextNode visita 2 elementos (div, span): got %v", r)
}

@(test)
m111_tree_walker_first_child_parent :: proc(t: ^testing.T) {
    root := m111_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var a = document.createElement('div');  document.body.appendChild(a);
        var b = document.createElement('span'); a.appendChild(b);
        var w = document.createTreeWalker(document.body, NodeFilter.SHOW_ELEMENT);
        var c1 = w.firstChild();        // -> div
        var c2 = w.firstChild();        // -> span
        var p  = w.parentNode();        // -> div
        c1.tagName === 'DIV' && c2.tagName === 'SPAN' && p.tagName === 'DIV'
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "firstChild/parentNode navegam a subárvore")
}

@(test)
m111_has_focus :: proc(t: ^testing.T) {
    root := m111_dom(); defer dom.free_tree(root)
    r := run_with_dom(`document.hasFocus()`, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "document.hasFocus() => true (aproximação)")
}

@(test)
m111_date_to_gmt_string :: proc(t: ^testing.T) {
    root := m111_dom(); defer dom.free_tree(root)
    r := run_with_dom(`typeof new Date(0).toGMTString() === 'string' && new Date(0).toGMTString() === new Date(0).toUTCString()`, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "toGMTString existe e espelha toUTCString")
}
