package ui

// M171 — `<select>` virou CONTROLE, não bloco de texto.
//
// Antes não havia tratamento nenhum de `select`/`option` em `src/ui`: o select
// caía como bloco comum e os `<option>` como filhos de fluxo, então a página
// DESPEJAVA a lista inteira como linhas de texto (na screenshot do tradebig,
// os ~22 setores abertos no lugar do dropdown fechado de 40px).
//
// Agora `build_layout` tem um branch dedicado (espelhando o do <textarea>): a
// caixa é um controle com `ctrl == .Select`, os <option> NÃO geram caixa, a
// altura padrão é de UMA linha e a largura padrão é a da maior opção + setinha.
// A lista só existe no popup do paint (BeginCombo), fora do alcance de teste
// sem frame de ImGui — ver a nota de limitação no fim do arquivo.
//
// ⚠️ sem atlas de fontes em `odin test` a medição de texto devolve 0, então a
// largura cai na estimativa por contagem de bytes (é o caminho que os testes de
// largura exercitam, de propósito — ver [[odin-test-armadilhas]]).

import "core:testing"
import htmlp "../html"
import csspkg "../css"
import dompkg "../dom"

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

@(private = "file")
find_tag :: proc(b: ^Box, tag: string) -> ^Box {
    if b == nil do return nil
    if b.node != nil && b.node.tag == tag do return b
    for c in b.children {
        if r := find_tag(c, tag); r != nil do return r
    }
    for &it in b.inlines {
        if it.kind == .InlineBox && it.box != nil {
            if r := find_tag(it.box, tag); r != nil do return r
        }
    }
    return nil
}

// Conta caixas de uma tag em TODA a árvore (inclui as que viram átomo inline).
@(private = "file")
count_tag :: proc(b: ^Box, tag: string) -> int {
    if b == nil do return 0
    n := 0
    if b.node != nil && b.node.tag == tag do n += 1
    for c in b.children do n += count_tag(c, tag)
    for &it in b.inlines do if it.kind == .InlineBox && it.box != nil do n += count_tag(it.box, tag)
    return n
}

@(private = "file")
SEL :: `<select id="s">
    <option value="">Todos os setores</option>
    <option value="fin">Finance</option>
    <option value="ret">Retail Trade</option>
</select>`

// (1) O BUG: o select é um controle e as opções NÃO entram no fluxo.
@(test)
test_m171_select_e_controle :: proc(t: ^testing.T) {
    root := layout_from_html(SEL)
    s := find_tag(root, "select")
    testing.expect(t, s != nil, "o <select> tem caixa")
    if s == nil do return
    testing.expect(t, s.ctrl == .Select, "marcado como controle .Select")
    testing.expectf(t, count_tag(root, "option") == 0, "nenhum <option> gera caixa; veio %d", count_tag(root, "option"))
    // era isto que despejava a lista: a altura crescia com o nº de opções
    testing.expectf(t, s.h < 40, "altura de UMA linha, não da lista inteira; veio %.1f", s.h)
    testing.expectf(t, s.h > 15, "e não colapsa; veio %.1f", s.h)
}

// (2) O CSS vence os padrões do UA nos dois eixos.
@(test)
test_m171_css_vence_padrao :: proc(t: ^testing.T) {
    root := layout_from_html(`<select id="s" style="width:260px;height:44px"><option>Finance</option></select>`)
    s := find_tag(root, "select")
    testing.expect(t, s != nil, "achou o select")
    if s == nil do return
    testing.expectf(t, s.w == 260, "width do CSS honrada; veio %.0f", s.w)
    testing.expectf(t, s.h == 44, "height do CSS honrada; veio %.0f", s.h)
}

// (3) Largura padrão vem da MAIOR opção (como no Chrome), não da 1ª nem do texto
// selecionado — e reserva a setinha nativa, exceto com appearance:none.
@(test)
test_m171_largura_pela_maior_opcao :: proc(t: ^testing.T) {
    curta := find_tag(layout_from_html(`<select><option>ab</option></select>`), "select")
    longa := find_tag(layout_from_html(`<select><option>ab</option><option>uma opcao bem mais longa</option></select>`), "select")
    testing.expect(t, curta != nil && longa != nil, "achou os dois selects")
    if curta == nil || longa == nil do return
    testing.expectf(t, longa.w > curta.w, "a maior opção manda na largura (%.0f vs %.0f)", longa.w, curta.w)
    testing.expectf(t, curta.w > 0, "sem opção larga a caixa ainda tem largura; veio %.0f", curta.w)

    // appearance:none = o autor desenha o próprio chevron → não reservamos o nosso
    nativo := find_tag(layout_from_html(`<select><option>abcdef</option></select>`), "select")
    sem := find_tag(layout_from_html(`<select style="appearance:none"><option>abcdef</option></select>`), "select")
    testing.expect(t, nativo != nil && sem != nil, "achou os selects de aparência")
    if nativo == nil || sem == nil do return
    testing.expectf(t, nativo.w > sem.w, "só o nativo reserva a setinha (%.0f vs %.0f)", nativo.w, sem.w)
}

// (4) Qual opção está corrente. O atributo `value` do select vence porque é onde
// `el.value = x` aterra neste motor (React controlado); sem ele vale `selected`;
// sem nada, a primeira.
@(test)
test_m171_opcao_corrente :: proc(t: ^testing.T) {
    dom1 := htmlp.parse(SEL)
    sel1 := dompkg.find_first(dom1, "select")
    opts := make([dynamic]^dompkg.Node)
    defer delete(opts)
    select_options(sel1, &opts)
    testing.expectf(t, len(opts) == 3, "3 opções coletadas; veio %d", len(opts))
    testing.expectf(t, select_selected_index(sel1, opts[:]) == 0, "sem nada: a primeira")

    dom2 := htmlp.parse(`<select value="ret"><option value="">T</option><option value="ret">R</option></select>`)
    sel2 := dompkg.find_first(dom2, "select")
    o2 := make([dynamic]^dompkg.Node); defer delete(o2)
    select_options(sel2, &o2)
    testing.expectf(t, select_selected_index(sel2, o2[:]) == 1, "atributo value do select escolhe")

    dom3 := htmlp.parse(`<select><option>A</option><option selected>B</option></select>`)
    sel3 := dompkg.find_first(dom3, "select")
    o3 := make([dynamic]^dompkg.Node); defer delete(o3)
    select_options(sel3, &o3)
    testing.expectf(t, select_selected_index(sel3, o3[:]) == 1, "<option selected> escolhe")
    // rótulo e valor: sem atributo value, o valor É o texto (regra da spec, e a
    // MESMA do dom_bindings — se divergirem, o JS lê um valor que a tela não mostra)
    testing.expectf(t, option_label(o3[1]) == "B" && option_value(o3[1]) == "B", "rótulo/valor caem no texto")
}

// (5) <optgroup> não vira opção: as opções DE DENTRO dele entram, achatadas.
@(test)
test_m171_optgroup_achata :: proc(t: ^testing.T) {
    dom := htmlp.parse(`<select><optgroup label="BR"><option>PETR4</option><option>VALE3</option></optgroup><option>AAPL</option></select>`)
    sel := dompkg.find_first(dom, "select")
    opts := make([dynamic]^dompkg.Node); defer delete(opts)
    select_options(sel, &opts)
    testing.expectf(t, len(opts) == 3, "as 2 do grupo + 1 solta; veio %d", len(opts))
    if len(opts) == 3 {
        testing.expect(t, option_label(opts[0]) == "PETR4" && option_label(opts[2]) == "AAPL", "ordem de documento preservada")
    }
    root := layout_from_html(`<select><optgroup label="BR"><option>PETR4</option></optgroup></select>`)
    testing.expect(t, count_tag(root, "optgroup") == 0, "<optgroup> também não gera caixa")
}

// (6) A ESCOLHA aterrando no DOM (`apply_select_choice`): é o estado que o
// handler de `change` vai ler. Se o `value` não acompanhasse, um select
// controlado leria `e.target.value` velho e reverteria a escolha na hora.
@(test)
test_m171_escolher_atualiza_dom :: proc(t: ^testing.T) {
    dom := htmlp.parse(`<select><option value="a">A</option><option value="b" selected>B</option><option value="c">C</option></select>`)
    sel := dompkg.find_first(dom, "select")
    opts := make([dynamic]^dompkg.Node); defer delete(opts)
    select_options(sel, &opts)
    testing.expectf(t, select_selected_index(sel, opts[:]) == 1, "parte da opção B")

    apply_select_choice(sel, opts[2])
    testing.expectf(t, sel.attrs["value"] == "c", "o value do select vira o da opção escolhida; veio %q", sel.attrs["value"])
    testing.expect(t, "selected" in opts[2].attrs, "a escolhida ganha selected")
    testing.expect(t, !("selected" in opts[1].attrs), "a anterior PERDE selected (senão duas ficam marcadas)")
    testing.expectf(t, select_selected_index(sel, opts[:]) == 2, "e o índice corrente acompanha")

    // o rótulo mostrado sai do mesmo lugar — é o que o combo pinta como preview
    testing.expect(t, option_label(opts[select_selected_index(sel, opts[:])]) == "C", "rótulo corrente = C")
}

// ⚠️ NÃO coberto por teste: o popup em si (BeginCombo/Selectable) e o disparo de
// `input`/`change`, que exigem um frame de ImGui com mouse — `odin test` não tem
// janela. O que é testável do caminho de interação é o passo (6); o resto se
// verifica por uso manual, e a limitação fica anotada aqui.
