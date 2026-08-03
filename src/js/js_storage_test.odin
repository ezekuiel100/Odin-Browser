package js

// Web Storage API (localStorage / sessionStorage) — storage.odin.
// Precisa do window instalado (install_window só roda com DOM), então os testes
// usam run_with_dom sobre um DOM mínimo.

import "core:strings"
import "core:testing"
import dom "../dom"

@(private = "file")
mk_page :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    e :: proc(tag: string) -> ^dom.Node {
        n := dom.make_node(.Element)
        n.tag = strings.clone(tag)
        n.attrs = make(map[string]string)
        return n
    }
    html := e("html"); head := e("head"); body := e("body")
    dom.append_child(html, head)
    dom.append_child(html, body)
    dom.append_child(root, html)
    return root
}

@(private = "file")
run_ls :: proc(src: string) -> Value {
    root := mk_page()
    defer dom.free_tree(root)
    return run_with_dom(src, root)
}

// ── getItem / setItem ────────────────────────────────────────────────────────

@(test)
test_storage_set_get :: proc(t: ^testing.T) {
    testing.expect_value(t, run_ls(`
        localStorage.setItem("token", "abc123");
        localStorage.getItem("token")
    `).(string), "abc123")
}

@(test)
test_storage_get_missing_is_null :: proc(t: ^testing.T) {
    testing.expect_value(t, run_ls(`localStorage.getItem("nope") === null`).(bool), true)
}

@(test)
test_storage_overwrite :: proc(t: ^testing.T) {
    testing.expect_value(t, run_ls(`
        localStorage.setItem("k", "1");
        localStorage.setItem("k", "2");
        localStorage.getItem("k")
    `).(string), "2")
}

// ── acesso por propriedade (named access) ────────────────────────────────────

@(test)
test_storage_named_access :: proc(t: ^testing.T) {
    testing.expect_value(t, run_ls(`
        localStorage.foo = "bar";
        localStorage.foo
    `).(string), "bar")
}

@(test)
test_storage_named_and_methods_agree :: proc(t: ^testing.T) {
    // named set visível via getItem, e vice-versa
    testing.expect_value(t, run_ls(`
        localStorage.a = "x";
        localStorage.setItem("b", "y");
        localStorage.getItem("a") + localStorage.b
    `).(string), "xy")
}

@(test)
test_storage_named_missing_is_undefined :: proc(t: ^testing.T) {
    // named access de chave ausente é undefined (getItem é que devolve null)
    testing.expect_value(t, run_ls(`typeof localStorage.missing === "undefined"`).(bool), true)
}

// ── length / key / removeItem / clear ────────────────────────────────────────

@(test)
test_storage_length :: proc(t: ^testing.T) {
    testing.expect_value(t, run_ls(`
        localStorage.setItem("a", "1");
        localStorage.setItem("b", "2");
        localStorage.length
    `).(f64), 2)
}

@(test)
test_storage_key_by_index :: proc(t: ^testing.T) {
    testing.expect_value(t, run_ls(`
        localStorage.setItem("first", "1");
        localStorage.setItem("second", "2");
        localStorage.key(0) + "," + localStorage.key(1) + "," + (localStorage.key(9) === null)
    `).(string), "first,second,true")
}

@(test)
test_storage_remove_item :: proc(t: ^testing.T) {
    testing.expect_value(t, run_ls(`
        localStorage.setItem("a", "1");
        localStorage.setItem("b", "2");
        localStorage.removeItem("a");
        (localStorage.getItem("a") === null) + "," + localStorage.length
    `).(string), "true,1")
}

@(test)
test_storage_clear :: proc(t: ^testing.T) {
    testing.expect_value(t, run_ls(`
        localStorage.setItem("a", "1");
        localStorage.setItem("b", "2");
        localStorage.clear();
        localStorage.length
    `).(f64), 0)
}

// ── coerção a string ─────────────────────────────────────────────────────────

@(test)
test_storage_coerces_to_string :: proc(t: ^testing.T) {
    // chave e valor viram string (ToString): setItem(1, 2) → getItem("1") === "2"
    testing.expect_value(t, run_ls(`
        localStorage.setItem(1, 2);
        localStorage.setItem("obj", {a:1});
        (localStorage.getItem("1") === "2") + "," + (typeof localStorage.getItem("1"))
    `).(string), "true,string")
}

// ── delete localStorage.x ────────────────────────────────────────────────────

@(test)
test_storage_delete_operator :: proc(t: ^testing.T) {
    testing.expect_value(t, run_ls(`
        localStorage.setItem("x", "1");
        delete localStorage.x;
        localStorage.getItem("x") === null
    `).(bool), true)
}

// ── enumeração: Object.keys / for-in devolvem as chaves armazenadas ──────────

@(test)
test_storage_object_keys :: proc(t: ^testing.T) {
    testing.expect_value(t, run_ls(`
        localStorage.setItem("a", "1");
        localStorage.setItem("b", "2");
        Object.keys(localStorage).join(",")
    `).(string), "a,b")
}

@(test)
test_storage_for_in :: proc(t: ^testing.T) {
    testing.expect_value(t, run_ls(`
        localStorage.setItem("a", "1");
        localStorage.setItem("b", "2");
        var out = "";
        for (var k in localStorage) out += k + "=" + localStorage[k] + ";";
        out
    `).(string), "a=1;b=2;")
}

// ── sessionStorage é independente do localStorage ────────────────────────────

@(test)
test_session_storage_independent :: proc(t: ^testing.T) {
    testing.expect_value(t, run_ls(`
        localStorage.setItem("k", "L");
        sessionStorage.setItem("k", "S");
        localStorage.getItem("k") + sessionStorage.getItem("k") + "," + sessionStorage.length + "," + localStorage.length
    `).(string), "LS,1,1")
}
