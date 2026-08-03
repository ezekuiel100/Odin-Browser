package js

// M171 (lado JS) — `select.selectedIndex`, get e set.
//
// O `.value` de select/option já existia (guardado no atributo `value`, com o
// fallback texto p/ `<option>` sem value). Faltava o `selectedIndex`, que é como
// script sem framework lê e muda a escolha — e o `<select>` só passou a ser um
// controle de verdade nesta rodada (ver [[real-site-fidelity]] M171 no lado ui).
//
// A precedência é a MESMA das três regras do pacote ui (`select_selected_index`):
// atributo `value` do select > primeiro `<option selected>` > a primeira opção.
// ⚠️ a regra vive DUPLICADA porque `src/js` não pode importar `src/ui`; divergir
// aí significa o script ler uma opção diferente da que está na tela.

import "core:testing"
import "core:strings"
import dom "../dom"

// <select id="s"><option value="">T</option><option value="fin">F</option>
//                <option value="ret">R</option></select>
@(private = "file")
m171_dom :: proc(sel_attrs: map[string]string = nil, selected_idx := -1) -> ^dom.Node {
    root := dom.make_node(.Document)
    sel := dom.make_node(.Element)
    sel.tag = strings.clone("select")
    sel.attrs = make(map[string]string)
    sel.attrs[strings.clone("id")] = strings.clone("s")
    for k, v in sel_attrs do sel.attrs[strings.clone(k)] = strings.clone(v)

    vals := [3]string{"", "fin", "ret"}
    labels := [3]string{"Todos", "Finance", "Retail"}
    for i in 0 ..< 3 {
        o := dom.make_node(.Element)
        o.tag = strings.clone("option")
        o.attrs = make(map[string]string)
        o.attrs[strings.clone("value")] = strings.clone(vals[i])
        if i == selected_idx do o.attrs[strings.clone("selected")] = strings.clone("true")
        txt := dom.make_node(.Text)
        txt.text = strings.clone(labels[i])
        dom.append_child(o, txt)
        dom.append_child(sel, o)
    }
    dom.append_child(root, sel)
    return root
}

@(test)
m171_selected_index_default_e_zero :: proc(t: ^testing.T) {
    root := m171_dom()
    v := run_with_dom(`document.getElementById("s").selectedIndex`, root)
    n, ok := v.(f64)
    testing.expect(t, ok, "selectedIndex é número")
    testing.expectf(t, n == 0, "sem value nem selected: 0; veio %v", v)
}

@(test)
m171_selected_index_segue_o_atributo_selected :: proc(t: ^testing.T) {
    root := m171_dom(selected_idx = 2)
    v := run_with_dom(`document.getElementById("s").selectedIndex`, root)
    testing.expectf(t, v.(f64) == 2, "<option selected> manda; veio %v", v)
}

@(test)
m171_value_do_select_vence_o_selected :: proc(t: ^testing.T) {
    attrs := make(map[string]string)
    defer delete(attrs)
    attrs["value"] = "fin"
    root := m171_dom(attrs, selected_idx = 2)
    v := run_with_dom(`document.getElementById("s").selectedIndex`, root)
    testing.expectf(t, v.(f64) == 1, "o value corrente vence o default; veio %v", v)
}

// set: escrever o índice equivale a escolher a opção — o `.value` tem de
// acompanhar, senão a tela (que lê o value) mostraria outra coisa.
@(test)
m171_set_selected_index_move_o_value :: proc(t: ^testing.T) {
    root := m171_dom()
    v := run_with_dom(`
        var s = document.getElementById("s");
        s.selectedIndex = 2;
        s.value + "|" + s.selectedIndex + "|" + s.options[2].selected
    `, root)
    testing.expectf(t, v.(string) == "ret|2|true", "value/índice/selected em sincronia; veio %v", v)
}

// índice fora da faixa: nada fica selecionado (como no DOM), sem crash
@(test)
m171_set_selected_index_fora_da_faixa :: proc(t: ^testing.T) {
    root := m171_dom(selected_idx = 1)
    v := run_with_dom(`
        var s = document.getElementById("s");
        s.selectedIndex = 9;
        String(s.options[1].selected)
    `, root)
    testing.expectf(t, v.(string) == "false", "a seleção anterior é limpa; veio %v", v)
}
