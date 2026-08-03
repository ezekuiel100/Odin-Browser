package js

// Fetch API: Headers, Request, Response, URLSearchParams, AbortController/Signal
// (M68). O `fetch()` assíncrono já existe (fetch.odin); aqui vêm as CLASSES que
// bibliotecas de rede (better-auth, axios-fetch, etc.) constroem antes de chamar
// fetch. O bloqueador do ultra-photo era `Request` undefined (better-auth faz
// ``\`credentials\` in Request.prototype``).
//
// Cada classe compartilha um prototype guardado no vm (web_*_proto); as instâncias
// têm .proto = esse prototype, então get_member resolve os métodos pela cadeia.
// APROXIMAÇÕES: net.fetch é GET-only, então method/body de um Request são
// GUARDADOS mas não enviados (a URL é o que importa p/ a 1ª renderização); sem
// streams; AbortSignal é um stub que nunca dispara sozinho.

import "core:strings"
import "core:fmt"

install_fetch_api :: proc(vm: ^Interp) {
    // ── Headers ──
    hp := new_object(vm)
    hp.props["get"]     = mk_native(vm, headers_get)
    hp.props["set"]     = mk_native(vm, headers_set)
    hp.props["has"]     = mk_native(vm, headers_has)
    hp.props["append"]  = mk_native(vm, headers_append)
    hp.props["delete"]  = mk_native(vm, headers_delete)
    hp.props["forEach"] = mk_native(vm, headers_for_each)
    hp.props["entries"] = mk_native(vm, headers_entries)
    hp.props["keys"]    = mk_native(vm, headers_keys)
    hp.props["values"]  = mk_native(vm, headers_values)
    vm.web_headers_proto = hp
    hctor := mk_native(vm, headers_ctor)
    hctor.props = make(map[string]Value)
    hctor.props["prototype"] = hp // core-js lê Headers.prototype.append/… (uncurryThis)
    env_define(vm.global, "Headers", hctor)

    // ── Request ── (prototype com `credentials` p/ o `in` do better-auth)
    rp := new_object(vm)
    rp.props["credentials"] = own_str(vm, "same-origin")
    rp.props["method"]      = own_str(vm, "GET")
    rp.props["clone"]       = mk_native(vm, request_clone)
    vm.web_request_proto = rp
    rctor := mk_native(vm, request_ctor)
    rctor.props = make(map[string]Value)
    rctor.props["prototype"] = rp
    env_define(vm.global, "Request", rctor)

    // ── Response ──
    sp := new_object(vm)
    sp.props["text"]  = vm.resp_text_fn // reusa os métodos do fetch (leem props["_body"])
    sp.props["json"]  = vm.resp_json_fn
    sp.props["clone"] = mk_native(vm, response_clone)
    vm.web_response_proto = sp
    rsctor := mk_native(vm, response_ctor)
    rsctor.props = make(map[string]Value)
    rsctor.props["prototype"] = sp
    rsctor.props["json"] = mk_native(vm, response_static_json) // Response.json(data)
    env_define(vm.global, "Response", rsctor)

    // ── URLSearchParams ──
    up := new_object(vm)
    up.props["get"]      = mk_native(vm, usp_get)
    up.props["getAll"]   = mk_native(vm, usp_get_all)
    up.props["set"]      = mk_native(vm, usp_set)
    up.props["append"]   = mk_native(vm, usp_append)
    up.props["has"]      = mk_native(vm, usp_has)
    up.props["delete"]   = mk_native(vm, usp_delete)
    up.props["forEach"]  = mk_native(vm, usp_for_each)
    up.props["toString"] = mk_native(vm, usp_to_string)
    up.props["entries"]  = mk_native(vm, usp_entries)
    up.props["keys"]     = mk_native(vm, usp_keys)
    up.props["values"]   = mk_native(vm, usp_values)
    vm.web_usp_proto = up
    // O core-js (presente em quase todo bundle) FAZ WRAPPING de URLSearchParams:
    // `jv=URLSearchParams, kv=jv.prototype, Iv=b(kv.append), ...`. Sem `.prototype`
    // no construtor, `kv` ficava undefined e `kv.append` lançava
    // "reading 'append' of undefined", ABORTANDO o chunk de polyfills inteiro
    // (14 sites no gap-report: react.dev/next/node/stripe/figma/notion/…).
    uctor := mk_native(vm, usp_ctor)
    uctor.props = make(map[string]Value)
    uctor.props["prototype"] = up
    env_define(vm.global, "URLSearchParams", uctor)

    // ── AbortController / AbortSignal ──
    sig := new_object(vm)
    sig.props["addEventListener"]    = mk_native(vm, dom_noop_true)
    sig.props["removeEventListener"] = mk_native(vm, dom_noop_true)
    sig.props["throwIfAborted"]      = mk_native(vm, dom_noop_true)
    vm.web_signal_proto = sig
    env_define(vm.global, "AbortController", mk_native(vm, abort_controller_ctor))

    // ── FormData ── (mesma API chave-valor de URLSearchParams; libs de rede a
    // constroem p/ multipart/form uploads. Reusa os métodos usp_* — valores não-Blob
    // são coeridos a string, exatamente como manda a spec de FormData.)
    fdp := new_object(vm)
    fdp.props["append"]  = mk_native(vm, usp_append) // 3º arg (filename) é ignorado
    fdp.props["set"]     = mk_native(vm, usp_set)
    fdp.props["get"]     = mk_native(vm, usp_get)
    fdp.props["getAll"]  = mk_native(vm, usp_get_all)
    fdp.props["has"]     = mk_native(vm, usp_has)
    fdp.props["delete"]  = mk_native(vm, usp_delete)
    fdp.props["forEach"] = mk_native(vm, usp_for_each)
    fdp.props["entries"] = mk_native(vm, usp_entries)
    fdp.props["keys"]    = mk_native(vm, usp_keys)
    fdp.props["values"]  = mk_native(vm, usp_values)
    if vm.sym_iterator_key != "" do fdp.props[vm.sym_iterator_key] = mk_native(vm, usp_entries)
    vm.web_formdata_proto = fdp
    fdctor := mk_native(vm, formdata_ctor)
    fdctor.props = make(map[string]Value)
    fdctor.props["prototype"] = fdp
    env_define(vm.global, "FormData", fdctor)

    // ── URL ── (API universal; `new URL(x).searchParams/pathname/origin/…`)
    urlp := new_object(vm)
    urlp.props["toString"] = mk_native(vm, url_to_string)
    urlp.props["toJSON"]   = mk_native(vm, url_to_string)
    vm.web_url_proto = urlp
    urlctor := mk_native(vm, url_ctor)
    urlctor.props = make(map[string]Value)
    urlctor.props["prototype"]       = urlp
    urlctor.props["canParse"]        = mk_native(vm, url_can_parse)
    urlctor.props["createObjectURL"] = mk_native(vm, url_create_object_url)
    urlctor.props["revokeObjectURL"] = mk_native(vm, dom_noop_true)
    env_define(vm.global, "URL", urlctor)
}

// converte um Value p/ string (ToString aproximado, via to_text), owned pelo vm.
@(private = "file")
// ToString das APIs web. Passa pelo ToPrimitive (M137): a IDL declara esses
// argumentos como USVString, então um objeto vira sua `toString()`. Sem isto,
// `new URL(x, outraURL)`, `new URL(location)` e `fetch(new URL(...))` — todos
// idiomáticos — recebiam "[object Object]" e davam "Invalid URL".
web_str :: proc(vm: ^Interp, v: Value) -> string {
    pv := to_primitive(vm, v, false, "string")
    if vm.throwing do return strings.clone("")
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    to_text(&sb, pv)
    return strings.clone(strings.to_string(sb))
}

@(private = "file")
dom_noop_true :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return true }

// wrappers de percent-encode reusando as nativas globais (limpam URIError p/ não
// propagar em query malformada — devolvem o texto cru nesse caso).
@(private = "file")
web_encode :: proc(vm: ^Interp, s: string) -> string {
    r := global_encode_uri_component(vm, nil, []Value{s})
    if out, ok := r.(string); ok do return out
    return s
}

@(private = "file")
web_decode :: proc(vm: ^Interp, s: string) -> string {
    r := global_decode_uri_component(vm, nil, []Value{s})
    if vm.throwing { vm.throwing = false; vm.thrown = nil; return s } // % malformado
    if out, ok := r.(string); ok do return out
    return s
}

// ── Headers ──────────────────────────────────────────────────────────────────
// Armazém: this.props["_h"] = ^Object com chaves em minúsculas (HTTP é
// case-insensitive) → valor string. A ordem de inserção (korder) dá a ordem de
// iteração.

@(private = "file")
headers_store :: proc(vm: ^Interp, this: Value) -> ^Object {
    o, ok := this.(^Object)
    if !ok do return new_object(vm)
    if h, hok := o.props["_h"].(^Object); hok do return h
    h := new_object(vm)
    o.props["_h"] = h
    return h
}

// aceita init: Headers, objeto {k:v}, ou array de [k,v]
@(private = "file")
headers_fill :: proc(vm: ^Interp, h: ^Object, init: Value) {
    #partial switch src in init {
    case ^Object:
        if inner, ok := src.props["_h"].(^Object); ok { // outro Headers
            keys: [dynamic]string; defer delete(keys)
            own_enum_keys(inner, &keys)
            for k in keys do oput(h, k, get_member(vm, inner, k))
            return
        }
        keys: [dynamic]string; defer delete(keys)
        own_enum_keys(src, &keys)
        for k in keys do oput(h, strings.to_lower(k, context.temp_allocator), web_str(vm, get_member(vm, src, k)))
    case ^Array:
        for it in src.items {
            if pair, ok := it.(^Array); ok && len(pair.items) >= 2 {
                oput(h, web_str(vm, pair.items[0]), web_str(vm, pair.items[1]))
            }
        }
    }
}

@(private = "file")
headers_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o := new_object(vm)
    o.proto = vm.web_headers_proto
    h := new_object(vm)
    o.props["_h"] = h
    if len(args) >= 1 do headers_fill(vm, h, args[0])
    return o
}

@(private = "file")
lc :: proc(vm: ^Interp, v: Value) -> string {
    return strings.to_lower(web_str(vm, v), context.temp_allocator)
}

@(private = "file")
headers_get :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    h := headers_store(vm, this)
    if v, ok := h.props[lc(vm, arg(args, 0))]; ok do return v
    return JS_Null{}
}

@(private = "file")
headers_set :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    oput(headers_store(vm, this), lc(vm, arg(args, 0)), web_str(vm, arg(args, 1)))
    return nil
}

@(private = "file")
headers_append :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    h := headers_store(vm, this)
    key := lc(vm, arg(args, 0))
    val := web_str(vm, arg(args, 1))
    if old, ok := h.props[key].(string); ok {
        oput(h, key, own_str(vm, strings.concatenate({old, ", ", val}, context.temp_allocator)))
    } else {
        oput(h, key, val)
    }
    return nil
}

@(private = "file")
headers_has :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    _, ok := headers_store(vm, this).props[lc(vm, arg(args, 0))]
    return ok
}

@(private = "file")
headers_delete :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    oremove(headers_store(vm, this), lc(vm, arg(args, 0)))
    return nil
}

@(private = "file")
headers_for_each :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    cb, ok := arg(args, 0).(^Function); if !ok do return nil
    h := headers_store(vm, this)
    keys: [dynamic]string; defer delete(keys)
    own_enum_keys(h, &keys)
    for k in keys {
        call_function(vm, cb, nil, []Value{h.props[k], own_str(vm, k), this}) // cb(value, name, headers)
        if vm.throwing do break
    }
    return nil
}

// entries/keys/values → iteradores (make_array_iterator sobre arrays montados)
@(private = "file")
headers_entries :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    h := headers_store(vm, this)
    keys: [dynamic]string; defer delete(keys)
    own_enum_keys(h, &keys)
    out := new_array(vm)
    for k in keys {
        pair := new_array(vm)
        append(&pair.items, own_str(vm, k), h.props[k])
        append(&out.items, pair)
    }
    return make_array_iterator(vm, out)
}

@(private = "file")
headers_keys :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    h := headers_store(vm, this)
    keys: [dynamic]string; defer delete(keys)
    own_enum_keys(h, &keys)
    out := new_array(vm)
    for k in keys do append(&out.items, own_str(vm, k))
    return make_array_iterator(vm, out)
}

@(private = "file")
headers_values :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    h := headers_store(vm, this)
    keys: [dynamic]string; defer delete(keys)
    own_enum_keys(h, &keys)
    out := new_array(vm)
    for k in keys do append(&out.items, h.props[k])
    return make_array_iterator(vm, out)
}

// ── Request ──────────────────────────────────────────────────────────────────

@(private = "file")
request_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o := new_object(vm)
    o.proto = vm.web_request_proto
    // input: string (url) OU outro Request (copia url/method)
    method: Value = own_str(vm, "GET")
    #partial switch input in arg(args, 0) {
    case string:
        o.props["url"] = own_str(vm, input)
    case ^Object:
        if u, ok := input.props["url"]; ok do o.props["url"] = u
        if m, ok := input.props["method"]; ok do method = m
    }
    // init: { method, headers, body, credentials, signal, ... }
    if init, ok := arg(args, 1).(^Object); ok {
        if m := get_member(vm, init, "method"); m != nil do method = own_str(vm, strings.to_upper(web_str(vm, m), context.temp_allocator))
        if b := get_member(vm, init, "body");   b != nil do o.props["body"] = b
        if c := get_member(vm, init, "credentials"); c != nil do o.props["credentials"] = c
        if s := get_member(vm, init, "signal");  s != nil do o.props["signal"] = s
        hv := get_member(vm, init, "headers")
        if hv != nil do o.props["headers"] = to_headers(vm, hv)
    }
    o.props["method"] = method
    if _, ok := o.props["headers"]; !ok do o.props["headers"] = to_headers(vm, nil)
    if _, ok := o.props["url"]; !ok do o.props["url"] = own_str(vm, "")
    return o
}

// Headers de uma resposta de rede. Só temos o Content-Type cru da libcurl (o resto
// dos cabeçalhos não é preservado), mas é justamente o que o código lê: o roteamento
// entre `.json()` e `.text()` se decide por ele.
make_response_headers :: proc(vm: ^Interp, content_type: string) -> Value {
    o := new_object(vm)
    if content_type != "" do o.props["content-type"] = own_str(vm, content_type)
    return to_headers(vm, o)
}

// coage um valor a um Headers (se já é Headers, devolve; senão constrói)
@(private = "file")
to_headers :: proc(vm: ^Interp, v: Value) -> Value {
    if o, ok := v.(^Object); ok && o.proto == vm.web_headers_proto do return o
    return headers_ctor(vm, nil, []Value{v})
}

@(private = "file")
request_clone :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := this.(^Object); if !ok do return nil
    c := new_object(vm)
    c.proto = vm.web_request_proto
    for k, v in o.props do c.props[k] = v
    return c
}

// ── Response ─────────────────────────────────────────────────────────────────

@(private = "file")
response_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o := new_object(vm)
    o.proto = vm.web_response_proto
    body := arg(args, 0)
    if body == nil {
        o.props["_body"] = own_str(vm, "")
    } else if s, ok := body.(string); ok {
        o.props["_body"] = own_str(vm, s)
    } else {
        o.props["_body"] = web_str(vm, body)
    }
    status := f64(200)
    if init, ok := arg(args, 1).(^Object); ok {
        if s := get_member(vm, init, "status"); s != nil do status = as_number(s)
        if st := get_member(vm, init, "statusText"); st != nil do o.props["statusText"] = st
        if hv := get_member(vm, init, "headers"); hv != nil do o.props["headers"] = to_headers(vm, hv)
    }
    o.props["status"] = status
    o.props["ok"] = status >= 200 && status <= 299
    o.props["redirected"] = false
    if _, ok := o.props["headers"]; !ok do o.props["headers"] = to_headers(vm, nil)
    return o
}

// Response.json(data, init?) — estático: serializa data e devolve uma Response.
@(private = "file")
response_static_json :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    body := json_stringify_native(vm, nil, []Value{arg(args, 0)})
    return response_ctor(vm, nil, []Value{body, arg(args, 1)})
}

@(private = "file")
response_clone :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := this.(^Object); if !ok do return nil
    c := new_object(vm)
    c.proto = vm.web_response_proto
    for k, v in o.props do c.props[k] = v
    return c
}

// ── URLSearchParams ──────────────────────────────────────────────────────────
// Armazém: this.props["_p"] = ^Array de pares [k,v] (mantém ORDEM e DUPLICATAS).

@(private = "file")
usp_pairs :: proc(vm: ^Interp, this: Value) -> ^Array {
    o, ok := this.(^Object); if !ok do return new_array(vm)
    if a, aok := o.props["_p"].(^Array); aok do return a
    a := new_array(vm)
    o.props["_p"] = a
    return a
}

@(private = "file")
usp_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o := new_object(vm)
    o.proto = vm.web_usp_proto
    a := new_array(vm)
    o.props["_p"] = a
    #partial switch init in arg(args, 0) {
    case string:
        usp_parse_query(vm, a, init)
    case ^Object:
        keys: [dynamic]string; defer delete(keys)
        own_enum_keys(init, &keys)
        for k in keys do usp_push(vm, a, own_str(vm, k), web_str(vm, get_member(vm, init, k)))
    }
    return o
}

// new FormData(form?): cria vazio. APROXIMAÇÃO: se um <form> for passado, NÃO
// populamos a partir dos campos (exigiria varrer o DOM e ler values; a submissão
// de form não roda na 1ª renderização). O uso dominante — construir vazio e dar
// append — funciona pleno. Storage idêntico ao USP (`_p` = pares [k,v]).
@(private = "file")
formdata_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o := new_object(vm)
    o.proto = vm.web_formdata_proto
    o.props["_p"] = new_array(vm)
    return o
}

@(private = "file")
usp_parse_query :: proc(vm: ^Interp, a: ^Array, q: string) {
    s := q
    if len(s) > 0 && s[0] == '?' do s = s[1:]
    parts := strings.split(s, "&", context.temp_allocator)
    for part in parts {
        if part == "" do continue
        k := part; v := ""
        if eq := strings.index_byte(part, '='); eq >= 0 { k = part[:eq]; v = part[eq+1:] }
        usp_push(vm, a, own_str(vm, web_decode(vm, k)), own_str(vm, web_decode(vm, v)))
    }
}

@(private = "file")
usp_push :: proc(vm: ^Interp, a: ^Array, k, v: Value) {
    pair := new_array(vm)
    append(&pair.items, k, v)
    append(&a.items, pair)
}

@(private = "file")
usp_get :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    key := web_str(vm, arg(args, 0))
    for it in usp_pairs(vm, this).items {
        if p, ok := it.(^Array); ok && len(p.items) >= 2 {
            if s, sok := p.items[0].(string); sok && s == key do return p.items[1]
        }
    }
    return JS_Null{}
}

@(private = "file")
usp_get_all :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    key := web_str(vm, arg(args, 0))
    out := new_array(vm)
    for it in usp_pairs(vm, this).items {
        if p, ok := it.(^Array); ok && len(p.items) >= 2 {
            if s, sok := p.items[0].(string); sok && s == key do append(&out.items, p.items[1])
        }
    }
    return out
}

@(private = "file")
usp_has :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    key := web_str(vm, arg(args, 0))
    for it in usp_pairs(vm, this).items {
        if p, ok := it.(^Array); ok && len(p.items) >= 1 {
            if s, sok := p.items[0].(string); sok && s == key do return true
        }
    }
    return false
}

@(private = "file")
usp_append :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    usp_push(vm, usp_pairs(vm, this), own_str(vm, web_str(vm, arg(args, 0))), own_str(vm, web_str(vm, arg(args, 1))))
    return nil
}

@(private = "file")
usp_set :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a := usp_pairs(vm, this)
    key := web_str(vm, arg(args, 0))
    val := own_str(vm, web_str(vm, arg(args, 1)))
    // remove todos os existentes, depois adiciona um
    for i := len(a.items) - 1; i >= 0; i -= 1 {
        if p, ok := a.items[i].(^Array); ok && len(p.items) >= 1 {
            if s, sok := p.items[0].(string); sok && s == key do ordered_remove(&a.items, i)
        }
    }
    usp_push(vm, a, own_str(vm, key), val)
    return nil
}

@(private = "file")
usp_delete :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a := usp_pairs(vm, this)
    key := web_str(vm, arg(args, 0))
    for i := len(a.items) - 1; i >= 0; i -= 1 {
        if p, ok := a.items[i].(^Array); ok && len(p.items) >= 1 {
            if s, sok := p.items[0].(string); sok && s == key do ordered_remove(&a.items, i)
        }
    }
    return nil
}

@(private = "file")
usp_for_each :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    cb, ok := arg(args, 0).(^Function); if !ok do return nil
    for it in usp_pairs(vm, this).items {
        if p, pok := it.(^Array); pok && len(p.items) >= 2 {
            call_function(vm, cb, nil, []Value{p.items[1], p.items[0], this}) // cb(value, key, usp)
            if vm.throwing do break
        }
    }
    return nil
}

@(private = "file")
usp_to_string :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    sb: strings.Builder
    strings.builder_init(&sb); defer strings.builder_destroy(&sb)
    first := true
    for it in usp_pairs(vm, this).items {
        if p, ok := it.(^Array); ok && len(p.items) >= 2 {
            if !first do strings.write_byte(&sb, '&')
            first = false
            strings.write_string(&sb, web_encode(vm, web_str(vm, p.items[0])))
            strings.write_byte(&sb, '=')
            strings.write_string(&sb, web_encode(vm, web_str(vm, p.items[1])))
        }
    }
    return own_str(vm, strings.to_string(sb))
}

@(private = "file")
usp_entries :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    out := new_array(vm)
    for it in usp_pairs(vm, this).items do append(&out.items, it)
    return make_array_iterator(vm, out)
}

@(private = "file")
usp_keys :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    out := new_array(vm)
    for it in usp_pairs(vm, this).items {
        if p, ok := it.(^Array); ok && len(p.items) >= 1 do append(&out.items, p.items[0])
    }
    return make_array_iterator(vm, out)
}

@(private = "file")
usp_values :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    out := new_array(vm)
    for it in usp_pairs(vm, this).items {
        if p, ok := it.(^Array); ok && len(p.items) >= 2 do append(&out.items, p.items[1])
    }
    return make_array_iterator(vm, out)
}

// ── AbortController / AbortSignal ────────────────────────────────────────────

@(private = "file")
abort_controller_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    ctrl := new_object(vm)
    sig := new_object(vm)
    sig.proto = vm.web_signal_proto
    sig.props["aborted"] = false
    sig.props["reason"]  = nil
    ctrl.props["signal"] = sig
    ctrl.props["abort"]  = mk_native(vm, abort_signal_do_abort)
    ctrl.props["_signal"] = sig // p/ o abort() achar o signal (this = controller)
    return ctrl
}

@(private = "file")
abort_signal_do_abort :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if ctrl, ok := this.(^Object); ok {
        if sig, sok := ctrl.props["_signal"].(^Object); sok {
            sig.props["aborted"] = true
            if len(args) >= 1 do sig.props["reason"] = args[0]
        }
    }
    return nil
}

// ── URL ───────────────────────────────────────────────────────────────────────
// Instância = ^Object com as PARTES fixas guardadas em props (protocol/username/
// password/hostname/port/pathname/hash + searchParams + _slashes) e um hook `get`
// (url_get) que COMPUTA href/host/origin/search sob demanda — assim mutar
// `url.searchParams` reflete em `url.href`/`url.search`. Parser próprio (self-
// contained no pacote js); resolução contra base cobre absoluta/root-relative/
// protocol-relative/query/hash/relativa-de-diretório com remoção de dot-segments.

URL_Parts :: struct {
    protocol, username, password, hostname, port, pathname, query, hash: string,
    slashes, ok: bool,
}

@(private = "file")
url_is_special :: proc(protocol: string) -> bool {
    switch protocol {
    case "http:", "https:", "ftp:", "ws:", "wss:", "file:": return true
    }
    return false
}

// true se `s` começa com um esquema válido ("http:", "data:", ...): letra seguida
// de [a-zA-Z0-9+.-]* e ':' ANTES de qualquer /?#.
@(private = "file")
url_has_scheme :: proc(s: string) -> bool {
    if len(s) == 0 do return false
    c0 := s[0]
    if !((c0 >= 'a' && c0 <= 'z') || (c0 >= 'A' && c0 <= 'Z')) do return false
    for i in 0 ..< len(s) {
        c := s[i]
        if c == ':' do return i > 0
        if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
             c == '+' || c == '-' || c == '.') {
            return false
        }
    }
    return false
}

// Remove segmentos "."/".." de um caminho (RFC 3986 §5.2.4, aproximado).
@(private = "file")
url_normalize_path :: proc(path: string) -> string {
    if !strings.contains(path, "..") && !strings.contains(path, "./") do return path
    lead := len(path) > 0 && path[0] == '/'
    trail := len(path) > 0 && path[len(path) - 1] == '/'
    segs := strings.split(path, "/", context.temp_allocator)
    stack: [dynamic]string; stack.allocator = context.temp_allocator
    for seg in segs {
        switch seg {
        case "", ".": // segmento vazio (de // ou lead) e "." são descartados
        case "..":    if len(stack) > 0 do pop(&stack)
        case:         append(&stack, seg)
        }
    }
    joined := strings.join(stack[:], "/", context.temp_allocator)
    b: strings.Builder; strings.builder_init(&b, context.temp_allocator)
    if lead do strings.write_byte(&b, '/')
    strings.write_string(&b, joined)
    if trail && len(stack) > 0 do strings.write_byte(&b, '/')
    return strings.to_string(b)
}

// Quebra uma URL ABSOLUTA nas partes. Não normaliza dot-segments (o chamador faz).
@(private = "file")
url_split :: proc(input: string) -> URL_Parts {
    p: URL_Parts
    s := strings.trim_space(input)
    if h := strings.index_byte(s, '#'); h >= 0 { p.hash = s[h:]; s = s[:h] } // inclui '#'
    if q := strings.index_byte(s, '?'); q >= 0 { p.query = s[q + 1:]; s = s[:q] }
    colon := strings.index_byte(s, ':')
    if colon <= 0 do return p // sem esquema → inválida (ok=false)
    p.protocol = strings.to_lower(s[:colon + 1], context.temp_allocator) // inclui ':'
    rest := s[colon + 1:]
    if strings.has_prefix(rest, "//") {
        p.slashes = true
        rest = rest[2:]
        auth := rest
        if ps := strings.index_byte(rest, '/'); ps >= 0 { auth = rest[:ps]; p.pathname = rest[ps:] }
        if at := strings.last_index_byte(auth, '@'); at >= 0 { // userinfo@
            ui := auth[:at]; auth = auth[at + 1:]
            if c2 := strings.index_byte(ui, ':'); c2 >= 0 { p.username = ui[:c2]; p.password = ui[c2 + 1:] }
            else { p.username = ui }
        }
        if strings.has_prefix(auth, "[") { // IPv6 literal [::1]:porta
            if rb := strings.index_byte(auth, ']'); rb >= 0 {
                p.hostname = auth[:rb + 1]
                if rb + 1 < len(auth) && auth[rb + 1] == ':' do p.port = auth[rb + 2:]
            } else { p.hostname = auth }
        } else if pc := strings.last_index_byte(auth, ':'); pc >= 0 {
            p.hostname = strings.to_lower(auth[:pc], context.temp_allocator); p.port = auth[pc + 1:]
        } else {
            p.hostname = strings.to_lower(auth, context.temp_allocator)
        }
        // porta default do esquema é omitida na serialização
        if (p.protocol == "https:" && p.port == "443") || (p.protocol == "http:" && p.port == "80") ||
           (p.protocol == "ws:" && p.port == "80") || (p.protocol == "wss:" && p.port == "443") ||
           (p.protocol == "ftp:" && p.port == "21") {
            p.port = ""
        }
    } else {
        p.pathname = rest // sem autoridade (mailto:, data:, ...)
    }
    if p.pathname == "" && url_is_special(p.protocol) do p.pathname = "/"
    p.ok = true
    return p
}

// Constrói a string absoluta resolvendo `input` (possivelmente relativo) contra
// `base_input`. Devolve ("", false) se `input` é relativo e a base não é absoluta.
@(private = "file")
url_resolve :: proc(input, base_input: string) -> (string, bool) {
    if url_has_scheme(input) do return input, true
    if base_input == "" do return "", false
    b := url_split(base_input)
    if !b.ok do return "", false

    auth: strings.Builder; strings.builder_init(&auth, context.temp_allocator)
    if b.username != "" {
        strings.write_string(&auth, b.username)
        if b.password != "" { strings.write_byte(&auth, ':'); strings.write_string(&auth, b.password) }
        strings.write_byte(&auth, '@')
    }
    strings.write_string(&auth, b.hostname)
    if b.port != "" { strings.write_byte(&auth, ':'); strings.write_string(&auth, b.port) }
    origin := strings.concatenate({b.protocol, "//", strings.to_string(auth)}, context.temp_allocator)

    if strings.has_prefix(input, "//") do return strings.concatenate({b.protocol, input}, context.temp_allocator), true
    if strings.has_prefix(input, "/")  do return strings.concatenate({origin, input}, context.temp_allocator), true
    if strings.has_prefix(input, "?")  do return strings.concatenate({origin, b.pathname, input}, context.temp_allocator), true
    if strings.has_prefix(input, "#") {
        q := b.query != "" ? strings.concatenate({"?", b.query}, context.temp_allocator) : ""
        return strings.concatenate({origin, b.pathname, q, input}, context.temp_allocator), true
    }
    // relativa ao diretório da base
    dir := "/"
    if sl := strings.last_index_byte(b.pathname, '/'); sl >= 0 do dir = b.pathname[:sl + 1]
    return strings.concatenate({origin, dir, input}, context.temp_allocator), true
}

// Cria um objeto URLSearchParams a partir de uma query (sem '?'), ligado ao proto.
@(private = "file")
url_make_search_params :: proc(vm: ^Interp, query: string) -> ^Object {
    o := new_object(vm)
    o.proto = vm.web_usp_proto
    a := new_array(vm)
    o.props["_p"] = a
    if query != "" do usp_parse_query(vm, a, query)
    return o
}

@(private = "file")
url_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    input := web_str(vm, arg(args, 0))
    base  := ""
    if len(args) >= 2 && !is_nullish(arg(args, 1)) do base = web_str(vm, arg(args, 1))

    abs, ok := url_resolve(input, base)
    if !ok {
        throw_type_error(vm, fmt.tprintf("Failed to construct 'URL': Invalid URL"))
        return nil
    }
    p := url_split(abs)
    if !p.ok {
        throw_type_error(vm, fmt.tprintf("Failed to construct 'URL': Invalid URL"))
        return nil
    }
    p.pathname = url_normalize_path(p.pathname)

    o := new_object(vm)
    o.proto = vm.web_url_proto
    o.get = url_get
    o.props["protocol"]     = own_str(vm, p.protocol)
    o.props["username"]     = own_str(vm, p.username)
    o.props["password"]     = own_str(vm, p.password)
    o.props["hostname"]     = own_str(vm, p.hostname)
    o.props["port"]         = own_str(vm, p.port)
    o.props["pathname"]     = own_str(vm, p.pathname)
    o.props["hash"]         = own_str(vm, p.hash)
    o.props["searchParams"] = url_make_search_params(vm, p.query)
    o.props["_slashes"]     = p.slashes
    return o
}

@(private = "file")
url_prop :: proc(o: ^Object, name: string) -> string {
    if s, ok := o.props[name].(string); ok do return s
    return ""
}

@(private = "file")
url_host :: proc(o: ^Object) -> string {
    host := url_prop(o, "hostname")
    port := url_prop(o, "port")
    if port != "" do return fmt.tprintf("%s:%s", host, port)
    return host
}

@(private = "file")
url_search :: proc(vm: ^Interp, o: ^Object) -> string {
    sp := o.props["searchParams"]
    if q, ok := usp_to_string(vm, sp, nil).(string); ok && q != "" do return fmt.tprintf("?%s", q)
    return ""
}

@(private = "file")
url_origin :: proc(o: ^Object) -> string {
    proto := url_prop(o, "protocol")
    switch proto {
    case "http:", "https:", "ftp:", "ws:", "wss:": return fmt.tprintf("%s//%s", proto, url_host(o))
    }
    return "null"
}

@(private = "file")
url_href :: proc(vm: ^Interp, o: ^Object) -> string {
    sb: strings.Builder; strings.builder_init(&sb, context.temp_allocator)
    strings.write_string(&sb, url_prop(o, "protocol"))
    slashes, _ := o.props["_slashes"].(bool)
    if slashes {
        strings.write_string(&sb, "//")
        user := url_prop(o, "username"); pass := url_prop(o, "password")
        if user != "" {
            strings.write_string(&sb, user)
            if pass != "" { strings.write_byte(&sb, ':'); strings.write_string(&sb, pass) }
            strings.write_byte(&sb, '@')
        }
        strings.write_string(&sb, url_host(o))
    }
    strings.write_string(&sb, url_prop(o, "pathname"))
    strings.write_string(&sb, url_search(vm, o))
    strings.write_string(&sb, url_prop(o, "hash"))
    return strings.to_string(sb)
}

// Hook de leitura: computa as partes derivadas; devolve handled=false p/ o resto
// (pathname/hostname/searchParams/métodos/… caem no lookup normal de props/proto).
@(private = "file")
url_get :: proc(vm: ^Interp, o: ^Object, name: string) -> (Value, bool) {
    switch name {
    case "href", "toString":
        if name == "href" do return own_str(vm, url_href(vm, o)), true
    case "host":   return own_str(vm, url_host(o)), true
    case "origin": return own_str(vm, url_origin(o)), true
    case "search": return own_str(vm, url_search(vm, o)), true
    }
    return nil, false
}

@(private = "file")
url_to_string :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := this.(^Object); if !ok do return own_str(vm, "")
    return own_str(vm, url_href(vm, o))
}

@(private = "file")
url_can_parse :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    input := web_str(vm, arg(args, 0))
    base  := ""
    if len(args) >= 2 && !is_nullish(arg(args, 1)) do base = web_str(vm, arg(args, 1))
    abs, ok := url_resolve(input, base)
    if !ok do return false
    return url_split(abs).ok
}

// createObjectURL(blob): não temos Blob real; devolve um blob: URL sintético só
// para o código não quebrar (revokeObjectURL é no-op).
@(private = "file")
url_create_object_url :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return own_str(vm, "blob:null/00000000-0000-0000-0000-000000000000")
}
