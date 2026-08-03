package js

import "core:strings"
import "core:testing"
import dom "../dom"

// M116 — identificador livre resolve p/ prop de window (browser: objeto global
// É o window). O nu `addEventListener(...)` == `window.addEventListener`. Antes só
// alguns globais eram espelhados à mão (localStorage/location/navigator) e os
// métodos de window ficavam de fora → `addEventListener is not a function`.
// (gap-miner pós-triagem anti-bot: dev.to/figma/brave/openstreetmap/aliexpress.)

@(private = "file")
m116_dom :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    body := dom.make_node(.Element); body.tag = strings.clone("body"); body.attrs = make(map[string]string)
    dom.append_child(root, body)
    return root
}

@(test)
m116_bare_add_event_listener :: proc(t: ^testing.T) {
    root := m116_dom(); defer dom.free_tree(root)
    // nu, sem `window.` — não deve lançar e deve ser função.
    r := run_with_dom(`typeof addEventListener === 'function'`, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "addEventListener nu resolve p/ window.addEventListener")
}

@(test)
m116_bare_add_event_listener_callable :: proc(t: ^testing.T) {
    root := m116_dom(); defer dom.free_tree(root)
    // chamável sem lançar (registra no host raiz; no-op observável = não crashar).
    r := run_with_dom(`
        var ok = true;
        try { addEventListener('resize', function(){}); } catch (e) { ok = false; }
        ok
    `, root)
    b, _ := r.(bool)
    testing.expect(t, b, "chamar addEventListener nu não lança")
}

@(test)
m116_bare_window_methods :: proc(t: ^testing.T) {
    root := m116_dom(); defer dom.free_tree(root)
    // outros métodos de window também resolvem nus.
    r := run_with_dom(`
        typeof matchMedia === 'function' &&
        typeof getComputedStyle === 'function' &&
        typeof scrollTo === 'function' &&
        typeof removeEventListener === 'function'
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "matchMedia/getComputedStyle/scrollTo/removeEventListener nus resolvem")
}

@(test)
m116_undefined_ident_still_undefined :: proc(t: ^testing.T) {
    root := m116_dom(); defer dom.free_tree(root)
    // regressão: ident genuinamente ausente continua undefined (has-check).
    r := run_with_dom(`typeof __naoExisteNoWindow_xyz__ === 'undefined'`, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "ident ausente do window continua undefined")
}

@(test)
m116_local_shadows_window :: proc(t: ^testing.T) {
    root := m116_dom(); defer dom.free_tree(root)
    // um local/param com o mesmo nome VENCE a prop de window (escopo primeiro).
    r := run_with_dom(`
        function f(addEventListener){ return addEventListener; }
        f(42)
    `, root)
    testing.expect_value(t, as_number(r), f64(42))
}
