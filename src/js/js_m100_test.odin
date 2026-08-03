package js

import "core:strings"
import "core:testing"
import dom "../dom"

// M100 — protótipos de interface DOM POPULADOS com os métodos nativos.
// Segue o M99 (que só criou as interfaces + cadeia). Agora `Element.prototype.matches`,
// `Node.prototype.appendChild`, feature-detects (`if (!Element.prototype.matches)`) e
// o padrão uncurryThis (`Node.prototype.appendChild.call(el, child)`) resolvem o
// NATIVO — como nos browsers. Colocação na interface-base; derivadas herdam pela cadeia.

@(private = "file")
m100_dom :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    div := dom.make_node(.Element)
    div.tag = strings.clone("div")
    div.attrs = make(map[string]string)
    div.attrs[strings.clone("id")] = strings.clone("x")
    dom.append_child(root, div)
    return root
}

@(test)
m100_methods_on_own_interface :: proc(t: ^testing.T) {
    root := m100_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        [typeof Element.prototype.matches,           // Element (própria)
         typeof Node.prototype.appendChild,          // Node (própria)
         typeof EventTarget.prototype.addEventListener // EventTarget (própria)
        ].join(',')
    `, root)
    s, _ := r.(string)
    testing.expectf(t, s == "function,function,function", "métodos na interface-base: got %v", s)
}

@(test)
m100_methods_inherited_down_chain :: proc(t: ^testing.T) {
    root := m100_dom(); defer dom.free_tree(root)
    // appendChild vive em Node.prototype → Element/HTMLElement herdam;
    // matches vive em Element.prototype → HTMLElement herda;
    // addEventListener vive em EventTarget.prototype → Node/Element herdam.
    r := run_with_dom(`
        [typeof Element.prototype.appendChild,        // herdado de Node
         typeof HTMLElement.prototype.appendChild,    // herdado de Node
         typeof HTMLElement.prototype.matches,        // herdado de Element
         typeof Node.prototype.addEventListener,      // herdado de EventTarget
         typeof Element.prototype.dispatchEvent       // herdado de EventTarget
        ].join(',')
    `, root)
    s, _ := r.(string)
    testing.expectf(t, s == "function,function,function,function,function", "herança pela cadeia: got %v", s)
}

// O padrão uncurryThis que quebrava: `Node.prototype.appendChild.call(parent, child)`.
@(test)
m100_uncurry_this_appendchild :: proc(t: ^testing.T) {
    root := m100_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var parent = document.getElementById('x');
        var child = document.createElement('span');
        Node.prototype.appendChild.call(parent, child);
        parent.children.length + ':' + parent.children[0].tagName
    `, root)
    s, _ := r.(string)
    testing.expectf(t, s == "1:SPAN", "uncurryThis appendChild: got %v", s)
}

// Feature-detect típico de polyfill: matches JÁ existe → o polyfill é PULADO.
@(test)
m100_matches_feature_detect_passes :: proc(t: ^testing.T) {
    root := m100_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var installed = false;
        if (!Element.prototype.matches) { Element.prototype.matches = function(){ installed = true; }; }
        installed // deve permanecer false: o nativo já satisfaz a detecção
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, !ok, "matches nativo satisfaz o feature-detect (polyfill pulado)")
}

// Métodos de protótipo são não-enumeráveis (Object.keys(Element.prototype) === []).
@(test)
m100_prototype_methods_non_enumerable :: proc(t: ^testing.T) {
    root := m100_dom(); defer dom.free_tree(root)
    r := run_with_dom(`Object.keys(Element.prototype).length`, root)
    testing.expectf(t, as_number(r) == 0, "métodos de protótipo não-enumeráveis: got %v", r)
}

// el.metodo() continua indo pelo get-hook nativo (não regrediu com a população).
@(test)
m100_element_method_dispatch_still_works :: proc(t: ^testing.T) {
    root := m100_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var el = document.getElementById('x');
        el.setAttribute('data-k', 'v');
        el.getAttribute('data-k')
    `, root)
    s, _ := r.(string)
    testing.expectf(t, s == "v", "dispatch de método de elemento: got %v", s)
}
