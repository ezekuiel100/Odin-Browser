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
