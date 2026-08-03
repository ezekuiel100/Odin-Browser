package js

// M54: global implícito (env_assign) + grupo stdlib da auditoria 2026-07-08
// (parseInt radix, parseFloat expoente/Infinity, substring de verdade, indexOf
// fromIndex, replace com $-refs em pattern string, Math.round half-up, slice
// com undefined explícito).
// Rodar: odin test src/js

import "core:strings"
import "core:testing"
import dom "../dom"

// ── global implícito ──────────────────────────────────────────────────────────

@(test)
test_implicit_global_from_function :: proc(t: ^testing.T) {
    // atribuição sem declaração dentro de função cria GLOBAL (sloppy mode)
    testing.expect_value(t, as_number(run(`
        function f(){ leaked = 42; }
        f();
        leaked
    `)), f64(42))
}

@(test)
test_implicit_global_from_block :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        { inner = 7; }
        inner
    `)), f64(7))
}

@(test)
test_declared_local_still_local :: proc(t: ^testing.T) {
    // regressão: var/let dentro de função NÃO vazam
    testing.expect_value(t, run(`
        function f(){ var x = 1; let y = 2; }
        f();
        typeof x + typeof y
    `).(string), "undefinedundefined")
}

@(test)
test_assign_outer_still_writes_outer :: proc(t: ^testing.T) {
    // regressão: atribuir a var de escopo externo escreve NELA, não cria global
    testing.expect_value(t, as_number(run(`
        var count = 0;
        function inc(){ count = count + 1; }
        inc(); inc();
        count
    `)), f64(2))
}

// ── parseInt / parseFloat ─────────────────────────────────────────────────────

@(test)
test_parse_int_radix :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`parseInt("ff", 16)`)), f64(255))
    testing.expect_value(t, as_number(run(`parseInt("101", 2)`)), f64(5))
    testing.expect_value(t, as_number(run(`parseInt("z", 36)`)), f64(35))
    testing.expect_value(t, as_number(run(`parseInt("-10", 8)`)), f64(-8))
}

@(test)
test_parse_int_0x_prefix :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`parseInt("0xFF")`)), f64(255))
    testing.expect_value(t, as_number(run(`parseInt("0x10", 16)`)), f64(16))
}

@(test)
test_parse_int_stops_at_invalid :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`parseInt("12px")`)), f64(12))
    testing.expect_value(t, as_number(run(`parseInt("129", 8)`)), f64(10)) // 9 inválido em octal
}

@(test)
test_parse_int_invalid :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`isNaN(parseInt("abc")) && isNaN(parseInt("5", 1)) && isNaN(parseInt("5", 37))`).(bool), true)
}

@(test)
test_parse_float_exponent :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`parseFloat("1e3")`)), f64(1000))
    testing.expect_value(t, as_number(run(`parseFloat("2.5e-2")`)), f64(0.025))
    testing.expect_value(t, as_number(run(`parseFloat("1e")`)), f64(1)) // "e" sem dígito não consome
}

@(test)
test_parse_float_infinity :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`parseFloat("Infinity") === Infinity && parseFloat("-Infinity") === -Infinity`).(bool), true)
}

// ── substring / slice / indexOf ───────────────────────────────────────────────

@(test)
test_substring_negative_is_zero :: proc(t: ^testing.T) {
    // o caso da auditoria: 'hello'.substring(-3) deve ser 'hello' (não 'llo')
    testing.expect_value(t, run(`'hello'.substring(-3)`).(string), "hello")
}

@(test)
test_substring_swaps_args :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`'hello'.substring(4, 1)`).(string), "ell")
}

@(test)
test_slice_negative_still_from_end :: proc(t: ^testing.T) {
    // regressão: slice continua contando do fim
    testing.expect_value(t, run(`'hello'.slice(-3)`).(string), "llo")
}

@(test)
test_slice_explicit_undefined_end :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`'hello'.slice(1, undefined)`).(string), "ello")
    testing.expect_value(t, as_number(run(`[1,2,3,4].slice(1, undefined).length`)), f64(3))
}

@(test)
test_index_of_from_index :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`'abcabc'.indexOf('a', 1)`)), f64(3))
    testing.expect_value(t, as_number(run(`'abcabc'.indexOf('a', -5)`)), f64(0)) // negativo → 0
    testing.expect_value(t, as_number(run(`'abc'.indexOf('a', 99)`)), f64(-1))
}

// ── replace com $-refs em pattern string ──────────────────────────────────────

@(test)
test_replace_string_dollar_refs :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`'preço: 10'.replace('10', '$$$&')`).(string), "preço: $10")
    testing.expect_value(t, run("'abc'.replace('b', \"[$`|$&|$']\")").(string), "a[a|b|c]c")
}

@(test)
test_replace_string_no_dollar_fast_path :: proc(t: ^testing.T) {
    // regressão: replace comum continua funcionando (caminho sem $)
    testing.expect_value(t, run(`'aXbXc'.replace('X', '-')`).(string), "a-bXc")
}

// ── Math.round ────────────────────────────────────────────────────────────────

@(test)
test_math_round_half_up :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`Math.round(-2.5)`)), f64(-2))
    testing.expect_value(t, as_number(run(`Math.round(2.5)`)), f64(3))
    testing.expect_value(t, as_number(run(`Math.round(-2.6)`)), f64(-3))
    testing.expect_value(t, as_number(run(`Math.round(2.4)`)), f64(2))
}

// ── eventos DOM (removeEventListener, dedup, detail/bubbles) ─────────────────

// <div id="pai"><span id="filho"></span></div> sob um Document.
@(private = "file")
build_event_dom :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    div := dom.make_node(.Element)
    div.tag = strings.clone("div")
    div.attrs = make(map[string]string)
    div.attrs[strings.clone("id")] = strings.clone("pai")
    span := dom.make_node(.Element)
    span.tag = strings.clone("span")
    span.attrs = make(map[string]string)
    span.attrs[strings.clone("id")] = strings.clone("filho")
    dom.append_child(div, span)
    dom.append_child(root, div)
    return root
}

@(test)
test_remove_event_listener :: proc(t: ^testing.T) {
    root := build_event_dom()
    defer dom.free_tree(root)
    testing.expect_value(t, as_number(run_with_dom(`
        var el = document.getElementById('filho');
        var n = 0;
        function h(){ n++; }
        el.addEventListener('ping', h);
        el.dispatchEvent('ping');       // 1
        el.removeEventListener('ping', h);
        el.dispatchEvent('ping');       // removido: não conta
        n
    `, root)), f64(1))
}

@(test)
test_remove_keeps_other_listeners :: proc(t: ^testing.T) {
    root := build_event_dom()
    defer dom.free_tree(root)
    testing.expect_value(t, as_number(run_with_dom(`
        var el = document.getElementById('filho');
        var n = 0;
        function a(){ n += 1; }
        function b(){ n += 10; }
        el.addEventListener('ping', a);
        el.addEventListener('ping', b);
        el.removeEventListener('ping', a);
        el.dispatchEvent('ping');
        n
    `, root)), f64(10))
}

@(test)
test_add_event_listener_dedup :: proc(t: ^testing.T) {
    root := build_event_dom()
    defer dom.free_tree(root)
    testing.expect_value(t, as_number(run_with_dom(`
        var el = document.getElementById('filho');
        var n = 0;
        function h(){ n++; }
        el.addEventListener('ping', h);
        el.addEventListener('ping', h); // duplicado: ignorado (spec)
        el.dispatchEvent('ping');
        n
    `, root)), f64(1))
}

@(test)
test_dispatch_event_detail :: proc(t: ^testing.T) {
    root := build_event_dom()
    defer dom.free_tree(root)
    testing.expect_value(t, as_number(run_with_dom(`
        var el = document.getElementById('filho');
        var got = 0;
        el.addEventListener('soma', function(e){ got = e.detail.valor; });
        el.dispatchEvent(new CustomEvent('soma', { detail: { valor: 99 } }));
        got
    `, root)), f64(99))
}

@(test)
test_dispatch_event_bubbles :: proc(t: ^testing.T) {
    root := build_event_dom()
    defer dom.free_tree(root)
    // sem bubbles o pai NÃO ouve; com bubbles:true ouve
    testing.expect_value(t, as_number(run_with_dom(`
        var pai = document.getElementById('pai');
        var filho = document.getElementById('filho');
        var n = 0;
        pai.addEventListener('ping', function(){ n++; });
        filho.dispatchEvent(new Event('ping'));                  // default: não sobe
        filho.dispatchEvent(new Event('ping', { bubbles: true })); // sobe
        n
    `, root)), f64(1))
}

@(test)
test_dispatch_event_prevent_default_return :: proc(t: ^testing.T) {
    root := build_event_dom()
    defer dom.free_tree(root)
    testing.expect_value(t, run_with_dom(`
        var el = document.getElementById('filho');
        el.addEventListener('go', function(e){ e.preventDefault(); });
        var cancelado = el.dispatchEvent(new Event('go')) === false;
        var normal = el.dispatchEvent(new Event('outro')) === true;
        cancelado && normal
    `, root).(bool), true)
}

@(test)
test_dispatch_string_still_bubbles :: proc(t: ^testing.T) {
    // regressão: dispatchEvent('tipo') como string continua subindo (comportamento antigo)
    root := build_event_dom()
    defer dom.free_tree(root)
    testing.expect_value(t, as_number(run_with_dom(`
        var pai = document.getElementById('pai');
        var filho = document.getElementById('filho');
        var n = 0;
        pai.addEventListener('ping', function(){ n++; });
        filho.dispatchEvent('ping');
        n
    `, root)), f64(1))
}

@(test)
test_remove_does_not_touch_prop_handler :: proc(t: ^testing.T) {
    // removeEventListener não afeta el.on<tipo> (igual ao DOM real)
    root := build_event_dom()
    defer dom.free_tree(root)
    testing.expect_value(t, as_number(run_with_dom(`
        var el = document.getElementById('filho');
        var n = 0;
        function h(){ n++; }
        el.onping = h; // handler-propriedade (mesma fn!)
        el.removeEventListener('ping', h);
        el.dispatchEvent('ping');
        n
    `, root)), f64(1))
}
