package js

import "core:testing"

// M114 — chave de propriedade de LITERAL de objeto com número não-decimal-inteiro
// deve ser ToString(valor) canônico, não o texto-fonte. Era a RAIZ do 2º blocker
// do decoder-runtime `_0x` (peel do M113): tabelas de dispatch ofuscadas usam
// `{0x1c6: fn, 0xa4: fn, ...}` e o lookup por `tabela[454]` (0x1c6 decimal) não
// casava porque a chave fora gravada como texto cru "0x1c6". Confirmado em
// arstechnica/amazon/imdb (o `_0x…[k] is not a function` sumiu com o fix).

@(test)
m114_hex_key_canonical :: proc(t: ^testing.T) {
    // 0x1c6 == 454; a propriedade deve ser acessável pelas 3 formas.
    r := run(`
        var o = {0x1c6: 'A'};
        (o[454] === 'A') && (o[0x1c6] === 'A') && (o['454'] === 'A')
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "chave hex 0x1c6 canonicaliza p/ '454'")
}

@(test)
m114_hex_key_dispatch_call :: proc(t: ^testing.T) {
    // o padrão do decoder: tabela hex-chaveada chamada por índice decimal.
    r := run(`
        var tbl = { 0x1c6: function(a){ return a + 1; }, 0xa4: function(a){ return a * 2; } };
        tbl[454](10) + tbl[164](10)
    `)
    testing.expect_value(t, as_number(r), f64(31)) // (10+1) + (10*2)
}

@(test)
m114_float_key_canonical :: proc(t: ^testing.T) {
    // 1.50 → "1.5"; 1e3 → "1000".
    r := run(`
        var o = {1.50: 'x', 1e3: 'y'};
        (o['1.5'] === 'x') && (o[1.5] === 'x') && (o['1000'] === 'y') && (o[1000] === 'y')
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "chave float/exponencial canonicaliza")
}

@(test)
m114_int_key_order_and_string :: proc(t: ^testing.T) {
    // chaves-índice inteiras enumeram em ordem numérica ascendente e como decimal.
    r := run(`Object.keys({0x1c6:1, 0xa4:1, 10:1}).join(',')`)
    s, _ := r.(string)
    testing.expect_value(t, s, "10,164,454")
}

@(test)
m114_decimal_key_unchanged :: proc(t: ^testing.T) {
    // regressão: chave decimal inteira comum continua exata.
    r := run(`var o = {42: 'a', 7: 'b'}; o[42] + o['7']`)
    s, _ := r.(string)
    testing.expect_value(t, s, "ab")
}
