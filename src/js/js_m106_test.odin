package js

import "core:strings"
import "core:testing"
import dom "../dom"

// M106 — document.currentScript FALTAVA (era undefined). O runtime do Turbopack
// (nextjs.org e cia.) lê `document.currentScript` + `.getAttribute('src')` p/ derivar
// o caminho-base dos chunks; sem ele, `!chunk` era true → "chunk path empty but not in
// a worker" em CADA chunk. Get-hook dinâmico no document; setado por script (load_page_
// scripts) e por chunk injetado (maybe_run_injected_script), null fora de execução.

@(private = "file")
m106_dom :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    head := dom.make_node(.Element); head.tag = strings.clone("head"); head.attrs = make(map[string]string)
    body := dom.make_node(.Element); body.tag = strings.clone("body"); body.attrs = make(map[string]string)
    dom.append_child(root, head); dom.append_child(root, body)
    return root
}

@(test)
m106_null_no_topo :: proc(t: ^testing.T) {
    root := m106_dom(); defer dom.free_tree(root)
    // fora de um <script> em execução: currentScript === null (spec)
    r := run_with_dom(`document.currentScript === null`, root)
    b, _ := r.(bool)
    testing.expect(t, b, "currentScript === null fora de <script>")
}

@(test)
m106_durante_script_injetado :: proc(t: ^testing.T) {
    root := m106_dom(); defer dom.free_tree(root)
    // durante a execução do <script> injetado, currentScript === esse próprio script
    r := run_with_dom(`
        var s = document.createElement('script');
        s.textContent = 'window.__cs = document.currentScript;';
        document.head.appendChild(s);
        window.__cs === s
    `, root)
    b, _ := r.(bool)
    testing.expect(t, b, "currentScript === o <script> injetado em execução")
}

@(test)
m106_restaura_null_apos :: proc(t: ^testing.T) {
    root := m106_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var s = document.createElement('script');
        s.textContent = '1;';
        document.head.appendChild(s);
        document.currentScript === null
    `, root)
    b, _ := r.(bool)
    testing.expect(t, b, "currentScript volta a null após o script injetado")
}

@(test)
m106_getAttribute_src :: proc(t: ^testing.T) {
    root := m106_dom(); defer dom.free_tree(root)
    // o padrão do Turbopack: currentScript.getAttribute(...) durante a execução
    r := run_with_dom(`
        var s = document.createElement('script');
        s.setAttribute('data-chunk','abc');
        s.textContent = 'window.__da = document.currentScript.getAttribute("data-chunk");';
        document.head.appendChild(s);
        window.__da
    `, root)
    s, _ := r.(string)
    testing.expectf(t, s == "abc", "currentScript.getAttribute durante execução: got %q", s)
}
