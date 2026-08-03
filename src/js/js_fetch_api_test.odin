package js

// M68 (2026-07-10): Fetch API (Request/Response/Headers/URLSearchParams/
// AbortController) + fix do curto-circuito de optional chaining. Descobertos
// atacando o ultra-photo (better-auth): `Request` undefined e
// `e?.plugins?.flatMap(...).filter(...)` avaliando .filter() no undefined.

import "core:testing"

// ── Headers ──────────────────────────────────────────────────────────────────

@(test)
test_headers_case_insensitive :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var h = new Headers({ 'Content-Type': 'application/json' });
        h.get('content-type') + '|' + h.get('CONTENT-TYPE')
    `).(string), "application/json|application/json")
}

@(test)
test_headers_append_and_has :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var h = new Headers();
        h.append('x', 'a'); h.append('x', 'b');
        h.get('x') + '|' + h.has('x') + '|' + h.has('nope')
    `).(string), "a, b|true|false")
}

@(test)
test_headers_request_credentials_in_prototype :: proc(t: ^testing.T) {
    // o check EXATO do better-auth que crashava
    testing.expect_value(t, run(`'credentials' in Request.prototype`).(bool), true)
}

// ── Request ──────────────────────────────────────────────────────────────────

@(test)
test_request_basic :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var r = new Request('https://x.com/a', { method: 'post', headers: { A: '1' } });
        r.url + '|' + r.method + '|' + r.headers.get('a')
    `).(string), "https://x.com/a|POST|1")
}

// ── Response ─────────────────────────────────────────────────────────────────

@(test)
test_response_basic :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var r = new Response('body', { status: 201 });
        r.status + '|' + r.ok + '|' + (new Response(null, {status:404}).ok)
    `).(string), "201|true|false")
}

// ── URLSearchParams ──────────────────────────────────────────────────────────

@(test)
test_url_search_params :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var u = new URLSearchParams('a=1&b=2&a=3');
        u.get('a') + '|' + u.getAll('a').join(',') + '|' + u.has('b') + '|' + u.has('z')
    `).(string), "1|1,3|true|false")
}

@(test)
test_url_search_params_tostring :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var u = new URLSearchParams();
        u.append('q', 'a b'); u.append('n', '5');
        u.toString()
    `).(string), "q=a%20b&n=5")
}

@(test)
test_url_search_params_prototype :: proc(t: ^testing.T) {
    // M91: core-js faz `kv = URLSearchParams.prototype; b(kv.append)`. Sem o
    // `.prototype` no construtor, kv era undefined → "reading 'append'" abortava
    // o chunk de polyfills (14 sites). Idem Headers.
    testing.expect_value(t, run(`
        var jv = URLSearchParams, kv = jv.prototype;
        (typeof kv === 'object') + '|' + (typeof kv.append) + '|' + (typeof kv.delete) +
        '|' + (typeof kv.forEach) + '|' + (typeof Headers.prototype.append)
    `).(string), "true|function|function|function|function")
}

// ── URL ──────────────────────────────────────────────────────────────────────

@(test)
test_url_parse_parts :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var u = new URL("https://user:pass@Example.COM:8443/a/b?x=1&y=2#f");
        [u.protocol, u.username, u.password, u.hostname, u.port, u.host,
         u.pathname, u.search, u.hash, u.origin].join('|')
    `).(string), "https:|user|pass|example.com|8443|example.com:8443|/a/b|?x=1&y=2|#f|https://example.com:8443")
}

@(test)
test_url_href_and_tostring :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var u = new URL("https://x.com/p?a=1#h");
        (u.href === u.toString()) + '|' + u.href
    `).(string), "true|https://x.com/p?a=1#h")
}

@(test)
test_url_default_port_dropped :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`new URL("https://x.com:443/p").host + '|' + new URL("http://x.com:80/").host`).(string),
        "x.com|x.com")
}

@(test)
test_url_search_params_live :: proc(t: ^testing.T) {
    // mutar searchParams reflete em .search e .href (get hook recomputa)
    testing.expect_value(t, run(`
        var u = new URL("https://x.com/p?a=1");
        u.searchParams.set("b", "2"); u.searchParams.append("a", "9");
        u.search + '|' + u.href
    `).(string), "?a=1&b=2&a=9|https://x.com/p?a=1&b=2&a=9")
}

@(test)
test_url_base_resolution :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`[
        new URL("/foo", "https://x.com/a/b").href,
        new URL("baz", "https://x.com/a/b").href,
        new URL("../q", "https://x.com/a/b/c").href,
        new URL("//cdn.com/x", "https://x.com/a").href,
        new URL("?z=1", "https://x.com/a/b").href,
        new URL("http://o.com/z", "https://x.com/a").href
    ].join('|')`).(string),
        "https://x.com/foo|https://x.com/a/baz|https://x.com/a/q|https://cdn.com/x|https://x.com/a/b?z=1|http://o.com/z")
}

@(test)
test_url_can_parse_and_invalid :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var threw = false;
        try { new URL("not a url"); } catch (e) { threw = e instanceof TypeError; }
        URL.canParse("https://x.com") + '|' + URL.canParse("/foo") + '|' + threw +
        '|' + (new URL("https://x.com") instanceof URL)
    `).(string), "true|false|true|true")
}

// ── FormData ──────────────────────────────────────────────────────────────────

@(test)
test_formdata_basic :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var f = new FormData();
        f.append('a', '1'); f.append('a', '2'); f.append('n', 5);
        [f.get('a'), f.getAll('a').join(','), f.get('n'), f.has('a'), f.has('z')].join('|')
    `).(string), "1|1,2|5|true|false") // valor numérico coerido a string (spec)
}

@(test)
test_formdata_set_delete_iter :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var f = new FormData();
        f.append('a', '1'); f.append('b', '2'); f.set('a', '9'); f.delete('b');
        var out = []; for (var e of f) out.push(e[0] + ':' + e[1]);
        out.join(',') + '|' + (new FormData() instanceof FormData) + '|' + (typeof FormData.prototype.append)
    `).(string), "a:9|true|function")
}

// ── AbortController ──────────────────────────────────────────────────────────

@(test)
test_abort_controller :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var c = new AbortController();
        var before = c.signal.aborted;
        c.abort();
        (before === false) && (c.signal.aborted === true)
    `).(bool), true)
}

// ── optional chaining: curto-circuita a cadeia INTEIRA ───────────────────────

@(test)
test_optchain_short_circuits_whole_chain :: proc(t: ^testing.T) {
    // o padrão do better-auth: ?. cancela até os elos NÃO-opcionais seguintes
    testing.expect_value(t, run(`
        var e = {};
        (e?.plugins?.flatMap(function(x){return x;}).filter(function(x){return x;}) || []).length
    `).(f64), f64(0))
}

@(test)
test_optchain_through_call_and_index :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var a = null;
        (typeof a?.b.c.d) + '|' + (typeof a?.b().c()) + '|' + (typeof a?.b[0].c)
    `).(string), "undefined|undefined|undefined")
}

@(test)
test_optchain_non_nullish_base_still_throws :: proc(t: ^testing.T) {
    // ?. só curto-circuita quando o LHS do ?. é nullish; senão a cadeia continua
    // e `.deeper` num undefined DEVE lançar (semântica correta do JS)
    testing.expect_value(t, run(`
        var o = { x: { y: 5 } };
        var threw = false;
        try { var r = o?.missing.deeper; } catch(e){ threw = true; }
        (o?.x?.y === 5) && (o?.x.y === 5) && threw
    `).(bool), true)
}

@(test)
test_optchain_arg_isolation :: proc(t: ^testing.T) {
    // uma cadeia curto-circuitada num ARGUMENTO não corrompe a cadeia externa
    testing.expect_value(t, run(`
        var a = null;
        var box = { get: function(k){ return { val: 42 }; } };
        box.get(a?.z).val
    `).(f64), f64(42))
}
