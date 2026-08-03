package ui

// Lote 26 — `text-wrap: balance` (28 sites, o maior gap real que restava).
//
// ⚠️ ESTE ARQUIVO SÓ TESTA O PARSING/HERANÇA. O efeito (reequilibrar as linhas)
// NÃO é testável em `odin test`: sem atlas de fonte carregado, `word_width` dá 0
// para toda palavra, nada quebra linha e a busca binária vira no-op — um assert
// ali JAMAIS falharia. O efeito foi validado por `--render`
// (tests/manual/text-balance.html, antes-vs-depois com imgdiff 3.04%).

import "core:testing"

@(test)
test_text_wrap_balance_parse :: proc(t: ^testing.T) {
    c := test_compute_one("div{text-wrap:balance}")
    testing.expect(t, c.text_balance, "text-wrap:balance deveria ligar o flag")

    // a forma longhand também
    c2 := test_compute_one("div{text-wrap-style:balance}")
    testing.expect(t, c2.text_balance, "text-wrap-style:balance deveria ligar o flag")

    // valores que NÃO são balance não podem ligar (pretty/stable seguem inertes)
    c3 := test_compute_one("div{text-wrap:pretty}")
    testing.expect(t, !c3.text_balance, "text-wrap:pretty NÃO é balance")
    c4 := test_compute_one("div{text-wrap:wrap}")
    testing.expect(t, !c4.text_balance, "text-wrap:wrap NÃO é balance")

    // e sem declaração nenhuma o flag fica desligado (default)
    c5 := test_compute_one("div{color:red}")
    testing.expect(t, !c5.text_balance, "sem text-wrap o flag deveria ficar desligado")
}
