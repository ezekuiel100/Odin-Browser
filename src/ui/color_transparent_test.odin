package ui

// `color: transparent` — o texto tem de SUMIR.
//
// Por que existe: `named_color` rejeita `transparent` DE PROPÓSITO, para que
// `background: transparent` signifique ausência de cor (e não preto). O efeito
// colateral era em `color`: a declaração inteira caía e o texto saía na cor
// HERDADA, bem visível — o oposto do que a página pediu. Padrão real que isso
// quebra: texto escondido atrás de ícone/imagem e placeholders de skeleton.
//
// ⚠️ O esquema de cor do motor tem a convenção **byte alto = alpha, 0 = OPACO**
// (retrocompat com 0xRRGGBB), então alpha exato 0 NÃO é representável: usamos
// `COLOR_TRANSPARENT` = byte 1 ≈ 0,4% de opacidade. Era o truque que a borda
// transparente já usava; agora tem nome e é compartilhado.

import "core:testing"
import htmlp "../html"
import csspkg "../css"
import dompkg "../dom"

@(private = "file")
cor_de :: proc(html_src, css, tag: string) -> (u32, bool) {
    dom := htmlp.parse(html_src)
    rules, _ := csspkg.parse(css)
    styles, _ := compute_styles(dom, &rules, 800, 600)
    alvo: ^dompkg.Node
    walk :: proc(n: ^dompkg.Node, tag: string, out: ^^dompkg.Node) {
        if n.kind == .Element && n.tag == tag && out^ == nil do out^ = n
        for c in n.children do walk(c, tag, out)
    }
    walk(dom, tag, &alvo)
    if alvo == nil do return 0, false
    return styles[alvo].color, true
}

@(test)
color_transparent_nao_e_ignorado :: proc(t: ^testing.T) {
    c := test_apply("color: transparent")
    testing.expect_value(t, c.color, COLOR_TRANSPARENT)
    testing.expect(t, c.has_color, "tem de contar como cor DEFINIDA")
}

// O modo antigo de falhar: a decl caía e sobrava a cor do PAI.
@(test)
color_transparent_ganha_da_heranca :: proc(t: ^testing.T) {
    cor, achou := cor_de(`<html><body><div class="pai"><p>x</p></div></body></html>`,
        `.pai { color: red } p { color: transparent }`, "p")
    testing.expect(t, achou, "achou o <p>")
    testing.expect_value(t, cor, COLOR_TRANSPARENT)
}

// ... e a transparência HERDA, como qualquer cor.
@(test)
color_transparent_herda_para_os_filhos :: proc(t: ^testing.T) {
    cor, achou := cor_de(`<html><body><div class="pai"><span>x</span></div></body></html>`,
        `.pai { color: transparent }`, "span")
    testing.expect(t, achou, "achou o <span>")
    testing.expect_value(t, cor, COLOR_TRANSPARENT)
}

// ⚠️ NÃO-REGRESSÃO: em `background`, `transparent` continua sendo AUSÊNCIA de cor
// (é a razão de o `named_color` rejeitar a palavra).
@(test)
background_transparent_continua_sem_fundo :: proc(t: ^testing.T) {
    c := test_apply("background-color: transparent")
    testing.expect(t, !c.has_bg, "background: transparent NAO pinta fundo")
}

// ⚠️ NÃO-REGRESSÃO: o texto com GRADIENTE (o padrão `color:transparent` +
// `background-clip:text`, que o ultra-photo usa no titulo) tem de continuar
// VISÍVEL — a cor vem do gradiente, não do transparent.
@(test)
texto_com_gradiente_continua_visivel :: proc(t: ^testing.T) {
    c := test_apply("color: transparent; background: linear-gradient(135deg,#a78bfa,#67e8f9); background-clip: text")
    testing.expect(t, c.color != COLOR_TRANSPARENT, "texto do gradiente nao pode sumir")
    testing.expect(t, c.has_color, "cor definida a partir do gradiente")
}

// ⚠️ DEGRADAÇÃO ANOTADA: `color:transparent` + `background-clip:text` SEM fundo
// que saibamos clipar (imagem raster) volta p/ a cor anterior em vez de apagar o
// texto. É a mesma escolha já feita p/ `-webkit-text-fill-color: transparent`
// sem clip: perder o texto é pior que mostrá-lo na cor errada.
@(test)
degradacao_clip_text_sem_fundo_conhecido :: proc(t: ^testing.T) {
    c := test_apply("color: transparent; background-image: url(foto.png); background-clip: text")
    testing.expect(t, c.color != COLOR_TRANSPARENT,
        "sem fundo clipavel, o texto tem de continuar visivel")
}

// currentColor segue a cor do texto — inclusive quando ela é transparente.
@(test)
currentcolor_segue_o_transparent :: proc(t: ^testing.T) {
    c := test_apply("color: transparent; border: 1px solid currentColor")
    testing.expect_value(t, c.border_c[0], COLOR_TRANSPARENT)
    testing.expect(t, c.border_w[0] == 1, "a largura da borda continua contando p/ o layout")
}

// ⚠️ NÃO-REGRESSÃO da constante compartilhada: borda transparente segue igual.
@(test)
border_transparent_inalterado :: proc(t: ^testing.T) {
    c := test_apply("border: 2px solid transparent")
    testing.expect_value(t, c.border_c[0], COLOR_TRANSPARENT)
    testing.expect(t, c.border_w[0] == 2, "largura conta p/ o layout")
}
