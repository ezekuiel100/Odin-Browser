package js

// M24: buracos de parser que travavam bundles reais (Vite/esbuild do tradebig.com.br).
// Cada teste cobre um construto que antes abortava o parse e vazava um `return`
// para o nível do módulo.

import "core:testing"

// ── parâmetros default ──────────────────────────────────────────────────────

@(test)
test_param_default_simples :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`function f(a, b = 5){ return a + b } f(10)`)), f64(15))
}

@(test)
test_param_default_ignorado_quando_passado :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`function f(a, b = 5){ return a + b } f(10, 1)`)), f64(11))
}

@(test)
test_param_default_refere_anterior :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`var f = (a, b = a * 2) => a + b; f(3)`)), f64(9))
}

@(test)
test_param_default_com_parenteses :: proc(t: ^testing.T) {
    // reproduz o __vite__mapDeps: arrow com default contendo parênteses/expressão
    testing.expect_value(t, as_number(run(`var f = (i, d = (1 || 2)) => i + d; f(10)`)), f64(11))
}

// ── múltiplos declaradores ──────────────────────────────────────────────────

@(test)
test_var_multiplos_declaradores :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`var a = 1, b = 2, c = 3; a + b + c`)), f64(6))
}

@(test)
test_var_declarador_sem_init :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`var a = 5, b; b = 10; a + b`)), f64(15))
}

@(test)
test_for_multiplos_init :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`var s = 0; for(var i = 0, n = 5; i < n; i++) s += i; s`)), f64(10))
}

// ── operador `in` ───────────────────────────────────────────────────────────

@(test)
test_in_operador :: proc(t: ^testing.T) {
    v, _ := run(`var o = {a: 1}; "a" in o && !("b" in o)`).(bool)
    testing.expect(t, v, "in operador")
}

@(test)
test_in_nao_confunde_for_in :: proc(t: ^testing.T) {
    // `for(x in o)` continua sendo for-in, não vira expressão
    testing.expect_value(t, as_number(run(`var o = {a:1, b:2}; var n = 0; for(var k in o) n++; n`)), f64(2))
}

@(test)
test_in_ternario :: proc(t: ^testing.T) {
    // padrão do bundle: `k in o ? x : y`
    testing.expect_value(t, as_number(run(`var o = {a:1}; "a" in o ? 7 : 9`)), f64(7))
}

// ── void / delete ───────────────────────────────────────────────────────────

@(test)
test_void :: proc(t: ^testing.T) {
    v := run(`void 0`)
    testing.expect(t, v == nil, "void 0 === undefined")
}

@(test)
test_void_diferente_de_null :: proc(t: ^testing.T) {
    v, _ := run(`var x = 5; x !== void 0`).(bool)
    testing.expect(t, v, "x !== void 0")
}

@(test)
test_delete :: proc(t: ^testing.T) {
    v, _ := run(`var o = {a: 1, b: 2}; delete o.a; !("a" in o) && ("b" in o)`).(bool)
    testing.expect(t, v, "delete o.a")
}

// ── operador vírgula em condições ───────────────────────────────────────────

@(test)
test_if_virgula :: proc(t: ^testing.T) {
    // if(A, B, C) — a condição é a sequência; vale o último (C)
    testing.expect_value(t, as_number(run(`var x = 0; if(x = 1, x = 2, x > 1) x = 99; x`)), f64(99))
}

@(test)
test_return_virgula :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`function f(){ var a = 0; return a = 1, a = 2, a } f()`)), f64(2))
}

// ── chaves computadas ───────────────────────────────────────────────────────

@(test)
test_chave_computada :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`var k = "x"; var o = {[k]: 42}; o.x`)), f64(42))
}

@(test)
test_chave_computada_mista :: proc(t: ^testing.T) {
    // reproduz `({...H, [T]: N})` do bundle
    testing.expect_value(t, as_number(run(`var H = {a: 1}; var T = "b"; var o = {...H, [T]: 2}; o.a + o.b`)), f64(3))
}

@(test)
test_chave_computada_expr :: proc(t: ^testing.T) {
    v, _ := run(`var o = {["k" + 1]: "v"}; o.k1 === "v"`).(bool)
    testing.expect(t, v, "chave computada por expressão")
}

// ── notação numérica ────────────────────────────────────────────────────────

@(test)
test_numero_exponencial :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`1e3`)), f64(1000))
}

@(test)
test_numero_exponencial_em_objeto :: proc(t: ^testing.T) {
    // `{staleTime: 1e3*60*10}` — antes quebrava o object literal
    testing.expect_value(t, as_number(run(`var o = {t: 1e3 * 60 * 10}; o.t`)), f64(600000))
}

@(test)
test_numero_hex :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`0xff`)), f64(255))
}

@(test)
test_numero_binario :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`0b1010`)), f64(10))
}

// ── módulo ES ───────────────────────────────────────────────────────────────

@(test)
test_export_default :: proc(t: ^testing.T) {
    // `export default expr` avalia a expressão; o resto do programa segue
    testing.expect_value(t, as_number(run(`var x = 5; export default x; x + 1`)), f64(6))
}

@(test)
test_export_lista_noop :: proc(t: ^testing.T) {
    // `export {a, b}` não quebra os statements seguintes
    testing.expect_value(t, as_number(run(`var a = 1, b = 2; export {a, b}; a + b`)), f64(3))
}
