package ui

// M215 — o shorthand `background` não RESETAVA `background-color`.
//
// Origem: mesmo depois do M214 (nav do github.com deixou de ficar espremida), os
// itens do menu apareciam sobre uma faixa CLARA que o Chrome não tem. O CSS do botão
// é `.NavDropdown-module__button{ …; background:0 0; border:0; … }` — `0 0` é uma
// POSIÇÃO, a grafia usada para dizer "sem fundo". Por spec o shorthand devolve todos
// os longhands que cobre ao valor inicial, então `background-color` vira transparent.
// Nós só ATRIBUÍAMOS quando encontrávamos uma cor, nunca zerávamos — e o fundo claro
// que o nosso UA dá ao `<button>` (`ua_button_look`) sobrevivia.
//
// ⚠️ O reset só acontece quando NÃO há `background-color` explícito no mesmo conjunto
// de declarações: o nosso `decls` é um mapa PLANO (uma entrada por propriedade) e não
// guarda a ordem relativa entre shorthand e longhand. Na dúvida o longhand vence, que
// é o caso comum na prática (`background: url(x)` numa regra e `background-color` em
// outra). Os dois últimos testes fixam essa escolha.

import "core:testing"

@(test)
m215_shorthand_so_com_posicao_zera_a_cor :: proc(t: ^testing.T) {
    // a grafia exata do github
    c := test_apply("background: 0 0")
    testing.expect(t, !c.has_bg, "`background: 0 0` tem de deixar o fundo transparente")
}

@(test)
m215_shorthand_none_e_url_tambem_zeram :: proc(t: ^testing.T) {
    testing.expect(t, !test_apply("background: none").has_bg, "`background: none` zera a cor")
    testing.expect(t, !test_apply("background: url(x.png)").has_bg, "`background: url()` zera a cor")
}

@(test)
m215_shorthand_com_cor_continua_aplicando :: proc(t: ^testing.T) {
    // CONTROLE: o caminho comum não pode ter regredido.
    c1 := test_apply("background: red")
    testing.expect(t, c1.has_bg, "`background: red` define o fundo")
    testing.expect_value(t, c1.bg & 0xffffff, u32(0xff0000))
    // cor + imagem no mesmo shorthand (a `<final-bg-layer>` da spec). ⚠️ NÃO é
    // controle: isto NUNCA funcionou — a cor só era procurada em camada sem imagem.
    // Entrou junto porque o reset do M215 transformaria "fica a cor antiga" em
    // "fica transparente", trocando um erro por outro.
    c2 := test_apply("background: #0000ff url(x.png) no-repeat")
    testing.expect(t, c2.has_bg, "cor junto de url continua valendo")
    testing.expect_value(t, c2.bg & 0xffffff, u32(0x0000ff))
    // …e a cor FUNCIONAL junto de imagem (o split por espaço a destruiria)
    c4 := test_apply("background: rgb(0 128 0) url(x.png)")
    testing.expect(t, c4.has_bg, "cor funcional junto de url")
    testing.expect_value(t, c4.bg & 0xffffff, u32(0x008000))
    // camada NÃO-final não carrega cor: `red` aqui é da última camada
    c5 := test_apply("background: url(a.png), red")
    testing.expect_value(t, c5.bg & 0xffffff, u32(0xff0000))
    // cor FUNCIONAL (a família do M172): não pode cair no reset por não parsear
    c3 := test_apply("background: rgb(0 128 0)")
    testing.expect(t, c3.has_bg, "cor funcional no shorthand continua valendo")
    testing.expect_value(t, c3.bg & 0xffffff, u32(0x008000))
}

@(test)
m215_longhand_explicito_vence_o_reset :: proc(t: ^testing.T) {
    // A escolha documentada acima: com `background-color` no mesmo conjunto, o
    // shorthand sem cor NÃO zera (o mapa é plano, não sabemos a ordem).
    c := test_apply("background-color: red; background: url(x.png)")
    testing.expect(t, c.has_bg, "longhand explícito sobrevive ao shorthand sem cor")
    testing.expect_value(t, c.bg & 0xffffff, u32(0xff0000))
}

@(test)
m215_sem_background_nenhum_nao_mexe :: proc(t: ^testing.T) {
    // CONTROLE do recorte: sem a propriedade, nada é zerado — é o que preserva o
    // fundo do UA de <button>/<input> quando o autor não pede nada.
    c := test_apply("") // Computed inicial
    c.bg = 0xffeeeeee
    c.has_bg = true
    d := test_apply_over(c, "color: red")
    testing.expect(t, d.has_bg, "sem `background` no CSS, o fundo herdado do UA fica")
    testing.expect_value(t, d.bg, u32(0xffeeeeee))
}
