package js

import "core:strings"
import "core:testing"
import dom "../dom"

// M102 — <script> injetado dinamicamente (createElement('script')+appendChild) EXECUTA.
// É o mecanismo de carregamento de chunk do webpack/Next (`__webpack_require__.l`:
// cria script, seta .src/.onload, faz head.appendChild). Sem isto, módulos de chunks
// assíncronos nunca se registravam e `modules[id].call(...)` estourava com "reading
// 'call' of undefined" — gap #1 do gap-miner (codepen/soundcloud/figma/slack/aliexpress/uol).
// Os testes usam a via INLINE (textContent), que executa sem rede (a via `src` usa
// net.fetch bloqueante, validada via --diagnose nos sites reais).

@(private = "file")
m102_dom :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    head := dom.make_node(.Element); head.tag = strings.clone("head"); head.attrs = make(map[string]string)
    body := dom.make_node(.Element); body.tag = strings.clone("body"); body.attrs = make(map[string]string)
    dom.append_child(root, head); dom.append_child(root, body)
    return root
}

@(test)
m102_inline_injected_script_executes :: proc(t: ^testing.T) {
    root := m102_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        window.__ran = false;
        var s = document.createElement('script');
        s.textContent = 'window.__ran = true;';
        document.head.appendChild(s);
        window.__ran
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "script inline injetado via appendChild deve executar")
}

// Define um global que o código seguinte consome (padrão de registro de módulo).
@(test)
m102_injected_script_defines_global :: proc(t: ^testing.T) {
    root := m102_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var s = document.createElement('script');
        s.textContent = 'window.__mod = { val: 42 };';
        document.body.appendChild(s);
        window.__mod.val
    `, root)
    testing.expectf(t, as_number(r) == 42, "script injetado registra global: got %v", r)
}

// onload dispara APÓS a execução (webpack resolve a Promise do chunk aí).
@(test)
m102_injected_script_fires_onload :: proc(t: ^testing.T) {
    root := m102_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var order = [];
        var s = document.createElement('script');
        s.textContent = 'order.push("exec");';
        s.onload = function(){ order.push("load"); };
        document.head.appendChild(s);
        order.join(',')
    `, root)
    s, _ := r.(string)
    testing.expectf(t, s == "exec,load", "onload dispara após exec: got %v", s)
}

// addEventListener('load') também dispara (webpack usa ambos conforme a versão).
@(test)
m102_injected_script_load_listener :: proc(t: ^testing.T) {
    root := m102_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var fired = false;
        var s = document.createElement('script');
        s.textContent = '1;';
        s.addEventListener('load', function(){ fired = true; });
        document.head.appendChild(s);
        fired
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "listener 'load' de script injetado deve disparar")
}

// Executa UMA vez só: re-anexar o mesmo script não re-executa (marca __executed).
@(test)
m102_injected_script_runs_once :: proc(t: ^testing.T) {
    root := m102_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        window.__n = 0;
        var s = document.createElement('script');
        s.textContent = 'window.__n++;';
        document.head.appendChild(s);
        document.body.appendChild(s); // re-anexa: NÃO deve re-executar
        window.__n
    `, root)
    testing.expectf(t, as_number(r) == 1, "script injetado executa 1x só: got %v", r)
}

// <script> vindo de innerHTML NÃO executa (só appendChild/insertBefore/append) —
// mantém o comportamento seguro pré-existente.
@(test)
m102_innerhtml_script_does_not_execute :: proc(t: ^testing.T) {
    root := m102_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        window.__inner = false;
        document.body.innerHTML = '<script>window.__inner = true;<\/script>';
        window.__inner
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, !ok, "script de innerHTML NÃO deve executar")
}

// insertBefore também executa (webpack às vezes usa insertBefore).
@(test)
m102_insertbefore_executes_script :: proc(t: ^testing.T) {
    root := m102_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        window.__ib = false;
        var ref = document.createElement('div');
        document.head.appendChild(ref);
        var s = document.createElement('script');
        s.textContent = 'window.__ib = true;';
        document.head.insertBefore(s, ref);
        window.__ib
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "script injetado via insertBefore deve executar")
}
