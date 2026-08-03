package ui

// Tamanho mínimo automático de item flex no eixo INLINE (CSS Flexbox §4.5).
// `min-width` de um item flex tem valor inicial `auto`, que resolve para o mínimo
// BASEADO EM CONTEÚDO — não 0. Uma linha que não cabe deve TRANSBORDAR; espremer
// os itens abaixo do min-content é o bug (navbar do GitHub saía com os botões
// sobrepostos, e o Chrome transborda). A metade de COLUNA disto já existia em
// layout_flex_column desde o colapso do bandcamp; aqui vai a metade de LINHA.
//
// ⚠️ Nenhum teste daqui mede TEXTO de propósito: o runner do `odin test` não monta
// o atlas de fontes, então Font_CalcTextSizeA devolve 0 e toda largura de palavra
// viraria 0 — um teste de texto passaria por motivo errado. O piso é exercitado por
// um filho de `width` fixa, que não depende de métrica. O caso com texto de verdade
// mora no golden `tests/layout/flex-min-content-navbar.html`, que roda por
// --dumplayout (esse SIM monta o atlas).

import "core:strings"
import "core:testing"
import htmlp "../html"
import csspkg "../css"

@(private = "file")
lay :: proc(html: string) -> ^Box {
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, 800, 600)
    root := build_layout(dom, styles, "")
    layout_box(root, 0, 0, 800)
    page := Rect{0, 0, 800, 600}
    layout_absolutes(root, page, page)
    return root
}

@(private = "file")
por_classe :: proc(b: ^Box, cls: string) -> ^Box {
    if b == nil do return nil
    if b.node != nil {
        if c, ok := b.node.attrs["class"]; ok && c == cls do return b
    }
    for c in b.children {
        if r := por_classe(c, cls); r != nil do return r
    }
    return nil
}

// container de 100px com um item cujo conteúdo indivisível mede 200px.
@(private = "file")
largura_item :: proc(estilo_extra: string) -> f32 {
    html := strings.concatenate({
        `<body style="margin:0"><div style="display:flex;width:100px">`,
        `<div class="it"`, estilo_extra, `><div style="width:200px;height:10px"></div></div>`,
        `</div></body>`,
    }, context.temp_allocator)
    b := por_classe(lay(html), "it")
    return b == nil ? -1 : b.w
}

@(test)
test_flex_row_nao_encolhe_abaixo_do_min_content :: proc(t: ^testing.T) {
    // o item vale 200 de min-content e o container só tem 100: o certo é
    // TRANSBORDAR (ficar 200), não ser espremido a 100.
    w := largura_item("")
    testing.expectf(t, w == 200, "item deveria parar no min-content 200 e transbordar, veio %v", w)
}

@(test)
test_flex_row_min_width_explicito_ainda_manda :: proc(t: ^testing.T) {
    // CONTROLE que impede o teste acima de passar por acidente: com `min-width:0`
    // EXPLÍCITO o autor optou por sair do mínimo automático, e aí encolhe mesmo.
    // Se este falhasse junto com o de cima, o piso estaria sendo aplicado sempre.
    w := largura_item(` style="min-width:0"`)
    testing.expectf(t, w == 100, "min-width:0 explícito deveria permitir encolher a 100, veio %v", w)
}

@(test)
test_flex_row_scroll_container_zera_o_minimo :: proc(t: ^testing.T) {
    // §4.5: o mínimo automático vira 0 em SCROLL CONTAINER (o conteúdo rola).
    who := largura_item(` style="overflow:hidden"`)
    testing.expectf(t, who == 100, "overflow:hidden é scroll container, deveria encolher a 100, veio %v", who)
    wsc := largura_item(` style="overflow:scroll"`)
    testing.expectf(t, wsc == 100, "overflow:scroll deveria encolher a 100, veio %v", wsc)
}

@(test)
test_flex_row_overflow_clip_nao_zera_o_minimo :: proc(t: ^testing.T) {
    // ⚠️ `overflow:clip` NÃO é scroll container (recorta mas não rola), então o
    // mínimo de conteúdo VALE — mesma distinção que a metade de coluna já fazia.
    w := largura_item(` style="overflow:clip"`)
    testing.expectf(t, w == 200, "overflow:clip deveria PRESERVAR o mínimo 200, veio %v", w)
}

@(test)
test_flex_row_width_definida_limita_o_minimo :: proc(t: ^testing.T) {
    // §4.5: o mínimo automático é o MENOR entre a "specified size suggestion" (a
    // width definida) e o min-content. Com width:150 e conteúdo de 200, o piso é
    // 150 — nem 200 (não pode ultrapassar a width pedida) nem 100 (não encolhe).
    w := largura_item(` style="width:150px"`)
    testing.expectf(t, w == 150, "width:150 deveria limitar o piso a 150, veio %v", w)
}

@(test)
test_flex_row_com_folga_nao_muda_nada :: proc(t: ^testing.T) {
    // CONTROLE de que a mudança não mexe no caminho comum: quando cabe, cabe.
    html := `<body style="margin:0"><div style="display:flex;width:800px">` +
        `<div class="it"><div style="width:200px;height:10px"></div></div>` +
        `</div></body>`
    b := por_classe(lay(html), "it")
    testing.expect(t, b != nil, "item deveria existir")
    if b == nil do return
    testing.expectf(t, b.w == 200, "com folga o item fica no conteúdo (200), veio %v", b.w)
}
