package js

// M65: APIs de browser reveladas pelos TypeError honestos do M60 num site real
// (google.com): this global = window, navigator/location/history como globais,
// document.body/head/documentElement, clientWidth, getElementsBy*, observers
// stub e sendBeacon. Rodar: odin test src/js

import "core:strings"
import "core:testing"
import dom "../dom"

// <html><head></head><body><p class="a" name="n1"/><p class="a b"/><div/></body></html>
@(private = "file")
build_page_dom :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    mk :: proc(tag: string) -> ^dom.Node {
        n := dom.make_node(.Element)
        n.tag = strings.clone(tag)
        n.attrs = make(map[string]string)
        return n
    }
    html := mk("html")
    head := mk("head")
    body := mk("body")
    p1 := mk("p"); p1.attrs[strings.clone("class")] = strings.clone("a"); p1.attrs[strings.clone("name")] = strings.clone("n1")
    p2 := mk("p"); p2.attrs[strings.clone("class")] = strings.clone("a b")
    d := mk("div")
    dom.append_child(body, p1)
    dom.append_child(body, p2)
    dom.append_child(body, d)
    dom.append_child(html, head)
    dom.append_child(html, body)
    dom.append_child(root, html)
    return root
}

@(test)
test_global_this_is_window :: proc(t: ^testing.T) {
    root := build_page_dom()
    defer dom.free_tree(root)
    testing.expect_value(t, run_with_dom(`
        this.gbar_ = { ok: 1 };                      // o idioma do Google
        var viaFn = (function(){ return this; })();  // sloppy: this = window
        (this === window) && (viaFn === window) && (window.gbar_.ok === 1) && (gbar_.ok === 1)
    `, root).(bool), true)
}

@(test)
test_bare_navigator_location_history :: proc(t: ^testing.T) {
    root := build_page_dom()
    defer dom.free_tree(root)
    testing.expect_value(t, run_with_dom(`
        (typeof navigator.userAgent === 'string') &&
        (navigator.sendBeacon('/x', 'dados') === true) &&
        (typeof location.href === 'string') &&
        (typeof history.pushState === 'function')
    `, root).(bool), true)
}

@(test)
test_document_body_head_root :: proc(t: ^testing.T) {
    root := build_page_dom()
    defer dom.free_tree(root)
    testing.expect_value(t, run_with_dom(`
        document.body.tagName + ':' + document.head.tagName + ':' +
        document.documentElement.tagName + ':' +
        (document.documentElement.clientWidth > 0) + ':' +
        (typeof document.body.addEventListener === 'function')
    `, root).(string), "BODY:HEAD:HTML:true:true")
}

@(test)
test_document_body_append_child :: proc(t: ^testing.T) {
    root := build_page_dom()
    defer dom.free_tree(root)
    testing.expect_value(t, run_with_dom(`
        var s = document.createElement('span');
        s.textContent = 'novo';
        document.body.appendChild(s);
        document.getElementsByTagName('span')[0].textContent + ':' + document.body.textContent
    `, root).(string), "novo:novo")
}

@(test)
test_get_elements_by :: proc(t: ^testing.T) {
    root := build_page_dom()
    defer dom.free_tree(root)
    testing.expect_value(t, run_with_dom(`
        document.getElementsByTagName('p').length + ':' +
        document.getElementsByTagName('*').length + ':' +
        document.getElementsByClassName('a').length + ':' +
        document.getElementsByClassName('b').length + ':' +
        document.getElementsByName('n1').length + ':' +
        document.body.getElementsByTagName('p').length
    `, root).(string), "2:6:2:1:1:2")
}

@(test)
test_observers_stub :: proc(t: ^testing.T) {
    root := build_page_dom()
    defer dom.free_tree(root)
    testing.expect_value(t, run_with_dom(`
        var mo = new MutationObserver(function(){});
        mo.observe(document.body, { childList: true });
        mo.disconnect();
        var io = new IntersectionObserver(function(){});
        io.observe(document.body);
        var ro = new ResizeObserver(function(){});
        (mo.takeRecords().length === 0) && (typeof io.unobserve === 'function') &&
        (typeof ro.observe === 'function')
    `, root).(bool), true)
}

@(test)
test_window_viewport_screen :: proc(t: ^testing.T) {
    root := build_page_dom()
    defer dom.free_tree(root)
    testing.expect_value(t, run_with_dom(`
        (window.innerWidth > 0) && (window.innerHeight > 0) && (screen.width > 0)
    `, root).(bool), true)
}

@(test)
test_this_undefined_without_dom :: proc(t: ^testing.T) {
    // regressão: no vm PURO (sem DOM/window), this global segue undefined
    testing.expect_value(t, run(`typeof this`).(string), "undefined")
}
