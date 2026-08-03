package js

import "core:strings"
import "core:testing"
import dom "../dom"

// M105 — DOMTokenList.replace(old,new) FALTAVA (canva e cia.: 1º erro era
// "document.documentElement.classList.replace is not a function"). Troca mantendo
// posição, devolve true/false, deduplica (é um set).

@(private = "file")
m105_dom :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    body := dom.make_node(.Element); body.tag = strings.clone("body"); body.attrs = make(map[string]string)
    dom.append_child(root, body)
    return root
}

@(test)
m105_replace_troca :: proc(t: ^testing.T) {
    root := m105_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var d = document.createElement('div');
        d.className = 'a light c';
        var ok = d.classList.replace('light','dark');
        ok + "|" + d.className
    `, root)
    s, _ := r.(string)
    testing.expectf(t, s == "true|a dark c", `replace mantém posição: got %q`, s)
}

@(test)
m105_replace_ausente_false :: proc(t: ^testing.T) {
    root := m105_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var d = document.createElement('div');
        d.className = 'a b';
        var ok = d.classList.replace('zzz','dark');
        ok + "|" + d.className
    `, root)
    s, _ := r.(string)
    testing.expectf(t, s == "false|a b", `token ausente: no-op + false: got %q`, s)
}

@(test)
m105_replace_dedup :: proc(t: ^testing.T) {
    root := m105_dom(); defer dom.free_tree(root)
    // se `new` já existe, o resultado não duplica
    r := run_with_dom(`
        var d = document.createElement('div');
        d.className = 'old new';
        d.classList.replace('old','new');
        d.className
    `, root)
    s, _ := r.(string)
    testing.expectf(t, s == "new", `dedup ao trocar p/ token existente: got %q`, s)
}

@(test)
m105_replace_e_funcao :: proc(t: ^testing.T) {
    root := m105_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var d = document.createElement('div');
        typeof d.classList.replace
    `, root)
    s, _ := r.(string)
    testing.expectf(t, s == "function", `classList.replace é função: got %q`, s)
}
