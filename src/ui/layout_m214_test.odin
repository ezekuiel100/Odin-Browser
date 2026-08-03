package ui

// M214 — `white-space` não chegava na caixa ANÔNIMA de um container flex/grid.
//
// Origem: a navegação do github.com saía espremida, com o texto de um item por cima
// do próximo ("Open So" seguido de "Enterprise"). O item de "Open Source" tinha 69px
// e o texto dentro dele, 94.
//
// Raiz: texto solto dentro de um container flex/grid vira uma caixa anônima, e
// `build_item_children` a construía com `white-space` **`.Normal` FIXO** — enquanto o
// caminho de bloco (`build_block_children`) já recebia o valor efetivo por parâmetro.
// Com os itens inline sem `nowrap`, o `inline_min_width` (M205) achava uma
// oportunidade de quebra no espaço e devolvia a maior PALAVRA; o tamanho mínimo
// automático do item flex (§4.5) caía junto e o item encolhia até caber só "Source".
//
// O que localizou a linha foi uma ASSIMETRIA: o mesmo texto dentro de um `<span>`
// media certo e solto media errado. O span tem `Computed` próprio (com o `nowrap`
// herdado); o texto solto dependia do parâmetro que estava fixo. **Quando dois
// caminhos que deveriam ser equivalentes divergem, o parâmetro esquecido está no que
// NÃO tem estilo próprio.** Conferido no Chrome: lá os dois medem igual.
//
// ⚠️ Estes testes conferem a FLAG `nowrap` dos itens inline, não larguras: o
// `odin test` não monta o atlas de fontes e toda métrica de texto sai 0 (armadilha
// já catalogada). A consequência em LARGURA é medida pelo golden
// `tests/layout/flex-anon-nowrap.html`, que roda por `--dumplayout` — lá a fonte
// existe.

import "core:testing"
import htmlp "../html"
import csspkg "../css"

@(private = "file")
lay214 :: proc(html: string, vw: f32 = 700, vh: f32 = 500) -> ^Box {
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, vw, vh)
    return build_layout(dom, styles, "")
}

@(private = "file")
find_id214 :: proc(b: ^Box, id: string) -> ^Box {
    if b == nil do return nil
    if b.node != nil {
        if v, ok := b.node.attrs["id"]; ok && v == id do return b
    }
    for c in b.children {
        if r := find_id214(c, id); r != nil do return r
    }
    for &it in b.inlines {
        if it.kind == .InlineBox && it.box != nil {
            if r := find_id214(it.box, id); r != nil do return r
        }
    }
    return nil
}

// `nowrap` do PRIMEIRO item Word da subárvore (é onde a quebra é decidida).
// Devolve (valor, achou) — sem o `achou`, uma fixture que não produzisse Word
// nenhum passaria como `false` e o teste não poderia falhar.
@(private = "file")
primeiro_word_nowrap :: proc(b: ^Box) -> (bool, bool) {
    if b == nil do return false, false
    for &it in b.inlines {
        if it.kind == .Word do return it.nowrap, true
    }
    for c in b.children {
        if v, ok := primeiro_word_nowrap(c); ok do return v, true
    }
    for &it in b.inlines {
        if it.kind == .InlineBox && it.box != nil {
            if v, ok := primeiro_word_nowrap(it.box); ok do return v, true
        }
    }
    return false, false
}

@(private = "file")
nowrap_de :: proc(t: ^testing.T, src, id: string) -> bool {
    box := find_id214(lay214(src), id)
    testing.expectf(t, box != nil, "achou #%s", id)
    if box == nil do return false
    v, ok := primeiro_word_nowrap(box)
    testing.expectf(t, ok, "#%s produziu ao menos um Word", id)
    return v
}

@(test)
m214_anon_de_flex_herda_nowrap :: proc(t: ^testing.T) {
    // texto SOLTO dentro do flex (caixa anônima) — era aqui que o `.Normal` fixo batia
    src := `<body><div id="a" style="display:flex;white-space:nowrap">Open Source</div></body>`
    testing.expect_value(t, nowrap_de(t, src, "a"), true)
}

@(test)
m214_span_dentro_do_flex_continua_certo :: proc(t: ^testing.T) {
    // o caminho que JÁ funcionava (o span tem Computed próprio): é a assimetria que
    // localizou o bug, e o teste que garante que os dois caminhos concordam
    src := `<body><div id="a" style="display:flex;white-space:nowrap"><span>Open Source</span></div></body>`
    testing.expect_value(t, nowrap_de(t, src, "a"), true)
}

@(test)
m214_sem_nowrap_continua_podendo_quebrar :: proc(t: ^testing.T) {
    // CONTROLE: se o fix tivesse marcado nowrap sempre, este teste pegaria.
    src := `<body><div id="a" style="display:flex">Open Source</div></body>`
    testing.expect_value(t, nowrap_de(t, src, "a"), false)
}

@(test)
m214_grid_tambem_herda :: proc(t: ^testing.T) {
    // o mesmo `build_item_children` serve flex E grid
    src := `<body><div id="a" style="display:grid;white-space:nowrap">Open Source</div></body>`
    testing.expect_value(t, nowrap_de(t, src, "a"), true)
    src2 := `<body><div id="a" style="display:grid">Open Source</div></body>`
    testing.expect_value(t, nowrap_de(t, src2, "a"), false)
}

@(test)
m214_nowrap_herdado_de_ancestral :: proc(t: ^testing.T) {
    // `white-space` é herdada: o flex nem precisa declarar — o valor efetivo do
    // container é que vale, e é ele que o parâmetro carrega.
    src := `<body style="white-space:nowrap"><div id="a" style="display:flex">Open Source</div></body>`
    testing.expect_value(t, nowrap_de(t, src, "a"), true)
}

@(test)
m214_bloco_continua_certo :: proc(t: ^testing.T) {
    // CONTROLE do caminho vizinho (`build_block_children`), que já passava o `ws`.
    src := `<body><div id="a" style="white-space:nowrap">Open Source</div></body>`
    testing.expect_value(t, nowrap_de(t, src, "a"), true)
}
