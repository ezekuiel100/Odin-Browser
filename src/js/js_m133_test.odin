package js

// M133 — peel do cluster `reading 'call'` (10 sites, o maior do ranking).
//
// Triagem primeiro (lição do M115: separar REDE de ENGINE): dos 10 sites, **3 eram
// página de DESAFIO anti-bot** (codepen, soundcloud, techcrunch — Cloudflare
// challenge-platform), então nem chegaram a ser gap. Dos 7 reais, 6 são portais
// brasileiros que compartilham a mesma stack — e o erro comum entre eles era
// `entity.constructor.toString()`.
//
// Raiz: `.constructor` faltava em QUASE TUDO. Só `Array` tinha.

import "core:testing"
import "core:strings"

// ── .constructor em primitivos e builtins ────────────────────────────────────

@(test)
m133_constructor_de_primitivos :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`"x".constructor === String`).(bool), true)
    testing.expect_value(t, run(`(1).constructor === Number`).(bool), true)
    testing.expect_value(t, run(`true.constructor === Boolean`).(bool), true)
}

@(test)
m133_constructor_de_objeto_e_funcao :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`({}).constructor === Object`).(bool), true)
    testing.expect_value(t, run(`(function(){}).constructor === Function`).(bool), true)
    testing.expect_value(t, run(`[].constructor === Array`).(bool), true)
}

@(test)
m133_constructor_de_regex_symbol_colecoes :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`/a/.constructor === RegExp`).(bool), true)
    testing.expect_value(t, run(`Symbol().constructor === Symbol`).(bool), true)
    testing.expect_value(t, run(`new Map().constructor === Map`).(bool), true)
    testing.expect_value(t, run(`new Set().constructor === Set`).(bool), true)
    testing.expect_value(t, run(`new WeakMap().constructor === WeakMap`).(bool), true)
}

@(test)
m133_o_padrao_que_quebrava_os_portais :: proc(t: ^testing.T) {
    // `entity.constructor.toString()` com entity primitivo — o erro compartilhado
    // por 6 portais brasileiros no corpus.
    src := `
        var entity = "texto";
        entity.constructor.toString().indexOf("function") === 0 ? "ok" : "falhou"
    `
    testing.expect_value(t, run(src).(string), "ok")
}

@(test)
m133_instancia_de_classe_tem_o_construtor_certo :: proc(t: ^testing.T) {
    // NÃO-REGRESSÃO: o fallback p/ Object só vale quando NADA na cadeia define
    // `constructor`. Uma instância de classe tem que achar a classe, não Object.
    src := `
        class Minha {}
        var m = new Minha();
        (m.constructor === Minha && m.constructor !== Object) ? "ok" : "falhou"
    `
    testing.expect_value(t, run(src).(string), "ok")
}

@(test)
m133_constructor_name_funciona :: proc(t: ^testing.T) {
    // `x.constructor.name` é o idioma de type-check mais comum depois do typeof.
    testing.expect_value(t, run(`"x".constructor.name`).(string), "String")
    testing.expect_value(t, run(`(1).constructor.name`).(string), "Number")
}

// ── Function.prototype.toString estava CORROMPIDA ────────────────────────────

@(test)
m133_fn_tostring_nao_tem_lixo_de_formato :: proc(t: ^testing.T) {
    // O fmt do Odin trata `{`/`}` como diretiva: o template
    // "function %s() { [native code] }" saía como
    // "function foo() %!(MISSING ARGUMENT)%!(MISSING CLOSE BRACE)[native code] }".
    got := run(`(function foo(){}).toString()`).(string)
    testing.expectf(t, !strings.contains(got, "MISSING"), "sem lixo de formato (got=%s)", got)
    testing.expect_value(t, got, "function foo() { [native code] }")
}

@(test)
m133_fn_tostring_passa_no_feature_detect_de_nativo :: proc(t: ^testing.T) {
    // `/\[native code\]/.test(fn.toString())` é o detect clássico de função nativa
    // (core-js e afins decidem por ele se envolvem o builtin).
    testing.expect_value(t, run(`/\[native code\]/.test(String.toString())`).(bool), true)
}
