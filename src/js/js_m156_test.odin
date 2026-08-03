package js

// M156 — eval() (direto e indireto) + valor de conclusão de if/block.
//
// Último global de LINGUAGEM no ranking do gap-miner (`eval is not defined`).
// Temos o interpretador inteiro, então eval é real: parseia e roda a fonte,
// devolvendo o VALOR DE CONCLUSÃO (o último statement).
//
//   • eval DIRETO — a forma sintática literal `eval(...)` — roda no ESCOPO do
//     chamador: vê e altera locais. Interceptado em eval_call (interp.odin).
//   • eval INDIRETO — `(0,eval)(x)`, `var e=eval; e(x)`, `obj.eval(x)` — roda no
//     escopo GLOBAL. Cai na nativa global_eval (builtins.odin).
//   • eval(nao-string) devolve o argumento intacto.
//
// Junto veio o valor de conclusão de `if`/`block` (antes descartado → nil), que
// o eval expõe: `eval("if(true) 7")` === 7.
//
// ⚠️ FRONTEIRA: nosso parser RECUPERA de erro de sintaxe em silêncio, então
// `eval("(")` roda o que parseou em vez de lançar SyntaxError. Degradação do
// parser tolerante, anotada.

import "core:testing"

// ── valor de conclusão ────────────────────────────────────────────────────────

@(test)
m156_eval_completion_de_expressao :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`eval("1+2")`)), f64(3))
    testing.expect_value(t, as_number(run(`eval("var a=2; a*a")`)), f64(4))
    testing.expect_value(t, run(`eval("var x=5") === undefined`).(bool), true)
}

@(test)
m156_eval_completion_de_if_e_block :: proc(t: ^testing.T) {
    // if/block passaram a devolver o valor de conclusão do ramo/último statement.
    testing.expect_value(t, as_number(run(`eval("if(true) 7")`)), f64(7))
    testing.expect_value(t, as_number(run(`eval("if(false) 1; else 2")`)), f64(2))
    testing.expect_value(t, as_number(run(`eval("{ 3; 5 }")`)), f64(5))
}

@(test)
m156_eval_aninhado :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`eval("eval('2*3')")`)), f64(6))
}

// ── eval DIRETO vê o escopo do chamador ───────────────────────────────────────

@(test)
m156_eval_direto_le_local :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`(function(){ var y = 10; return eval("y+1"); })()`)), f64(11))
}

@(test)
m156_eval_direto_escreve_local :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`(function(){ var y = 1; eval("y = 99"); return y; })()`)), f64(99))
}

@(test)
m156_eval_direto_define_local :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`(function(){ eval("var z = 7"); return z; })()`)), f64(7))
}

// ── eval INDIRETO roda no escopo global ───────────────────────────────────────

@(test)
m156_eval_indireto_nao_ve_local :: proc(t: ^testing.T) {
    // `var e = eval; e(...)` é indireto → escopo global → não enxerga `loc`.
    src := `(function(){ var loc = 1; var e = eval; return e("typeof loc"); })()`
    testing.expect_value(t, run(src).(string), "undefined")
}

@(test)
m156_eval_indireto_ve_global :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`var gg = 5; (0,eval)("gg")`)), f64(5))
}

// ── eval(não-string) devolve o argumento ──────────────────────────────────────

@(test)
m156_eval_nao_string_intacto :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`eval(42)`)), f64(42))
    testing.expect_value(t, run(`var o = {a:1}; eval(o) === o`).(bool), true)
}

// ── eval devolve função chamável ──────────────────────────────────────────────

@(test)
m156_eval_devolve_funcao :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`typeof eval("(function(){return 1})")`).(string), "function")
    testing.expect_value(t, as_number(run(`eval("(function(){return 9})")()`)), f64(9))
}

// ── eval SOMBREADO não é direto (não é o builtin) ─────────────────────────────

@(test)
m156_eval_sombreado_nao_e_builtin :: proc(t: ^testing.T) {
    // `var eval = ...` local sombreia o builtin → chamada usa a função local,
    // não o eval real (a detecção de eval-direto compara o PONTEIRO do builtin).
    src := `(function(){ var eval = function(s){ return "shadow:" + s; }; return eval("x"); })()`
    testing.expect_value(t, run(src).(string), "shadow:x")
}
