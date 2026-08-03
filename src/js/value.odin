package js

import "core:math"
import "core:strconv"
import "core:strings"

// Um valor JavaScript.
//
// A union "vazia" (nil) é o nosso `undefined`. `null` é um marcador próprio
// (JS_Null), porque em JS `null` e `undefined` são valores distintos.
JS_Null :: struct {}

Value :: union {
    f64,
    bool,
    string,
    JS_Null,
    ^Function, // função (definida em interp.odin) — user-defined ou nativa
    ^Object,   // objeto { ... }
    ^Array,    // array [ ... ]
    ^Regex,    // expressão regular (definida em regex.odin)
    ^Collection, // Map/Set/WeakMap/WeakSet (definida em collections.odin)
    ^Symbol,   // Symbol / Symbol.for (definida em symbol.odin) — identidade = ponteiro
    ^BigInt,   // inteiro de precisão arbitrária (definida em bigint.odin)
}

// ToNumber (spec): number vira ele mesmo; bool -> 1/0; null -> 0;
// undefined -> NaN; string: whitespace aparado, "" -> 0, "Infinity" -> ±inf,
// 0x/0b/0o -> inteiro, inválida -> NaN; objetos -> NaN (arrays: [] -> 0,
// [x] -> ToNumber(x), como o ToPrimitive real produziria).
as_number :: proc(v: Value) -> f64 {
    switch x in v {
    case f64:
        return x
    case bool:
        return 1 if x else 0
    case string:
        return str_to_number(x)
    case JS_Null:
        return 0
    case ^Array:
        // ToPrimitive: String([])="" -> 0; String([x])=String(x) -> ToNumber(x)
        if len(x.items) == 0 do return 0
        if len(x.items) == 1 do return as_number(x.items[0])
        return math.nan_f64()
    case ^BigInt:
        return bigint_to_f64(x) // Number(1n)===1 (ToNumber de BigInt é permitido aqui)
    case ^Function, ^Object, ^Regex, ^Collection, ^Symbol:
        return math.nan_f64() // "[object Object]" não é número
    case:
        return math.nan_f64() // undefined
    }
}

// ToNumber de string (spec StringToNumber): base do as_number e do Number().
@(private = "file")
str_to_number :: proc(s: string) -> f64 {
    t := strings.trim_space(s)
    if len(t) == 0 do return 0
    // prefixos de base (sem sinal, como na spec)
    if len(t) > 2 && t[0] == '0' {
        c := t[1]
        if c == 'x' || c == 'X' || c == 'b' || c == 'B' || c == 'o' || c == 'O' {
            n, ok := strconv.parse_int(t, 0)
            return f64(n) if ok else math.nan_f64()
        }
    }
    body := t
    neg := false
    if len(body) > 0 && (body[0] == '+' || body[0] == '-') {
        neg = body[0] == '-'
        body = body[1:]
    }
    if body == "Infinity" do return math.inf_f64(-1) if neg else math.inf_f64(1)
    n, ok := strconv.parse_f64(t)
    return n if ok else math.nan_f64()
}

// ToInteger prático p/ índices e contagens: NaN -> 0 (charAt() sem arg etc.),
// ±Infinity clampado p/ um valor grande finito (evita int(inf), que é UB).
as_int :: proc(v: Value) -> int {
    n := as_number(v)
    if n != n do return 0 // NaN
    LIM :: 1 << 53
    if n > LIM do return LIM
    if n < -LIM do return -LIM
    return int(n)
}

is_string :: proc(v: Value) -> bool {
    _, ok := v.(string)
    return ok
}

// null OU undefined — o gatilho do curto-circuito de `?.` e `??`.
is_nullish :: proc(v: Value) -> bool {
    if v == nil do return true // undefined
    _, is_null := v.(JS_Null)
    return is_null
}

// Truthiness do JS: undefined/null/0/NaN/"" são falsos; o resto é verdadeiro.
truthy :: proc(v: Value) -> bool {
    switch x in v {
    case f64:
        return x != 0 && x == x // 0 e NaN são falsy (NaN != NaN em IEEE)
    case bool:
        return x
    case string:
        return len(x) > 0
    case JS_Null:
        return false
    case ^BigInt:
        return !bigint_is_zero(x) // 0n é falsy; demais BigInts truthy
    case ^Function, ^Object, ^Array, ^Regex, ^Collection, ^Symbol:
        return true // funções/objetos/arrays/regex/coleções/símbolos são sempre truthy
    case:
        return false // undefined
    }
}
