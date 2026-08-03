package js

// M47: bugs do lexer (auditoria 2026-07-08) — escapes \x/\u/\u{}, ASI
// (produções restritas: return/break/continue/throw e ++/-- pós-fixo),
// operadores de atribuição lógica &&= ||= ??=, número com um só ponto
// (100..toString) e identificadores unicode.

import "core:testing"

// ── escapes de string ─────────────────────────────────────────────────────────

@(test)
test_escape_u4 :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("'\\u0041' == 'A' ? 1 : 0")), f64(1))
}

@(test)
test_escape_x2 :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("'\\x41\\x42' == 'AB' ? 1 : 0")), f64(1))
}

@(test)
test_escape_u_braces :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("'\\u{48}\\u{69}' == 'Hi' ? 1 : 0")), f64(1))
}

@(test)
test_escape_surrogate_pair :: proc(t: ^testing.T) {
    // 😀 combinados formam U+1F600 (😀)
    testing.expect_value(t, as_number(run("'\\uD83D\\uDE00' == '😀' ? 1 : 0")), f64(1))
}

@(test)
test_escape_bfv :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("'\\b'.charCodeAt(0)*10000 + '\\f'.charCodeAt(0)*100 + '\\v'.charCodeAt(0)")), f64(8.1211e4))
}

@(test)
test_escape_line_continuation :: proc(t: ^testing.T) {
    // barra invertida + newline REAL dentro do literal: some
    testing.expect_value(t, as_number(run("'a\\\nb' == 'ab' ? 1 : 0")), f64(1))
}

@(test)
test_escape_unicode_em_template :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("`\\u0041${1}` == 'A1' ? 1 : 0")), f64(1))
}

@(test)
test_escape_malformado_literal :: proc(t: ^testing.T) {
    // \u sem 4 dígitos hex: mantém comportamento antigo (emite literal, sem crash)
    testing.expect_value(t, as_number(run("'\\uZZ'.length")), f64(3))
}

// ── ASI: produções restritas ──────────────────────────────────────────────────

@(test)
test_asi_return :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("function f(){ return\n42 }\nf() === undefined ? 1 : 0")), f64(1))
}

@(test)
test_asi_return_mesma_linha :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("function f(){ return 42 }\nf()")), f64(42))
}

@(test)
test_asi_break :: proc(t: ^testing.T) {
    // `break\nx=1` é break; x=1 (inalcançável) — NÃO `break x`
    testing.expect_value(t, as_number(run("var x=0; while(true){ break\nx=1 }\nx")), f64(0))
}

@(test)
test_asi_break_label_mesma_linha :: proc(t: ^testing.T) {
    // label na mesma linha continua funcionando
    testing.expect_value(t, as_number(run("var n=0; outer: for(var i=0;i<3;i++){ for(var j=0;j<3;j++){ n++; break outer } }\nn")), f64(1))
}

@(test)
test_asi_continue :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var n=0; for(var i=0;i<3;i++){ if(i==0) continue\nn++ }\nn")), f64(2))
}

@(test)
test_asi_postfix :: proc(t: ^testing.T) {
    // `a\n++b` é `a; ++b`, não `a++; b`
    testing.expect_value(t, as_number(run("var a=1, b=2; var r = a\n++b\nr*100 + a*10 + b")), f64(113))
}

@(test)
test_asi_throw :: proc(t: ^testing.T) {
    // `throw\nx` não pode engolir a linha seguinte (spec: SyntaxError; aqui: throw undefined)
    testing.expect_value(t, as_number(run("var ran=0; try { throw\nran=1 } catch(e) {}\nran")), f64(0))
}

@(test)
test_asi_comentario_bloco_conta :: proc(t: ^testing.T) {
    // newline dentro de /* */ vale como quebra de linha p/ ASI
    testing.expect_value(t, as_number(run("function f(){ return /* quebra\naqui */ 42 }\nf() === undefined ? 1 : 0")), f64(1))
}

// ── atribuição lógica &&= ||= ??= ─────────────────────────────────────────────

@(test)
test_logical_assign_and :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var a=1; a &&= 5; a")), f64(5))
    testing.expect_value(t, as_number(run("var a=0; a &&= 5; a")), f64(0))
}

@(test)
test_logical_assign_or :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var b=0; b ||= 7; b")), f64(7))
    testing.expect_value(t, as_number(run("var b=3; b ||= 7; b")), f64(3))
}

@(test)
test_logical_assign_nullish :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var c=null; c ??= 9; c")), f64(9))
    testing.expect_value(t, as_number(run("var c=0; c ??= 9; c")), f64(0)) // 0 não é nullish
}

@(test)
test_logical_assign_curto_circuito :: proc(t: ^testing.T) {
    // quando não atribui, o RHS nem é avaliado
    testing.expect_value(t, as_number(run("var calls=0; function f(){ calls++; return 1 }\nvar x=5; x ??= f(); var y=1; y &&= y; var z=1; z ||= f(); calls")), f64(0))
}

@(test)
test_logical_assign_member :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var o={x:null, y:2}; o.x ??= 3; o.y &&= 8; o.x*10 + o.y")), f64(38))
}

// ── número com no máximo um ponto ─────────────────────────────────────────────

@(test)
test_num_ponto_final :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("100. + .5")), f64(100.5))
}

@(test)
test_num_dois_pontos_membro :: proc(t: ^testing.T) {
    // 100..toString é (100.).toString — acesso a membro, não número "100.."
    testing.expect_value(t, as_number(run("typeof 100..toString == 'number' ? 0 : 1")), f64(1))
}

// ── identificadores unicode ───────────────────────────────────────────────────

@(test)
test_ident_unicode :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var π = 3.14; π * 2")), f64(6.28))
}

@(test)
test_ident_unicode_acento :: proc(t: ^testing.T) {
    // `café` e `caf` são variáveis DISTINTAS (bytes não-ASCII não são mais descartados)
    testing.expect_value(t, as_number(run("var caf = 1; var café = 2; caf*10 + café")), f64(12))
}
