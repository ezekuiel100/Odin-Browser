package ui

// M174 — `width` em PORCENTAGEM era ignorada em ÁTOMO INLINE (campo de formulário).
//
// Origem: a busca do topo do tradebig.com.br, último item aberto do screenshot do
// usuário — um campo de ~58px no lugar de 512. O layout da PÁGINA estava certo (o
// wrapper media 512 no dump, vivo e estático); quem colapsava era a caixa do
// próprio `<input class="w-full">`.
//
// Raiz: em `layout_inline`, o átomo `.InlineBox` (inline-block, `<input>`,
// `<textarea>`, `<svg>`) é dimensionado por `measure_intrinsic_w`, que ignora
// `width_pct` DE PROPÓSITO — uma % não contribui p/ max-content. Só que ali o
// container (`cw`) É conhecido e ninguém resolvia a % depois. Um campo VAZIO tem
// conteúdo intrínseco 0, então media só o próprio padding: `pl-10` + `px-4` = 56px
// + borda ≈ 58. Alcance muito além do tradebig: `w-full` do Tailwind e
// `.form-control` do Bootstrap são ambos `width: 100%`.

import "core:testing"
import htmlp "../html"
import csspkg "../css"

@(private = "file")
lay174 :: proc(html: string, vw: f32 = 800, vh: f32 = 600) -> ^Box {
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, vw, vh)
    root := build_layout(dom, styles, "")
    layout_box(root, 0, 0, vw)
    page := Rect{0, 0, vw, vh}
    layout_absolutes(root, page, page)
    return root
}

// Acha uma caixa por TAG. ⚠️ precisa descer também nos ÁTOMOS INLINE (`it.box`) —
// um `<input>` em fluxo de texto não é filho de `children`, é item de `inlines`,
// e uma busca só por `children` não o encontraria (o teste passaria vazio).
@(private = "file")
find_tag174 :: proc(b: ^Box, tag: string) -> ^Box {
    if b == nil do return nil
    if b.node != nil && b.node.tag == tag do return b
    for c in b.children {
        if r := find_tag174(c, tag); r != nil do return r
    }
    for &it in b.inlines {
        if it.kind == .InlineBox && it.box != nil {
            if r := find_tag174(it.box, tag); r != nil do return r
        }
    }
    return nil
}

// O caso do site: campo VAZIO com width:100% dentro de um container de 400px.
@(test)
m174_input_width_pct_enche_o_container :: proc(t: ^testing.T) {
    root := lay174(`<body style="margin:0"><div style="width:400px">` +
        `<input id="a" style="width:100%;box-sizing:border-box;padding:0 8px 0 40px;border:1px solid red">` +
        `</div></body>`)
    inp := find_tag174(root, "input")
    testing.expect(t, inp != nil, "achou o input")
    if inp == nil do return
    testing.expectf(t, inp.w == 400, "input width:100%% = 400 (border-box), tem %.1f", inp.w)
}

// Sem a % o campo mede o INTRÍNSECO — e é isso que dava 58px no tradebig. Esta é a
// guarda que prova que o teste acima pode falhar: o mesmo campo, sem `width`,
// TEM de continuar pequeno (medido pelo padding), senão o teste de cima passaria
// por qualquer motivo.
@(test)
m174_input_sem_width_segue_intrinseco :: proc(t: ^testing.T) {
    root := lay174(`<body style="margin:0"><div style="width:400px">` +
        `<input id="a" style="box-sizing:border-box;padding:0 8px 0 40px;border:1px solid red">` +
        `</div></body>`)
    inp := find_tag174(root, "input")
    testing.expect(t, inp != nil, "achou o input")
    if inp == nil do return
    testing.expectf(t, inp.w < 400, "sem width o campo NAO enche o container, tem %.1f", inp.w)
}

// Porcentagem diferente de 100 e largura em px (não-regressão).
@(test)
m174_input_width_pct_parcial_e_px :: proc(t: ^testing.T) {
    root := lay174(`<body style="margin:0"><div style="width:400px">` +
        `<input id="a" style="width:50%;box-sizing:border-box;padding:0;border:0">` +
        `</div></body>`)
    inp := find_tag174(root, "input")
    testing.expect(t, inp != nil, "achou o input")
    if inp != nil do testing.expectf(t, inp.w == 200, "width:50%% de 400 = 200, tem %.1f", inp.w)

    root2 := lay174(`<body style="margin:0"><div style="width:400px">` +
        `<input id="b" style="width:120px;box-sizing:border-box;padding:0;border:0">` +
        `</div></body>`)
    inp2 := find_tag174(root2, "input")
    testing.expect(t, inp2 != nil, "achou o input px")
    if inp2 != nil do testing.expectf(t, inp2.w == 120, "width:120px intacto, tem %.1f", inp2.w)
}

// `<textarea>` é o outro controle que vira átomo inline — mesmo caminho.
@(test)
m174_textarea_width_pct :: proc(t: ^testing.T) {
    root := lay174(`<body style="margin:0"><div style="width:400px">` +
        `<textarea id="a" style="width:100%;box-sizing:border-box;padding:0;border:0"></textarea>` +
        `</div></body>`)
    ta := find_tag174(root, "textarea")
    testing.expect(t, ta != nil, "achou o textarea")
    if ta == nil do return
    testing.expectf(t, ta.w == 400, "textarea width:100%% = 400, tem %.1f", ta.w)
}

// A estrutura EXATA do tradebig: wrapper `position:relative; width:100%` dentro de
// um item flex com max-width — o campo tem de herdar os 512 até o fim da cadeia.
@(test)
m174_cadeia_do_tradebig :: proc(t: ^testing.T) {
    root := lay174(`<body style="margin:0"><div style="display:flex;width:1216px">` +
        `<div style="flex:1 1 0%;max-width:512px">` +
        `<div style="position:relative;width:100%">` +
        `<input id="busca" style="width:100%;box-sizing:border-box;padding:8px 16px 8px 40px;border:1px solid #ccc">` +
        `</div></div></div></body>`)
    inp := find_tag174(root, "input")
    testing.expect(t, inp != nil, "achou a busca")
    if inp == nil do return
    testing.expectf(t, inp.w == 512, "a busca ocupa os 512 do max-w-lg, tem %.1f", inp.w)
}
