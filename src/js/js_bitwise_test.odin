package js

// Testes dos operadores bitwise (& | ^ ~ << >> >>>), seus compostos
// (&= |= ^= <<= >>= >>>=) e o unário + — adicionados após o M25.
// Semântica JS: operam sobre inteiros de 32 bits (ToInt32/ToUint32).

import "core:testing"

@(test)
test_bit_and :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("12 & 10")), f64(8))   // 1100 & 1010 = 1000
}

@(test)
test_bit_or :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("12 | 10")), f64(14))  // 1100 | 1010 = 1110
}

@(test)
test_bit_xor :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("12 ^ 10")), f64(6))   // 1100 ^ 1010 = 0110
}

@(test)
test_bit_not :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("~0")), f64(-1))       // ~x == -(x+1)
    testing.expect_value(t, as_number(run("~5")), f64(-6))
}

@(test)
test_shl :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("1 << 4")), f64(16))
    testing.expect_value(t, as_number(run("1 << 31")), f64(-2147483648)) // sinal: vira negativo
}

@(test)
test_shr :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("256 >> 4")), f64(16))
    testing.expect_value(t, as_number(run("-8 >> 1")), f64(-4))  // aritmético preserva sinal
}

@(test)
test_ushr :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("-1 >>> 0")), f64(4294967295)) // zero-fill: unsigned
    testing.expect_value(t, as_number(run("256 >>> 4")), f64(16))
}

@(test)
test_shift_mask :: proc(t: ^testing.T) {
    // a contagem de shift é mascarada aos 5 bits baixos: 32 & 31 == 0
    testing.expect_value(t, as_number(run("1 << 32")), f64(1))
    testing.expect_value(t, as_number(run("1 << 33")), f64(2))
}

@(test)
test_bit_truncation :: proc(t: ^testing.T) {
    // ToInt32 trunca a parte fracionária antes de operar
    testing.expect_value(t, as_number(run("6.9 & 3")), f64(2))     // 6 & 3
    testing.expect_value(t, as_number(run("NaN | 0")), f64(0))     // NaN → 0
}

@(test)
test_bit_precedence :: proc(t: ^testing.T) {
    // igualdade liga mais forte que &: 1 & (3==3) == 1 & 1 == 1
    testing.expect_value(t, as_number(run("1 & 3 == 3")), f64(1))
    // & liga mais forte que ^, que liga mais forte que |
    testing.expect_value(t, as_number(run("1 | 2 ^ 3 & 1")), f64(3)) // 1 | (2 ^ (3&1)) = 1 | (2^1) = 1|3 = 3
}

@(test)
test_bit_compound :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var x = 12; x &= 10; x")), f64(8))
    testing.expect_value(t, as_number(run("var x = 12; x |= 10; x")), f64(14))
    testing.expect_value(t, as_number(run("var x = 12; x ^= 10; x")), f64(6))
    testing.expect_value(t, as_number(run("var x = 1; x <<= 4; x")), f64(16))
    testing.expect_value(t, as_number(run("var x = 256; x >>= 4; x")), f64(16))
    testing.expect_value(t, as_number(run("var x = -1; x >>>= 0; x")), f64(4294967295))
}

@(test)
test_unary_plus :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("+'5'")), f64(5))
    testing.expect_value(t, as_number(run("+true")), f64(1))
    testing.expect_value(t, as_number(run("+'3' + +'4'")), f64(7))
}

@(test)
test_exponent :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("2 ** 10")), f64(1024))
    testing.expect_value(t, as_number(run("2 ** -1")), f64(0.5))     // expoente unário
    testing.expect_value(t, as_number(run("9 ** 0.5")), f64(3))      // raiz
}

@(test)
test_exponent_right_assoc :: proc(t: ^testing.T) {
    // ** é associativa à direita: 2 ** 3 ** 2 == 2 ** 9 == 512 (não 64)
    testing.expect_value(t, as_number(run("2 ** 3 ** 2")), f64(512))
}

@(test)
test_exponent_precedence :: proc(t: ^testing.T) {
    // ** liga mais forte que *: 3 * 2 ** 3 == 3 * 8 == 24
    testing.expect_value(t, as_number(run("3 * 2 ** 3")), f64(24))
}

@(test)
test_exponent_compound :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run("var x = 3; x **= 4; x")), f64(81))
}

@(test)
test_bit_flags :: proc(t: ^testing.T) {
    // padrão idiomático de máscara de flags (o que era silenciosamente descartado antes)
    src := "var R=1, W=2, X=4; var p = R | X; (p & W) === 0 && (p & R) !== 0"
    v, _ := run(src).(bool)
    testing.expect(t, v, "máscara de bits deve funcionar")
}
