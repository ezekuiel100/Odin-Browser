package js

import "core:testing"

// ── M87: BigInt real (^BigInt sobre core:math/big) ───────────────────────────
// Literais 123n, BigInt(x), typeof "bigint", aritmética/bitwise/comparações de
// precisão arbitrária. Os testes retornam PRIMITIVOS (bool/string via toString)
// porque run() libera o vm ao retornar — um ^BigInt devolvido ficaria dangling.

// helper de string via expressão
sbig :: proc(src: string) -> string { v, _ := run(src).(string); return v }

// ── typeof / literais ────────────────────────────────────────────────────────

@(test)
test_bigint_typeof :: proc(t: ^testing.T) {
    testing.expect(t, sbig(`typeof 123n`) == "bigint", "typeof 123n deve ser 'bigint'")
}

@(test)
test_bigint_string_sem_n :: proc(t: ^testing.T) {
    testing.expect(t, sbig(`String(42n)`) == "42", "String(42n) deve ser '42' (sem o 'n')")
    testing.expect(t, sbig(`("" + 7n)`) == "7", "concat de BigInt deve dar os dígitos")
}

// ── aritmética ───────────────────────────────────────────────────────────────

@(test)
test_bigint_arit :: proc(t: ^testing.T) {
    testing.expect(t, sbig(`(10n + 5n).toString()`) == "15", "soma")
    testing.expect(t, sbig(`(10n - 5n).toString()`) == "5", "subtração")
    testing.expect(t, sbig(`(10n * 5n).toString()`) == "50", "multiplicação")
    testing.expect(t, sbig(`(2n ** 10n).toString()`) == "1024", "potência")
}

// divisão TRUNCA em direção a zero.
@(test)
test_bigint_div_trunca :: proc(t: ^testing.T) {
    testing.expect(t, sbig(`(7n / 2n).toString()`) == "3", "7n/2n = 3n (trunca)")
    testing.expect(t, sbig(`(-7n / 2n).toString()`) == "-3", "-7n/2n = -3n (trunca p/ zero)")
}

// resto com sinal do DIVIDENDO (não floored).
@(test)
test_bigint_mod_sinal :: proc(t: ^testing.T) {
    testing.expect(t, sbig(`(-7n % 3n).toString()`) == "-1", "-7n%3n = -1n (sinal do dividendo)")
    testing.expect(t, sbig(`(7n % 3n).toString()`) == "1", "7n%3n = 1n")
}

// PRECISÃO ARBITRÁRIA: além de 2^53 (onde f64 perde precisão).
@(test)
test_bigint_precisao :: proc(t: ^testing.T) {
    // 2^53 = 9007199254740992; +1 exato só com BigInt
    testing.expect(t, sbig(`(9007199254740992n + 1n).toString()`) == "9007199254740993", "exato além de 2^53")
    // 20! não cabe em f64 exato
    testing.expect(t, sbig(`
        var f = 1n;
        for (var i = 1n; i <= 20n; i++) f *= i;
        f.toString()
    `) == "2432902008176640000", "20! exato com BigInt")
}

// ── erros de aritmética ──────────────────────────────────────────────────────

@(test)
test_bigint_div_zero :: proc(t: ^testing.T) {
    src := `var e=''; try { 1n / 0n; } catch(x){ e = x.name; } e`
    testing.expect(t, sbig(src) == "RangeError", "divisão por 0n deve lançar RangeError")
}

@(test)
test_bigint_pow_neg :: proc(t: ^testing.T) {
    src := `var e=''; try { 2n ** -1n; } catch(x){ e = x.name; } e`
    testing.expect(t, sbig(src) == "RangeError", "expoente negativo deve lançar RangeError")
}

@(test)
test_bigint_mix_number :: proc(t: ^testing.T) {
    src := `var e=''; try { 1n + 2; } catch(x){ e = x.name; } e`
    testing.expect(t, sbig(src) == "TypeError", "misturar BigInt e Number em + deve lançar TypeError")
}

@(test)
test_bigint_unary_plus_throws :: proc(t: ^testing.T) {
    src := `var e=''; try { +1n; } catch(x){ e = x.name; } e`
    testing.expect(t, sbig(src) == "TypeError", "unário + em BigInt deve lançar TypeError")
}

// ── bitwise ──────────────────────────────────────────────────────────────────

@(test)
test_bigint_bitwise :: proc(t: ^testing.T) {
    testing.expect(t, sbig(`(12n & 10n).toString()`) == "8", "12n & 10n = 8n")
    testing.expect(t, sbig(`(12n | 10n).toString()`) == "14", "12n | 10n = 14n")
    testing.expect(t, sbig(`(12n ^ 10n).toString()`) == "6", "12n ^ 10n = 6n")
    testing.expect(t, sbig(`(~5n).toString()`) == "-6", "~5n = -6n")
    testing.expect(t, sbig(`(1n << 8n).toString()`) == "256", "1n << 8n = 256n")
    testing.expect(t, sbig(`(256n >> 2n).toString()`) == "64", "256n >> 2n = 64n")
}

// ── unário / negação ─────────────────────────────────────────────────────────

@(test)
test_bigint_neg :: proc(t: ^testing.T) {
    testing.expect(t, sbig(`(-5n).toString()`) == "-5", "negação de BigInt")
    testing.expect(t, sbig(`(- -5n).toString()`) == "5", "dupla negação")
}

// ── comparações ──────────────────────────────────────────────────────────────

@(test)
test_bigint_comparacoes :: proc(t: ^testing.T) {
    testing.expect(t, run(`1n < 2n`).(bool), "1n < 2n")
    testing.expect(t, run(`2n > 1n`).(bool), "2n > 1n")
    testing.expect(t, run(`1n <= 1n`).(bool), "1n <= 1n")
    testing.expect(t, run(`2n >= 2n`).(bool), "2n >= 2n")
}

// comparação MISTA com Number.
@(test)
test_bigint_cmp_number :: proc(t: ^testing.T) {
    testing.expect(t, run(`1n < 2`).(bool), "1n < 2 (Number)")
    testing.expect(t, run(`2n > 1.5`).(bool), "2n > 1.5")
    testing.expect(t, !run(`5n < 3`).(bool), "5n < 3 é falso")
}

// igualdade: == mistura, === exige mesmo tipo.
@(test)
test_bigint_igualdade :: proc(t: ^testing.T) {
    testing.expect(t, run(`1n == 1`).(bool), "1n == 1 (frouxa)")
    testing.expect(t, !run(`1n === 1`).(bool), "1n === 1 é falso (tipos diferentes)")
    testing.expect(t, run(`2n === 2n`).(bool), "2n === 2n")
    testing.expect(t, run(`1n == "1"`).(bool), `1n == "1" (frouxa via string)`)
    testing.expect(t, !run(`1n == 1.5`).(bool), "1n == 1.5 é falso")
}

// ── truthiness ───────────────────────────────────────────────────────────────

@(test)
test_bigint_truthy :: proc(t: ^testing.T) {
    testing.expect(t, sbig(`0n ? "t" : "f"`) == "f", "0n é falsy")
    testing.expect(t, sbig(`5n ? "t" : "f"`) == "t", "5n é truthy")
}

// ── BigInt(x) construtor ─────────────────────────────────────────────────────

@(test)
test_bigint_ctor :: proc(t: ^testing.T) {
    testing.expect(t, sbig(`BigInt("123").toString()`) == "123", "BigInt de string")
    testing.expect(t, sbig(`BigInt(42).toString()`) == "42", "BigInt de number")
    testing.expect(t, sbig(`BigInt(true).toString()`) == "1", "BigInt(true) = 1n")
    testing.expect(t, sbig(`BigInt("0x1F").toString()`) == "31", "BigInt de hex string")
}

@(test)
test_bigint_ctor_erros :: proc(t: ^testing.T) {
    src1 := `var e=''; try { BigInt(1.5); } catch(x){ e=x.name; } e`
    testing.expect(t, sbig(src1) == "RangeError", "BigInt(1.5) deve lançar RangeError")
    src2 := `var e=''; try { BigInt("abc"); } catch(x){ e=x.name; } e`
    testing.expect(t, sbig(src2) == "SyntaxError", "BigInt('abc') deve lançar SyntaxError")
}

// toString(radix).
@(test)
test_bigint_tostring_radix :: proc(t: ^testing.T) {
    testing.expect(t, sbig(`(255n).toString(16)`) == "ff", "255n em base 16")
    testing.expect(t, sbig(`(10n).toString(2)`) == "1010", "10n em base 2")
}

// asUintN / asIntN.
@(test)
test_bigint_as_n :: proc(t: ^testing.T) {
    testing.expect(t, sbig(`BigInt.asUintN(8, 258n).toString()`) == "2", "asUintN(8, 258n) = 2n (258 mod 256)")
    testing.expect(t, sbig(`BigInt.asIntN(8, 200n).toString()`) == "-56", "asIntN(8, 200n) = -56n")
}

// ── string concat ────────────────────────────────────────────────────────────

@(test)
test_bigint_concat :: proc(t: ^testing.T) {
    testing.expect(t, sbig(`1n + "x"`) == "1x", "BigInt + string = concat")
    testing.expect(t, sbig(`"x" + 1n`) == "x1", "string + BigInt = concat")
}

// ── JSON ─────────────────────────────────────────────────────────────────────

@(test)
test_bigint_json_throws :: proc(t: ^testing.T) {
    src := `var e=''; try { JSON.stringify(1n); } catch(x){ e=x.name; } e`
    testing.expect(t, sbig(src) == "TypeError", "JSON.stringify(BigInt) deve lançar TypeError")
}

// ── Map/Set com chaves BigInt (SameValueZero por VALOR) ──────────────────────

@(test)
test_bigint_map_key :: proc(t: ^testing.T) {
    src := `
        var m = new Map();
        m.set(1n, "a");
        m.set(2n, "b");
        m.get(1n) + m.get(2n) + ':' + m.has(1n) + ':' + m.size
    `
    testing.expect(t, sbig(src) == "ab:true:2", "BigInt como chave de Map (por valor)")
}

@(test)
test_bigint_set_dedup :: proc(t: ^testing.T) {
    // 1n e 1n são a MESMA chave → Set não duplica
    src := `var s = new Set(); s.add(1n); s.add(1n); s.add(2n); s.size.toString()`
    testing.expect(t, sbig(src) == "2", "Set deve deduplicar BigInts iguais")
}
