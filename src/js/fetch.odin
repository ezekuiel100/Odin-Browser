package js

// fetch() assíncrono. A nativa dispara uma THREAD que faz o net.fetch
// (bloqueante) e deposita o resultado no request; o vm_pump_fetches (chamado
// por vm_pump_timers, a cada frame, na thread dona do vm) consome e resolve a
// Promise. A thread NUNCA toca no vm — só no seu ^Fetch_Req.
//
// Posse do request (protocolo atômico em `flag`):
//   0 = em voo      — thread trabalhando; ninguém libera
//   1 = pronto      — thread terminou; o pump consome e libera
//   2 = abandonado  — vm morreu antes; a PRÓPRIA THREAD libera ao terminar
// As transições usam compare-exchange: exatamente um lado libera, sempre.

import "core:strings"
import "core:thread"
import "base:runtime"
import "base:intrinsics"
import net "../net"

Fetch_Req :: struct {
    url:     string,            // resolvida e clonada (posse do req)
    alloc:   runtime.Allocator, // alocador do vm — a thread o adota (evita bad-free no debug)
    promise: ^Object,           // só a thread dona do vm toca
    resp:    net.Response,
    ctype:   string,            // Content-Type CLONADO (a fatia da libcurl morre)
    flag:    i32,               // 0/1/2 (atômico), ver protocolo acima
}

install_fetch :: proc(vm: ^Interp) {
    vm.resp_text_fn = new_function(vm)
    vm.resp_text_fn.native = native_resp_text
    vm.resp_text_fn.name = "text"
    vm.resp_json_fn = new_function(vm)
    vm.resp_json_fn.native = native_resp_json
    vm.resp_json_fn.name = "json"

    f := new_function(vm)
    f.native = native_fetch
    f.name = "fetch"
    env_define(vm.global, "fetch", f)

    install_fetch_api(vm) // Request/Response/Headers/URLSearchParams/AbortController
    install_streams(vm)   // ReadableStream/WritableStream/TransformStream (streams.odin)
}

@(private = "file")
fetch_thread_proc :: proc(req: ^Fetch_Req) {
    context.allocator = req.alloc // aloca resp.body no alocador do vm
    req.resp = net.fetch(req.url)
    // content_type é uma fatia da libcurl, válida só até o handle ser reusado —
    // clonar AQUI, na thread, antes de a resposta esperar o pump (o valor chegava
    // como lixo/espaços do lado do JS).
    req.ctype = strings.clone(req.resp.content_type)
    if _, swapped := intrinsics.atomic_compare_exchange_strong(&req.flag, 0, 1); !swapped {
        free_req(req) // já abandonado (flag era 2): ninguém mais consome
    }
}

@(private = "file")
free_req :: proc(req: ^Fetch_Req) {
    delete(req.url)
    if req.ctype != "" do delete(req.ctype)
    if len(req.resp.body) > 0 do delete(req.resp.body)
    if req.resp.err != "" do delete(req.resp.err)
    free(req)
}

// Chamado por vm_destroy: marca os fetches em voo como abandonados (a thread
// libera ao terminar) e libera na hora os que já terminaram sem ser consumidos.
fetch_abandon_pending :: proc(vm: ^Interp) {
    for req in vm.pending_fetches {
        if _, swapped := intrinsics.atomic_compare_exchange_strong(&req.flag, 0, 2); !swapped {
            free_req(req) // flag era 1: pronto e não consumido — libera aqui
        }
    }
    delete(vm.pending_fetches)
}

// Consome os fetches prontos, resolvendo as Promises. Devolve true se algum
// resolveu (o hospedeiro re-estiliza, como nos timers).
vm_pump_fetches :: proc(vm: ^Interp) -> bool {
    fired := false
    for i := len(vm.pending_fetches) - 1; i >= 0; i -= 1 {
        req := vm.pending_fetches[i]
        if intrinsics.atomic_load(&req.flag) != 1 do continue
        ordered_remove(&vm.pending_fetches, i)

        if req.resp.ok {
            // Response COMPLETA (M137): antes era um objeto paralelo com só
            // {status, ok, text, json} — sem `headers` e sem `url`. `r.headers.get(
            // "content-type")` é o passo seguinte de praticamente todo cliente HTTP,
            // e dava "Cannot read properties of undefined (reading 'get')" (crates.io).
            // Ligando ao web_response_proto, clone/text/json vêm do protótipo.
            r := new_object(vm)
            r.proto = vm.web_response_proto
            r.props["status"] = f64(req.resp.status)
            r.props["ok"] = req.resp.status >= 200 && req.resp.status <= 299
            r.props["statusText"] = own_str(vm, req.resp.status == 200 ? "OK" : "")
            r.props["redirected"] = false
            r.props["type"] = own_str(vm, "basic")
            r.props["url"] = own_str(vm, req.url)
            r.props["headers"] = make_response_headers(vm, req.ctype)
            append(&vm.owned_strings, req.resp.body) // transfere a posse do corpo
            r.props["_body"] = req.resp.body
            r.props["text"] = vm.resp_text_fn
            r.props["json"] = vm.resp_json_fn
            req.resp.body = "" // não liberar no free_req: agora é do vm
            promise_resolve_with(vm, req.promise, r)
        } else {
            // falha de rede: rejeita com {name:"TypeError", message: err}
            e := new_object(vm)
            e.props["name"] = "TypeError"
            if req.resp.err != "" {
                append(&vm.owned_strings, req.resp.err) // posse -> vm
                e.props["message"] = req.resp.err
                req.resp.err = ""
            } else {
                e.props["message"] = "fetch falhou"
            }
            promise_settle(vm, req.promise, PROMISE_REJECTED, e)
        }
        free_req(req)
        vm_clear_uncaught(vm) // callbacks do then podem lançar
        fired = true
    }
    return fired
}

// fetch(url) -> Promise<Response>. URL relativa é resolvida contra vm.base_url.
@(private = "file")
native_fetch :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    p := promise_new(vm)
    url: string
    ok: bool
    // 1º arg: string (url) OU um Request (lê a prop .url). net.fetch é GET-only,
    // então method/headers/body do Request são ignorados no envio (basta a URL
    // p/ a 1ª renderização — libs de auth só precisam que a Promise resolva).
    if len(args) >= 1 {
        #partial switch a in args[0] {
        case string:
            url, ok = a, true
        case ^Object:
            if u, uok := get_member(vm, a, "url").(string); uok { url, ok = u, true }
        }
    }
    if !ok {
        e := new_object(vm)
        e.props["name"] = "TypeError"
        e.props["message"] = "fetch: url deve ser string ou Request"
        promise_settle(vm, p, PROMISE_REJECTED, e)
        return p
    }

    req := new(Fetch_Req)
    if vm.base_url != "" {
        req.url = strings.clone(net.resolve_url(vm.base_url, url, context.temp_allocator))
    } else {
        req.url = strings.clone(url)
    }
    req.alloc = context.allocator
    req.promise = p
    append(&vm.pending_fetches, req)
    thread.create_and_start_with_poly_data(req, fetch_thread_proc, self_cleanup = true)
    return p
}

// ── métodos da Response ─────────────────────────────────────────────────────

@(private = "file")
native_resp_text :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    p := promise_new(vm)
    if r, ok := this.(^Object); ok {
        promise_resolve_with(vm, p, r.props["_body"])
    }
    return p
}

@(private = "file")
native_resp_json :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    p := promise_new(vm)
    r, ok := this.(^Object)
    if !ok do return p
    parsed := json_parse_native(vm, nil, []Value{r.props["_body"]})
    if vm.throwing { // JSON inválido: rejeita em vez de propagar o throw
        vm.throwing = false
        thrown := vm.thrown
        vm.thrown = nil
        promise_settle(vm, p, PROMISE_REJECTED, thrown)
    } else {
        promise_resolve_with(vm, p, parsed)
    }
    return p
}
