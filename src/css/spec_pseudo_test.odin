package css

// M240 — ESPECIFICIDADE de pseudo-classe. Sonda antes de conserto: cada caso
// aqui declara o número que a spec manda (Selectors 4 §17), e o que falhar é o
// buraco medido.
//
// Origem: a sonda de cascata (CASCADEPROBE) no "Skip to content" do github.
// `.show-on-focus:not(:focus)` imprimia spec=10 — devia ser 20 — e por isso
// perdia para um utilitário `.tmp-py-4` de classe única.

import "core:testing"
import "core:fmt"
import "core:strings"

@(private = "file")
spec_de :: proc(sel: string) -> int {
    // ⚠️ NÃO use fmt.tprintf aqui: o `{` do corpo CSS é chave de FORMATAÇÃO no
    // Odin e a string sai como `a:hover%!(MISSING ARGUMENT)…`. O parser devolve
    // zero regras e todo caso "falha" — inclusive os que já funcionavam. Foi o
    // controle conhecido (`.x:not(.y)` = 20, que o test_parse_not já afirma) dar
    // -1 junto que denunciou a SONDA em vez do motor.
    src := strings.concatenate({sel, "{color:red}"}, context.temp_allocator)
    rules, _ := parse(src)
    defer free_rules(&rules)
    if len(rules) == 0 || len(rules[0].selectors) == 0 do return -1
    return rules[0].selectors[0].spec
}

@(private = "file")
checa :: proc(t: ^testing.T, sel: string, esperado: int, porque: string) {
    got := spec_de(sel)
    testing.expect(t, got == esperado,
        fmt.tprintf("`%s`: esperava spec=%d (%s), veio %d", sel, esperado, porque, got))
}

// ── :hover/:focus/:active são pseudo-CLASSES: valem 10 ───────────────────────
//
// ⚠️ compound_spec não somava NADA por `state`. `a:hover` valia 1, igual a `a`
// puro — e quem decidia era a ordem no arquivo. Funciona por acidente quando o
// autor põe o `:hover` depois; quebra assim que a regra concorrente é de classe.

@(test)
m240_spec_estado :: proc(t: ^testing.T) {
    checa(t, "a:hover",  11, "a(1) + :hover(10)")
    checa(t, "a:focus",  11, "a(1) + :focus(10)")
    checa(t, "a:active", 11, "a(1) + :active(10)")
    checa(t, ":hover",   10, "pseudo-classe solta")
    // focus-visible/focus-within também são pseudo-classes (viram state Focus)
    checa(t, "a:focus-visible", 11, "a(1) + :focus-visible(10)")
    checa(t, ".btn:hover", 20, "classe(10) + :hover(10)")
}

@(test)
m240_estado_bate_classe_dupla :: proc(t: ^testing.T) {
    // O caso que importa na prática: `.btn:hover` (20) tem de PERDER para
    // `.btn.primary` (20)? Não — empata, e ganha o mais tarde. Mas tem de
    // GANHAR de `.primary` sozinha (10). Antes valia 10 e empatava com ela.
    testing.expect(t, spec_de(".btn:hover") > spec_de(".primary"),
        "estado tem de somar: .btn:hover deve bater .primary")
}

// ── :dir() é pseudo-classe ──────────────────────────────────────────────────

@(test)
m240_spec_dir :: proc(t: ^testing.T) {
    checa(t, "p:dir(rtl)", 11, "p(1) + :dir(10)")
}

// ── :not()/:is()/:has(): a spec é a do argumento MAIS específico, não a SOMA ──
//
// Selectors 4 §17: "The specificity of an :is(), :not(), or :has() pseudo-class
// is replaced by the specificity of the most specific complex selector in its
// selector list argument." O `:is` já fazia máx; `:not` e `:has` somavam.

@(test)
m240_spec_not_e_has_sao_maximo :: proc(t: ^testing.T) {
    checa(t, ".x:not(.a, #b)", 110, "classe(10) + máx(.a=10, #b=100)")
    checa(t, "div:has(.a, #b)", 101, "div(1) + máx(.a=10, #b=100)")
    // CONTROLE: com UM argumento, soma e máximo coincidem — é por isso que o
    // teste antigo (`.x:not(.y)` = 20) passava dos dois lados.
    checa(t, ".x:not(.y)", 20, "classe(10) + :not(.y)(10)")
}

// ── o buraco do github: argumento que NÃO sabemos avaliar ───────────────────
//
// `:not(:focus)` não restringe nada que a gente saiba checar num render
// estático, então a APROXIMAÇÃO de matching (ignorar a negação e deixar a regra
// ativa) fica. Mas ignorar o argumento também zerava a ESPECIFICIDADE dele, e
// isso não é aproximação — é erro puro: a spec conta o argumento tenha o motor
// avaliado ou não.

@(test)
m240_spec_not_de_argumento_ignorado :: proc(t: ^testing.T) {
    checa(t, ".show-on-focus:not(:focus)", 20, "classe(10) + :not(:focus)(10)")
    checa(t, "a:not(:hover)", 11, "a(1) + :not(:hover)(10)")
    // mistura: o argumento avaliável e o ignorado disputam o máximo
    checa(t, ".x:not(:focus, #big)", 110, "classe(10) + máx(:focus=10, #big=100)")
}

@(test)
m240_not_ignorado_ainda_casa :: proc(t: ^testing.T) {
    // ⚠️ SABOTAGEM DIRIGIDA: dar especificidade não pode virar restrição. A
    // regra `.show-on-focus:not(:focus)` tem de seguir CASANDO o elemento não
    // focado — se o conserto de spec derrubasse o matching, o link do github
    // sumiria em vez de aparecer no lugar certo.
    rules, _ := parse(".show-on-focus:not(:focus){color:red}")
    defer free_rules(&rules)
    testing.expect(t, len(rules) == 1 && len(rules[0].selectors) == 1, "parseou")
    if len(rules) != 1 do return
    sel := rules[0].selectors[0]
    tgt := sel.parts[len(sel.parts) - 1]
    testing.expect(t, !tgt.pseudo_only, "não pode virar casa-nada")
    testing.expect(t, !tgt.never, "não pode virar casa-nada")
    testing.expect(t, len(tgt.nots) == 0, "o argumento segue não avaliado (aproximação)")
    testing.expect_value(t, len(tgt.classes), 1)
}
