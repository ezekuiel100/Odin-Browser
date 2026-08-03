package js

// M165 — Object.is(+0,-0) e Array.isArray(arguments).
//
// As duas últimas divergências "de uma linha" da campanha de sondas.
//
//   (1) Object.is é o SameValue da spec: como `===` mas com DUAS diferenças, e o
//       motor só tinha uma. NaN igual a NaN já valia; +0 diferente de -0 não —
//       o `==` do Odin sobre f64 segue o IEEE, onde +0 == -0. A distinção mora no
//       bit de sinal. NÃO confundir com SameValueZero (Map/Set/includes), onde os
//       dois zeros são o MESMO valor de propósito — há teste fixando isso.
//
//   (2) `arguments` é um ^Array por dentro (é o que faz
//       `Array.prototype.slice.call(arguments)` funcionar), mas o JS tem de vê-lo
//       como Arguments. `Array.isArray(x) ? x : slice.call(x)` é idioma comum em
//       lib: responder true mandava o arguments pelo ramo errado.

import "core:testing"

// ── (1) Object.is ────────────────────────────────────────────────────────────

@(test)
m165_object_is_distingue_os_zeros :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`Object.is(0, -0)`).(bool), false)
    testing.expect_value(t, run(`Object.is(-0, 0)`).(bool), false)
    testing.expect_value(t, run(`Object.is(-0, -0)`).(bool), true)
    testing.expect_value(t, run(`Object.is(0, 0)`).(bool), true)
    // o zero negativo tem de sobreviver ao cálculo que o produz
    testing.expect_value(t, run(`Object.is(-1 * 0, -0)`).(bool), true)
    testing.expect_value(t, run(`Object.is(0 * -1, 0)`).(bool), false)
}

@(test)
m165_object_is_resto_inalterado :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`Object.is(NaN, NaN)`).(bool), true)   // ≠ do ===
    testing.expect_value(t, run(`Object.is(1, 1)`).(bool), true)
    testing.expect_value(t, run(`Object.is(1, 2)`).(bool), false)
    testing.expect_value(t, run(`Object.is("a", "a")`).(bool), true)
    testing.expect_value(t, run(`Object.is("a", "b")`).(bool), false)
    testing.expect_value(t, run(`Object.is(null, null)`).(bool), true)
    testing.expect_value(t, run(`Object.is(undefined, undefined)`).(bool), true)
    testing.expect_value(t, run(`Object.is(null, undefined)`).(bool), false)
    testing.expect_value(t, run(`Object.is({}, {})`).(bool), false)     // identidade
    testing.expect_value(t, run(`var o = {}; Object.is(o, o)`).(bool), true)
    testing.expect_value(t, run(`Object.is(1, "1")`).(bool), false)     // sem coerção
    testing.expect_value(t, run(`Object.is(Infinity, Infinity)`).(bool), true)
    testing.expect_value(t, run(`Object.is(Infinity, -Infinity)`).(bool), false)
}

@(test)
m165_same_value_zero_nao_mudou :: proc(t: ^testing.T) {
    // Map/Set e includes usam SameValueZero, onde +0 e -0 são o MESMO valor —
    // é a diferença deliberada em relação ao Object.is acima.
    testing.expect_value(t, as_number(run(`var m = new Map(); m.set(0, "a"); m.set(-0, "b"); m.size`)), f64(1))
    testing.expect_value(t, run(`var m = new Map(); m.set(0, "a"); m.get(-0)`).(string), "a")
    testing.expect_value(t, as_number(run(`new Set([0, -0]).size`)), f64(1))
    testing.expect_value(t, run(`[0].includes(-0)`).(bool), true)
    // `includes` compara por SameValueZero — é o que o separa do indexOf, e era
    // um `==` de union (NaN != NaN pelo IEEE), então este caso falhava calado.
    testing.expect_value(t, run(`[NaN].includes(NaN)`).(bool), true)
    testing.expect_value(t, as_number(run(`[NaN].indexOf(NaN)`)), f64(-1)) // indexOf usa ===
    testing.expect_value(t, run(`[1,2].includes(2)`).(bool), true)
    testing.expect_value(t, run(`[1,2].includes(3)`).(bool), false)
    testing.expect_value(t, run(`["a"].includes("a")`).(bool), true)
    testing.expect_value(t, run(`var o={}; [o].includes(o)`).(bool), true)
    testing.expect_value(t, run(`[{}].includes({})`).(bool), false) // identidade
    // e o === segue o IEEE (os dois zeros iguais)
    testing.expect_value(t, run(`0 === -0`).(bool), true)
}

// ── (2) arguments não é Array ────────────────────────────────────────────────

@(test)
m165_is_array_de_arguments :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`(function(){ return Array.isArray(arguments) })(1,2)`).(bool), false)
    testing.expect_value(t, run(`(function(){ return Object.prototype.toString.call(arguments) })(1)`).(string), "[object Arguments]")
    // array de verdade segue sendo array
    testing.expect_value(t, run(`Array.isArray([])`).(bool), true)
    testing.expect_value(t, run(`Array.isArray([1,2])`).(bool), true)
    testing.expect_value(t, run(`Object.prototype.toString.call([])`).(string), "[object Array]")
    testing.expect_value(t, run(`Array.isArray({})`).(bool), false)
    testing.expect_value(t, run(`Array.isArray("abc")`).(bool), false)
    // e o array DERIVADO de arguments é um array normal
    testing.expect_value(t, run(`(function(){ return Array.isArray(Array.prototype.slice.call(arguments)) })(1)`).(bool), true)
    testing.expect_value(t, run(`(function(){ return Array.isArray(Array.from(arguments)) })(1)`).(bool), true)
    testing.expect_value(t, run(`(function(){ return Array.isArray([...arguments]) })(1)`).(bool), true)
}

@(test)
m165_arguments_continua_utilizavel :: proc(t: ^testing.T) {
    // O ponto delicado: por dentro ele SEGUE um ^Array, senão os idiomas de
    // conversão (que são a razão de alguém tocar em arguments) parariam.
    testing.expect_value(t, as_number(run(`(function(){ return arguments.length })(1,2,3)`)), f64(3))
    testing.expect_value(t, as_number(run(`(function(){ return arguments[1] })(7,8)`)), f64(8))
    testing.expect_value(t, run(`(function(){ return Array.prototype.slice.call(arguments).join(",") })(1,2)`).(string), "1,2")
    testing.expect_value(t, run(`(function(){ return Array.prototype.join.call(arguments, "-") })(1,2)`).(string), "1-2")
    testing.expect_value(t, run(`(function(){ return Array.from(arguments).join(",") })(3,4)`).(string), "3,4")
    testing.expect_value(t, run(`(function(){ return [...arguments].join(",") })(5,6)`).(string), "5,6")
    testing.expect_value(t, as_number(run(`(function(){ var s=0; for (var i=0;i<arguments.length;i++) s+=arguments[i]; return s })(1,2,3)`)), f64(6))
    // o idioma que a mudança conserta: o ramo certo do ternário
    testing.expect_value(t, run(`
        function norm(x){ return Array.isArray(x) ? "era array" : "converti" }
        (function(){ return norm(arguments) })(1)
    `).(string), "converti")
    testing.expect_value(t, run(`(function(){ return typeof arguments })(1)`).(string), "object")
}
