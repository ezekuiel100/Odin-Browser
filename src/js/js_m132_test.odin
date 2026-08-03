package js

// M132 — lote guiado pela mineração de 2026-07-21 (com rejeições no ranking):
//   1. legibilidade da mensagem de erro (13 sites reportavam "[object Object]"/"undefined")
//   2. MessageChannel (4 sites; é o canal do scheduler do React)
//   3. as lacunas de 1 linha da sonda de capacidade (87 → 96 de 105)
//
// Achado do lote: `URL` estava DUPLICADO — o de dom_bindings, instalado depois,
// sombreava o completo do fetch_api, e em toda PÁGINA `new URL(x).searchParams` era
// undefined (em JS puro funcionava). A sonda apontava isso e eu havia lido como
// "feature ausente" em vez de "sombreada por uma implementação pior".

import "core:testing"
import dom "../dom"
import "core:strings"

@(private = "file")
run_dom :: proc(src: string) -> Value {
    root := dom.make_node(.Document)
    defer dom.free_tree(root)
    html := dom.make_node(.Element); html.tag = strings.clone("html")
    body := dom.make_node(.Element); body.tag = strings.clone("body")
    dom.append_child(html, body)
    dom.append_child(root, html)
    return run_with_dom(src, root)
}

// ── 1) mensagem de erro legível ──────────────────────────────────────────────

@(test)
m132_objeto_lancado_descreve_as_chaves :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_exec(vm, `throw {code: 404, msg: "nao achou"}`)
    vm_clear_uncaught(vm)
    testing.expect(t, len(vm.uncaught_log) > 0, "registrou a exceção")
    if len(vm.uncaught_log) == 0 do return
    m := vm.uncaught_log[0]
    testing.expectf(t, strings.contains(m, "code"), "cita a chave code (msg=%s)", m)
    testing.expectf(t, strings.contains(m, "404"), "cita o valor 404 (msg=%s)", m)
    testing.expectf(t, !strings.contains(m, "[object Object]"), "NÃO é [object Object] (msg=%s)", m)
}

@(test)
m132_undefined_lancado_e_identificavel :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_exec(vm, `throw undefined`)
    vm_clear_uncaught(vm)
    if len(vm.uncaught_log) == 0 { testing.fail(t); return }
    testing.expectf(t, strings.contains(vm.uncaught_log[0], "undefined"),
        "diz que lançou undefined (msg=%s)", vm.uncaught_log[0])
}

@(test)
m132_error_de_verdade_mantem_o_formato :: proc(t: ^testing.T) {
    // Não-regressão: Error continua "Name: message", que é o que já era útil.
    vm := vm_create()
    defer vm_free(vm)
    vm_exec(vm, `throw new TypeError("xyz")`)
    vm_clear_uncaught(vm)
    if len(vm.uncaught_log) == 0 { testing.fail(t); return }
    testing.expect_value(t, vm.uncaught_log[0], "TypeError: xyz")
}

// ── 2) MessageChannel ────────────────────────────────────────────────────────

@(test)
m132_message_channel_existe_com_duas_portas :: proc(t: ^testing.T) {
    src := `
        var ch = new MessageChannel();
        (typeof ch.port1 === "object" && typeof ch.port2 === "object"
         && typeof ch.port1.postMessage === "function") ? "ok" : "falhou"
    `
    testing.expect_value(t, run(src).(string), "ok")
}

@(test)
m132_post_message_entrega_na_porta_irma :: proc(t: ^testing.T) {
    // O padrão EXATO do scheduler do React.
    vm := vm_create()
    defer vm_free(vm)
    vm_exec(vm, `
        var recebido = "nada";
        var ch = new MessageChannel();
        ch.port1.onmessage = function(e){ recebido = "veio:" + String(e.data) };
        ch.port2.postMessage("carga");
    `)
    // entrega é ASSÍNCRONA: antes de bombear, nada chegou
    testing.expect_value(t, vm_run(vm, "recebido").(string), "nada")
    vm_pump_timers(vm, 1)
    testing.expect_value(t, vm_run(vm, "recebido").(string), "veio:carga")
}

@(test)
m132_port_add_event_listener :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_exec(vm, `
        var n = 0;
        var ch = new MessageChannel();
        ch.port1.addEventListener("message", function(){ n++ });
        ch.port2.postMessage(null);
    `)
    vm_pump_timers(vm, 1)
    testing.expect_value(t, as_number(vm_run(vm, "n")), 1)
}

@(test)
m132_window_post_message :: proc(t: ^testing.T) {
    // Vizinho do MessageChannel: no medium.com o erro seguinte era exatamente
    // "postMessage is not a function".
    src := `
        var got = "nada";
        window.addEventListener("message", function(e){ got = "veio:" + String(e.data) });
        window.postMessage("carga", "*");
        got
    `
    // assíncrono: ainda não chegou no mesmo turno
    testing.expect_value(t, run_dom(src).(string), "nada")
}

// ── 3) lacunas de uma linha ──────────────────────────────────────────────────

@(test)
m132_object_has_own :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`Object.hasOwn({a:1}, "a")`).(bool), true)
    testing.expect_value(t, run(`Object.hasOwn({a:1}, "b")`).(bool), false)
    testing.expect_value(t, run(`Object.hasOwn([1,2], 0)`).(bool), true)
}

@(test)
m132_object_group_by :: proc(t: ^testing.T) {
    src := `
        var g = Object.groupBy([1,2,3,4], function(n){ return n % 2 ? "impar" : "par" });
        g.impar.join(",") + "|" + g.par.join(",")
    `
    testing.expect_value(t, run(src).(string), "1,3|2,4")
}

@(test)
m132_error_cause :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`new Error("x", {cause: 42}).cause`).(f64), 42)
    testing.expect_value(t, run(`new Error("x").cause === undefined`).(bool), true)
}

@(test)
m132_escape_unescape :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`escape("a b")`).(string), "a%20b")
    testing.expect_value(t, run(`unescape("a%20b")`).(string), "a b")
    // preserva @*_+-./ (Annex B) e usa %uXXXX acima de 0xFF
    testing.expect_value(t, run(`escape("a@b*c_d+e-f.g/h")`).(string), "a@b*c_d+e-f.g/h")
    testing.expect_value(t, run(`escape("é")`).(string), "%E9")
    testing.expect_value(t, run(`unescape("%u00e9")`).(string), "é")
    testing.expect_value(t, run(`unescape(escape("olá mundo"))`).(string), "olá mundo")
}

@(test)
m132_regexp_unicode_e_has_indices :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`/a/u.unicode`).(bool), true)
    testing.expect_value(t, run(`/a/.unicode`).(bool), false)
    testing.expect_value(t, run(`/a/d.hasIndices`).(bool), true)
}

@(test)
m132_node_is_connected :: proc(t: ^testing.T) {
    src := `
        var solto = document.createElement("div");
        var preso = document.createElement("div");
        document.body.appendChild(preso);
        (solto.isConnected === false && preso.isConnected === true) ? "ok"
            : ("solto=" + solto.isConnected + " preso=" + preso.isConnected)
    `
    testing.expect_value(t, run_dom(src).(string), "ok")
}

@(test)
m132_url_search_params_na_pagina :: proc(t: ^testing.T) {
    // O `URL` de dom_bindings sombreava o completo do fetch_api: em PÁGINA (com DOM
    // instalado) o searchParams sumia. run_dom instala o DOM, então cobre a regressão.
    src := `
        var u = new URL("https://a.b/c?x=1&y=2");
        (u.searchParams.get("x") === "1" && u.searchParams.get("y") === "2"
         && u.protocol === "https:" && u.pathname === "/c") ? "ok" : "falhou"
    `
    testing.expect_value(t, run_dom(src).(string), "ok")
}

@(test)
m132_url_search_params_continua_vivo :: proc(t: ^testing.T) {
    // Não-regressão do design existente: mutar searchParams reflete em .search.
    src := `
        var u = new URL("https://a.b/c?x=1");
        u.searchParams.append("z", "9");
        u.search
    `
    testing.expect_value(t, run_dom(src).(string), "?x=1&z=9")
}
