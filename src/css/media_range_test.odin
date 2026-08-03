package css

// Media queries de RANGE (MQ4): `(width >= 40rem)` no lugar de `(min-width: 40rem)`.
//
// Por que existe: o **Tailwind v4 emite esta grafia por padrão**. Sem suporte, a
// feature não tinha ':', virava <general-enclosed> desconhecida e a lógica de 3
// valores descartava o bloco @media INTEIRO — todo `sm:`/`lg:` sumia e o site
// renderizava o layout MOBILE dentro de um viewport de desktop (grids de 1
// coluna, `.container` sem max-width). Achado no ultra-photo.com, mas atinge
// qualquer site em Tailwind v4.
//
// Mesma família do M172 (ver `src/ui/style_grafia_test.odin`): a FEATURE
// funcionava (média query, grid, container), o que faltava era a ORTOGRAFIA que
// a web moderna usa. Daí o gate abaixo ser de EQUIVALÊNCIA — as duas grafias do
// mesmo limite têm de casar nos mesmos viewports, largura a largura.

import "core:testing"
import "core:fmt"

// Aplica-se a regra `p{}` da folha no viewport de largura vw?
@(private = "file")
aplica :: proc(css: string, vw: f32) -> bool {
    rules, _ := parse(css)
    defer free_rules(&rules)
    for r in rules {
        for s in r.selectors do if len(s.parts) > 0 && s.parts[0].tag == "p" {
            return media_matches(r, vw)
        }
    }
    return false // regra não parseada = não aplica
}

@(private = "file")
LARGURAS := []f32{320, 480, 639, 640, 641, 800, 999, 1000, 1001, 1279, 1280, 1281, 1920}

// O scanner de número compartilhado (`scan_number_end`): o expoente exige DÍGITO
// depois do 'e', senão o 'e' é o começo da UNIDADE. Sem esta condição, "consertar"
// o expoente comeria `em`/`ex` — por isso os dois lados estão pinados aqui.
@(test)
scanner_de_numero_expoente_vs_unidade :: proc(t: ^testing.T) {
    testing.expect_value(t, scan_number_end("1e3px", 0), 3)   // consome o expoente
    testing.expect_value(t, scan_number_end("1E3px", 0), 3)
    testing.expect_value(t, scan_number_end("1e-3px", 0), 4)
    testing.expect_value(t, scan_number_end("1e+3px", 0), 4)
    testing.expect_value(t, scan_number_end("3em", 0), 1)     // 'e' e UNIDADE
    testing.expect_value(t, scan_number_end("2ex", 0), 1)
    testing.expect_value(t, scan_number_end("5epx", 0), 1)    // 'e' sem digito
    testing.expect_value(t, scan_number_end("1e", 0), 1)
    testing.expect_value(t, scan_number_end("px", 0), 0)      // sem numero nenhum
    testing.expect_value(t, scan_number_end("-5px", 0), 0)          // sinal so com allow_sign
    testing.expect_value(t, scan_number_end("-5px", 0, true), 2)
    testing.expect_value(t, scan_number_end("-px", 0, true), 0)     // sinal sem digito nao conta
}

// O gate: as duas grafias do MESMO limite decidem igual em TODA largura.
@(test)
range_equivale_a_min_max_width :: proc(t: ^testing.T) {
    Par :: struct { nome, velha, nova: string }
    pares := []Par{
        {"limite inferior",   `@media (min-width: 40rem) { p{color:red} }`,  `@media (width>=40rem) { p{color:red} }`},
        {"limite superior",   `@media (max-width: 80rem) { p{color:red} }`,  `@media (width<=80rem) { p{color:red} }`},
        {"px em vez de rem",  `@media (min-width: 640px) { p{color:red} }`,  `@media (width>=640px) { p{color:red} }`},
        {"lado invertido",    `@media (min-width: 40rem) { p{color:red} }`,  `@media (40rem<=width) { p{color:red} }`},
        {"faixa fechada",     `@media (min-width: 40rem) and (max-width: 80rem) { p{color:red} }`,
                              `@media (40rem<=width<=80rem) { p{color:red} }`},
        {"largura exata",     `@media (width: 640px) { p{color:red} }`,      `@media (width=640px) { p{color:red} }`},
        {"com media-type",    `@media screen and (min-width: 40rem) { p{color:red} }`,
                              `@media screen and (width>=40rem) { p{color:red} }`},
        {"com calc",          `@media (min-width: calc(40rem + 10px)) { p{color:red} }`,
                              `@media (width>=calc(40rem + 10px)) { p{color:red} }`},
        {"negado",            `@media not all and (min-width: 40rem) { p{color:red} }`,
                              `@media not all and (width>=40rem) { p{color:red} }`},
        {"aninhado",          `@media screen { @media (min-width: 40rem) { p{color:red} } }`,
                              `@media screen { @media (width>=40rem) { p{color:red} } }`},
        {"espacos ao redor",  `@media (min-width: 40rem) { p{color:red} }`,  `@media ( width >= 40rem ) { p{color:red} }`},
        // NOTAÇÃO CIENTÍFICA no comprimento (o mesmo scanner do `rounded-full`).
        // ⚠️ o modo antigo de falhar era SILENCIOSO e pior que erro: o número
        // parava no 'e', `len_unit_px` trata unidade desconhecida como px, e
        // `1e3px` virava 1px — a media query casava em TODA largura.
        {"expoente",          `@media (min-width: 1000px) { p{color:red} }`, `@media (min-width: 1e3px) { p{color:red} }`},
        {"expoente em range", `@media (width>=1000px) { p{color:red} }`,     `@media (width>=1e3px) { p{color:red} }`},
        {"expoente em calc",  `@media (min-width: calc(1000px + 8px)) { p{color:red} }`,
                              `@media (min-width: calc(1e3px + 8px)) { p{color:red} }`},
    }
    for par in pares {
        for vw in LARGURAS {
            a := aplica(par.velha, vw)
            b := aplica(par.nova,  vw)
            testing.expectf(t, a == b,
                "%s @ vw=%.0f: `%s` diz %v mas `%s` diz %v",
                par.nome, vw, par.velha, a, par.nova, b)
        }
    }
    fmt.printf("[gate de grafia MQ] %d pares x %d larguras\n", len(pares), len(LARGURAS))
}

// O caso concreto do ultra-photo.com: o bloco tem de APLICAR no desktop. (O gate
// de equivalência sozinho passaria se as DUAS grafias quebrassem juntas.)
@(test)
range_do_tailwind_v4_aplica_no_desktop :: proc(t: ^testing.T) {
    css :: `@media (width>=40rem){p{grid-template-columns:repeat(3,minmax(0,1fr))}}`
    testing.expect(t, aplica(css, 1920), "sm: do Tailwind v4 tem de aplicar em 1920")
    testing.expect(t, aplica(css, 640),  "640px = 40rem: o limite e INCLUSIVO")
    testing.expect(t, !aplica(css, 639), "639 < 640 nao aplica")
}

// `<` e `>` são ESTRITOS — é o que separa `(width>640px)` de `(width>=640px)`.
@(test)
range_comparador_estrito :: proc(t: ^testing.T) {
    maior :: `@media (width>640px) { p{color:red} }`
    testing.expect(t, !aplica(maior, 640), "estrito: 640 nao satisfaz > 640")
    testing.expect(t,  aplica(maior, 641), "641 satisfaz > 640")

    menor :: `@media (width<640px) { p{color:red} }`
    testing.expect(t, !aplica(menor, 640), "estrito: 640 nao satisfaz < 640")
    testing.expect(t,  aplica(menor, 639), "639 satisfaz < 640")

    // faixa de dois lados com estrito de um lado só
    faixa :: `@media (40rem<=width<80rem) { p{color:red} }`
    testing.expect(t,  aplica(faixa, 640),  "inicio inclusivo")
    testing.expect(t,  aplica(faixa, 1279), "dentro")
    testing.expect(t, !aplica(faixa, 1280), "fim exclusivo")
    testing.expect(t, !aplica(faixa, 639),  "abaixo do inicio")
}

// Degradação HONESTA: feature de range que não modelamos continua sendo
// <general-enclosed> (não aplica) em vez de virar um limite inventado.
@(test)
range_de_feature_nao_modelada_nao_aplica :: proc(t: ^testing.T) {
    testing.expect(t, !aplica(`@media (height>=40rem) { p{color:red} }`, 1920),
        "height nao e modelado: nao pode aplicar por acidente")
    testing.expect(t, !aplica(`@media (resolution>=2dppx) { p{color:red} }`, 1920),
        "resolution nao e modelado")
    // valor ilegível também não vira limite
    testing.expect(t, !aplica(`@media (width>=banana) { p{color:red} }`, 1920),
        "valor invalido nao aplica")
    testing.expect(t, !aplica(`@media (40rem<=80rem) { p{color:red} }`, 1920),
        "sem nome de feature nao aplica")
}

// Guarda de regressão do caminho ANTIGO: feature sem ':', sem comparador e que não
// seja de interação tem de continuar desconhecida (o que o `colon < 0` cobria sozinho).
@(test)
range_nao_mexeu_no_general_enclosed :: proc(t: ^testing.T) {
    testing.expect(t, !aplica(`@media (prefers-reduced-motion) { p{color:red} }`, 1920),
        "(prefers-reduced-motion) continua <general-enclosed>")
    testing.expect(t, !aplica(`@media (banana) { p{color:red} }`, 1920),
        "feature inventada continua <general-enclosed>")
    // e o de dois-pontos segue pelo caminho de sempre
    testing.expect(t, aplica(`@media (min-width: 40rem) { p{color:red} }`, 1920),
        "grafia classica intocada")
}

// aspect-ratio também tem grafia de range.
@(test)
range_aspect_ratio :: proc(t: ^testing.T) {
    css :: `@media (aspect-ratio>=3/2) { p{color:red} }`
    rules, _ := parse(css)
    defer free_rules(&rules)
    testing.expect(t, len(rules) > 0, "regra parseada")
    testing.expect(t,  media_matches(rules[0], 1920, 1080), "16/9 >= 3/2 aplica")
    testing.expect(t, !media_matches(rules[0], 1024, 768),  "4/3 < 3/2 nao aplica")
}
