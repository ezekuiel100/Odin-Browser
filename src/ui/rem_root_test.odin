package ui

// Unidade `rem` = font-size do elemento RAIZ (CSS Values §5.1.3).
//
// Era 16px FIXO em três lugares do motor, então o truque `html{font-size:62.5%}`
// (rem = 10px), que sites inteiros usam para fazer conta em dezenas, não valia
// nada: no svelte.dev a fonte do hero saía 86,4px em vez de 54px, e com ela todo
// `em` derivado dela.
//
// ⚠️ RODE COM `-define:ODIN_TEST_THREADS=1` (o test.ps1 faz isso p/ src/ui) —
// a base do `rem` é global de pacote (thread_local, mas ainda assim global).

import "core:testing"
import "core:fmt"
import htmlp "../html"
import dompkg "../dom"
import csspkg "../css"

@(private = "file")
larg :: proc(html: string, tag := "section", css := "") -> f32 {
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse(css)
    styles, _ := compute_styles(dom, &rules, 600, 600)
    root := build_layout(dom, styles, "")
    layout_box(root, 0, 0, 600)
    pg := Rect{0, 0, 600, 600}
    layout_absolutes(root, pg, pg)
    found: ^Box
    w :: proc(b: ^Box, tag: string, out: ^^Box) {
        if b == nil do return
        if b.node != nil && b.node.tag == tag do out^ = b
        for c in b.children do w(c, tag, out)
        for it in b.inlines do if it.kind == .InlineBox do w(it.box, tag, out)
    }
    w(root, tag, &found)
    return found == nil ? -1 : found.w
}

@(private = "file")
caso :: proc(t: ^testing.T, nome, html: string, esperado: f32) {
    got := larg(html)
    testing.expectf(t, abs(got - esperado) < 0.5, "%s: esperava %v, veio %v", nome, esperado, got)
}

@(test)
test_rem_segue_a_raiz :: proc(t: ^testing.T) {
    // O caso que motivou tudo: 62.5% de 16 = 10px por rem.
    caso(t, "html 62.5% (o truque)",
        `<html style="font-size:62.5%"><body style="margin:0"><section style="width:10rem;height:5px"></section></body></html>`, 100)
    // px na raiz também manda
    caso(t, "html font-size px",
        `<html style="font-size:10px"><body style="margin:0"><section style="width:10rem;height:5px"></section></body></html>`, 100)
    // CONTROLE: sem declaração na raiz, rem = 16px (o inicial) — é o caso de quase
    // todo site, e o que garante que esta mudança não mexe neles.
    caso(t, "sem font-size na raiz (CONTROLE)",
        `<body style="margin:0"><section style="width:10rem;height:5px"></section></body>`, 160)
    // ⚠️ `rem` NÃO é `em`: font-size no <body> (ou em qualquer ancestral que não
    // seja a raiz) não muda a base. Sem esta afirmação, um conserto que usasse a
    // fonte HERDADA passaria igual.
    caso(t, "font-size no body NÃO muda o rem",
        `<html style="font-size:62.5%"><body style="margin:0;font-size:40px"><section style="width:10rem;height:5px"></section></body></html>`, 100)
    // ...e o `em` continua seguindo o ancestral (contraprova do caso acima)
    caso(t, "em segue o ancestral, não a raiz",
        `<html style="font-size:62.5%"><body style="margin:0;font-size:40px"><section style="width:10em;height:5px"></section></body></html>`, 400)
    // rem em OUTRAS propriedades que passam pelo mesmo parse de comprimento
    caso(t, "rem em max-width",
        `<html style="font-size:10px"><body style="margin:0"><section style="width:600px;max-width:15rem;height:5px"></section></body></html>`, 150)
    caso(t, "rem em padding (soma na caixa)",
        `<html style="font-size:10px"><body style="margin:0"><section style="width:100px;padding:0 2rem;height:5px"></section></body></html>`, 140)

    // ⚠️ pela FOLHA de estilo, não por `style=` inline: é como o site real escreve
    // (`html{font-size:62.5%}` no CSS), e passa por outro caminho da cascata.
    // ⚠️⚠️ o fixture PRECISA da tag <html> explícita: com `<body>…</body>` solto o
    // nosso parser NÃO sintetiza o elemento raiz (`find_first(dom,"html")` = nil),
    // então a regra não casa com nada e o teste acusaria o motor por um defeito do
    // FIXTURE. (Foi o meu 1º vermelho aqui; o motor estava certo.)
    w := larg(`<html><body style="margin:0"><section style="width:10rem;height:5px"></section></body></html>`,
              "section", `html{font-size:62.5%}`)
    testing.expectf(t, abs(w - 100) < 0.5, "regra de folha na raiz: esperava 100, veio %v", w)

    // ...e o mesmo pela folha com `:root` (seletor que o Tailwind/design systems usam)
    w2 := larg(`<html><body style="margin:0"><section style="width:10rem;height:5px"></section></body></html>`,
               "section", `:root{font-size:10px}`)
    testing.expectf(t, abs(w2 - 100) < 0.5, ":root{font-size:10px} na folha: esperava 100, veio %v", w2)
}

@(test)
test_rem_da_propria_raiz_e_o_inicial :: proc(t: ^testing.T) {
    // Na declaração de font-size da PRÓPRIA raiz, `rem` vale o valor INICIAL
    // (16px), não o que ela está definindo — senão seria circular. Spec explícita.
    dom := htmlp.parse(`<html style="font-size:2rem"><body style="margin:0"><section style="width:10rem;height:5px"></section></body></html>`)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, 600, 600)
    if html := dompkg.find_first(dom, "html"); html != nil {
        if c, ok := styles[html]; ok {
            testing.expectf(t, abs(c.font_size - 32) < 0.5, "font-size:2rem na raiz = 2×16 = 32, veio %v", c.font_size)
        }
    }
    // ...e daí em diante o rem dos descendentes é 32
    caso(t, "descendente usa a raiz nova", `<html style="font-size:2rem"><body style="margin:0"><section style="width:10rem;height:5px"></section></body></html>`, 320)
}

@(test)
test_rem_nao_vaza_entre_paginas :: proc(t: ^testing.T) {
    // A base é global: uma página com raiz de 10px não pode deixar o `rem` da
    // PRÓXIMA (que não declara nada) valendo 10px. O reset é no compute_styles.
    _ = larg(`<html style="font-size:10px"><body style="margin:0"><section style="width:10rem;height:5px"></section></body></html>`)
    w := larg(`<body style="margin:0"><section style="width:10rem;height:5px"></section></body>`)
    testing.expectf(t, abs(w - 160) < 0.5, "página seguinte tem de voltar a 16px/rem (160), veio %v", w)
    if w != 160 do fmt.eprintfln("[rem] vazou a base da página anterior: %v", w)
}
