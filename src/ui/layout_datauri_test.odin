package ui

// `<img src="data:…">` (M192).
//
// A camada de rede SEMPRE soube decodificar data URIs (`netpkg.fetch` desvia para
// `fetch_data_uri`, e `resolve_url` devolve a URI intacta de propósito). O que
// faltava era o layout ACEITAR o src: os dois pontos que leem `src` tinham um
// `&& !strings.has_prefix(src, "data:")` que jogava a URI fora, deixando
// `img_url` vazio — o `<img>` virava placeholder cinza.
//
// Estes testes cobrem os DOIS caminhos, que são código separado: `<img>` de
// BLOCO (vira Box, layout.odin ~456) e `<img>` INLINE (vira Inline_Item, ~1151).

import "core:testing"
import "core:strings"
import htmlp "../html"
import csspkg "../css"
import netpkg "../net"

// PNG 4x2 de verdade (o mesmo dos fixtures), em base64.
@(private = "file")
PNG_4X2 :: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAQAAAACCAIAAAD91JpzAAAAJUlEQVR4nGP8z4AATAxIYBRIYGD8jwCMDIz/UWWRJUelkYUBAlUEDGgV8DsAAAAASUVORK5CYII="

@(private = "file")
monta :: proc(html: string, vw: f32 = 800, vh: f32 = 600) -> ^Box {
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, vw, vh)
    root := build_layout(dom, styles, "")
    layout_box(root, 0, 0, vw)
    return root
}

@(private = "file")
acha_img_box :: proc(b: ^Box) -> ^Box {
    if b == nil do return nil
    if b.kind == .Image && b.img_url != "" do return b
    for ch in b.children {
        if r := acha_img_box(ch); r != nil do return r
    }
    return nil
}

@(private = "file")
acha_img_inline :: proc(b: ^Box) -> string {
    if b == nil do return ""
    for &it in b.inlines {
        if it.kind == .Image && it.img_url != "" do return it.img_url
    }
    for ch in b.children {
        if r := acha_img_inline(ch); r != "" do return r
    }
    return ""
}

// (1) <img> de BLOCO: o src tem de chegar em b.img_url.
@(test)
data_uri_chega_no_img_de_bloco :: proc(t: ^testing.T) {
    root := monta(strings.concatenate({
        `<div><img src="`, PNG_4X2, `" width="8" height="2" style="display:block"><div>irmao</div></div>`,
    }, context.temp_allocator))
    f := acha_img_box(root)
    if !testing.expect(t, f != nil, "o <img> de bloco tem de ficar com a data URI (img_url vazio = descartada)") do return
    testing.expect(t, strings.has_prefix(f.img_url, "data:image/png"), "a URI chega INTEIRA, sem passar por resolve contra a base")
}

// (2) <img> INLINE: outro ramo do código, mesma exigência.
@(test)
data_uri_chega_no_img_inline :: proc(t: ^testing.T) {
    root := monta(strings.concatenate({
        `<p>antes <img src="`, PNG_4X2, `" width="8" height="2"> depois</p>`,
    }, context.temp_allocator))
    u := acha_img_inline(root)
    testing.expect(t, strings.has_prefix(u, "data:image/png"), "o <img> inline tem de ficar com a data URI")
}

// (3) A ponta de baixo: a URI que passamos adiante DECODIFICA mesmo. Sem isto os
// dois testes acima só provariam que guardamos uma string.
@(test)
data_uri_decodifica_para_png :: proc(t: ^testing.T) {
    resp := netpkg.fetch(PNG_4X2)
    defer if resp.ok do delete(resp.body)
    testing.expect(t, resp.ok, "fetch de data: URI resolve local, sem rede")
    testing.expectf(t, len(resp.body) > 8, "corpo decodificado; veio %d bytes", len(resp.body))
    // assinatura PNG: \x89 P N G
    if len(resp.body) >= 4 {
        testing.expect(t, resp.body[0] == 0x89 && resp.body[1] == 'P' && resp.body[2] == 'N' && resp.body[3] == 'G',
            "os bytes decodificados são um PNG de verdade")
    }
}

// (4) Guarda: uma URL http comum NÃO pode ser confundida com data:.
@(test)
url_http_segue_normal :: proc(t: ^testing.T) {
    root := monta(`<div><img src="https://exemplo.com/a.png" width="8" height="2" style="display:block"><div>irmao</div></div>`)
    f := acha_img_box(root)
    if !testing.expect(t, f != nil, "achou o img") do return
    testing.expectf(t, f.img_url == "https://exemplo.com/a.png", "url http intacta; veio %q", f.img_url)
}
