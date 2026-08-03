package js

// M131 — ORDEM DE DOCUMENTO dos atributos. `dom.Node.attrs` é um map, e map do Odin
// não tem ordem: `getAttributeNames()` devolvia uma ordem DIFERENTE a cada execução.
//
// Por que importa: o lit-html pareia `getAttributeNames()` POSICIONALMENTE com a
// própria lista de bindings (`attrNames[attrNameIndex++]`). Com ordem embaralhada, o
// valor de um binding ia para a propriedade ERRADA — no archive.org isso gerava 36
// erros `_$AP is not a function` (part do tipo errado). Com a ordem certa: ZERO.

import "core:testing"
import dom "../dom"
import "core:strings"

@(private = "file")
run_dom :: proc(src: string) -> Value {
    root := dom.make_node(.Document)
    defer dom.free_tree(root)
    html := dom.make_node(.Element); html.tag = strings.clone("html")
    body := dom.make_node(.Element); body.tag = strings.clone("body")
    dom.append_child(html, body)
    dom.append_child(root, html)
    return run_with_dom(src, root)
}

@(test)
m131_ordem_do_parser_e_de_documento :: proc(t: ^testing.T) {
    src := `
        var d = document.createElement("div");
        d.innerHTML = '<x a1="1" b2="2" c3="3" d4="4" e5="5" f6="6"></x>';
        d.firstChild.getAttributeNames().join(",")
    `
    testing.expect_value(t, run_dom(src).(string), "a1,b2,c3,d4,e5,f6")
}

@(test)
m131_ordem_de_setattribute_e_de_insercao :: proc(t: ^testing.T) {
    src := `
        var e = document.createElement("p");
        e.setAttribute("zz","1"); e.setAttribute("aa","2"); e.setAttribute("mm","3");
        e.getAttributeNames().join(",")
    `
    testing.expect_value(t, run_dom(src).(string), "zz,aa,mm")
}

@(test)
m131_reescrever_atributo_nao_muda_a_ordem :: proc(t: ^testing.T) {
    // spec: setAttribute num atributo existente troca o VALOR e mantém a posição.
    src := `
        var e = document.createElement("p");
        e.setAttribute("a","1"); e.setAttribute("b","2"); e.setAttribute("c","3");
        e.setAttribute("a","9");
        e.getAttributeNames().join(",") + "|" + e.getAttribute("a")
    `
    testing.expect_value(t, run_dom(src).(string), "a,b,c|9")
}

@(test)
m131_remover_atributo_tira_da_ordem :: proc(t: ^testing.T) {
    src := `
        var e = document.createElement("p");
        e.setAttribute("a","1"); e.setAttribute("b","2"); e.setAttribute("c","3");
        e.removeAttribute("b");
        e.getAttributeNames().join(",")
    `
    testing.expect_value(t, run_dom(src).(string), "a,c")
}

@(test)
m131_remover_e_readicionar_vai_para_o_fim :: proc(t: ^testing.T) {
    src := `
        var e = document.createElement("p");
        e.setAttribute("a","1"); e.setAttribute("b","2"); e.setAttribute("c","3");
        e.removeAttribute("a");
        e.setAttribute("a","novo");
        e.getAttributeNames().join(",")
    `
    testing.expect_value(t, run_dom(src).(string), "b,c,a")
}

@(test)
m131_clone_preserva_a_ordem :: proc(t: ^testing.T) {
    src := `
        var d = document.createElement("div");
        d.innerHTML = '<x p1="a" q2="b" r3="c"></x>';
        d.firstChild.cloneNode(true).getAttributeNames().join(",")
    `
    testing.expect_value(t, run_dom(src).(string), "p1,q2,r3")
}

@(test)
m131_ordem_e_estavel_entre_leituras :: proc(t: ^testing.T) {
    // A ordem não pode depender de iteração de map (que varia até na MESMA execução).
    src := `
        var d = document.createElement("div");
        d.innerHTML = '<x a="1" b="2" c="3" d="4" e="5" f="6" g="7" h="8"></x>';
        var x = d.firstChild;
        var primeira = x.getAttributeNames().join(",");
        var igual = true;
        for (var i = 0; i < 20; i++) {
            if (x.getAttributeNames().join(",") !== primeira) igual = false;
        }
        igual && primeira === "a,b,c,d,e,f,g,h"
    `
    testing.expect_value(t, run_dom(src).(bool), true)
}

@(test)
m131_atributo_duplicado_mantem_o_primeiro :: proc(t: ^testing.T) {
    // spec: o PRIMEIRO vence e a ordem não ganha entrada duplicada.
    src := `
        var d = document.createElement("div");
        d.innerHTML = '<x a="1" b="2" a="9"></x>';
        var x = d.firstChild;
        x.getAttributeNames().join(",") + "|" + x.getAttribute("a")
    `
    testing.expect_value(t, run_dom(src).(string), "a,b|1")
}
