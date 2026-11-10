package ui

// A caixa de destino de um <img> (M191).
//
// `b.img_dw/img_dh` é o retângulo em que a imagem é desenhada — é ele que o
// `object-fit` usa como caixa de referência no paint. O cálculo olhava só
// `b.has_height` (height em px), e por isso ignorava as DUAS outras formas de a
// altura ficar definida: `height:<%>` (resolvida pelo PAI) e os INSETS de um
// absoluto (top+bottom, resolvidos em place_absolute). Ambas chegam ao layout_box
// por `force_h`, ou seja, dentro de `avail_h`.
//
// Sem imagem carregada (não há rede em `odin test`), `image_dims` cai nos
// atributos width/height do HTML — é o que dá o tamanho INTRÍNSECO aqui: 8x2,
// aspecto 4:1, bem diferente das caixas usadas nos testes.
//
// ⚠️ `<img>` só vira Box (o caminho que usa img_dw/img_dh) em contexto de BLOCO;
// sozinho num div ele vira item INLINE e o teste mede outra coisa. Daí o irmão
// `<div>` em cada fixture — é a mesma situação do site. Uma img EM FLUXO é
// inline por padrão, então nesses dois casos ela leva `display:block`.

import "core:testing"
import htmlp "../html"
import csspkg "../css"

@(test)
img_famosos_flex_percentage_overrides_html_height :: proc(t: ^testing.T) {
    // Exact structure and dimensions from Famosos-BR's index.astro/index.css:
    // the HTML reserves 80x90; CSS makes it fill a square 80x80 flex container.
    root := layout_from_html(`<body style="margin:0"><div style="display:flex;align-items:center;gap:24px">
        <div style="display:flex;align-items:center;justify-content:center;width:80px;height:80px;border-radius:50%">
            <img id="foto" width="80" height="90" style="width:100%;height:100%;border-radius:50%;object-fit:cover">
        </div><div>Nome</div></div></body>`)
    defer free_layout(root)
    f := acha(root, "foto")
    if !testing.expect(t, f != nil) do return
    testing.expectf(t, f.w == 80 && f.h == 80, "avatar box must be 80x80, got %vx%v", f.w, f.h)
    testing.expectf(t, f.img_dw == 80 && f.img_dh == 80, "photo must paint 80x80, got %vx%v", f.img_dw, f.img_dh)
}

@(test)
flex_percentage_height_is_not_stretched_or_resolved_against_line :: proc(t: ^testing.T) {
    root := layout_from_html(`<body style="margin:0"><div style="display:flex;flex-wrap:wrap;align-items:stretch;align-content:space-between;width:100px;height:200px">
        <div id="foto" style="width:100px;flex-shrink:0;height:25%"></div>
        <div style="width:100px;flex-shrink:0;height:20px"></div></div></body>`)
    defer free_layout(root)
    f := acha(root, "foto")
    if !testing.expect(t, f != nil) do return
    testing.expectf(t, f.h == 50, "25%% of the 200px container, not of the flex line: %v", f.h)
}

@(test)
flex_percentage_height_indefinite_remains_auto :: proc(t: ^testing.T) {
    root := layout_from_html(`<body style="margin:0"><div style="display:flex;align-items:center;width:80px">
        <img id="foto" width="80" height="90" style="width:100%;height:100%">
        </div></body>`)
    defer free_layout(root)
    f := acha(root, "foto")
    if !testing.expect(t, f != nil) do return
    testing.expect(t, f.h == 90, "a percentage against an auto-height parent must keep the intrinsic height")
}

@(test)
flex_percentage_height_accounts_for_box_sizing_and_limits :: proc(t: ^testing.T) {
    root := layout_from_html(`<body style="margin:0"><div style="display:flex;align-items:center;width:300px;height:100px">
        <div id="content" style="width:40px;height:50%;padding:5px;border:5px solid black"></div>
        <div id="border" style="box-sizing:border-box;width:40px;height:50%;padding:5px;border:5px solid black"></div>
        <div id="limited" style="width:40px;height:100%;max-height:60px"></div></div></body>`)
    defer free_layout(root)
    c := acha(root, "content"); b := acha(root, "border"); l := acha(root, "limited")
    if !testing.expect(t, c != nil && b != nil && l != nil) do return
    testing.expectf(t, c.h == 70 && b.h == 50 && l.h == 60, "content-box/border-box/max-height: got %v/%v/%v", c.h, b.h, l.h)
}

@(test)
img_flex_uses_final_content_dimensions :: proc(t: ^testing.T) {
    root := layout_from_html(`<body style="margin:0"><div style="display:flex;width:170px;align-items:center">
        <img id="foto" width="200" height="300" style="width:90px;height:80px;min-width:0;object-fit:cover;border-radius:50%">
        <div style="width:90px;flex-shrink:0"></div></div></body>`)
    defer free_layout(root)
    f := acha(root, "foto")
    if !testing.expect(t, f != nil) do return
    testing.expect(t, abs(f.w-80) < 0.01 && abs(f.h-80) < 0.01, "used avatar box is square after flex shrink")
    testing.expect(t, abs(f.img_dw-80) < 0.01 && abs(f.img_dh-80) < 0.01, "paint dimensions must match the square clip, independent of the portrait source")
}

@(test)
img_percentage_width_is_not_resolved_twice :: proc(t: ^testing.T) {
    root := layout_from_html(`<body style="margin:0"><div style="width:160px">
        <img id="foto" width="200" height="300" style="display:block;width:50%;height:80px;object-fit:cover;border-radius:50%">
        <div></div></div></body>`)
    defer free_layout(root)
    f := acha(root, "foto")
    if !testing.expect(t, f != nil) do return
    testing.expect(t, f.w == 80 && f.h == 80 && f.img_dw == 80 && f.img_dh == 80, "50% resolves against the container once, not against the image's own width")
}

@(private = "file")
layout_from_html :: proc(html: string, vw: f32 = 800, vh: f32 = 600) -> ^Box {
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, vw, vh)
    root := build_layout(dom, styles, "")
    layout_box(root, 0, 0, vw)
    page := Rect{0, 0, vw, vh}
    layout_absolutes(root, page, page)
    return root
}

@(private = "file")
acha :: proc(b: ^Box, id: string) -> ^Box {
    if b == nil do return nil
    if b.node != nil && b.node.attrs != nil {
        if v, ok := b.node.attrs["id"]; ok && v == id do return b
    }
    for ch in b.children {
        if r := acha(ch, id); r != nil do return r
    }
    return nil
}

// O caso do ultra-photo: `absolute inset-0 w-full h-full`. A caixa de destino tem
// de ser a do CONTAINER (400x200) — com a altura vindo do aspecto (400x100) o
// object-fit calcularia o encaixe contra uma caixa que não existe, e a foto saía
// esticada e sem letterbox.
@(test)
img_absoluta_com_insets_usa_a_caixa :: proc(t: ^testing.T) {
    root := layout_from_html(
        `<div style="position:relative;width:400px;height:200px">
            <img id="foto" src="x.png" width="8" height="2"
                 style="position:absolute;top:0;bottom:0;left:0;right:0;width:100%;height:100%;object-fit:contain">
            <div>irmao de bloco</div>
         </div>`)
    f := acha(root, "foto")
    if !testing.expect(t, f != nil, "achou a img") do return
    testing.expectf(t, f.img_dw == 400, "largura da caixa; veio %.0f", f.img_dw)
    testing.expectf(t, f.img_dh == 200, "ALTURA da caixa (nao a do aspecto, 100); veio %.0f", f.img_dh)
    testing.expectf(t, f.obj_fit == .Contain, "object-fit chega como Contain; veio %v", f.obj_fit)
}

// `height:<%>` com o pai de altura definida. ⚠️ HONESTIDADE: este par passa MESMO
// SEM o fix (a % já chega resolvida em b.height nesse caminho) — não é ele que
// prova a correção, é guarda de que height:% segue certo. Quem falha sem o fix é
// o teste do absoluto acima (dá 100 em vez de 200).
@(test)
img_com_altura_percentual_usa_a_caixa :: proc(t: ^testing.T) {
    root := layout_from_html(
        `<div style="width:400px;height:200px">
            <img id="foto" src="x.png" width="8" height="2" style="display:block;width:100%;height:50%">
            <div>irmao de bloco</div>
         </div>`)
    f := acha(root, "foto")
    if !testing.expect(t, f != nil, "achou a img") do return
    testing.expectf(t, f.img_dh == 100, "50%% de 200 = 100; veio %.0f", f.img_dh)
}

// CONTROLE — sem altura definida a imagem TEM de manter o aspecto. É o que
// separa "usar a altura resolvida" de "esticar tudo": se este par quebrar, o fix
// passou a impor altura onde o autor pediu `auto`.
@(test)
img_sem_altura_mantem_aspecto :: proc(t: ^testing.T) {
    root := layout_from_html(
        `<div style="display:block;width:400px">
            <img id="foto" src="x.png" width="8" height="2" style="display:block;width:400px">
            <div>irmao de bloco</div>
         </div>`)
    f := acha(root, "foto")
    if !testing.expect(t, f != nil, "achou a img") do return
    testing.expectf(t, f.img_dw == 400, "largura pedida; veio %.0f", f.img_dw)
    testing.expectf(t, f.img_dh == 100, "altura pelo aspecto 4:1 = 100; veio %.0f", f.img_dh)
}
