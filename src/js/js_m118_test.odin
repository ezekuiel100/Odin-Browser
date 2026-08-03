package js

import "core:strings"
import "core:testing"
import dom "../dom"

// M118 — history.state persiste o que pushState/replaceState guardam. Antes
// pushState/replaceState eram no-op e history.state ficava fixo em null → SPAs
// que fazem `history.replaceState({key},…)` e leem `history.state.key` batiam em
// "reading 'key' of null" (medium blank). Sem navegação real: só o state persiste.

@(private = "file")
m118_dom :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    body := dom.make_node(.Element); body.tag = strings.clone("body"); body.attrs = make(map[string]string)
    dom.append_child(root, body)
    return root
}

@(test)
m118_initial_state_null :: proc(t: ^testing.T) {
    root := m118_dom(); defer dom.free_tree(root)
    r := run_with_dom(`history.state === null`, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "history.state inicial é null")
}

@(test)
m118_replace_state_persists :: proc(t: ^testing.T) {
    root := m118_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        history.replaceState({ key: 'abc', idx: 3 }, '', '/x');
        history.state.key + ':' + history.state.idx
    `, root)
    s, _ := r.(string)
    testing.expect_value(t, s, "abc:3")
}

@(test)
m118_push_state_persists :: proc(t: ^testing.T) {
    root := m118_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        history.pushState({ key: 'def' }, '', '/y');
        history.state.key
    `, root)
    s, _ := r.(string)
    testing.expect_value(t, s, "def")
}

@(test)
m118_push_then_replace :: proc(t: ^testing.T) {
    root := m118_dom(); defer dom.free_tree(root)
    // replaceState sobrescreve o state atual.
    r := run_with_dom(`
        history.pushState({ n: 1 }, '', '/a');
        history.replaceState({ n: 2 }, '', '/b');
        history.state.n
    `, root)
    testing.expect_value(t, as_number(r), f64(2))
}

@(test)
m118_null_state_resets :: proc(t: ^testing.T) {
    root := m118_dom(); defer dom.free_tree(root)
    // pushState(null) volta history.state a null (não deixa o objeto antigo).
    r := run_with_dom(`
        history.pushState({ x: 1 }, '', '/a');
        history.pushState(null, '', '/b');
        history.state === null
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "pushState(null) zera history.state")
}
