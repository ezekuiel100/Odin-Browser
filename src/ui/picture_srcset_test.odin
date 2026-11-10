package ui

// M236 — `<picture>`/`<source>`/`srcset` não existiam: usávamos sempre o `<img src>`,
// que num `<picture>` é só o FALLBACK.
//
// Origem: o hero da svelte.dev. O `<img>` aponta para a arte MOBILE e não tem
// `width`/`height`; quem carrega a proporção é o `<source>` de desktop, que declara
// 3795×993 (razão 3,82). Sem seleção de source a ilustração caía no default
// 320×180 de `image_dims` — 16:9 — e saía **1280×720** em vez de **1280×335**,
// estourando o `.hero` e empurrando a página inteira para baixo.
// `--imgdiff` contra o Chrome: 25,7 → 19,3.
//
// ⚠️ O `type` NÃO é decoração: o primeiro `<source>` da svelte é AVIF, que não temos
// decoder para abrir. Escolher por ordem sem checar o formato trocaria uma imagem
// que aparece por uma que falha — e, depois do M234, uma que falha COM `alt` de
// conteúdo ainda pinta o esqueleto cinza. É por isso que existe o teste do AVIF.

import "core:testing"
import "core:fmt"
import htmlp "../html"
import csspkg "../css"
import dompkg "../dom"

@(test)
inline_image_uses_high_resolution_source :: proc(t: ^testing.T) {
    dom, styles := prep(`<body><div><img src="small.png" srcset="small.png 80w, large.png 1200w" style="width:80px;height:80px;border-radius:50%"></div></body>`, 1000, 600)
    root := build_layout(dom, styles, "https://example.com/")
    defer free_layout(root)
    found := false
    visit :: proc(b: ^Box, t: ^testing.T, found: ^bool) {
        for it in b.inlines {
            if it.kind == .Image {
                found^ = true
                testing.expect_value(t, it.img_url, "https://example.com/large.png")
            }
            if it.kind == .InlineBox && it.box != nil do visit(it.box, t, found)
        }
        for child in b.children do visit(child, t, found)
    }
    visit(root, t, &found)
    testing.expect(t, found, "exercise the inline image path, not a block image")
}

@(private = "file")
PIC := `<body><picture>
    <source type="image/avif" media="(min-width: 800px)" srcset="d.avif 3795w" width="3795" height="993">
    <source type="image/webp" media="(min-width: 800px)" srcset="d.webp 3795w" width="3795" height="993">
    <source type="image/png" srcset="m.png 2208w" width="2208" height="936">
    <img src="mobile.png" alt="a maquina">
  </picture></body>`

@(private = "file")
prep :: proc(html: string, vw: f32 = 1280, vh: f32 = 900) -> (^dompkg.Node, map[^dompkg.Node]Computed) {
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse("")
    // compute_styles é quem seta g_viewport_w/h — as MESMAS globais que a seleção
    // de source lê, e é essa a invariante: CSS e `<source media>` não podem
    // discordar sobre "sou desktop?".
    styles, _ := compute_styles(dom, &rules, vw, vh)
    return dom, styles
}

@(test)
m236_source_pula_formato_sem_decoder :: proc(t: ^testing.T) {
    dom, _ := prep(PIC)
    img := dompkg.find_first(dom, "img")
    testing.expect(t, img != nil, "achou o <img>")
    if img == nil do return
    src := test_picture_source(img)
    testing.expect(t, src != nil, "algum <source> tem de vencer")
    if src == nil do return
    // O 1º da ordem é AVIF e NÃO pode vencer; o 2º (webp) sim.
    testing.expect_value(t, src.attrs["type"], "image/webp")
    testing.expect_value(t, src.attrs["srcset"], "d.webp 3795w")
}

@(test)
m236_source_respeita_o_media :: proc(t: ^testing.T) {
    // Em 500px de viewport os dois primeiros (min-width:800px) não casam, e vence
    // o terceiro — que não tem `media`.
    dom, _ := prep(PIC, 500, 800)
    img := dompkg.find_first(dom, "img")
    src := test_picture_source(img)
    testing.expect(t, src != nil, "o <source> sem media tem de vencer")
    if src == nil do return
    testing.expect_value(t, src.attrs["srcset"], "m.png 2208w")
}

@(test)
m236_img_fora_de_picture_nao_seleciona :: proc(t: ^testing.T) {
    // CONTROLE: `<img>` solto não tem source nenhum — o caminho antigo segue igual.
    dom, _ := prep(`<body><img src="a.png"><source srcset="b.png"></body>`)
    img := dompkg.find_first(dom, "img")
    testing.expect(t, test_picture_source(img) == nil, "sem <picture> não há seleção")
}

@(test)
m236_proporcao_vem_do_source :: proc(t: ^testing.T) {
    // Ponta a ponta, na MESMA forma da svelte.dev (`.machine img` é absoluto com
    // `width:100%;height:auto`): a altura sai da razão do <source> — 3795×993 ⇒
    // 1280 × 335 — e não do default 16:9 do image_dims, que dava 720.
    // ⚠️ o absoluto não é decoração do teste: dentro de `<picture>` um `<img>` em
    // fluxo vira ITEM INLINE e não tem Box para inspecionar.
    dom, styles := prep(`<body style="margin:0"><div style="position:relative;width:1280px;height:400px"><picture>
        <source type="image/webp" srcset="d.webp 3795w" width="3795" height="993">
        <img src="mobile.png" alt="x" style="position:absolute;top:0;left:0;width:100%;height:auto">
      </picture></div></body>`)
    root := build_layout(dom, styles, "")
    pagina := Rect{0, 0, 1280, 900}
    layout_box(root, 0, 0, 1280)
    layout_absolutes(root, pagina, pagina)
    alvo := find_tag236(root, "img")
    testing.expect(t, alvo != nil, "achou a caixa do <img>")
    if alvo == nil do return
    testing.expect_value(t, alvo.w, f32(1280))
    // ⚠️ 1280·993/3795 = 334,9249 — o `--dumplayout` mostra 335 ARREDONDADO, e eu
    // tinha escrito 335 aqui. Confere a razão com folga, não o inteiro bonito.
    esperado := f32(1280) * 993 / 3795
    testing.expect(t, abs(alvo.h - esperado) < 0.05,
        fmt.tprintf("altura pela razão do <source>: esperava ~%.3f, veio %.3f (720 = default 16:9)", esperado, alvo.h))
}

@(private = "file")
find_tag236 :: proc(b: ^Box, tag: string) -> ^Box {
    if b == nil do return nil
    if b.node != nil && b.node.tag == tag do return b
    for c in b.children {
        if r := find_tag236(c, tag); r != nil do return r
    }
    for &it in b.inlines {
        if it.kind == .InlineBox && it.box != nil {
            if r := find_tag236(it.box, tag); r != nil do return r
        }
    }
    return nil
}

// ── srcset: a escolha do candidato ──────────────────────────────────────────

@(test)
m236_srcset_menor_que_cobre :: proc(t: ^testing.T) {
    ss := "a.png 1200w, b.png 2000w, c.png 3795w"
    // 1200 não cobre 1280; o menor que cobre é o de 2000.
    testing.expect_value(t, test_srcset_pick(ss, 1280), "b.png")
    // 1200 cobre 1000 e é o menor.
    testing.expect_value(t, test_srcset_pick(ss, 1000), "a.png")
}

@(test)
m236_srcset_cai_no_maior_quando_nenhum_cobre :: proc(t: ^testing.T) {
    // Sem candidato à altura, o maior é o menos pior — devolver "" apagaria a imagem.
    testing.expect_value(t, test_srcset_pick("a.png 400w, b.png 800w", 4000), "b.png")
}

@(test)
m236_srcset_descritor_x_e_ausente :: proc(t: ^testing.T) {
    // Sem descritor = 1x = exatamente o alvo, então já cobre e vence o 2x.
    testing.expect_value(t, test_srcset_pick("a.png, b.png 2x", 1280), "a.png")
    testing.expect_value(t, test_srcset_pick("so-esta.png", 1280), "so-esta.png")
}

@(test)
m236_srcset_vazio_e_espacos :: proc(t: ^testing.T) {
    testing.expect_value(t, test_srcset_pick("", 1280), "")
    testing.expect_value(t, test_srcset_pick("   ", 1280), "")
    // quebra de linha e espaços extras são comuns no HTML gerado
    testing.expect_value(t, test_srcset_pick("  a.png   1200w ,\n  b.png  2000w  ", 1280), "b.png")
}
