package ui

// M242 — a margem de um ÁTOMO inline (inline-block/inline-flex/inline-grid/
// inline-table/<svg> em fluxo) era descartada por COMPLETO, nos quatro lados.
//
// Sintoma em site real (tradebig.com.br, topo da lista): o toggle Brasil/EUA é
// `<div class="inline-flex … mb-6">` e os cards começavam COLADOS nele — os 24px
// de `mb-6` simplesmente não existiam. O Chrome põe o irmão seguinte 24px abaixo.
//
// Raiz, em dois pontos que se somavam:
//   (1) build_inline_items: o ramo de átomo inline dá `return` ANTES do bloco que
//       converte margem/padding/borda de elemento inline em pad_before/pad_after —
//       aquele bloco trata o inline NÃO-substituído, e o átomo nunca chegava nele;
//   (2) o case .InlineBox do layout da linha gravava `it.w/it.h = bx.w/bx.h`, ou
//       seja a BORDER box. Como finalize_line/item_ascent medem a linha por it.h,
//       a margem não existia para a altura da linha.
//   CSS 2.1 §10.8.1: para átomo inline o que entra na linha é a MARGIN box.
//
// A `margin-left` era o único lado que "funcionava", e por acidente: layout_box faz
// `b.x = x + ml`, e o paint soma bx.x de volta. Por isso o conserto lê as margens
// efetivas de bx.x/bx.y — somar b.margin[3] por cima DUPLICARIA a esquerda (e o
// default de UA de <p> & cia. entra em bx.y sem passar por b.margin[0]).
//
// ⚠️ sem atlas de fontes em `odin test` a medição de texto devolve 0 — todas as
// asserções usam dimensões EXPLÍCITAS (ver [[odin-test-armadilhas]]).

import "core:strings"
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

// Acha por id descendo pelos filhos de BLOCO **e** pelas caixas penduradas nos
// itens inline (um átomo inline não é `children`, é `inlines[i].box`).
@(private = "file")
find_id :: proc(b: ^Box, want: string) -> ^Box {
    if b == nil do return nil
    if b.node != nil && b.node.attrs != nil {
        if v, ok := b.node.attrs["id"]; ok && v == want do return b
    }
    for c in b.children {
        if r := find_id(c, want); r != nil do return r
    }
    for &it in b.inlines {
        if it.kind == .InlineBox && it.box != nil {
            if r := find_id(it.box, want); r != nil do return r
        }
    }
    return nil
}

// A caixa de 40px de altura + o bloco de 20px logo abaixo; a `<section>` mede a
// soma, então a altura DELA é a leitura direta de quanta margem entrou na linha.
@(private = "file")
sec :: proc(estilo: string) -> (altura: f32, depois_rel: f32) {
    // `+` de string em Odin só vale entre CONSTANTES; `estilo` é parâmetro.
    // (strings.concatenate e não fmt.tprintf: CSS tem `{`, que o tprintf lê como
    // chave de formatação — aqui não há, mas o idioma seguro é este.)
    html := strings.concatenate({
        `<section id="s" style="width:400px"><div id="a" style="width:100px;height:40px;`,
        estilo,
        `"></div><div id="d" style="height:20px"></div></section>`,
    }, context.temp_allocator)
    root := layout_from_html(html)
    s := find_id(root, "s")
    d := find_id(root, "d")
    if s == nil || d == nil do return -1, -1
    return s.h, d.y - s.y
}

// (1) O BUG, na forma exata do tradebig: `inline-flex` + `margin-bottom`.
@(test)
test_m242_margem_inferior_de_atomo_inline :: proc(t: ^testing.T) {
    h, dy := sec("display:inline-flex;margin-bottom:24px")
    // 40 (caixa) + 24 (margem) + 20 (o bloco seguinte) = 84
    testing.expectf(t, h == 84, "inline-flex mb:24 → section h=%.0f, esperado 84", h)
    testing.expectf(t, dy == 64, "o irmão devia cair em +64, caiu em +%.0f", dy)

    h2, dy2 := sec("display:inline-block;margin-bottom:24px")
    testing.expectf(t, h2 == 84, "inline-block mb:24 → section h=%.0f, esperado 84", h2)
    testing.expectf(t, dy2 == 64, "o irmão devia cair em +64, caiu em +%.0f", dy2)
}

// (2) `margin-top` do átomo: empurra a caixa para baixo E cresce a linha (era o
// caso mais enganoso — o paint JÁ deslocava a caixa por bx.y, mas a linha não
// crescia, então o átomo invadia o conteúdo de baixo em vez de afastá-lo).
@(test)
test_m242_margem_superior_de_atomo_inline :: proc(t: ^testing.T) {
    h, dy := sec("display:inline-flex;margin-top:24px")
    testing.expectf(t, h == 84, "inline-flex mt:24 → section h=%.0f, esperado 84", h)
    testing.expectf(t, dy == 64, "o irmão devia cair em +64, caiu em +%.0f", dy)

    root := layout_from_html(
        `<section id="s" style="width:400px"><div id="a" style="width:100px;height:40px;display:inline-flex;margin-top:24px"></div></section>`)
    a := find_id(root, "a")
    testing.expect(t, a != nil, "o átomo inline tem de ser alcançável por inlines[].box")
    if a != nil {
        // bx.y é a margem superior efetiva (layout_box foi chamado com y=0)
        testing.expectf(t, a.y == 24, "a border-box devia estar 24px abaixo do topo da linha, está em %.0f", a.y)
    }
}

// (3) Eixo horizontal: `margin-right` tem de AVANÇAR o próximo item da linha, e
// `margin-left` NÃO pode ser contada duas vezes (ela já vive em bx.x).
@(test)
test_m242_margem_horizontal_de_atomo_inline :: proc(t: ^testing.T) {
    // sem espaço em branco entre as tags: `space_before` somaria 4px e embaralharia
    root := layout_from_html(
        `<div id="w" style="width:400px"><div id="a" style="width:100px;height:40px;display:inline-block;margin-right:30px"></div><div id="b" style="width:100px;height:40px;display:inline-block"></div></div>`)
    w := find_id(root, "w")
    testing.expect(t, w != nil && len(w.inlines) == 2, "esperados 2 átomos inline na linha")
    if w == nil || len(w.inlines) != 2 do return
    // it.x é o canto da MARGIN box; o 1º item ocupa 100+30
    testing.expectf(t, w.inlines[0].w == 130, "margin box do 1º devia medir 130, mede %.0f", w.inlines[0].w)
    testing.expectf(t, w.inlines[1].x == 130, "o 2º átomo devia começar em 130, começa em %.0f", w.inlines[1].x)

    // margin-left: a border-box sai em 30, e o item mede 130 — não 160 (duplicada)
    root2 := layout_from_html(
        `<div id="w" style="width:400px"><div id="a" style="width:100px;height:40px;display:inline-block;margin-left:30px"></div></div>`)
    w2 := find_id(root2, "w")
    a2 := find_id(root2, "a")
    testing.expect(t, w2 != nil && len(w2.inlines) == 1 && a2 != nil)
    if w2 == nil || len(w2.inlines) != 1 || a2 == nil do return
    testing.expectf(t, w2.inlines[0].w == 130, "margin box devia medir 130 (não 160 = esquerda em dobro), mede %.0f", w2.inlines[0].w)
    testing.expectf(t, a2.x == 30, "a border-box devia sair em 30, saiu em %.0f", a2.x)
}

// (4) CONTROLES — têm de passar nos DOIS binários (antes e depois do conserto).
// Sem eles o teste acima não distingue "margem entrou" de "tudo cresceu 24px".
@(test)
test_m242_controles :: proc(t: ^testing.T) {
    // bloco com a MESMA margem: o caminho de bloco sempre funcionou
    h, dy := sec("display:block;margin-bottom:24px")
    testing.expectf(t, h == 84, "controle bloco mb:24 → section h=%.0f, esperado 84", h)
    testing.expectf(t, dy == 64, "controle bloco: irmão em +%.0f, esperado +64", dy)

    // átomo inline SEM margem: nada pode ter mudado
    for est in ([]string{"display:inline-flex", "display:inline-block"}) {
        h2, dy2 := sec(est)
        testing.expectf(t, h2 == 60, "controle %s sem margem → section h=%.0f, esperado 60", est, h2)
        testing.expectf(t, dy2 == 40, "controle %s: irmão em +%.0f, esperado +40", est, dy2)
    }
}
