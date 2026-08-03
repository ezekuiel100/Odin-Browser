package ui

// Lote 24 — grade IMPLÍCITA: grid-auto-rows / grid-auto-columns / grid-auto-flow.
// Três entradas seguidas do gap-report (10 + 8 + 8 sites). Antes: as linhas
// implícitas só cresciam pelo conteúdo (grid-auto-rows era IGNORADO), não existia
// coluna implícita, e o fluxo era sempre por LINHA com packing esparso.
// Testes de POSIÇÃO (não de parsing): é o layout que precisa provar o efeito.

import "core:testing"
import htmlp "../html"
import csspkg "../css"

@(private = "file")
grid_kids :: proc(html: string, vw: f32 = 600) -> []^Box {
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, vw, 600)
    root := build_layout(dom, styles, "")
    layout_box(root, 0, 0, vw)
    page := Rect{0, 0, vw, 600}
    layout_absolutes(root, page, page)
    g := find_grid(root)
    if g == nil do return nil
    return g.children[:]
}

@(private = "file")
find_grid :: proc(b: ^Box) -> ^Box {
    if b == nil do return nil
    if b.is_grid do return b
    for c in b.children {
        if r := find_grid(c); r != nil do return r
    }
    return nil
}

@(test)
test_grid_auto_rows :: proc(t: ^testing.T) {
    // sem grid-template-rows, TODA linha é implícita: grid-auto-rows manda.
    // (body tem margem 8px por padrão → medimos DIFERENÇAS, não absolutos)
    k := grid_kids(`<body style="margin:0"><div style="display:grid;grid-template-columns:1fr 1fr;grid-auto-rows:50px">
        <i>a</i><i>b</i><i>c</i><i>d</i></div></body>`)
    testing.expect(t, len(k) == 4, "esperados 4 itens")
    if len(k) < 4 do return
    testing.expectf(t, k[2].y - k[0].y == 50, "linha implícita deveria ter 50px, veio %v", k[2].y - k[0].y)
    testing.expectf(t, k[0].h == 50, "o item deve esticar na linha de 50px, veio %v", k[0].h)
}

@(test)
test_grid_auto_rows_nao_cresce_com_conteudo :: proc(t: ^testing.T) {
    // trilha implícita FIXA não é engordada pelo conteúdo (o conteúdo transborda),
    // ao contrário da trilha `auto` — é a diferença que a prop existe p/ expressar.
    k := grid_kids(`<body style="margin:0"><div style="display:grid;grid-template-columns:1fr;grid-auto-rows:20px">
        <i style="height:90px">a</i><i>b</i></div></body>`)
    testing.expect(t, len(k) == 2, "esperados 2 itens")
    if len(k) < 2 do return
    testing.expectf(t, k[1].y - k[0].y == 20, "linha fixa de 20px não deveria crescer p/ o conteúdo de 90px, veio %v", k[1].y - k[0].y)
}

@(test)
test_grid_auto_flow_column :: proc(t: ^testing.T) {
    // fluxo por COLUNA: preenche as linhas do template p/ baixo e cria colunas.
    k := grid_kids(`<body style="margin:0"><div style="display:grid;grid-template-rows:40px 40px;grid-auto-flow:column;grid-auto-columns:80px">
        <i>a</i><i>b</i><i>c</i><i>d</i></div></body>`)
    testing.expect(t, len(k) == 4, "esperados 4 itens")
    if len(k) < 4 do return
    // a,b na 1ª coluna (linhas 0 e 1); c,d na 2ª
    testing.expectf(t, k[0].x == k[1].x, "a e b deveriam ficar na MESMA coluna, veio %v vs %v", k[0].x, k[1].x)
    testing.expectf(t, k[1].y - k[0].y == 40, "b deveria estar na 2ª linha (40px abaixo), veio %v", k[1].y - k[0].y)
    testing.expectf(t, k[2].y == k[0].y, "c deveria voltar p/ a 1ª linha, veio %v vs %v", k[2].y, k[0].y)
    testing.expectf(t, k[2].x - k[0].x == 80, "c deveria estar na 2ª coluna implícita (80px), veio %v", k[2].x - k[0].x)
    testing.expectf(t, k[0].w == 80, "a coluna implícita deveria ter 80px (grid-auto-columns), veio %v", k[0].w)
}

@(test)
test_grid_auto_flow_dense :: proc(t: ^testing.T) {
    // 3 colunas; A ocupa a linha toda; B (span 2) vai p/ a linha 1 e deixa um
    // BURACO em (1,2); C (span 2) não cabe nele e desce p/ a linha 2.
    // Esparso: D fica ao LADO de C (o cursor nunca volta). Denso: D VOLTA e tapa
    // o buraco da linha de B. (A 1ª expectativa que escrevi — "D abaixo de C" —
    // estava errada: no esparso D cai na mesma linha de C.)
    html :: `<body style="margin:0"><div style="display:grid;grid-template-columns:1fr 1fr 1fr;grid-auto-rows:20px%s">
        <i style="grid-column:span 3">A</i><i style="grid-column:span 2">B</i>
        <i style="grid-column:span 2">C</i><i>D</i></div></body>`
    esparso := grid_kids(fmt_sub(html, ""))
    denso   := grid_kids(fmt_sub(html, ";grid-auto-flow:row dense"))
    testing.expect(t, len(esparso) == 4 && len(denso) == 4, "esperados 4 itens")
    if len(esparso) < 4 || len(denso) < 4 do return
    testing.expectf(t, esparso[3].y == esparso[2].y,
        "esparso: D deveria ficar AO LADO de C, na última linha (y %v vs %v)", esparso[3].y, esparso[2].y)
    testing.expectf(t, denso[3].y < denso[2].y,
        "denso: D deveria TAPAR o buraco acima de C (y %v vs %v)", denso[3].y, denso[2].y)
    testing.expectf(t, denso[3].y == denso[1].y,
        "denso: D deveria ficar na MESMA linha de B, veio %v vs %v", denso[3].y, denso[1].y)
}

// substituição simples de "%s" (evita depender de core:fmt nos testes)
@(private = "file")
fmt_sub :: proc(tpl, val: string) -> string {
    i := 0
    for ; i + 1 < len(tpl); i += 1 do if tpl[i] == '%' && tpl[i + 1] == 's' do break
    if i + 1 >= len(tpl) do return tpl
    out := make([]u8, len(tpl) - 2 + len(val), context.temp_allocator)
    copy(out[:i], tpl[:i])
    copy(out[i:], val)
    copy(out[i + len(val):], tpl[i + 2:])
    return string(out)
}

@(test)
test_grid_sem_row_sizing_nao_colapsa :: proc(t: ^testing.T) {
    // REGRESSÃO do lote 24, achada só no lote 28 (o WPT NÃO pegou): o array de
    // trilhas efetivas era zerado, e o zero-value de Grid_Track_Kind é .Fixed —
    // então TODA linha implícita virava "fixa", nunca era engordada pelo conteúdo,
    // e um grid SEM grid-template-rows/grid-auto-rows (o caso mais comum) ia p/ h=0.
    // Meus testes do lote 24 não pegaram porque TODOS declaravam grid-auto-rows.
    k := grid_kids(`<body style="margin:0"><div style="display:grid;grid-template-columns:100px 100px">
        <div><i>a</i></div><div><i>b</i></div></div></body>`)
    testing.expect(t, len(k) == 2, "esperados 2 itens")
    if len(k) < 2 do return
    testing.expectf(t, k[0].h > 5, "item de grid sem sizing de linha deveria ter altura de conteúdo, veio %v", k[0].h)
}
