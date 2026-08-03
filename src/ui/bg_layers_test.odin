package ui

// `background-image` (e o shorthand `background`) aceitam uma LISTA de camadas
// separadas por vírgula. Antes só a PRIMEIRA era pintada: `parse_gradient`
// casava o 1º `…-gradient(` do valor e `Box.grad` era um só — o hero do
// getbootstrap, que empilha vários radiais, perdia todas as camadas menos uma.
//
// Modelo: a camada 0 fica nos campos diretos (caminho sem alocação, o de quase
// todo elemento) e as demais em `bg_extra`, em ordem de documento. Como a
// PRIMEIRA camada da lista é a de CIMA no CSS, o paint percorre bg_extra de trás
// pra frente e só então pinta a camada 0.

import "core:testing"
import htmlp "../html"
import csspkg "../css"
import dompkg "../dom"

// ⚠️ background-image NÃO herda — mas o filho começa com uma CÓPIA do Computed
// do pai (child_inherit), e só os campos listados no reset de não-herdados são
// zerados. Sem `comp.bg_extra = nil` lá, as camadas extras vazavam p/ TODA a
// subárvore: no getbootstrap cada descendente do hero repintava os 4 radiais
// do pai por cima do próprio conteúdo. Os testes de `test_apply` acima NÃO
// pegam isso (aplicam decls a um Computed solto, sem árvore).
@(test)
test_bg_extra_nao_herda :: proc(t: ^testing.T) {
    dom := htmlp.parse(`<div class="pai"><div class="filho"><p>x</p></div></div>`)
    rules, _ := csspkg.parse(`.pai { background-image: linear-gradient(red,red), linear-gradient(blue,blue) }`)
    styles, _ := compute_styles(dom, &rules, 800, 600)
    pai   := dompkg_find_class(dom, "pai")
    filho := dompkg_find_class(dom, "filho")
    testing.expect(t, pai != nil && filho != nil, "fixture montada")
    testing.expect_value(t, len(styles[pai].bg_extra), 1)   // a 2a camada
    testing.expect_value(t, len(styles[filho].bg_extra), 0) // NÃO herda
    testing.expect(t, !styles[filho].grad.active, "nem a camada 0 herda")
}

@(private = "file")
dompkg_find_class :: proc(n: ^dompkg.Node, cls: string) -> ^dompkg.Node {
    if n.kind == .Element && n.attrs["class"] == cls do return n
    for c in n.children {
        if r := dompkg_find_class(c, cls); r != nil do return r
    }
    return nil
}

@(test)
test_bg_uma_camada_nao_aloca :: proc(t: ^testing.T) {
    c := test_apply("background-image: linear-gradient(red, blue)")
    testing.expect(t, c.grad.active, "camada 0 no campo direto")
    testing.expect_value(t, len(c.bg_extra), 0) // sem alocação no caso comum

    u := test_apply("background-image: url(a.png)")
    testing.expect_value(t, u.bg_img, "a.png")
    testing.expect_value(t, len(u.bg_extra), 0)
}

@(test)
test_bg_varias_camadas_em_ordem :: proc(t: ^testing.T) {
    c := test_apply("background-image: linear-gradient(red, red), url(b.png), radial-gradient(circle, blue, blue)")
    testing.expect(t, c.grad.active && !c.grad.radial, "camada 0 = o linear (fica por CIMA)")
    testing.expect_value(t, len(c.bg_extra), 2)
    testing.expect_value(t, c.bg_extra[0].img, "b.png")
    testing.expect(t, c.bg_extra[1].grad.active && c.bg_extra[1].grad.radial, "camada 2 = o radial")
}

@(test)
test_bg_virgula_dentro_de_parenteses_nao_divide :: proc(t: ^testing.T) {
    // rgb(…) e a lista de stops têm vírgulas: NÃO podem virar camadas novas
    c := test_apply("background-image: linear-gradient(90deg, rgb(255, 0, 0), rgb(0, 0, 255))")
    testing.expect_value(t, len(c.bg_extra), 0)
    testing.expect(t, c.grad.active && c.grad.n == 2, "um gradiente de 2 stops")
}

@(test)
test_bg_shorthand_com_camadas_e_cor :: proc(t: ^testing.T) {
    // a cor só pode vir na ÚLTIMA camada (spec) e vale p/ o elemento todo
    c := test_apply("background: url(a.png) no-repeat, linear-gradient(red, blue), #ffd21e")
    testing.expect_value(t, c.bg_img, "a.png")
    testing.expect(t, !c.bg_repeat, "no-repeat da camada 0")
    testing.expect(t, c.has_bg && c.bg == 0xffd21e, "cor do fim da lista")
    testing.expect_value(t, len(c.bg_extra), 1)
    testing.expect(t, c.bg_extra[0].grad.active, "camada 1 = o gradiente")
}

@(test)
test_bg_size_repeat_position_sao_listas :: proc(t: ^testing.T) {
    // o i-ésimo valor vale p/ a i-ésima camada
    c := test_apply(
        "background-image: url(a.png), url(b.png), url(c.png);" +
        "background-repeat: no-repeat, repeat, no-repeat;" +
        "background-size: cover, auto, contain;" +
        "background-position: left top, center, right bottom")
    testing.expect_value(t, len(c.bg_extra), 2)
    // camada 0
    testing.expect(t, !c.bg_repeat && c.bg_size == .Cover, "camada 0: no-repeat + cover")
    testing.expect(t, c.bg_pos_x == 0 && c.bg_pos_y == 0, "camada 0: left top")
    // camada 1
    testing.expect(t, c.bg_extra[0].repeat && c.bg_extra[0].size == .Auto, "camada 1: repeat + auto")
    testing.expect(t, abs(c.bg_extra[0].pos_x - 0.5) < 1e-4, "camada 1: center")
    // camada 2
    testing.expect(t, !c.bg_extra[1].repeat && c.bg_extra[1].size == .Contain, "camada 2: no-repeat + contain")
    testing.expect(t, c.bg_extra[1].pos_x == 1 && c.bg_extra[1].pos_y == 1, "camada 2: right bottom")
}

@(test)
test_bg_camada_sem_imagem_nao_entra :: proc(t: ^testing.T) {
    // `none` no meio da lista é uma camada VAZIA: não gera desenho nenhum
    c := test_apply("background-image: url(a.png), none, url(c.png)")
    testing.expect_value(t, len(c.bg_extra), 1)
    testing.expect_value(t, c.bg_extra[0].img, "c.png")
}
