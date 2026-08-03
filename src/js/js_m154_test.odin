package js

// M154 — document.createNodeIterator (dom_bindings.odin).
//
// Gap que o M153 destapou: com `CSS is not defined` resolvido, o airbnb avancou
// e bateu em `document.createNodeIterator is not a function`. NodeIterator e um
// iterador LINEAR sobre a subarvore, com o modelo referenceNode +
// pointerBeforeReferenceNode da spec.
//
// O que estes testes guardam:
//  1. o PRIMEIRO nextNode() devolve o proprio root (ponteiro comeca ANTES da
//     referencia) — a diferenca comportamental vs. TreeWalker;
//  2. whatToShow filtra por tipo de no;
//  3. o FILTRO (funcao e objeto-com-acceptNode) e HONRADO — nao ignorado como no
//     TreeWalker aproximado;
//  4. previousNode() alcanca root de volta.
//
// Precisa de VM com DOM (document so existe com window) — run() puro daria
// ReferenceError.

import "core:testing"
import "core:strings"
import dom "../dom"

// Monta:  Document > html > (head, body > (div#one > "x", div#two > (<!--c-->, "y")))
@(private = "file")
m154_dom :: proc() -> ^dom.Node {
    el :: proc(tag: string) -> ^dom.Node {
        n := dom.make_node(.Element)
        n.tag = strings.clone(tag)
        n.attrs = make(map[string]string)
        return n
    }
    txt :: proc(s: string) -> ^dom.Node {
        n := dom.make_node(.Text)
        n.text = strings.clone(s)
        return n
    }
    root := dom.make_node(.Document)
    html := el("html"); body := el("body"); head := el("head")
    // chave E valor clonados: free_tree faz delete(k) e delete(v) nos atributos,
    // entao a chave TAMBEM tem de ser heap (literal daria bad-free no teardown).
    one := el("div"); one.attrs[strings.clone("id")] = strings.clone("one")
    two := el("div"); two.attrs[strings.clone("id")] = strings.clone("two")
    cmt := dom.make_node(.Comment); cmt.text = strings.clone("c")
    dom.append_child(root, html)
    dom.append_child(html, head)
    dom.append_child(html, body)
    dom.append_child(body, one)
    dom.append_child(one, txt("x"))
    dom.append_child(body, two)
    dom.append_child(two, cmt)
    dom.append_child(two, txt("y"))
    return root
}

@(private = "file")
run_m154 :: proc(src: string) -> Value {
    root := m154_dom()
    defer dom.free_tree(root)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    return vm_run(vm, src)
}

// ── whatToShow: elementos, na ordem de documento, ROOT PRIMEIRO ───────────────

@(test)
m154_show_element_inclui_o_root :: proc(t: ^testing.T) {
    // A pegadinha vs TreeWalker: o 1o nextNode() devolve o proprio root (body),
    // porque o ponteiro comeca ANTES da referencia.
    src := `
        var it = document.createNodeIterator(document.body, NodeFilter.SHOW_ELEMENT);
        var out = [];
        var n;
        while ((n = it.nextNode())) out.push(n.tagName + (n.id ? "#" + n.id : ""));
        out.join(",");
    `
    testing.expect_value(t, run_m154(src).(string), "BODY,DIV#one,DIV#two")
}

// ── whatToShow: apenas nos de texto ──────────────────────────────────────────

@(test)
m154_show_text :: proc(t: ^testing.T) {
    src := `
        var it = document.createNodeIterator(document.body, NodeFilter.SHOW_TEXT);
        var out = [];
        var n;
        while ((n = it.nextNode())) out.push(n.textContent);
        out.join(",");
    `
    testing.expect_value(t, run_m154(src).(string), "x,y")
}

// ── whatToShow: apenas comentarios ───────────────────────────────────────────

@(test)
m154_show_comment :: proc(t: ^testing.T) {
    src := `
        var it = document.createNodeIterator(document.body, NodeFilter.SHOW_COMMENT);
        var c = 0;
        while (it.nextNode()) c++;
        c;
    `
    testing.expect_value(t, run_m154(src).(f64), 1)
}

// ── FILTRO como funcao (honrado, nao ignorado) ───────────────────────────────

@(test)
m154_filtro_funcao_rejeita :: proc(t: ^testing.T) {
    // Rejeita div#one; sobram body e div#two.
    src := `
        var it = document.createNodeIterator(document.body, NodeFilter.SHOW_ELEMENT,
            function(n){ return n.id === 'one' ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT; });
        var out = [];
        var n;
        while ((n = it.nextNode())) out.push(n.tagName + (n.id ? "#" + n.id : ""));
        out.join(",");
    `
    testing.expect_value(t, run_m154(src).(string), "BODY,DIV#two")
}

// ── FILTRO como objeto com acceptNode ────────────────────────────────────────

@(test)
m154_filtro_objeto_accept_node :: proc(t: ^testing.T) {
    src := `
        var it = document.createNodeIterator(document.body, NodeFilter.SHOW_ELEMENT, {
            acceptNode: function(n){ return n.id === 'two' ? NodeFilter.FILTER_ACCEPT : NodeFilter.FILTER_SKIP; }
        });
        var out = [];
        var n;
        while ((n = it.nextNode())) out.push(n.id);
        out.join(",");
    `
    testing.expect_value(t, run_m154(src).(string), "two")
}

// ── previousNode alcanca o root de volta ─────────────────────────────────────

@(test)
m154_previous_node_volta_ate_root :: proc(t: ^testing.T) {
    // Avanca ate div#two (ref=two, ponteiro DEPOIS). Pela spec, o 1o previousNode
    // reposiciona o ponteiro e devolve o PROPRIO two (nextNode+previousNode dao o
    // mesmo no), depois one, depois body, entao null.
    src := `
        var it = document.createNodeIterator(document.body, NodeFilter.SHOW_ELEMENT);
        it.nextNode(); it.nextNode(); it.nextNode(); // body, one, two
        var out = [];
        var n;
        while ((n = it.previousNode())) out.push(n.tagName + (n.id ? "#" + n.id : ""));
        out.join(",");
    `
    testing.expect_value(t, run_m154(src).(string), "DIV#two,DIV#one,BODY")
}

// ── SHOW_ALL sem filtro devolve todos os tipos ───────────────────────────────

@(test)
m154_show_all_conta_tudo :: proc(t: ^testing.T) {
    // body + div#one + "x" + div#two + comentario + "y" = 6 nos.
    src := `
        var it = document.createNodeIterator(document.body, NodeFilter.SHOW_ALL);
        var c = 0;
        while (it.nextNode()) c++;
        c;
    `
    testing.expect_value(t, run_m154(src).(f64), 6)
}

// ── propriedades expostas pela spec ──────────────────────────────────────────

@(test)
m154_props_da_spec :: proc(t: ^testing.T) {
    src := `
        var it = document.createNodeIterator(document.body, NodeFilter.SHOW_ELEMENT);
        [it.root.tagName, it.whatToShow, it.pointerBeforeReferenceNode, typeof it.detach].join("|");
    `
    testing.expect_value(t, run_m154(src).(string), "BODY|1|true|function")
}
