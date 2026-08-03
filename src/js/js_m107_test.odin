package js

import "core:testing"

// M107 — TextEncoder/TextDecoder (UTF-8) FALTAVAM ("TextDecoder is not a constructor",
// gap-miner: apnews e cia.). Strings da engine já são UTF-8 → encode/decode diretos.

@(test)
m107_ctors_sao_funcoes :: proc(t: ^testing.T) {
    r := run(`(typeof TextEncoder) + "," + (typeof TextDecoder)`)
    s, _ := r.(string)
    testing.expectf(t, s == "function,function", "ctors: got %q", s)
}

@(test)
m107_encode_ascii :: proc(t: ^testing.T) {
    r := run(`var b = new TextEncoder().encode('abc'); b.length + ',' + b[0] + ',' + b[1] + ',' + b[2]`)
    s, _ := r.(string)
    testing.expectf(t, s == "3,97,98,99", "encode('abc'): got %q", s)
}

@(test)
m107_encode_utf8_multibyte :: proc(t: ^testing.T) {
    // 'é' = U+00E9 = C3 A9 em UTF-8 → 'café' são 5 bytes
    r := run("var b = new TextEncoder().encode('café'); b.length + ',' + b[3] + ',' + b[4]")
    s, _ := r.(string)
    testing.expectf(t, s == "5,195,169", "encode('café'): got %q", s)
}

@(test)
m107_decode_ascii :: proc(t: ^testing.T) {
    r := run(`new TextDecoder().decode(new Uint8Array([104,105]))`)
    s, _ := r.(string)
    testing.expectf(t, s == "hi", "decode([104,105]): got %q", s)
}

@(test)
m107_roundtrip_utf8 :: proc(t: ^testing.T) {
    r := run("var e = new TextEncoder(); var d = new TextDecoder(); d.decode(e.encode('olá, café ☕'))")
    s, _ := r.(string)
    testing.expectf(t, s == "olá, café ☕", "round-trip UTF-8: got %q", s)
}

@(test)
m107_decode_subarray_offset :: proc(t: ^testing.T) {
    // view com offset: só os bytes da subarray
    r := run(`new TextDecoder().decode(new Uint8Array([65,66,67,68]).subarray(1,3))`)
    s, _ := r.(string)
    testing.expectf(t, s == "BC", "decode de subarray com offset: got %q", s)
}

@(test)
m107_encoding_prop :: proc(t: ^testing.T) {
    r := run(`new TextEncoder().encoding + "," + new TextDecoder().encoding`)
    s, _ := r.(string)
    testing.expectf(t, s == "utf-8,utf-8", "encoding: got %q", s)
}

@(test)
m107_decode_vazio :: proc(t: ^testing.T) {
    r := run(`new TextDecoder().decode(new Uint8Array(0)) + "|" + new TextDecoder().decode()`)
    s, _ := r.(string)
    testing.expectf(t, s == "|", "decode vazio/sem-arg: got %q", s)
}
