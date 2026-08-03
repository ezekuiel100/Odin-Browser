package css

// Testes da avaliação de `@supports` (supports.odin).
//
// Dois níveis:
//  1. a GRAMÁTICA, com hook EXPLÍCITO (`supports_condition_with`) — nada é
//     escrito no global `g_prop_supported`, porque o runner de testes roda 16
//     em paralelo e global mutável em teste é a receita de flake deste projeto;
//  2. o WIRING no parser (`parse`), que usa o global. Nos testes do pacote css
//     o global é NIL (o ui é quem o instala), então o caminho "condição falsa"
//     é exercitado por `font-tech()` — que responde NÃO independentemente do
//     hook, porque sem `@font-face` não carregamos fonte nenhuma. O caminho que
//     depende do motor de estilo de verdade está em ui/style_supports_test.odin.

import "core:testing"

// Motor de mentira: conhece só estas três props. Fica no nível de arquivo p/
// ser passável como Prop_Supported_Fn.
@(private = "file")
fake_engine :: proc(prop: string, value: string) -> bool {
    switch prop {
    case "margin", "display", "color": return true
    }
    return false
}

@(private = "file")
sup :: proc(cond: string) -> bool {
    return supports_condition_with(cond, fake_engine)
}

// Alguma regra coletada tem `prop: val`? (o find_rule de css_test.odin é
// private="file"; este é o mesmo predicado, sem devolver a regra.)
@(private = "file")
has_decl :: proc(rules: []Rule, prop, val: string) -> bool {
    for r in rules {
        if v, ok := r.decls[prop]; ok && v == val do return true
    }
    return false
}

@(test)
test_supports_declaracao :: proc(t: ^testing.T) {
    testing.expect(t, sup("(margin: 0)"), "prop conhecida ⇒ true")
    testing.expect(t, sup("( display:grid )"), "espaços em volta não importam")
    testing.expect(t, !sup("(nao-existe: 0)"), "prop desconhecida ⇒ false")
    testing.expect(t, !sup("(margin: 0 !important)"), "!important é inválido em @supports")
    testing.expect(t, !sup("(margin: )"), "valor vazio ⇒ false")
}

@(test)
test_supports_and_or_not :: proc(t: ^testing.T) {
    testing.expect(t, sup("(margin: 0) and (color: red)"), "and de dois verdadeiros")
    testing.expect(t, !sup("(margin: 0) and (nao-existe: 1)"), "and com um falso")
    testing.expect(t, sup("(margin: 0) or (nao-existe: 1)"), "or com um verdadeiro")
    testing.expect(t, !sup("(nao-existe: 1) or (outra-nao: 2)"), "or de dois falsos")
    testing.expect(t, sup("not (nao-existe: 1)"), "not de falso ⇒ true")
    testing.expect(t, !sup("not (margin: 0)"), "not de verdadeiro ⇒ false")
    // é ESTE o caso que motivou o marco: o fallback de progressive enhancement
    // não pode mais ser aplicado por cima do caminho moderno.
    testing.expect(t, !sup("not (display: grid)"), "fallback de `not (display:grid)` NÃO aplica")
    // aninhamento e precedência (and liga mais forte que or)
    testing.expect(t, sup("((margin: 0))"), "parêntese redundante")
    testing.expect(t, sup("(nao-existe: 1) or ((margin: 0) and (color: red))"), "or de and aninhado")
    testing.expect(t, !sup("(margin: 0) and (not (color: red))"), "not aninhado dentro de and")
}

@(test)
test_supports_custom_property :: proc(t: ^testing.T) {
    // O teste clássico de "este navegador tem custom properties?". Nós temos —
    // e o hook nunca é consultado (o fake_engine diria false p/ `--x`).
    testing.expect(t, sup("(--x: 1)"), "custom property ⇒ sempre suportada")
    testing.expect(t, !sup("not (--x: 1)"), "e o `not` dela é falso")
}

@(test)
test_supports_sintaxe_desconhecida_e_permissiva :: proc(t: ^testing.T) {
    // A decisão de projeto: "não sei avaliar" NÃO pode virar "some com o CSS".
    testing.expect(t, sup("bananas(x)"), "função desconhecida no topo ⇒ permissivo")
    testing.expect(t, sup("(sem-dois-pontos)"), "parêntese que não é declaração ⇒ permissivo")
    testing.expect(t, sup("(color: red) and bananas(x)"), "true and não-sei ⇒ permissivo")
    testing.expect(t, sup("bananas(x) or (nao-existe: 1)"), "não-sei or false ⇒ permissivo")
    // ...mas um lado que decide sozinho DECIDE.
    testing.expect(t, !sup("(nao-existe: 1) and bananas(x)"), "false and não-sei = false")
    testing.expect(t, sup("(margin: 0) or bananas(x)"), "true or não-sei = true")
}

@(test)
test_supports_selector :: proc(t: ^testing.T) {
    // `selector()` é respondido pelo PARSER DE SELETOR real, não por chute.
    testing.expect(t, sup("selector(.foo)"), "classe simples: suportada")
    testing.expect(t, sup("selector(a:has(img))"), ":has() nós implementamos")
    testing.expect(t, sup("selector(li:nth-child(2n+1))"), ":nth-child() idem")
    testing.expect(t, sup("selector(div > p + span)"), "combinadores idem")
    // pseudo-elemento que o motor marca como "casa nada" ⇒ honestamente NÃO
    testing.expect(t, !sup("selector(::selection)"), "::selection não é estilizável aqui")
    testing.expect(t, !sup("selector(::marker)"), "::marker idem")
    testing.expect(t, !sup("selector(a, b)"), "lista não é <complex-selector>")
}

@(test)
test_supports_font_tech :: proc(t: ^testing.T) {
    // Sem @font-face não carregamos fonte alguma — e isso é uma resposta que
    // sabemos dar (não é "não sei"), então o `not` dela é TRUE.
    testing.expect(t, !sup("font-tech(color-COLRv1)"), "font-tech ⇒ não suportado")
    testing.expect(t, !sup("font-format(woff2)"), "font-format idem")
    testing.expect(t, sup("not font-tech(color-COLRv1)"), "e o not é true")
}

// ── wiring no parser ────────────────────────────────────────────────────────

@(test)
test_supports_bloco_falso_e_descartado :: proc(t: ^testing.T) {
    rules, _ := parse("@supports font-tech(color-COLRv1) { div { color: red } }")
    defer free_rules(&rules)
    found := has_decl(rules[:], "color", "red")
    testing.expect(t, !found, "condição FALSA ⇒ o bloco inteiro sai (antes entrava sempre)")
}

@(test)
test_supports_bloco_verdadeiro_entra :: proc(t: ^testing.T) {
    rules, _ := parse("@supports not font-tech(color-COLRv1) { div { color: green } }")
    defer free_rules(&rules)
    found := has_decl(rules[:], "color", "green")
    testing.expect(t, found, "condição VERDADEIRA ⇒ o bloco entra")
}

@(test)
test_supports_aninhado_em_regra :: proc(t: ^testing.T) {
    // CSS nesting: antes deste marco o @supports aninhado caía no skip_at_rule
    // e o bloco era descartado SEMPRE — o erro oposto ao do top-level.
    rules, _ := parse(".a { color: red; @supports not font-tech(x) { color: green } }")
    defer free_rules(&rules)
    pai   := has_decl(rules[:], "color", "red")
    filho := has_decl(rules[:], "color", "green")
    testing.expect(t, pai, "as declarações do próprio seletor continuam")
    testing.expect(t, filho, "@supports aninhado com condição VERDADEIRA agora entra")
}

@(test)
test_supports_aninhado_falso_sai :: proc(t: ^testing.T) {
    rules, _ := parse(".a { color: red; @supports font-tech(x) { color: blue } }")
    defer free_rules(&rules)
    blue := has_decl(rules[:], "color", "blue")
    testing.expect(t, !blue, "aninhado com condição FALSA não entra")
}

@(test)
test_supports_media_dentro_e_fora :: proc(t: ^testing.T) {
    // @media dentro de @supports e vice-versa continuam compondo (é o que os
    // reftests at-supports-002/003 do WPT cobrem).
    r1, _ := parse("@media all { @supports not font-tech(x) { div { color: green } } }")
    defer free_rules(&r1)
    f1 := has_decl(r1[:], "color", "green")
    testing.expect(t, f1, "@supports dentro de @media")

    r2, _ := parse("@supports not font-tech(x) { @media all { div { color: green } } }")
    defer free_rules(&r2)
    f2 := has_decl(r2[:], "color", "green")
    testing.expect(t, f2, "@media dentro de @supports")

    r3, _ := parse("@supports font-tech(x) { @media all { div { color: red } } }")
    defer free_rules(&r3)
    f3 := has_decl(r3[:], "color", "red")
    testing.expect(t, !f3, "condição falsa leva o @media interno junto")
}

@(test)
test_supports_sem_bloco_nao_engole_o_resto :: proc(t: ^testing.T) {
    // `@supports (x);` malformado (termina em ';') não pode comer a regra seguinte.
    rules, _ := parse("@supports (margin:0); div { color: red }")
    defer free_rules(&rules)
    found := has_decl(rules[:], "color", "red")
    testing.expect(t, found, "at-rule sem bloco é pulada, a regra seguinte fica")
}
