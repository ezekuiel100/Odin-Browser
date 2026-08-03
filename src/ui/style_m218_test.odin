package ui

// M218 — `::placeholder` era DESCARTADO (casava com nada).
//
// Origem: no formulário do hero do github.com o rótulo "Enter your email" saía
// SOBREPOSTO ao placeholder "you@domain.com". O CSS é o idioma do RÓTULO FLUTUANTE:
//
//     .CtaFormControl-input::placeholder      { opacity: 0; transition: opacity .32s }
//     .CtaFormControl-input:focus::placeholder{ opacity: 1 }
//     .CtaFormControl-label                   { position: absolute; top: 12px; left: 18px }
//
// ou seja: a dica fica INVISÍVEL e quem o usuário lê é o rótulo posicionado por cima;
// a dica só aparece no foco. Como `::placeholder` entrava em `is_ignored_pseudo_element`
// (pseudo_only ⇒ casa nada), o `opacity:0` sumia e pintávamos OS DOIS.
//
// O fix reusa a máquina de pseudo-elementos que já existia (`Pseudo_Kind` +
// `Pass_Bit` + `compute_pseudo`): `::placeholder` virou um kind próprio, com
// `compute_placeholder` (modelado no ::first-letter — NÃO exige `content`).
// A pintura consome só `color` e `opacity`, que é o que decide se a dica aparece.
//
// ⚠️ O `Pass_Set` passou de `bit_set[...; u8]` para `u16`: com o bit novo são 9, e
// 9 bits não cabem em u8. Um bit_set estourado não dá erro de compilação óbvio — é o
// tipo de detalhe que vira flake meses depois.
//
// Conferido contra o Chrome numa fixture de 6 campos (sem regra / opacity:0 / cor /
// cor+opacity / textarea / campo com valor): as 6 batem.

import "core:testing"
import htmlp "../html"
import csspkg "../css"
import dompkg "../dom"

@(private = "file")
styles_de :: proc(css, html: string) -> (^dompkg.Node, map[^dompkg.Node]Computed) {
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse(css)
    styles, _ := compute_styles(dom, &rules, 800, 600)
    return dom, styles
}

@(private = "file")
find_tag218 :: proc(n: ^dompkg.Node, tag: string) -> ^dompkg.Node {
    if n == nil do return nil
    if n.kind == .Element && n.tag == tag do return n
    for c in n.children {
        if r := find_tag218(c, tag); r != nil do return r
    }
    return nil
}

@(test)
m218_placeholder_opacity_zero :: proc(t: ^testing.T) {
    // a regra exata do github
    dom, styles := styles_de(`input::placeholder{opacity:0}`,
        `<body><input placeholder="you@domain.com"></body>`)
    defer free_styles(styles)
    inp := find_tag218(dom, "input")
    testing.expect(t, inp != nil, "achou o input")
    if inp == nil do return
    c := styles[inp]
    testing.expect(t, c.placeholder != nil, "a regra ::placeholder tem de produzir Computed")
    if c.placeholder == nil do return
    testing.expect_value(t, c.placeholder.opacity, f32(0))
}

@(test)
m218_placeholder_cor :: proc(t: ^testing.T) {
    dom, styles := styles_de(`input::placeholder{color:#d00000}`,
        `<body><input placeholder="x"></body>`)
    defer free_styles(styles)
    inp := find_tag218(dom, "input")
    if inp == nil { testing.fail(t); return }
    c := styles[inp]
    testing.expect(t, c.placeholder != nil, "produziu Computed")
    if c.placeholder == nil do return
    testing.expect(t, c.placeholder.has_color, "cor definida")
    testing.expect_value(t, c.placeholder.color & 0xffffff, u32(0xd00000))
}

@(test)
m218_regra_do_pseudo_nao_vaza_pro_input :: proc(t: ^testing.T) {
    // CONTROLE que já existia antes do fix e não pode ter regredido: `::placeholder`
    // NUNCA muda o estilo do próprio <input> (era o motivo de ele estar na lista de
    // pseudos ignorados).
    dom, styles := styles_de(`input::placeholder{color:#00a000;opacity:0}`,
        `<body><input placeholder="x"></body>`)
    defer free_styles(styles)
    inp := find_tag218(dom, "input")
    if inp == nil { testing.fail(t); return }
    c := styles[inp]
    testing.expect_value(t, c.opacity, f32(1))
    testing.expect(t, (c.color & 0xffffff) != 0x00a000, "a cor do pseudo não vai para o input")
}

@(test)
m218_sem_regra_nao_produz_nada :: proc(t: ^testing.T) {
    // CONTROLE do caminho antigo: sem `::placeholder`, nada muda (a dica segue
    // pintada com a cor do texto a 50%).
    dom, styles := styles_de(``, `<body><input placeholder="x"></body>`)
    defer free_styles(styles)
    inp := find_tag218(dom, "input")
    if inp == nil { testing.fail(t); return }
    testing.expect(t, styles[inp].placeholder == nil, "sem regra ⇒ sem Computed de pseudo")
}

@(test)
m218_textarea_tambem :: proc(t: ^testing.T) {
    // o <textarea> desenha a dica por um caminho SEPARADO (DrawList_AddText, porque
    // o InputTextMultiline do ImGui não tem variante "with hint") — tem de honrar
    // a mesma regra.
    dom, styles := styles_de(`textarea::placeholder{opacity:0}`,
        `<body><textarea placeholder="x"></textarea></body>`)
    defer free_styles(styles)
    ta := find_tag218(dom, "textarea")
    if ta == nil { testing.fail(t); return }
    c := styles[ta]
    testing.expect(t, c.placeholder != nil, "textarea também produz Computed")
    if c.placeholder == nil do return
    testing.expect_value(t, c.placeholder.opacity, f32(0))
}

@(test)
m218_outros_pseudos_seguem_ignorados :: proc(t: ^testing.T) {
    // CONTROLE do recorte: só `::placeholder` saiu da lista de ignorados. Se
    // `::selection` tivesse saído junto, ele passaria a casar o elemento e mudaria
    // o estilo do <input> — que é exatamente o bug que a lista evita.
    dom, styles := styles_de(`input::selection{color:#00a000}`,
        `<body><input placeholder="x"></body>`)
    defer free_styles(styles)
    inp := find_tag218(dom, "input")
    if inp == nil { testing.fail(t); return }
    c := styles[inp]
    testing.expect(t, c.placeholder == nil, "::selection não vira ::placeholder")
    testing.expect(t, (c.color & 0xffffff) != 0x00a000, "::selection não vaza para o input")
}

@(test)
m218_caixa_recebe_cor_e_alfa :: proc(t: ^testing.T) {
    // A ponte estilo→caixa (é o que a pintura lê). `hint_alpha` nasce em 1 quando não
    // há regra — sem isso todo campo do mundo ficaria com a dica invisível.
    dom, styles := styles_de(`#a::placeholder{opacity:0} #b::placeholder{color:#123456}`,
        `<body><input id="a" placeholder="x"><input id="b" placeholder="y"><input id="c" placeholder="z"></body>`)
    defer free_styles(styles)
    root := build_layout(dom, styles, "")
    a := find_box_by_id218(root, "a"); b := find_box_by_id218(root, "b"); c := find_box_by_id218(root, "c")
    testing.expect(t, a != nil && b != nil && c != nil, "achou as 3 caixas")
    if a == nil || b == nil || c == nil do return
    testing.expect_value(t, a.hint_alpha, f32(0))
    testing.expect_value(t, b.hint_color & 0xffffff, u32(0x123456))
    testing.expect_value(t, b.hint_alpha, f32(1))
    testing.expect_value(t, c.hint_alpha, f32(1)) // sem regra: caminho antigo
    testing.expect_value(t, c.hint_color, u32(0))
}

@(private = "file")
find_box_by_id218 :: proc(b: ^Box, id: string) -> ^Box {
    if b == nil do return nil
    if b.node != nil {
        if v, ok := b.node.attrs["id"]; ok && v == id do return b
    }
    for c in b.children {
        if r := find_box_by_id218(c, id); r != nil do return r
    }
    for &it in b.inlines {
        if it.kind == .InlineBox && it.box != nil {
            if r := find_box_by_id218(it.box, id); r != nil do return r
        }
    }
    return nil
}
