package ui

// M234 — `height:N%` num elemento ABSOLUTAMENTE POSICIONADO resolvia como ZERO.
//
// Origem: fui investigar por que o `<video>` do github.com não aparecia, supondo que
// faltasse decoder. A caixa saía `w=1204 h=0`, e a regra que a governa não fala de
// vídeo nenhum:
//
//     .lp-HeroCarousel-visual video { width:100%; height:100%; position:absolute; top:0 }
//
// Trocando o `<video>` por um `<div>` o defeito é IDÊNTICO — ou seja, nunca foi mídia:
// era `position:absolute` + `height:%`, um dos idiomas mais comuns da web (overlay,
// mídia que preenche o pai, backdrop de modal).
//
// Raiz: o `layout_box` não converte fração de altura sozinho. No fluxo normal quem a
// resolve é o PAI, que manda o px pronto por `force_h` (a chamada com `ch_fh`). O
// `place_absolute` impõe tamanho pelo mesmo canal mas só preenchia `fh` no caso de
// esticar entre `top`+`bottom`; com `height:%` o `fh` ficava -1 e a altura virava 0.
//
// A LARGURA escapou por uma assimetria de convenção que vale registrar: `width:N%`
// grava `has_width=true` + `width_pct`, e o layout_box a resolve contra o `avail_w`
// que já recebe; `height:N%` grava `has_height=FALSE` + `has_height_pct`, e sem o pai
// ninguém a resolve. É a 3ª vez que o padrão "quem IMPÕE tamanho tem de resolvê-lo
// por INTEIRO" morde (M228, M229, aqui).
//
// Oráculo: Chrome headless sobre a mesma fixture — 200/200/200/16/200/200 nos seis
// casos, contra 0/0/0/0/0/200 nossos (só o filho NÃO posicionado acertava).

import "core:testing"
import htmlp "../html"
import csspkg "../css"

@(private = "file")
lay234 :: proc(html: string, passes := 1, vw: f32 = 800, vh: f32 = 600) -> ^Box {
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, vw, vh)
    root := build_layout(dom, styles, "")
    page := Rect{0, 0, vw, vh}
    // DOIS passes por padrão não: o default é 1, mas os testes de estabilidade
    // abaixo pedem N — bug que só aparece do 2º passe é conhecido da casa (M196/M212).
    for _ in 0 ..< passes {
        layout_box(root, 0, 0, vw)
        layout_absolutes(root, page, page)
    }
    return root
}

@(private = "file")
find_id234 :: proc(b: ^Box, id: string) -> ^Box {
    if b == nil do return nil
    if b.node != nil {
        if v, ok := b.node.attrs["id"]; ok && v == id do return b
    }
    for c in b.children {
        if r := find_id234(c, id); r != nil do return r
    }
    for &it in b.inlines {
        if it.kind == .InlineBox && it.box != nil {
            if r := find_id234(it.box, id); r != nil do return r
        }
    }
    return nil
}

@(test)
m234_altura_percentual_em_absoluto :: proc(t: ^testing.T) {
    // O caso base: pai posicionado com altura explícita, filho absoluto preenchendo.
    src := `<body style="margin:0">
        <div style="position:relative;width:400px;height:200px">
            <div id="alvo" style="position:absolute;top:0;left:0;width:100%;height:100%"></div>
        </div></body>`
    alvo := find_id234(lay234(src), "alvo")
    testing.expect(t, alvo != nil, "achou o alvo")
    if alvo == nil do return
    testing.expect_value(t, alvo.w, f32(400)) // já funcionava
    testing.expect_value(t, alvo.h, f32(200)) // era 0
}

@(test)
m234_pai_flex_ou_aspect_ratio :: proc(t: ^testing.T) {
    // As duas formas do github: o pai é `display:flex` e a altura dele vem de
    // `aspect-ratio`, não de `height`. Para o filho absoluto tanto faz — o CB é uma
    // caixa já disposta, e a altura dela é definida qualquer que seja a origem.
    flex := `<body style="margin:0">
        <div style="position:relative;display:flex;width:400px;height:200px">
            <div id="alvo" style="position:absolute;top:0;width:100%;height:100%"></div>
        </div></body>`
    ar := `<body style="margin:0">
        <div style="position:relative;display:flex;width:400px;aspect-ratio:2/1">
            <div id="alvo" style="position:absolute;top:0;width:100%;height:100%"></div>
        </div></body>`
    testing.expect_value(t, find_id234(lay234(flex), "alvo").h, f32(200))
    testing.expect_value(t, find_id234(lay234(ar), "alvo").h, f32(200))
}

@(test)
m234_altura_do_pai_vinda_do_conteudo :: proc(t: ^testing.T) {
    // ⚠️ Aqui minha intuição de CSS estava errada e o Chrome corrigiu: para um filho
    // ABSOLUTO a porcentagem resolve mesmo quando a altura do pai veio do CONTEÚDO —
    // o bloco contenedor de um absoluto é uma caixa JÁ DISPOSTA, então a altura é
    // sempre definida. (É o fluxo normal que exige altura explícita no pai.)
    src := `<body style="margin:0">
        <div id="pai" style="position:relative;width:400px">
            <div style="height:60px"></div>
            <div id="alvo" style="position:absolute;top:0;width:100%;height:100%"></div>
        </div></body>`
    root := lay234(src)
    pai := find_id234(root, "pai"); alvo := find_id234(root, "alvo")
    testing.expect(t, pai != nil && alvo != nil, "achou pai e alvo")
    if pai == nil || alvo == nil do return
    testing.expect_value(t, pai.h, f32(60))
    testing.expect_value(t, alvo.h, f32(60))
}

@(test)
m234_calc_misto_na_altura :: proc(t: ^testing.T) {
    // `calc(100% - 40px)` chega como fração + OFFSET; o offset tem de sobreviver ao
    // mesmo caminho (é o `height_pct_off`, funil `pct_resolve`).
    src := `<body style="margin:0">
        <div style="position:relative;width:400px;height:200px">
            <div id="alvo" style="position:absolute;top:0;width:100%;height:calc(100% - 40px)"></div>
        </div></body>`
    testing.expect_value(t, find_id234(lay234(src), "alvo").h, f32(160))
}

@(test)
m234_max_height_percentual_limita :: proc(t: ^testing.T) {
    // min/max-height em % têm a MESMA base e também só o CB a conhece. Sem
    // resolve_child_minmax_h o limite ficaria não-resolvido e a caixa iria a 200.
    src := `<body style="margin:0">
        <div style="position:relative;width:400px;height:200px">
            <div id="alvo" style="position:absolute;top:0;width:100%;height:100%;max-height:50%"></div>
        </div></body>`
    testing.expect_value(t, find_id234(lay234(src), "alvo").h, f32(100))
}

@(test)
m234_video_se_comporta_como_div :: proc(t: ^testing.T) {
    // O caso que originou tudo. O ponto do teste NÃO é "vídeo funciona", é que o
    // elemento de mídia não tem nada de especial neste caminho: mesma regra, mesma
    // altura. Se um dia `<video>` ganhar tamanho intrínseco, isto continua valendo
    // porque a altura aqui é IMPOSTA por CSS.
    src := `<body style="margin:0">
        <div style="position:relative;width:400px;height:200px">
            <video id="alvo" style="position:absolute;top:0;left:0;width:100%;height:100%"></video>
        </div></body>`
    alvo := find_id234(lay234(src), "alvo")
    testing.expect(t, alvo != nil, "achou o video")
    if alvo == nil do return
    testing.expect_value(t, alvo.h, f32(200))
}

@(test)
m234_estavel_entre_passes :: proc(t: ^testing.T) {
    // Defeito que só aparece do 2º passe em diante é conhecido da casa (M196/M212/M213):
    // o `--dumplayout` faz UM passe e jura que está tudo certo.
    src := `<body style="margin:0">
        <div style="position:relative;width:400px;height:200px">
            <div id="alvo" style="position:absolute;top:0;left:0;width:100%;height:100%"></div>
        </div></body>`
    for passes in ([]int{1, 2, 5}) {
        testing.expect_value(t, find_id234(lay234(src, passes), "alvo").h, f32(200))
    }
}

// ── CONTROLES: passam dos DOIS lados do fix (provam o recorte, não o fix) ────────

@(test)
m234_controle_estica_entre_insets :: proc(t: ^testing.T) {
    // Sem `height`, com `top`+`bottom`: continua esticando entre os insets. Este ramo
    // virou o `else` do novo, então é o que trava a ordem dos dois.
    src := `<body style="margin:0">
        <div style="position:relative;width:400px;height:200px">
            <div id="alvo" style="position:absolute;top:20px;bottom:30px;left:0;width:100%"></div>
        </div></body>`
    testing.expect_value(t, find_id234(lay234(src), "alvo").h, f32(150))
}

@(test)
m234_controle_altura_px_inalterada :: proc(t: ^testing.T) {
    // Altura em px num absoluto não passa pelo caminho novo.
    src := `<body style="margin:0">
        <div style="position:relative;width:400px;height:200px">
            <div id="alvo" style="position:absolute;top:0;left:0;width:100%;height:75px"></div>
        </div></body>`
    testing.expect_value(t, find_id234(lay234(src), "alvo").h, f32(75))
}

@(test)
m234_controle_filho_em_fluxo_normal :: proc(t: ^testing.T) {
    // O caminho que SEMPRE funcionou (o pai resolve e manda por force_h): é o
    // contraste que provou que o defeito era exclusivo do absoluto.
    src := `<body style="margin:0">
        <div style="width:400px;height:200px">
            <div id="alvo" style="width:100%;height:100%"></div>
        </div></body>`
    testing.expect_value(t, find_id234(lay234(src), "alvo").h, f32(200))
}
