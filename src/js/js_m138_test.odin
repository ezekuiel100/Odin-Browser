package js

// M138 — peel do `reading 'get'` que sobrou no crates.io (M137).
//
// A sonda de membro (compile-gated, `-define:MEMBERPROBE=true`) disse o que a
// mensagem padrão não diz: a base era `o(...)` — uma NATIVA NOSSA, sem nome, com 2
// argumentos, devolvendo undefined, e o que se lia dela era `.get`. Assinatura de
// `Object.getOwnPropertyDescriptor(alvo, chave)`.
//
// Raiz: as props dos elementos são servidas por um HOOK na instância, então os
// prototypes de interface (Element.prototype, Node.prototype…) eram cascas vazias e
// `getOwnPropertyDescriptor(Element.prototype, "innerHTML")` dava undefined. Pegar o
// acessor nativo por descritor é o idioma de meia biblioteca (React no
// inputValueTracking, Svelte, polyfills de input).
//
// Agora os prototypes têm acessores SINTETIZADOS que delegam ao hook do receptor —
// uma implementação só, sem segunda verdade.
//
// ⚠️ A 1ª versão delegava via `get_member` e RECURSAVA: um nome que o hook não serve
// cai na cadeia de protótipo, reencontra o mesmo getter e estoura a pilha (aconteceu
// com `parentElement`; as 3 rejeições do crates.io viraram um RangeError). O acessor
// tem que chamar o hook DIRETO.

import "core:testing"
import "core:strings"
import dom "../dom"

@(private = "file")
run_dom_page :: proc(src: string) -> Value {
    root := dom.make_node(.Document)
    defer dom.free_tree(root)
    html := dom.make_node(.Element); html.tag = strings.clone("html")
    body := dom.make_node(.Element); body.tag = strings.clone("body")
    dom.append_child(html, body)
    dom.append_child(root, html)
    return run_with_dom(src, root)
}

// ── descritores nos prototypes de interface ──────────────────────────────────

@(test)
m138_descritor_de_acessor_do_dom_existe :: proc(t: ^testing.T) {
    src := `
        var d = Object.getOwnPropertyDescriptor(Element.prototype, "innerHTML");
        (d ? typeof d.get : "sem descritor") + "|" + (d ? typeof d.set : "-")
    `
    testing.expect_value(t, run_dom_page(src).(string), "function|function")
}

@(test)
m138_descritor_get_le_do_elemento :: proc(t: ^testing.T) {
    // O uso real: capturar o acessor e chamá-lo com um elemento como this.
    src := `
        var d = Object.getOwnPropertyDescriptor(Element.prototype, "innerHTML");
        var el = document.createElement("div");
        el.innerHTML = "<b>x</b>";
        d.get.call(el)
    `
    testing.expect_value(t, run_dom_page(src).(string), "<b>x</b>")
}

@(test)
m138_descritor_set_escreve_no_elemento :: proc(t: ^testing.T) {
    src := `
        var d = Object.getOwnPropertyDescriptor(Node.prototype, "textContent");
        var el = document.createElement("div");
        d.set.call(el, "posto");
        el.textContent
    `
    testing.expect_value(t, run_dom_page(src).(string), "posto")
}

@(test)
m138_acessor_no_prototype_nao_recursa :: proc(t: ^testing.T) {
    // NÃO-REGRESSÃO da recursão: ler a prop DIRETO do prototype (receptor sem nó por
    // trás) tem que devolver undefined, não estourar a pilha. `parentElement` é o
    // caso exato que estourou — nome com acessor sintetizado que o hook não serve.
    src := `
        var a = Element.prototype.innerHTML;
        var b = Node.prototype.parentElement;
        (a === undefined) + "|" + (b === undefined)
    `
    testing.expect_value(t, run_dom_page(src).(string), "true|true")
}

@(test)
m138_prototype_de_interface_nao_enumera :: proc(t: ^testing.T) {
    // Os acessores são não-enumeráveis, como no navegador: `Object.keys(
    // Element.prototype)` é vazio e um `for in` num elemento não os lista.
    src := `Object.keys(Element.prototype).length`
    testing.expect_value(t, as_number(run_dom_page(src)), 0)
}

@(test)
m138_leitura_normal_do_elemento_intacta :: proc(t: ^testing.T) {
    // NÃO-REGRESSÃO: o hook da instância continua vencendo a cadeia de protótipo.
    src := `
        var e = document.createElement("p");
        e.innerHTML = "<i>y</i>";
        e.className = "c";
        e.innerHTML + "|" + e.className + "|" + e.tagName
    `
    testing.expect_value(t, run_dom_page(src).(string), "<i>y</i>|c|P")
}

@(test)
m138_descritor_de_objeto_comum_intacto :: proc(t: ^testing.T) {
    // NÃO-REGRESSÃO do getOwnPropertyDescriptor fora do DOM.
    src := `
        var d1 = Object.getOwnPropertyDescriptor({ a: 1 }, "a");
        var d2 = Object.getOwnPropertyDescriptor({ get x() { return 1 } }, "x");
        var d3 = Object.getOwnPropertyDescriptor({}, "naoExiste");
        d1.value + "|" + typeof d2.get + "|" + (d3 === undefined)
    `
    testing.expect_value(t, run(src).(string), "1|function|true")
}

// ── parentElement e namespaceURI ─────────────────────────────────────────────

@(test)
m138_parent_element :: proc(t: ^testing.T) {
    // Só `parentNode` existia. `el.parentElement.appendChild(...)` é o idioma comum,
    // e dava "reading 'appendChild' of undefined".
    src := `
        var d = document.createElement("div");
        var s = document.createElement("span");
        d.appendChild(s);
        s.parentElement.tagName
    `
    testing.expect_value(t, run_dom_page(src).(string), "DIV")
}

@(test)
m138_parent_element_para_no_documento :: proc(t: ^testing.T) {
    // A diferença p/ parentNode: o pai de <html> é o Document, que NÃO é elemento.
    src := `
        var h = document.documentElement;
        (h.parentNode !== null) + "|" + (h.parentElement === null)
    `
    testing.expect_value(t, run_dom_page(src).(string), "true|true")
}

@(test)
m138_namespace_uri :: proc(t: ^testing.T) {
    // O hidratador do Svelte lê p/ escolher createElement vs createElementNS.
    src := `
        document.createElement("div").namespaceURI + "|" + document.createElement("svg").namespaceURI
    `
    testing.expect_value(t, run_dom_page(src).(string),
        "http://www.w3.org/1999/xhtml|http://www.w3.org/2000/svg")
}
