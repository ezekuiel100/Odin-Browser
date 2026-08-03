package ui

// M212 — `position:fixed` SEM insets, sob um ancestral `position:relative`, MIGRAVA
// para o fim do documento a partir do 2º passe de layout.
//
// Origem: a home do github.com aparecia vazia. O `<h1>` do hero existia, tinha
// tamanho certo e y=164 — e mesmo assim não aparecia. A sonda de pintura
// (`-define:PAINTPROBE=true`) mostrou o motivo: no 1º frame a caixa era pintada em
// y=164 e do 2º em diante em **y=13601** (a página tem 14812), ou seja, fora da tela.
//
// Raiz: `layout_absolutes_rec` levava UMA âncora de içamento, calculada a partir do
// bloco contenedor de ABSOLUTE (`ccb_box`). Mas `position:relative` estabelece CB
// para absolute e **não** para fixed. Sob `.lp-Intro{position:relative}` a âncora do
// fixed virava ELE MESMO, e `mark_hoisted` desiste nesse caso (`anchor == child`):
// a caixa era içada para a raiz SEM registro. No passe seguinte o bloco que grava a
// posição estática não tinha `hoist_anchor` para recompor e lia `cy` — que, com a
// caixa já içada para junto da raiz, é a base de TODO o documento.
//
// ⚠️ É invisível em um passe só: o `--dumplayout` (e por consequência os goldens de
// `tests/layout`) roda `layout_box` + `layout_absolutes` UMA vez e acerta. Estes
// testes rodam o par DUAS vezes de propósito — é a única forma de reproduzir o que
// o `--render` faz a cada frame. Mesma assinatura do M196.

import "core:testing"
import htmlp "../html"
import csspkg "../css"

// Monta e roda o layout `passes` vezes, como o loop de frames do --render.
@(private = "file")
lay212 :: proc(html: string, passes: int, vw: f32 = 800, vh: f32 = 600) -> ^Box {
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, vw, vh)
    root := build_layout(dom, styles, "")
    page := Rect{0, 0, vw, vh}
    for _ in 0 ..< passes {
        layout_box(root, 0, 0, vw)
        layout_absolutes(root, page, page)
    }
    return root
}

@(private = "file")
find_id212 :: proc(b: ^Box, id: string) -> ^Box {
    if b == nil do return nil
    if b.node != nil {
        if v, ok := b.node.attrs["id"]; ok && v == id do return b
    }
    for c in b.children {
        if r := find_id212(c, id); r != nil do return r
    }
    for &it in b.inlines {
        if it.kind == .InlineBox && it.box != nil {
            if r := find_id212(it.box, id); r != nil do return r
        }
    }
    return nil
}

// A forma do github: fixed sem insets, dentro de um relative, com irmãos ANTES
// (que dão a posição estática) e MUITO conteúdo depois (que é para onde a caixa
// escorregava).
@(private = "file")
FIXTURE :: `<body style="margin:0">
    <div style="position:relative">
        <div style="height:100px"></div>
        <div id="alvo" style="position:fixed;width:100%;height:50px;background:red"></div>
        <div style="height:4000px"></div>
    </div>
</body>`

@(test)
m212_fixed_sob_relative_nao_migra_entre_passes :: proc(t: ^testing.T) {
    um   := find_id212(lay212(FIXTURE, 1), "alvo")
    dois := find_id212(lay212(FIXTURE, 2), "alvo")
    tres := find_id212(lay212(FIXTURE, 5), "alvo")
    testing.expect(t, um != nil && dois != nil && tres != nil, "achou a caixa nos tres")
    if um == nil || dois == nil || tres == nil do return
    // a posição estática é logo abaixo do irmão de 100px
    testing.expect_value(t, um.y, f32(100))
    // …e não pode mudar por rodar o layout de novo (era 4100 no 2º passe)
    testing.expect_value(t, dois.y, f32(100))
    testing.expect_value(t, tres.y, f32(100))
}

@(test)
m212_fixed_com_top_explicito_continua_no_inset :: proc(t: ^testing.T) {
    // CONTROLE: quem tem `top` não usa a estática — não pode ter sido afetado.
    src := `<body style="margin:0"><div style="position:relative">
        <div style="height:100px"></div>
        <div id="alvo" style="position:fixed;top:30px;width:100%;height:50px"></div>
        <div style="height:4000px"></div>
    </div></body>`
    testing.expect_value(t, find_id212(lay212(src, 1), "alvo").y, f32(30))
    testing.expect_value(t, find_id212(lay212(src, 3), "alvo").y, f32(30))
}

@(test)
m212_absolute_sob_relative_continua_ancorado_no_relative :: proc(t: ^testing.T) {
    // CONTROLE do recorte: `position:relative` É bloco contenedor de ABSOLUTE, então
    // a âncora do absolute continua saindo do `ccb_box`. Se o fix tivesse trocado a
    // âncora dos dois, este teste pegaria.
    src := `<body style="margin:0">
        <div style="height:200px"></div>
        <div style="position:relative;height:300px">
            <div style="height:100px"></div>
            <div id="alvo" style="position:absolute;width:50px;height:50px"></div>
        </div>
    </body>`
    // estática dentro do relative: 200 (irmão de cima) + 100 = 300
    testing.expect_value(t, find_id212(lay212(src, 1), "alvo").y, f32(300))
    testing.expect_value(t, find_id212(lay212(src, 3), "alvo").y, f32(300))
}

@(test)
m212_fixed_dentro_de_fixed_estavel :: proc(t: ^testing.T) {
    // O aninhamento que o fix introduziu (um fixed vira a âncora dos fixed abaixo
    // dele): tem de continuar estável entre passes.
    src := `<body style="margin:0"><div style="position:relative">
        <div style="height:80px"></div>
        <div id="pai" style="position:fixed;width:100%">
            <div style="height:40px"></div>
            <div id="filho" style="position:fixed;width:20px;height:20px"></div>
        </div>
        <div style="height:3000px"></div>
    </div></body>`
    p1 := find_id212(lay212(src, 1), "pai");    f1 := find_id212(lay212(src, 1), "filho")
    p3 := find_id212(lay212(src, 3), "pai");    f3 := find_id212(lay212(src, 3), "filho")
    testing.expect(t, p1 != nil && f1 != nil && p3 != nil && f3 != nil, "achou pai e filho")
    if p1 == nil || f1 == nil || p3 == nil || f3 == nil do return
    testing.expect_value(t, p3.y, p1.y)
    testing.expect_value(t, f3.y, f1.y)
}

@(test)
m212_varios_fixed_irmaos_mantem_a_ordem :: proc(t: ^testing.T) {
    // O içamento insere logo APÓS a âncora; com vários irmãos içados p/ o mesmo
    // ponto, a ordem de árvore (= ordem de pintura) tem de ser preservada, e as
    // posições não podem se embaralhar de um passe p/ o outro.
    src := `<body style="margin:0"><div style="position:relative">
        <div style="height:10px"></div>
        <div id="a" style="position:fixed;width:100%;height:5px"></div>
        <div style="height:20px"></div>
        <div id="b" style="position:fixed;width:100%;height:5px"></div>
        <div style="height:2000px"></div>
    </div></body>`
    for passes in ([]int{1, 2, 4}) {
        root := lay212(src, passes)
        a := find_id212(root, "a"); b := find_id212(root, "b")
        testing.expect(t, a != nil && b != nil, "achou a e b")
        if a == nil || b == nil do continue
        testing.expect_value(t, a.y, f32(10))
        testing.expect_value(t, b.y, f32(30))
    }
}
