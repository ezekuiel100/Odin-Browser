package js

// M62 (grupo 4 das sondas): literais numéricos que MISCOMPILAVAM em silêncio —
// separadores 1_000_000 (implementados de verdade, inclusive em hex/bin/frac/
// expoente) e sufixo BigInt 10n (consumido p/ a estrutura parsear certo;
// APROXIMAÇÃO: valor vira number comum). Rodar: odin test src/js

import "core:testing"

@(test)
test_numeric_separator :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`1_000_000`)), f64(1000000))
    testing.expect_value(t, as_number(run(`1_000 + 2_000`)), f64(3000))
    testing.expect_value(t, run(`1_000_000 === 1000000`).(bool), true)
}

@(test)
test_numeric_separator_fraction_exponent :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`1_234.567_8`)), f64(1234.5678))
    testing.expect_value(t, as_number(run(`1e1_0`)), f64(1e10))
}

@(test)
test_numeric_separator_hex_bin :: proc(t: ^testing.T) {
    testing.expect_value(t, as_number(run(`0xFF_FF`)), f64(65535))
    testing.expect_value(t, as_number(run(`0b1010_1010`)), f64(170))
}

@(test)
test_numeric_separator_not_ident :: proc(t: ^testing.T) {
    // regressão: '_' fora de número continua identificador normal
    testing.expect_value(t, as_number(run(`var _000 = 7; _000`)), f64(7))
    testing.expect_value(t, as_number(run(`var a_1 = 3; a_1`)), f64(3))
}

@(test)
test_bigint_literal_structure :: proc(t: ^testing.T) {
    // M87: BigInt REAL — literais viram ^BigInt; aritmética e hex funcionam.
    // Nota: os testes retornam PRIMITIVOS (bool/string) porque run() libera o vm
    // antes de devolver — um ^BigInt devolvido ficaria dangling (como strings).
    testing.expect_value(t, run(`10n === 10n`).(bool), true)
    testing.expect_value(t, run(`(10n + 5n).toString()`).(string), "15")
    testing.expect_value(t, run(`(0xFFn).toString()`).(string), "255")
}

@(test)
test_bigint_typeof_real :: proc(t: ^testing.T) {
    // M87: typeof de BigInt agora é "bigint" (era "number" na aproximação antiga)
    testing.expect_value(t, run(`typeof 10n`).(string), "bigint")
}

@(test)
test_bigint_n_not_greedy :: proc(t: ^testing.T) {
    // `10nx` NÃO consome o n (é ident colado, JS real nem compila); e um
    // ident começando com n logo após número segue funcionando com espaço
    testing.expect_value(t, as_number(run(`var n = 2; 10 * n`)), f64(20))
}
