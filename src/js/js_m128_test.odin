package js

// M128 — ToPrimitive ligado aos operadores. A maquinaria (`to_primitive`/`to_number`)
// já existia e era spec-correct, mas `binop` chamava `as_number` CRU e as conversões
// para texto usavam `to_text` (o formatador de DEBUG do console.log). Resultado: uma
// dúzia de sintomas silenciosos — sem exceção, só valor errado.
//
// O mais caro na prática era aritmética de DATAS: `fim - inicio` dava NaN.

import "core:testing"

// ── datas: o idioma mais comum ────────────────────────────────────────────────

@(test)
m128_subtracao_de_datas :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`new Date(3000) - new Date(1000)`).(f64), 2000)
}

@(test)
m128_comparacao_de_datas :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`new Date(1000) < new Date(3000)`).(bool), true)
    testing.expect_value(t, run(`new Date(3000) > new Date(1000)`).(bool), true)
}

@(test)
m128_number_e_unario_de_data :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`Number(new Date(3000))`).(f64), 3000)
    testing.expect_value(t, run(`+new Date(3000)`).(f64), 3000)
}

@(test)
m128_data_mais_string_usa_hint_string :: proc(t: ^testing.T) {
    // @@toPrimitive default de Date é STRING: `data + ""` dá a data por extenso,
    // não o timestamp. É o que distingue `+` dos demais operadores aritméticos.
    src := `var s = new Date(0) + ""; s.indexOf("1970") >= 0 && s !== "0"`
    testing.expect_value(t, run(src).(bool), true)
}

// ── valueOf / toString custom ─────────────────────────────────────────────────

@(test)
m128_valueof_em_aritmetica :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`var o={valueOf:function(){return 42}}; o * 1`).(f64), 42)
    testing.expect_value(t, run(`var o={valueOf:function(){return 42}}; o + 1`).(f64), 43)
    testing.expect_value(t, run(`var o={valueOf:function(){return 42}}; +o`).(f64), 42)
    testing.expect_value(t, run(`var o={valueOf:function(){return 42}}; -o`).(f64), -42)
}

@(test)
m128_valueof_em_relacional :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`var o={valueOf:function(){return 42}}; o > 10`).(bool), true)
}

@(test)
m128_tostring_em_concat_e_template :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`var s={toString:function(){return "abc"}}; s + ""`).(string), "abc")
    testing.expect_value(t, run("var s={toString:function(){return \"abc\"}}; `${s}`").(string), "abc")
    testing.expect_value(t, run(`var s={toString:function(){return "abc"}}; String(s)`).(string), "abc")
}

@(test)
m128_symbol_toprimitive_tem_precedencia :: proc(t: ^testing.T) {
    // @@toPrimitive vence valueOf E toString (spec).
    src := `
        var o = { valueOf: function(){ return 1 }, toString: function(){ return "x" } };
        o[Symbol.toPrimitive] = function(hint){ return hint === "number" ? 99 : "NOVENTA" };
        (o * 1) === 99 && (o + "") === "NOVENTA"
    `
    testing.expect_value(t, run(src).(bool), true)
}

// ── array → string (era representação de DEBUG) ───────────────────────────────

@(test)
m128_array_vira_string_com_virgula :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`"x" + [1,2]`).(string), "x1,2")
    testing.expect_value(t, run(`String([1,2,3])`).(string), "1,2,3")
    testing.expect_value(t, run(`[] + []`).(string), "")
}

@(test)
m128_join_usa_tostring_e_pula_nulos :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`[{toString:function(){return "a"}}].join("")`).(string), "a")
    // spec: null/undefined viram string VAZIA no join
    testing.expect_value(t, run(`[1,null,undefined,2].join("-")`).(string), "1---2")
}

@(test)
m128_objeto_simples_em_concat :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`1 + {}`).(string), "1[object Object]")
}

// ── JSON.stringify: hook toJSON ───────────────────────────────────────────────

@(test)
m128_json_usa_tojson :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`JSON.stringify({toJSON:function(){return 5}})`).(string), "5")
    testing.expect_value(t, run(`JSON.stringify([{toJSON:function(){return 1}}])`).(string), "[1]")
}

@(test)
m128_json_serializa_data_como_iso :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`JSON.stringify(new Date(0))`).(string), `"1970-01-01T00:00:00.000Z"`)
    testing.expect_value(t, run(`JSON.stringify({d:new Date(0)})`).(string), `{"d":"1970-01-01T00:00:00.000Z"}`)
}

@(test)
m128_json_tojson_aninhado_nao_recursiona :: proc(t: ^testing.T) {
    // toJSON aplicado UMA vez por valor: devolver `this` não pode dar laço infinito.
    src := `var o = { a: 1 }; o.toJSON = function(){ return { a: 2 } }; JSON.stringify(o)`
    testing.expect_value(t, run(src).(string), `{"a":2}`)
}

// ── não-regressão: primitivos e o caminho quente ──────────────────────────────

@(test)
m128_primitivos_intactos :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`1 + 2`).(f64), 3)
    testing.expect_value(t, run(`"a" + "b"`).(string), "ab")
    testing.expect_value(t, run(`"a" + 1`).(string), "a1")
    testing.expect_value(t, run(`3 - 1`).(f64), 2)
    testing.expect_value(t, run(`2 < 3`).(bool), true)
    testing.expect_value(t, run(`"a" < "b"`).(bool), true)
    testing.expect_value(t, run(`null + 1`).(f64), 1)
    // `undefined + 1` é NaN NUMÉRICO (não a string "NaN") — minha expectativa
    // original estava errada, não o motor.
    testing.expect_value(t, run(`String(undefined + 1)`).(string), "NaN")
}

@(test)
m128_console_mantem_texto_de_debug :: proc(t: ^testing.T) {
    // A conversão de DEBUG (to_text) tinha que continuar existindo para o console:
    // é ela que mostra "Error: msg" no log de exceção. Aqui só garantimos que o
    // caminho de erro segue formatando com name+message.
    testing.expect_value(t, run(`String(new Error("x"))`).(string), "Error: x")
}
