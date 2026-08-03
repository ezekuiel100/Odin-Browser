package js

// M49: semântica que quebra lógica de app (auditoria 2026-07-08, grupo 3) —
// ToNumber spec (NaN em vez de 0), NaN falsy, relacionais de string,
// for(let) com binding por iteração, ordem de avaliação da atribuição,
// ordem de inserção de chaves (for-in/Object.keys/JSON.stringify).

import "core:testing"

// ── ToNumber / NaN ────────────────────────────────────────────────────────────

@(test)
test_tonumber_string_invalida :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("isNaN(Number('abc')) ? 1 : 0")), f64(1))
    testing.expect_value(t, as_number(run("isNaN('5' * 'px') ? 1 : 0")), f64(1))
    testing.expect_value(t, as_number(run("isNaN(undefined + 1) ? 1 : 0")), f64(1))
}

@(test)
test_tonumber_whitespace_e_bases :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("Number(' 12 ')")), f64(12))
    testing.expect_value(t, as_number(run("Number('')")), f64(0))
    testing.expect_value(t, as_number(run("Number('0x1F')")), f64(31))
    testing.expect_value(t, as_number(run("Number('-Infinity') === -Infinity ? 1 : 0")), f64(1))
}

@(test)
test_nan_falsy :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("NaN ? 1 : 0")), f64(0))
    testing.expect_value(t, as_number(run("parseFloat('abc') ? 1 : 0")), f64(0))
    testing.expect_value(t, as_number(run("!!NaN ? 1 : 0")), f64(0))
}

@(test)
test_loose_eq_nao_iguala_lixo :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("'abc' == 0 ? 1 : 0")), f64(0))
    testing.expect_value(t, as_number(run("NaN == NaN ? 1 : 0")), f64(0))
}

@(test)
test_tonumber_array :: proc(t: ^testing.T) {
    // ToPrimitive de array: [] -> 0, [7] -> 7, [1,2] -> NaN
    testing.expect_value(t, as_number(run("+[] === 0 && +[7] === 7 && isNaN(+[1,2]) ? 1 : 0")), f64(1))
}

@(test)
test_string_infinity_nan :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("('' + 1/0) == 'Infinity' ? 1 : 0")), f64(1))
    testing.expect_value(t, as_number(run("('' + -1/0) == '-Infinity' ? 1 : 0")), f64(1))
    testing.expect_value(t, as_number(run("('' + Number('x')) == 'NaN' ? 1 : 0")), f64(1))
}

@(test)
test_args_opcionais_continuam_zero :: proc(t: ^testing.T) {
    // arg ausente nos builtins ainda conta como 0 (ToInteger(NaN)=0), não índice-lixo
    testing.expect_value(t, as_number(run("'hello'.charAt() == 'h' ? 1 : 0")), f64(1))
    testing.expect_value(t, as_number(run("['a','b'].slice().length")), f64(2))
}

@(test)
test_array_chave_nao_indice :: proc(t: ^testing.T) {
    // arr['foo'] NÃO pode ler items[0]; arr['1'] indexa; arr[1.5] é undefined
    testing.expect_value(t, as_number(run(`
        var a = [10, 20];
        (a['foo'] === undefined && a['1'] === 20 && a[1.5] === undefined) ? 1 : 0`)), f64(1))
}

// ── relacionais de string ─────────────────────────────────────────────────────

@(test)
test_relacional_string :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("'b' > 'a' ? 1 : 0")), f64(1))
    testing.expect_value(t, as_number(run("'2024-06' < '2024-07' ? 1 : 0")), f64(1))
    testing.expect_value(t, as_number(run("'abc' <= 'abc' && 'ab' < 'abc' ? 1 : 0")), f64(1))
    // misto string-número continua numérico: '10' > 9
    testing.expect_value(t, as_number(run("'10' > 9 ? 1 : 0")), f64(1))
}

// ── for(let) por iteração ─────────────────────────────────────────────────────

@(test)
test_for_let_closure :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        var fns = [];
        for (let i = 0; i < 3; i++) fns.push(function(){ return i });
        fns[0]()*100 + fns[1]()*10 + fns[2]()`)), f64(12))
}

@(test)
test_for_var_closure_compartilha :: proc(t: ^testing.T) {
    // com var o comportamento antigo (compartilhado) é o CORRETO
    testing.expect_value(t, as_number(run(`
        var fns = [];
        for (var i = 0; i < 3; i++) fns.push(function(){ return i });
        fns[0]()*100 + fns[1]()*10 + fns[2]()`)), f64(333))
}

@(test)
test_for_let_sem_closure_normal :: proc(t: ^testing.T) {
    // caminho rápido (sem função no corpo) continua somando certo
    testing.expect_value(t, as_number(run("var s = 0; for (let i = 0; i < 100; i++) s += i; s")), f64(4950))
}

@(test)
test_for_let_body_muta :: proc(t: ^testing.T) {
    // corpo pode mutar o binding da própria iteração (pulo de 2 em 2)
    testing.expect_value(t, as_number(run(`
        var fns = [];
        for (let i = 0; i < 6; i++) { i++; fns.push(function(){ return i }) }
        fns.length*100 + fns[0]() + fns[1]() + fns[2]()`)), f64(309))
}

// ── ordem de avaliação da atribuição ──────────────────────────────────────────

@(test)
test_assign_indice_antes_do_rhs :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        var i = 0; var a = [9, 9];
        a[i] = i++;
        a[0]*10 + a[1]`)), f64(9)) // a = [0, 9]
}

@(test)
test_assign_composto_le_antes :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var x = 1; x += (x = 10, 5); x")), f64(6))
}

@(test)
test_assign_base_avaliada_uma_vez :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        var calls = 0;
        var o = { x: 1 };
        function get(){ calls++; return o }
        get().x += 5;
        calls*10 + o.x`)), f64(16)) // 1 chamada, x = 6
}

// ── ordem de chaves (inserção; índices primeiro) ──────────────────────────────

@(test)
test_keys_ordem_insercao :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(
        "Object.keys({b:1, a:2, z:3, c:4}).join(',') == 'b,a,z,c' ? 1 : 0")), f64(1))
}

@(test)
test_keys_indices_primeiro :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(
        "Object.keys({b:1, 2:'x', a:2, 0:'y'}).join(',') == '0,2,b,a' ? 1 : 0")), f64(1))
}

@(test)
test_forin_ordem :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        var o = {um:1, dois:2, tres:3}; o.quatro = 4;
        var ks = [];
        for (var k in o) ks.push(k);
        ks.join(',') == 'um,dois,tres,quatro' ? 1 : 0`)), f64(1))
}

@(test)
test_json_stringify_ordem :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(
        `JSON.stringify({b:1, a:{y:2, x:3}}) == '{"b":1,"a":{"y":2,"x":3}}' ? 1 : 0`)), f64(1))
}

@(test)
test_json_parse_ordem :: proc(t: ^testing.T) {
    // parse → stringify redondo preserva a ordem do texto
    testing.expect_value(t, as_number(run(
        `JSON.stringify(JSON.parse('{"z":1,"a":2,"m":3}')) == '{"z":1,"a":2,"m":3}' ? 1 : 0`)), f64(1))
}

@(test)
test_spread_ordem_e_getter :: proc(t: ^testing.T) {
    // spread preserva ordem da fonte E materializa getters
    testing.expect_value(t, as_number(run(`
        var src = {b:1, a:2, get g(){ return 42 }};
        var o = {...src, z:9};
        (Object.keys(o).join(',') == 'b,a,g,z' && o.g === 42) ? 1 : 0`)), f64(1))
}

@(test)
test_delete_reinsere_no_fim :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        var o = {a:1, b:2, c:3};
        delete o.a; o.a = 9;
        Object.keys(o).join(',') == 'b,c,a' ? 1 : 0`)), f64(1))
}

@(test)
test_classfield_ordem :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        class C { z = 1; a = 2; m = 3 }
        Object.keys(new C()).join(',') == 'z,a,m' ? 1 : 0`)), f64(1))
}
