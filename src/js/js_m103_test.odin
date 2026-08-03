package js

import "core:testing"

// M103 — métodos padrão triviais que FALTAVAM e quebravam bundles reais (gap-miner):
//   • String.prototype.substr (Annex B)  — `Math.random().toString(36).substr(2)` (ge/g1.globo)
//   • Array.prototype.toString            — `[a,b].toString()` (techcrunch e cia.)
//   • String.prototype.toString/valueOf   — `x.toString()` sobre valor de tipo desconhecido
// O erro que apareciam era ".substr is not a function" / "(intermediate value).toString
// is not a function". Semântica em CODE POINTS (convenção da engine).

@(test)
m103_substr_basico :: proc(t: ^testing.T) {
    r := run(`"hello world".substr(6)`)
    s, _ := r.(string)
    testing.expectf(t, s == "world", `substr(6) => %q`, s)
}

@(test)
m103_substr_start_length :: proc(t: ^testing.T) {
    r := run(`"hello world".substr(0,5)`)
    s, _ := r.(string)
    testing.expectf(t, s == "hello", `substr(0,5) => %q`, s)
}

@(test)
m103_substr_start_negativo :: proc(t: ^testing.T) {
    r := run(`"hello world".substr(-5)`)
    s, _ := r.(string)
    testing.expectf(t, s == "world", `substr(-5) => %q`, s)
}

@(test)
m103_substr_negativo_com_len :: proc(t: ^testing.T) {
    r := run(`"hello world".substr(-5,3)`)
    s, _ := r.(string)
    testing.expectf(t, s == "wor", `substr(-5,3) => %q`, s)
}

@(test)
m103_substr_len_maior_que_resto :: proc(t: ^testing.T) {
    r := run(`"abc".substr(1,99)`)
    s, _ := r.(string)
    testing.expectf(t, s == "bc", `substr(1,99) => %q`, s)
}

@(test)
m103_substr_len_zero_ou_negativo :: proc(t: ^testing.T) {
    r := run(`"abc".substr(1,0) + "|" + "abc".substr(1,-3)`)
    s, _ := r.(string)
    testing.expectf(t, s == "|", `substr len<=0 => %q`, s)
}

@(test)
m103_substr_code_points :: proc(t: ^testing.T) {
    // 'café' tem 4 code points; substr(2,2) = "fé"
    r := run("\"café\".substr(2,2)")
    s, _ := r.(string)
    testing.expectf(t, s == "fé", `substr code points => %q`, s)
}

@(test)
m103_substr_idioma_id :: proc(t: ^testing.T) {
    // o idioma real: toString(36).substr(2) — só precisa não estourar e dar string
    r := run(`typeof (0.123456).toString(36).substr(2)`)
    s, _ := r.(string)
    testing.expectf(t, s == "string", `idioma de ID => %q`, s)
}

@(test)
m103_array_tostring :: proc(t: ^testing.T) {
    r := run(`[1,2,3].toString()`)
    s, _ := r.(string)
    testing.expectf(t, s == "1,2,3", `array toString => %q`, s)
}

@(test)
m103_array_tostring_vazio :: proc(t: ^testing.T) {
    r := run(`[].toString()`)
    s, ok := r.(string)
    testing.expectf(t, ok && s == "", `array vazio toString => %q`, s)
}

@(test)
m103_string_tostring_valueof :: proc(t: ^testing.T) {
    r := run(`"abc".toString() + "|" + "def".valueOf()`)
    s, _ := r.(string)
    testing.expectf(t, s == "abc|def", `string toString/valueOf => %q`, s)
}

@(test)
m103_tostring_sao_funcoes :: proc(t: ^testing.T) {
    // feature-detect que libs fazem: typeof x.toString === 'function'
    r := run(`(typeof [].toString) + "," + (typeof "".toString) + "," + (typeof "".substr)`)
    s, _ := r.(string)
    testing.expectf(t, s == "function,function,function", `feature-detect => %q`, s)
}
