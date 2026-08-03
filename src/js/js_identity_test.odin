package js

// Testes de IDENTIDADE dos wrappers de nó DOM (#1 do roadmap SPA).
// Antes do cache, cada getElementById/parentNode/firstChild/createElement criava
// um ^Object novo → `a === a` dava false entre consultas, quebrando refs e diffing
// do React. Aqui provamos que o MESMO nó sempre devolve o MESMO objeto JS.
// Rodar: odin test src/js

import "core:strings"
import "core:testing"
import dom "../dom"

// Monta:  <div id="x"><span id="s">a</span></div>  sob um Document.
@(private = "file")
build_nested :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)

    div := dom.make_node(.Element)
    div.tag = strings.clone("div")
    div.attrs = make(map[string]string)
    div.attrs[strings.clone("id")] = strings.clone("x")

    span := dom.make_node(.Element)
    span.tag = strings.clone("span")
    span.attrs = make(map[string]string)
    span.attrs[strings.clone("id")] = strings.clone("s")

    txt := dom.make_node(.Text)
    txt.text = strings.clone("a")

    dom.append_child(span, txt)
    dom.append_child(div, span)
    dom.append_child(root, div)
    return root
}

@(private = "file")
expect_true :: proc(t: ^testing.T, src: string, root: ^dom.Node, msg: string) {
    r := run_with_dom(src, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, msg)
}

// Duas consultas ao mesmo id devolvem o MESMO objeto.
@(test)
test_identity_same_lookup :: proc(t: ^testing.T) {
    root := build_nested()
    defer dom.free_tree(root)
    expect_true(t,
        "document.getElementById('x') === document.getElementById('x')",
        root, "getElementById duas vezes deve dar objetos idênticos")
}

// Ida e volta pela árvore: div.firstChild (span) .parentNode === div.
@(test)
test_identity_roundtrip_navigation :: proc(t: ^testing.T) {
    root := build_nested()
    defer dom.free_tree(root)
    expect_true(t,
        `var d = document.getElementById('x'); d.firstChild.parentNode === d`,
        root, "navegar filho->pai deve voltar ao mesmo objeto")
}

// O nó do span alcançado por dois caminhos diferentes é o mesmo objeto.
@(test)
test_identity_cross_paths :: proc(t: ^testing.T) {
    root := build_nested()
    defer dom.free_tree(root)
    expect_true(t,
        "document.getElementById('s') === document.getElementById('x').firstChild",
        root, "mesmo nó por caminhos diferentes deve ser idêntico")
}

// createElement + appendChild: o objeto criado, alcançado por OUTRO caminho
// (.children do pai), continua sendo o mesmo objeto. (Usa navegação em vez de
// querySelector para não depender do hook g_dom_query, que só o pacote ui instala.)
@(test)
test_identity_created_node :: proc(t: ^testing.T) {
    root := build_nested()
    defer dom.free_tree(root)
    expect_true(t,
        `var d = document.getElementById('x');
         var c = document.createElement('b');
         d.appendChild(c);
         d.children[1] === c`,
        root, "nó criado deve manter identidade alcançado pelo pai")
}

// Guarda-chave para o React: um objeto usado como chave de Map reencontra o valor
// quando o MESMO nó é reconsultado (é assim que fibers indexam stateNode).
@(test)
test_identity_as_map_key :: proc(t: ^testing.T) {
    root := build_nested()
    defer dom.free_tree(root)
    expect_true(t,
        `var m = new Map();
         m.set(document.getElementById('x'), 42);
         m.get(document.getElementById('x')) === 42`,
        root, "nó como chave de Map deve reencontrar o valor")
}

// Após textContent= liberar a subárvore, novas consultas continuam coerentes
// (sem wrapper pendente): re-adicionar e reconsultar dá identidade estável.
@(test)
test_identity_stable_after_text_reset :: proc(t: ^testing.T) {
    root := build_nested()
    defer dom.free_tree(root)
    expect_true(t,
        `var d = document.getElementById('x');
         d.textContent = 'zerado';
         var c = document.createElement('i');
         d.appendChild(c);
         d.children[0] === c`,
        root, "após textContent= a identidade de novos nós deve ser estável")
}
