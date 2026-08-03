package ui

// caret-color (css-ui §4).
//
// ⚠️ Só o PARSE é afirmável aqui. O caret existe apenas com FOCO, e o headless
// não tem foco — a pintura foi verificada dirigindo o app de verdade
// (clique real no campo + F9 → capture.png), varrendo a coluna do caret.
// É a mesma situação do scroll-behavior (lote 9) e do arraste do resize (33).
//
// ⚠️⚠️ O valor `auto` tem de deixar `has_caret` FALSO, não gravar a cor do
// texto: "sem override" é exatamente o que o ImGui já faz sozinho, e é o que
// mantém o caret seguindo o `color` quando ele muda.

import "core:testing"

@(test)
test_caret_color_parse :: proc(t: ^testing.T) {
    c1 := test_apply(`caret-color: #ff0000`)
    testing.expect(t, c1.has_caret && c1.caret_color == 0xff0000, "cor explícita")

    c2 := test_apply(`caret-color: auto`)
    testing.expect(t, !c2.has_caret, "`auto` = sem override (o padrão já é a cor do texto)")

    c3 := test_apply(`color: #123456`)
    testing.expect(t, !c3.has_caret, "sem a prop não há override")

    // nome de cor e rgb() funcional
    c4 := test_apply(`caret-color: rebeccapurple`)
    testing.expect(t, c4.has_caret && c4.caret_color == 0x663399, "cor por NOME")
    c5 := test_apply(`caret-color: rgb(0 128 0)`)
    testing.expectf(t, c5.has_caret && c5.caret_color == 0x008000, "rgb() sem vírgula; veio %x", c5.caret_color)

    // valor inválido não declara nada
    c6 := test_apply(`caret-color: banana`)
    testing.expect(t, !c6.has_caret, "valor inválido não pode marcar como declarado")
}

@(test)
test_caret_color_currentcolor :: proc(t: ^testing.T) {
    // ⚠️ o caso que motivou a ORDEM do parse: `currentColor` resolve contra o
    // `color` da MESMA regra. Se o bloco do caret rodasse ANTES do de `color`,
    // aqui sairia a cor HERDADA (preto) em vez do vermelho declarado ao lado.
    c := test_apply(`color: #ff0000; caret-color: currentColor`)
    testing.expectf(t, c.has_caret && c.caret_color == 0xff0000,
        "currentColor = o `color` da mesma regra; veio %x", c.caret_color)

    // CONTRA-CASO: sem `color` na regra, currentColor cai no valor herdado
    c2 := test_apply(`caret-color: currentColor`)
    testing.expectf(t, c2.has_caret && c2.caret_color == c2.color,
        "sem color na regra, currentColor = o herdado; veio %x vs %x", c2.caret_color, c2.color)
}

@(test)
test_caret_color_herda :: proc(t: ^testing.T) {
    // caret-color HERDA (como `color`): declarada no pai, vale no <input> filho.
    // É o que faz `body{caret-color:…}` funcionar, que é como os sites usam.
    c := test_compute_one(`div { caret-color: #00c000 }`, "div")
    testing.expect(t, c.has_caret && c.caret_color == 0x00c000, "declarada no próprio nó")

    // o teste de herança de verdade precisa de árvore: o filho SEM a prop tem
    // de receber a do pai (é o bloco de reset das NÃO-herdadas que decidiria o
    // contrário, e caret-color não pode estar lá)
    inh := test_apply_over(computed_com_caret(0x00c000), `font-size: 12px`)
    testing.expectf(t, inh.has_caret && inh.caret_color == 0x00c000,
        "outra declaração não pode APAGAR o caret herdado; veio set=%v %x", inh.has_caret, inh.caret_color)
}

// Um Computed "vindo do pai" com caret-color já definido. `computed_initial` é
// `@(private="file")` no style.odin, então parte-se do que o test_apply produz.
@(private = "file")
computed_com_caret :: proc(col: u32) -> Computed {
    c := test_apply(`caret-color: #00c000`)
    c.caret_color = col
    c.has_caret = true
    return c
}
