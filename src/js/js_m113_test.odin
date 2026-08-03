package js

import "core:testing"

// M113 — índice de acesso computado aceita a Expression completa (operador
// vírgula/sequência): `obj[a, b, c]` avalia a, b e usa c como chave. Sem isso o
// parser truncava no 1º vírgula, deixava tokens soltos e cascateava centenas de
// recuperações — o gatilho real por trás dos sites BLANK ofuscados (_0x…): os
// decoders de string usam `tabela[i = x, j = y, calc(i, j)]` massivamente.
// (gap-miner: arstechnica/amazon/booking/imdb — 371 recoveries → "_0x… is not a
// function"). `run` chama check_parse_recoveries → paniquearia se houvesse recovery.

@(test)
m113_index_comma_sequence :: proc(t: ^testing.T) {
    // usa o ÚLTIMO da sequência como chave.
    r := run(`var o = {}; o['x'] = 42; var i; o[i = 1, 'x']`)
    testing.expect_value(t, as_number(r), f64(42))
}

@(test)
m113_index_comma_side_effects :: proc(t: ^testing.T) {
    // efeitos colaterais da sequência acontecem esquerda→direita.
    r := run(`
        var log = '';
        var o = {}; o['k'] = 7;
        var v = o[(log += 'a'), (log += 'b'), 'k'];
        log + ':' + v
    `)
    s, _ := r.(string)
    testing.expect_value(t, s, "ab:7")
}

@(test)
m113_index_comma_then_call :: proc(t: ^testing.T) {
    // o padrão exato do obfuscador: tabela[i = x, j = y, f(i, j)](args)
    r := run(`
        var tbl = {};
        tbl['m'] = function(a, b){ return a + b; };
        var i, j;
        tbl[i = 0, j = 0, 'm'](3, 4)
    `)
    testing.expect_value(t, as_number(r), f64(7))
}

@(test)
m113_index_no_stray_recovery :: proc(t: ^testing.T) {
    // asserção explícita: ZERO recuperações silenciosas no padrão ofuscado.
    vm := vm_create()
    defer vm_free(vm)
    _ = vm_run(vm, `var o = {a:1,b:2,c:3}; var x, y; o[x = 1, y = 2, 'c'];`)
    testing.expectf(t, vm.parse_recoveries == 0, "esperado 0 recuperações, obtido %d", vm.parse_recoveries)
}

@(test)
m113_optional_chain_index_comma :: proc(t: ^testing.T) {
    // optional chaining com índice-sequência: a?.[x, y]
    r := run(`var o = {}; o['z'] = 9; var i; o?.[i = 1, 'z']`)
    testing.expect_value(t, as_number(r), f64(9))
}
