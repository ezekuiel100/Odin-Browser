package css

// Media queries de INTERAÇÃO (MQ4 §10): `hover`, `any-hover`, `pointer`, `any-pointer`.
//
// Por que existe: `@media (hover: hover)` é o que o **Tailwind emite para o variant
// `hover:`** — o bloco carrega TODOS os `hover:*` e `group-hover:*` do site. Enquanto
// a feature caía em <general-enclosed>, o bloco inteiro era descartado e o site não
// tinha estilo de hover NENHUM (achado junto do [[M181]], no ultra-photo.com).
//
// Somos uma janela de desktop com mouse ⇒ `hover: hover` e `pointer: fine` casam.
// A parte que exige cuidado é o `not`: a lógica de 3 valores da MQ4 inverte T↔F mas
// MANTÉM U, então "sei avaliar e deu falso" (F) precisa ser distinto de "não sei"
// (U) — daí o campo `no_match` separado do `unknown`.

import "core:testing"

@(private = "file")
aplica :: proc(css: string) -> bool {
    rules, _ := parse(css)
    defer free_rules(&rules)
    for r in rules {
        for s in r.selectors do if len(s.parts) > 0 && s.parts[0].tag == "p" {
            return media_matches(r, 1280, 800)
        }
    }
    return false
}

@(test)
hover_de_desktop_casa :: proc(t: ^testing.T) {
    testing.expect(t,  aplica(`@media (hover: hover) { p{color:red} }`),      "temos hover")
    testing.expect(t, !aplica(`@media (hover: none) { p{color:red} }`),       "nao somos touch")
    testing.expect(t,  aplica(`@media (any-hover: hover) { p{color:red} }`),  "any-hover idem")
    testing.expect(t, !aplica(`@media (any-hover: none) { p{color:red} }`),   "any-hover: none nao")
}

@(test)
pointer_fino_casa :: proc(t: ^testing.T) {
    testing.expect(t,  aplica(`@media (pointer: fine) { p{color:red} }`),       "mouse = ponteiro fino")
    testing.expect(t, !aplica(`@media (pointer: coarse) { p{color:red} }`),     "nao e dedo")
    testing.expect(t, !aplica(`@media (pointer: none) { p{color:red} }`),       "ha ponteiro")
    testing.expect(t,  aplica(`@media (any-pointer: fine) { p{color:red} }`),   "any-pointer idem")
    testing.expect(t, !aplica(`@media (any-pointer: coarse) { p{color:red} }`), "any-pointer: coarse nao")
}

// Contexto BOOLEANO: `(hover)` = "o dispositivo tem hover?".
@(test)
interacao_em_contexto_booleano :: proc(t: ^testing.T) {
    testing.expect(t, aplica(`@media (hover) { p{color:red} }`),   "(hover) = tem hover")
    testing.expect(t, aplica(`@media (pointer) { p{color:red} }`), "(pointer) = tem ponteiro")
}

// O caso que obrigou o `no_match` a existir: `not` inverte F, mas não U.
@(test)
not_inverte_falso_e_preserva_desconhecido :: proc(t: ^testing.T) {
    testing.expect(t,  aplica(`@media not all and (hover: none) { p{color:red} }`),
        "not (hover:none) = T: TEM de aplicar")
    testing.expect(t, !aplica(`@media not all and (hover: hover) { p{color:red} }`),
        "not (hover:hover) = F: nao aplica")
    // U permanece U sob `not` — nao vira T por acidente
    testing.expect(t, !aplica(`@media not all and (banana) { p{color:red} }`),
        "not de feature desconhecida continua sem aplicar")
    // F ganha de U quando as duas aparecem juntas (F AND U = F em Kleene)
    testing.expect(t, !aplica(`@media (hover: none) and (banana) { p{color:red} }`),
        "F com U junto continua nao aplicando")
}

// Valor fora da spec não pode virar "casa" por acidente.
@(test)
valor_de_interacao_invalido_e_desconhecido :: proc(t: ^testing.T) {
    testing.expect(t, !aplica(`@media (hover: banana) { p{color:red} }`),   "valor invalido nao aplica")
    testing.expect(t, !aplica(`@media (pointer: banana) { p{color:red} }`), "valor invalido nao aplica")
}

// Composição: o bloco de hover do Tailwind vem junto com uma condição de largura.
@(test)
hover_compoe_com_largura :: proc(t: ^testing.T) {
    css :: `@media (hover: hover) and (width>=40rem) { p{color:red} }`
    rules, _ := parse(css)
    defer free_rules(&rules)
    testing.expect(t, len(rules) > 0, "regra parseada")
    testing.expect(t,  media_matches(rules[0], 1280), "hover + 1280 >= 640 aplica")
    testing.expect(t, !media_matches(rules[0], 400),  "hover mas 400 < 640 nao aplica")
}
