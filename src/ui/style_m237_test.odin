package ui

// M237 — quatro defeitos achados por sondagem da engine CSS (2026-08-01).
//
// Os quatro são da mesma FAMÍLIA: valor que o autor escreveu e o motor deixava
// cair em silêncio, ou pior, valor que o motor INVENTAVA (a pseudo-classe que
// casa tudo). Nenhum deles aparecia nos gates existentes porque todos os nossos
// corpora escrevem a forma "fácil" da mesma feature — a mesma lição do M172.
//
//   1. shorthand `font` jogava fora o PESO (e não resetava style/weight)
//   2. `background-color: transparent` não apagava o fundo anterior
//   3. pseudo-classe de ESTADO não suportada casava TODO elemento
//   4. valor inválido/insuportado APAGAVA a declaração válida anterior
//
// ⚠️ Estes testes usam test_compute_one/test_compute_child (pipeline REAL).
// `test_apply` NÃO serve aqui: ele parte de `computed_initial()`, que não passa
// pelo bloco de reset das não-herdadas de compute_node — foi assim que a sonda
// me deu um falso positivo em `flex:1` (shrink 0 lá, 1 no pipeline).

import "core:testing"
import "core:fmt"

// ── 1. shorthand `font` ─────────────────────────────────────────────────────

@(test)
test_m237_font_shorthand_peso :: proc(t: ^testing.T) {
    Caso :: struct { css: string, bold: bool, italic: bool }
    casos := []Caso{
        {"font: bold 14px Arial",                    true,  false},
        {"font: 700 14px Arial",                     true,  false},
        {"font: italic bold 12px/1.5 serif",         true,  true},
        {"font: bold italic 12px/1.5 serif",         true,  true},  // ordem livre
        {"font: normal normal 700 14px/1.2 Arial",   true,  false},
        {"font: 900 1rem sans-serif",                true,  false},
        {"font: 14px Arial",                         false, false},
        {"font: italic 14px Arial",                  false, true},
        {"font: normal 14px Arial",                  false, false},
    }
    for k in casos {
        c := test_compute_one(fmt.tprintf(".i{{%s}}", k.css), "div", "i")
        got := c.weight == .Bold
        testing.expectf(t, got == k.bold,   "%s → bold=%v; veio %v",   k.css, k.bold,   c.weight)
        testing.expectf(t, c.italic == k.italic, "%s → italic=%v; veio %v", k.css, k.italic, c.italic)
    }
}

@(test)
test_m237_font_shorthand_reseta :: proc(t: ^testing.T) {
    // O shorthand devolve ao inicial o que NÃO foi dito (spec). Aqui o peso vem
    // do PAI (herdado) e o `font:` sem peso tem de zerá-lo.
    c := test_compute_child(".g{font-weight:700} .i{font: 14px serif}")
    testing.expectf(t, c.weight == .Regular, "font: sem peso reseta p/ normal; veio %v", c.weight)

    c2 := test_compute_child(".g{font-style:italic} .i{font: 14px serif}")
    testing.expectf(t, !c2.italic, "font: sem estilo reseta p/ normal; veio %v", c2.italic)

    // …mas o LONGHAND explícito no MESMO conjunto continua vencendo (o decls é
    // plano e não guarda ordem por-declaração — convenção do `background`).
    c3 := test_compute_one(".i{font: 14px serif; font-weight: 700}", "div", "i")
    testing.expectf(t, c3.weight == .Bold, "longhand vence o reset do shorthand; veio %v", c3.weight)

    // sem TAMANHO não é um `font` válido → não reseta nada
    c4 := test_compute_child(".g{font-weight:700} .i{font: inherit}")
    testing.expectf(t, c4.weight == .Bold, "`font: inherit` não pode zerar o peso; veio %v", c4.weight)
}

// ── 2. background-color: transparent ────────────────────────────────────────

@(test)
test_m237_background_color_transparent :: proc(t: ^testing.T) {
    // fundo do UA de um <button>: o autor pede transparente e tem de sumir
    c := test_compute_one("button{background-color: transparent}", "button")
    testing.expectf(t, !c.has_bg, "background-color:transparent deveria apagar o fundo do UA; has=%v bg=%08x", c.has_bg, c.bg)

    // fundo vindo do SHORTHAND de outra regra (chave diferente no decls)
    c2 := test_compute_one(".a{background:#ff0000} .i{background-color:transparent}", "div", "a i")
    testing.expectf(t, !c2.has_bg, "transparent deveria apagar o `background` de outra regra; has=%v bg=%08x", c2.has_bg, c2.bg)

    // e o caminho normal continua funcionando
    c3 := test_compute_one(".i{background-color:#00ff00}", "div", "i")
    testing.expectf(t, c3.has_bg && (c3.bg & 0xffffff) == 0x00ff00, "cor normal segue valendo; has=%v bg=%08x", c3.has_bg, c3.bg)

    // TRANSPARENT em MAIÚSCULA / com espaço em volta (grafia)
    c4 := test_compute_one("button{background-color:  TRANSPARENT }", "button")
    testing.expectf(t, !c4.has_bg, "TRANSPARENT maiúsculo; has=%v", c4.has_bg)
}

@(test)
test_m237_shorthand_vence_longhand_por_especificidade :: proc(t: ^testing.T) {
    // O par que o WPT (at-supports-001) cobra: quem ganha a CASCATA ganha, e não
    // quem apy_decls aplica por último. O `decls` é plano, então collect_decls
    // tem de tirar do conjunto o perdedor.
    // shorthand MAIS específico vence o longhand
    c := test_compute_one("div{background-color:#ff0000} .i{background:#00ff00}", "div", "i")
    testing.expectf(t, c.has_bg && (c.bg & 0xffffff) == 0x00ff00,
        "shorthand de spec maior vence; veio has=%v bg=%08x", c.has_bg, c.bg)

    // longhand MAIS específico vence o shorthand
    c2 := test_compute_one("div{background:#ff0000} .i{background-color:#00ff00}", "div", "i")
    testing.expectf(t, c2.has_bg && (c2.bg & 0xffffff) == 0x00ff00,
        "longhand de spec maior vence; veio has=%v bg=%08x", c2.has_bg, c2.bg)

    // mesma spec: decide a ORDEM de fonte, nos dois sentidos
    c3 := test_compute_one(".i{background-color:#ff0000} .i{background:#00ff00}", "div", "i")
    testing.expectf(t, (c3.bg & 0xffffff) == 0x00ff00, "empate: shorthand depois vence; bg=%08x", c3.bg)
    c4 := test_compute_one(".i{background:#ff0000} .i{background-color:#00ff00}", "div", "i")
    testing.expectf(t, (c4.bg & 0xffffff) == 0x00ff00, "empate: longhand depois vence; bg=%08x", c4.bg)

    // e o mesmo para font/font-weight (o reset do fix 1)
    c5 := test_compute_one("div{font-weight:700} .i{font: 14px serif}", "div", "i")
    testing.expectf(t, c5.weight == .Regular, "shorthand font de spec maior reseta o peso; veio %v", c5.weight)
}

// ── 3. pseudo-classe de estado não suportada ────────────────────────────────

@(test)
test_m237_pseudo_estado_casa_nada :: proc(t: ^testing.T) {
    // Nenhuma delas é verdadeira num render estático → não pode casar.
    casos := []string{
        "target", "target-within", "visited", "invalid", "user-invalid", "user-valid",
        "out-of-range", "indeterminate", "autofill", "-webkit-autofill",
        "modal", "fullscreen", "picture-in-picture", "popover-open",
        "paused", "playing", "seeking", "muted",
    }
    for ps in casos {
        c := test_compute_one(fmt.tprintf("div:%s{{color:#ff0000}}", ps), "div", "x")
        testing.expectf(t, (c.color & 0xffffff) != 0xff0000, ":%s casou um <div> comum (cor=%08x)", ps, c.color)
    }
    // o caso destrutivo: escondia conteúdo
    c2 := test_compute_one(".p:target{display:none}", "div", "p")
    testing.expectf(t, !c2.display_none, ":target{display:none} escondeu elemento que não é alvo")

    // …e as ESTATICAMENTE VERDADEIRAS continuam permissivas de propósito
    permissivas := []string{"valid", "in-range", "defined", "any-link", "placeholder-shown"}
    for ps in permissivas {
        c := test_compute_one(fmt.tprintf("div:%s{{color:#00ff00}}", ps), "div", "x")
        testing.expectf(t, (c.color & 0xffffff) == 0x00ff00, ":%s deveria seguir permissiva; cor=%08x", ps, c.color)
    }
}

@(test)
test_m237_nth_argumento_invalido :: proc(t: ^testing.T) {
    // O par CASO/CONTROLE difere só no ARGUMENTO — mesma forma de seletor, mesma
    // árvore (pai + filho único, logo índice 1).
    invalidos := []string{"bogus", "", "2n of .x", "+-3n"}
    for arg in invalidos {
        c := test_compute_child(fmt.tprintf(".g > :nth-child(%s){{color:#ff0000}}", arg))
        testing.expectf(t, (c.color & 0xffffff) != 0xff0000, ":nth-child(%s) casou (cor=%08x)", arg, c.color)
    }
    validos := []string{"1", "odd", "2n+1", "-n+3", "n"}
    for arg in validos {
        c := test_compute_child(fmt.tprintf(".g > :nth-child(%s){{color:#00ff00}}", arg))
        testing.expectf(t, (c.color & 0xffffff) == 0x00ff00, ":nth-child(%s) deveria casar o 1º filho; cor=%08x", arg, c.color)
    }
}

@(test)
test_m237_empty_e_only_of_type :: proc(t: ^testing.T) {
    // `:empty` de verdade: o filho VAZIO casa, o que tem texto não
    css := ".g > :empty{color:#ff0000}"
    c := test_compute_child(css, "g", "i") // filho sem conteúdo
    testing.expectf(t, (c.color & 0xffffff) == 0xff0000, ":empty deveria casar filho vazio; cor=%08x", c.color)

    c2 := test_compute_child_text(css, "g", "i", "oi")
    testing.expectf(t, (c2.color & 0xffffff) != 0xff0000, ":empty casou elemento COM texto; cor=%08x", c2.color)

    // espaço em branco não conta (Selectors 4, igual ao Chrome)
    c3 := test_compute_child_text(css, "g", "i", "  \n ")
    testing.expectf(t, (c3.color & 0xffffff) == 0xff0000, ":empty deveria casar com só espaços; cor=%08x", c3.color)

    // :only-of-type — filho único do pai
    c4 := test_compute_child(".g > :only-of-type{color:#00ff00}", "g", "i")
    testing.expectf(t, (c4.color & 0xffffff) == 0x00ff00, ":only-of-type deveria casar filho único; cor=%08x", c4.color)
}

// ── 4. cadeia de fallback: valor insuportado não apaga o anterior ───────────

@(test)
test_m237_fallback_no_mesmo_bloco :: proc(t: ^testing.T) {
    // o padrão real: forma antiga primeiro, forma nova depois
    c := test_compute_one(".i{width: 300px; width: -webkit-fill-available}", "div", "i")
    testing.expectf(t, c.has_width && c.width == 300, "fallback de width; veio has=%v w=%v", c.has_width, c.width)

    c2 := test_compute_one(".i{width: 300px; width: fit-content}", "div", "i")
    testing.expect(t, c2.width_mc && c2.width_fit && !c2.has_width,
        "fit-content agora implementado deve substituir a largura de fallback")

    c3 := test_compute_one(".i{width: 100px; width: bogus}", "div", "i")
    testing.expectf(t, c3.has_width && c3.width == 100, "valor sem sentido não pode apagar; veio has=%v w=%v", c3.has_width, c3.width)

    // cor de SISTEMA (css-color-4) — não implementada, e é padrão de fallback
    c4 := test_compute_one(".i{color: #ff0000; color: AccentColor}", "div", "i")
    testing.expectf(t, (c4.color & 0xffffff) == 0xff0000, "fallback de cor; veio %08x", c4.color)
}

@(test)
test_m237_fallback_nao_engole_valor_bom :: proc(t: ^testing.T) {
    // CONTROLE: quando o SEGUNDO valor é utilizável, ele tem de vencer —
    // senão o "conserto" viraria uma regressão calada em toda folha minificada.
    c := test_compute_one(".i{width: 300px; width: 120px}", "div", "i")
    testing.expectf(t, c.width == 120, "o 2º valor VÁLIDO vence; veio %v", c.width)

    c2 := test_compute_one(".i{width: 300px; width: 50%}", "div", "i")
    testing.expectf(t, c2.width_pct && c2.width == 0.5, "%% vence; veio %v pct=%v", c2.width, c2.width_pct)

    c3 := test_compute_one(".i{width: 300px; width: calc(100px + 20px)}", "div", "i")
    testing.expectf(t, c3.width == 120, "calc vence; veio %v", c3.width)

    c4 := test_compute_one(".i{width: 300px; width: var(--x)}", "div", "i", "")
    testing.expectf(t, !c4.has_width || c4.width != 300, "var() nunca é descartado no parse; veio has=%v w=%v", c4.has_width, c4.width)

    // palavras-chave que RESETAM: têm de passar (senão `background-color:
    // transparent` depois de uma cor voltaria a ser engolido — ver o fix 2)
    c5 := test_compute_one(".i{background-color:#ff0000; background-color:transparent}", "div", "i")
    testing.expectf(t, !c5.has_bg, "transparent depois de cor tem de limpar; has=%v bg=%08x", c5.has_bg, c5.bg)

    c6 := test_compute_one(".i{width: 300px; width: auto}", "div", "i")
    testing.expectf(t, !c6.has_width, "`auto` depois de px tem de valer; veio has=%v w=%v", c6.has_width, c6.width)

    c7 := test_compute_one(".i{display:flex; display:none}", "div", "i")
    testing.expectf(t, c7.display_none, "2º display válido vence; veio %v", c7.display_none)
}
