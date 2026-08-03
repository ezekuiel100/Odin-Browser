package js

// M51: restos do parser (auditoria 2026-07-08) — destructuring em posição de
// expressão, catch com padrão, new a[b](args), buracos em array literal e
// regex após `)` de cabeçalho de controle.

import "core:testing"

// ── destructuring-expressão ───────────────────────────────────────────────────

@(test)
test_destr_swap :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var a=1, b=2; [a, b] = [b, a]; a*10 + b")), f64(21))
}

@(test)
test_destr_objeto_parens :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var x = 0; var o = {x: 5}; ({x} = o); x")), f64(5))
}

@(test)
test_destr_aninhado :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var a=0, b=0; [a, [b]] = [1, [2]]; a*10 + b")), f64(12))
}

@(test)
test_destr_default :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var a=0, b=0; [a = 9, b = 8] = [1]; a*10 + b")), f64(18))
}

@(test)
test_destr_rest :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var h=0, r; [h, ...r] = [1, 2, 3]; h*100 + r.length*10 + r[1]")), f64(123))
}

@(test)
test_destr_alvo_membro :: proc(t: ^testing.T) {
    // alvo member/index no padrão (só existe na forma-expressão)
    testing.expect_value(t, as_number(run("var o = {}; var xs = [7, 8]; [o.x, xs[0]] = [1, 2]; o.x*10 + xs[0]")), f64(12))
}

@(test)
test_destr_atribui_nao_declara :: proc(t: ^testing.T) {
    // sem let/const: atribui na variável EXISTENTE (sobe a cadeia de escopos)
    testing.expect_value(t, as_number(run("var a = 1; function f(){ [a] = [5] }\nf(); a")), f64(5))
}

@(test)
test_destr_valor_da_expressao :: proc(t: ^testing.T) {
    // a expressão de atribuição devolve o RHS
    testing.expect_value(t, as_number(run("var a, b; var r = ([a, b] = [1, 2]); r[1]")), f64(2))
}

@(test)
test_destr_rename_objeto :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var c = 0; ({a: c} = {a: 42}); c")), f64(42))
}

// ── catch com padrão ──────────────────────────────────────────────────────────

@(test)
test_catch_pattern :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        var m = '';
        try { throw { message: 'oi', code: 7 } }
        catch ({ message, code }) { m = message + code }
        m == 'oi7' ? 1 : 0`)), f64(1))
}

@(test)
test_catch_pattern_so_no_erro :: proc(t: ^testing.T) {
    // antes: o handler rodava SEMPRE, fora do try
    testing.expect_value(t, as_number(run("var ran = 0; try { var q = 1 } catch ({ message }) { ran = 1 }\nran")), f64(0))
}

@(test)
test_catch_ident_continua :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var v = 0; try { throw 9 } catch (e) { v = e }\nv")), f64(9))
}

// ── new a[b](args) ────────────────────────────────────────────────────────────

@(test)
test_new_indexado :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        function C(x){ this.v = x }
        var handlers = { k: C };
        new handlers['k'](7).v`)), f64(7))
}

@(test)
test_new_indexado_array :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        function C(x){ this.v = x }
        var fabricas = [C];
        new fabricas[0](3).v`)), f64(3))
}

@(test)
test_new_membro_continua :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`
        function C(x){ this.v = x }
        var ns = { sub: { C: C } };
        new ns.sub.C(4).v`)), f64(4))
}

// ── buracos em array literal ──────────────────────────────────────────────────

@(test)
test_array_hole :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("[1, , 3].length")), f64(3))
    testing.expect_value(t, as_number(run("[1, , 3][1] === undefined ? 1 : 0")), f64(1))
    testing.expect_value(t, as_number(run("[1, , 3][2]")), f64(3))
}

@(test)
test_array_trailing_comma :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("[1, 2, ].length")), f64(2))
}

// ── regex após `)` de controle ────────────────────────────────────────────────

@(test)
test_regex_apos_if :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var ok = 0; if (true) /a/.test('a') && (ok = 1);\nok")), f64(1))
}

@(test)
test_regex_apos_while :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var n = 0; while (n < 2) /x/.test('x') ? n++ : n++;\nn")), f64(2))
}

@(test)
test_divisao_apos_paren_normal :: proc(t: ^testing.T) {
    // paren de EXPRESSÃO continua divisão: (4)/2
    testing.expect_value(t, as_number(run("var x = (4) / 2; x")), f64(2))
    testing.expect_value(t, as_number(run("function f(){ return 8 }\nf() / 2")), f64(4))
}
