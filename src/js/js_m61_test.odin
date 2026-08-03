package js

// M61 (grupo 3 das sondas): percent-encoding REAL (encodeURIComponent operava
// como passthrough!), encodeURI/decodeURI preservando reservados, btoa/atob
// com semântica Latin-1, e URIError. Rodar: odin test src/js

import "core:testing"

// ── encodeURIComponent / decodeURIComponent ───────────────────────────────────

@(test)
test_encode_uri_component :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`encodeURIComponent('ã&')`).(string), "%C3%A3%26")
    testing.expect_value(t, run(`encodeURIComponent('a b')`).(string), "a%20b")
    testing.expect_value(t, run(`encodeURIComponent('q=a/b?')`).(string), "q%3Da%2Fb%3F")
    testing.expect_value(t, run(`encodeURIComponent("A-_.!~*'()9")`).(string), "A-_.!~*'()9") // unreserved intactos
}

@(test)
test_decode_uri_component :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`decodeURIComponent('%C3%A3%26')`).(string), "ã&")
    testing.expect_value(t, run(`decodeURIComponent('a%20b')`).(string), "a b")
}

@(test)
test_encode_decode_roundtrip :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var s = 'Promoção: até 50% & já!';
        decodeURIComponent(encodeURIComponent(s)) === s
    `).(bool), true)
}

@(test)
test_decode_malformed_throws_urierror :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var r = '';
        try { decodeURIComponent('%GG'); } catch(e){ r = e.name + ':' + (e instanceof Error); }
        var r2 = '';
        try { decodeURIComponent('fim%2'); } catch(e){ r2 = e.name; }
        r + '|' + r2
    `).(string), "URIError:true|URIError")
}

// ── encodeURI / decodeURI ─────────────────────────────────────────────────────

@(test)
test_encode_uri_keeps_reserved :: proc(t: ^testing.T) {
    // URL inteira: / ? = & # ficam; espaço e acento codificam
    testing.expect_value(t, run(`encodeURI('http://a.com/p?q=é ok#f')`).(string), "http://a.com/p?q=%C3%A9%20ok#f")
}

@(test)
test_decode_uri_keeps_encoded_reserved :: proc(t: ^testing.T) {
    // %2F (/) NÃO decodifica no decodeURI (spec); %20 decodifica
    testing.expect_value(t, run(`decodeURI('a%2Fb%20c')`).(string), "a%2Fb c")
    testing.expect_value(t, run(`decodeURIComponent('a%2Fb')`).(string), "a/b") // component decodifica tudo
}

// ── btoa / atob ───────────────────────────────────────────────────────────────

@(test)
test_btoa_basic :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`btoa('hi')`).(string), "aGk=")
    testing.expect_value(t, run(`btoa('hello')`).(string), "aGVsbG8=")
    testing.expect_value(t, run(`btoa('abc')`).(string), "YWJj")
    testing.expect_value(t, run(`btoa('')`).(string), "")
}

@(test)
test_atob_basic :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`atob('aGk=')`).(string), "hi")
    testing.expect_value(t, run(`atob('YWJj')`).(string), "abc")
    testing.expect_value(t, run(`atob('aGVsbG8=')`).(string), "hello")
    testing.expect_value(t, run(`atob('aGk')`).(string), "hi") // sem padding: tolerado (browsers)
}

@(test)
test_btoa_atob_roundtrip_latin1 :: proc(t: ^testing.T) {
    // 'ã' é U+00E3 (≤ 0xFF): btoa aceita como byte 0xE3 e o atob devolve
    testing.expect_value(t, run(`atob(btoa('ãé')) === 'ãé'`).(bool), true)
}

@(test)
test_btoa_non_latin1_throws :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var r = '';
        try { btoa('中'); } catch(e){ r = e.name; }
        r
    `).(string), "InvalidCharacterError")
}

@(test)
test_atob_invalid_throws :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var r = '';
        try { atob('!@#$'); } catch(e){ r = e.name; }
        var r2 = '';
        try { atob('YWJjZQ='); } catch(e){ r2 = 'lanç'; } // 5+pad: tamanho inválido...
        r
    `).(string), "InvalidCharacterError")
}

@(test)
test_atob_whitespace_tolerated :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`atob(' aG k= ')`).(string), "hi")
}

@(test)
test_uri_error_ctor :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var e = new URIError('u');
        (e instanceof URIError) && (e instanceof Error) && e.name === 'URIError'
    `).(bool), true)
}
