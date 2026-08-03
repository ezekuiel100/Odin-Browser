package ui

// Testes do `@supports` do lado do MOTOR (2026-07-29): a política de "o motor
// implementa esta declaração?" (`css_supports_decl`) e o efeito ponta-a-ponta
// na cascata. O pacote css testa a gramática com um motor de mentira
// (src/css/supports_test.odin); aqui o hook é o REAL, instalado pelo @(init).

import "core:testing"
import "core:fmt"
import jspkg "../js"

@(test)
test_supports_decl_tabela_verdade :: proc(t: ^testing.T) {
    // 1. propriedade desconhecida — a resposta 100% confiável
    testing.expect(t, !css_supports_decl("nao-existe-mesmo", "1"), "prop desconhecida")
    testing.expect(t, css_supports_decl("margin", "0"), "prop conhecida com valor comum")
    testing.expect(t, css_supports_decl("--minha-var", "seja-o-que-for"), "custom property")
    testing.expect(t, !css_supports_decl("margin", ""), "valor vazio")

    // 2. valor com unidade/função que o motor não converte — a declaração cairia
    testing.expect(t, css_supports_decl("height", "100dvh"), "dvh passou a ser convertida (M222)")
    testing.expect(t, !css_supports_decl("width", "50cqw"), "unidade de container query")
    testing.expect(t, !css_supports_decl("width", "10ch"), "ch ficou de fora do parse_len")
    testing.expect(t, !css_supports_decl("padding-left", "env(safe-area-inset-left)"), "env()")
    testing.expect(t, !css_supports_decl("width", "round(down, 10px, 3px)"), "round()")
    testing.expect(t, css_supports_decl("height", "100vh"), "vh É convertida (controle)")
    testing.expect(t, css_supports_decl("width", "clamp(1rem, 2vw, 4rem)"), "clamp/rem/vw (controle)")
    testing.expect(t, css_supports_decl("transition", "opacity 0.3s ease"), "s não é unidade de comprimento")
    testing.expect(t, css_supports_decl("transform", "rotate(45deg)"), "deg idem")
    testing.expect(t, css_supports_decl("color", "#00ff00"), "hex não é número+unidade")
    testing.expect(t, css_supports_decl("background", "linear-gradient(#333 0 12px, #fff)"), "px em gradiente")
    testing.expect(t, css_supports_decl("transform", "translate3d(0,0,0)"), "dígito dentro de identificador")
    // ⚠️ o par abaixo usa `ch` (ainda não convertida) DE PROPÓSITO: com `in`, que
    // passou a ser suportada no M238, os dois lados dariam `true` e o par deixaria
    // de discriminar — passaria pelo motivo errado.
    testing.expect(t, css_supports_decl("background", "url(foto-2ch.png)"), "hífen de IDENTIFICADOR não faz `2ch` virar unidade")
    testing.expect(t, !css_supports_decl("margin-left", "-2ch"), "mas o hífen de SINAL faz (controle do caso acima)")

    // 3. palavra-chave fechada: o valor tem de existir no switch do apply_decls
    testing.expect(t, css_supports_decl("display", "grid"), "display:grid")
    testing.expect(t, css_supports_decl("display", "contents"), "display:contents")
    testing.expect(t, !css_supports_decl("display", "list-item"), "display:list-item não é tratado")
    testing.expect(t, !css_supports_decl("display", "inline flow-root"), "display de duas palavras")
    testing.expect(t, !css_supports_decl("display", "-ms-grid"), "display legado da IE")
    testing.expect(t, css_supports_decl("position", "sticky"), "position:sticky")
    testing.expect(t, !css_supports_decl("position", "running(x)"), "position desconhecida")
}

// ⚠️ TESTE-ESPELHO: a lista de unidades rejeitadas por `value_has_unsupported_unit`
// tem de bater com o que o `parse_len` REALMENTE não converte. Se alguém
// implementar `dvh` (ou `ch`, ou `cm`) e esquecer de tirá-la da lista, este
// teste cai — e a mensagem diz qual unidade e onde arrumar. O controle na outra
// direção (uma unidade suportada listada por engano) está na tabela-verdade
// acima (`100vh`/`clamp(...)`).
@(test)
test_supports_unidades_espelham_parse_len :: proc(t: ^testing.T) {
    // cm/mm/in/pc/q saíram da lista no M238 (o parse_len converte todas agora);
    // o espelho na direção POSITIVA está em test_m238_unidades_absolutas.
    rejeitadas := []string{
        "ch", "rlh", "cqw", "cqh", "cqi", "cqb", "cqmin", "cqmax",
    }
    for u in rejeitadas {
        decl := fmt.tprintf("width: 10%s", u)
        comp := test_apply(decl)
        testing.expectf(t, !comp.has_width,
            "`%s` foi ACEITA pelo parse_len — implemente-a ou tire-a da lista de value_has_unsupported_unit (style.odin)", decl)
        testing.expectf(t, !css_supports_decl("width", fmt.tprintf("10%s", u)),
            "@supports diz suportar `10%s`, mas o parse_len descarta a declaração", u)
    }
    // controle: uma unidade que o parse_len converte de verdade
    ctrl := test_apply("width: 10vh")
    testing.expect(t, ctrl.has_width, "controle: `vh` continua sendo convertida")
}

// ── ponta-a-ponta pela cascata real (collect_decls → apply_decls) ────────────

@(test)
test_supports_e2e_fallback_nao_sobrescreve :: proc(t: ^testing.T) {
    // O bug que este marco fecha: com o @supports transparente, o bloco do
    // `not (...)` — que é o FALLBACK — entrava também, e por vir depois na
    // ordem de fonte VENCIA o caminho moderno.
    css := `div { color: rgb(255,0,0) }
            @supports (display: grid)     { div { color: rgb(0,0,255) } }
            @supports not (display: grid) { div { color: rgb(0,128,0) } }`
    comp := test_compute_one(css)
    testing.expectf(t, comp.color == 0x0000ff,
        "esperava azul (bloco da condição VERDADEIRA); veio %6x — o bloco do `not` sobrescreveu?", comp.color)
}

@(test)
test_supports_e2e_prop_desconhecida_some :: proc(t: ^testing.T) {
    css := `div { color: rgb(255,0,0) }
            @supports (nao-existe-mesmo: 1) { div { color: rgb(0,0,255) } }`
    comp := test_compute_one(css)
    testing.expectf(t, comp.color == 0xff0000,
        "bloco condicionado a prop desconhecida não pode aplicar; veio %6x", comp.color)
}

@(test)
test_supports_e2e_aninhado :: proc(t: ^testing.T) {
    // Antes: o @supports aninhado por CSS nesting era descartado SEMPRE.
    verd := test_compute_one(`div { color: rgb(255,0,0); @supports (display: grid) { color: rgb(0,128,0) } }`)
    testing.expectf(t, verd.color == 0x008000, "aninhado verdadeiro agora aplica; veio %6x", verd.color)

    fals := test_compute_one(`div { color: rgb(255,0,0); @supports (nao-existe-mesmo: 1) { color: rgb(0,0,255) } }`)
    testing.expectf(t, fals.color == 0xff0000, "aninhado falso não aplica; veio %6x", fals.color)
}

@(test)
test_supports_e2e_unidade_nao_convertida_cai_no_fallback :: proc(t: ^testing.T) {
    // Caso real de site moderno: unidade nova com fallback. Quando o motor não
    // converte a unidade, a resposta honesta é NÃO — e o site fica com o
    // fallback, que funciona. Com o @supports transparente, o bloco entrava, a
    // declaração era descartada no parse_len e a altura sumia (sem fallback E
    // sem a propriedade). `cqw` (container query) segue não convertida.
    css := `div { height: 500px }
            @supports (height: 50cqw) { div { height: 50cqw } }`
    comp := test_compute_one(css)
    testing.expectf(t, comp.has_height && comp.height == 500,
        "altura deveria continuar 500px, veio has=%v h=%v", comp.has_height, comp.height)
}

// ── `CSS.supports()` do JS com o hook REAL (js/css_om.odin) ─────────────────
// O pacote js testa a GRAMÁTICA com o hook nil (heurística sintática); só aqui a
// resposta sai da política do motor. É o que faz este bloco valer: sob heurística
// `nao-existe-mesmo: 1` seria TRUE (é um identificador plausível), então cada
// `false` abaixo prova que a declaração NUA (passo 2 do CSSOM, o que faltava) foi
// parar no `css_supports_decl` — e não numa aproximação.
@(private = "file")
sup_js :: proc(t: ^testing.T, expr: string) -> bool {
    vm := jspkg.vm_create()
    defer jspkg.vm_free(vm)
    v, ok := jspkg.vm_run(vm, expr).(bool)
    testing.expectf(t, ok, "`%s` não devolveu boolean", expr)
    return v
}

@(test)
test_supports_js_declaracao_nua_usa_o_motor :: proc(t: ^testing.T) {
    // o caso do relatório: forma de 1 argumento, condição SEM parênteses
    testing.expect(t, sup_js(t, `CSS.supports('color: red')`), "CSS.supports('color: red')")
    testing.expect(t, sup_js(t, `CSS.supports('display: grid')`), "display: grid")
    testing.expect(t, sup_js(t, `CSS.supports('--tema: escuro')`), "custom property")

    // e a resposta 100% confiável continua NÃO — o passo 2 não é um "sim" fácil
    testing.expect(t, !sup_js(t, `CSS.supports('nao-existe-mesmo: 1')`), "prop desconhecida")
    testing.expect(t, !sup_js(t, `CSS.supports('display: list-item')`), "valor fora do switch de display")
    testing.expect(t, !sup_js(t, `CSS.supports('width: 50cqw')`), "unidade não convertida")
    testing.expect(t, !sup_js(t, `CSS.supports('color: red !important')`), "!important é inválido")
}

@(test)
test_supports_js_duas_grafias_concordam :: proc(t: ^testing.T) {
    // ⚠️ GATE DE EQUIVALÊNCIA DE GRAFIA: as três formas de perguntar a MESMA coisa
    // têm de dar a mesma resposta. O bug era exatamente uma delas discordando das
    // outras duas — e nenhum teste escrevia as três lado a lado.
    casos := []string{"color: red", "display: grid", "nao-existe-mesmo: 1", "width: 50cqw"}
    for c in casos {
        ci := 0
        for ci < len(c) && c[ci] != ':' do ci += 1
        nua  := sup_js(t, fmt.tprintf(`CSS.supports("%s")`, c))
        par  := sup_js(t, fmt.tprintf(`CSS.supports("(%s)")`, c))
        dois := sup_js(t, fmt.tprintf(`CSS.supports("%s", "%s")`, c[:ci], c[ci + 1:]))
        testing.expectf(t, nua == par && par == dois,
            "`%s`: nua=%v parênteses=%v dois-args=%v — as três grafias divergiram", c, nua, par, dois)
    }
}

@(test)
test_supports_e2e_dvh_agora_aplica :: proc(t: ^testing.T) {
    // O contrário do teste acima, depois que `dvh` passou a ser convertida (M222):
    // o bloco moderno DEVE vencer o fallback.
    css := `div { height: 500px }
            @supports (height: 100dvh) { div { height: 100dvh } }`
    comp := test_compute_one(css)
    testing.expectf(t, comp.has_height && comp.height != 500,
        "o bloco de 100dvh deveria aplicar; veio has=%v h=%v", comp.has_height, comp.height)
}
