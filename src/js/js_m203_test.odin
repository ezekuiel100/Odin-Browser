package js

// M203 — `el.innerHTML = '...'` não vaza mais.
//
// Cada atribuição é UM parse_fragment inteiro, e o parser não liberava o próprio
// andaime: a fila de tokens do tokenizador (1,19 KiB), as pilhas do builder, a
// raiz <html> sintética que é descascada no fim e o elemento de CONTEXTO — mais
// as strings de cada token (nome de tag, valores de atributo, texto decodificado).
// Medido antes do conserto, com um DOM mínimo e nada mais:
//   innerHTML=''                → 1,60 KiB   (o piso: só o andaime)
//   innerHTML='<p></p><p></p>'  → 1,67 KiB
//   o mesmo, 10 vezes           → 16,67 KiB  (linear: vaza POR ATRIBUIÇÃO)
// Uma SPA reescreve innerHTML aos milhares por sessão.
//
// O gate FINO (por caminho de token: RAWTEXT vs RCDATA, CDATA, comentário
// bogus, tag inacabada) está em src/html/parse_leak_test.odin, junto do código
// que possui as strings. Este aqui é o de PONTA A PONTA: garante que o caminho
// do JS — dom_elem_set → parse_html_fragment → mo_insert → free_tree do
// fragmento — também fecha a conta, incluindo o VM.
//
// Tracking_Allocator próprio porque o WARN de vazamento do runner do Odin não
// REPROVA o teste: ele só imprime, e some no meio de 1600 testes do pacote.

import "core:mem"
import "core:strings"
import "core:testing"
import dom "../dom"

// <body><div id="h"></div></body> sob um Document.
@(private = "file")
m203_dom :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    body := dom.make_node(.Element)
    body.tag = strings.clone("body")
    body.attrs = make(map[string]string)
    h := dom.make_node(.Element)
    h.tag = strings.clone("div")
    h.attrs = make(map[string]string)
    dom.set_attr(h, strings.clone("id"), strings.clone("h"))
    dom.append_child(body, h)
    dom.append_child(root, body)
    return root
}

// Roda `src` com DOM sob um Tracking_Allocator e exige zero vazamento.
// Tudo (DOM, VM e fragmento) nasce e morre dentro da região rastreada.
@(private = "file")
expect_no_leak :: proc(t: ^testing.T, label: string, src: string) {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    {
        context.allocator = mem.tracking_allocator(&track)
        root := m203_dom()
        run_with_dom(src, root)
        dom.free_tree(root)
    }
    bytes := 0
    for _, e in track.allocation_map do bytes += e.size
    testing.expectf(t, len(track.allocation_map) == 0,
        "%s: vazou %d bloco(s) / %d byte(s)", label, len(track.allocation_map), bytes)
    testing.expectf(t, len(track.bad_free_array) == 0,
        "%s: %d free(s) de ponteiro não alocado", label, len(track.bad_free_array))
}

@(test)
test_m203_innerhtml_vazio_nao_vaza :: proc(t: ^testing.T) {
    // O piso: mesmo sem markup nenhum o parse acontece e pagava 1,60 KiB.
    expect_no_leak(t, "innerHTML=''", `document.getElementById('h').innerHTML=''`)
}

@(test)
test_m203_innerhtml_nao_vaza :: proc(t: ^testing.T) {
    expect_no_leak(t, "innerHTML=<p><p>", `document.getElementById('h').innerHTML='<p></p><p></p>'`)
}

@(test)
test_m203_innerhtml_com_atributos_e_texto_nao_vaza :: proc(t: ^testing.T) {
    // Atributos eram o termo mais caro por elemento (map + ordem + valores do
    // TOKEN, separados dos do elemento, que clona).
    expect_no_leak(t, "innerHTML com atributos",
        `document.getElementById('h').innerHTML='<a href="/x?a=1&amp;b=2" class="c d">t&amp;t</a><!-- c -->'`)
}

@(test)
test_m203_innerhtml_repetido_nao_acumula :: proc(t: ^testing.T) {
    // O caso da SPA: reescrever o MESMO nó em laço. Era aqui que 1,67 KiB
    // viravam 16,67 KiB em 10 voltas — o teste que mais importa.
    expect_no_leak(t, "innerHTML 50x", `
        var h = document.getElementById('h');
        for (var i = 0; i < 50; i++) h.innerHTML = '<ul><li class="r">' + i + '</li><li>b</li></ul>';
    `)
}

@(test)
test_m203_insert_adjacent_html_nao_vaza :: proc(t: ^testing.T) {
    // Mesmo parse_fragment por outro caminho (native_insert_adjacent_html).
    expect_no_leak(t, "insertAdjacentHTML", `
        var h = document.getElementById('h');
        for (var i = 0; i < 10; i++) h.insertAdjacentHTML('beforeend', '<span id="s' + i + '">x</span>');
    `)
}

@(test)
test_m203_innerhtml_continua_funcionando :: proc(t: ^testing.T) {
    // Liberar o andaime não pode ter levado junto nada da árvore: o conteúdo
    // ainda tem de estar lá e legível (um free a mais apareceria aqui como lixo
    // ou crash, não como vazamento).
    root := m203_dom()
    defer dom.free_tree(root)
    r := run_with_dom(`
        var h = document.getElementById('h');
        h.innerHTML = '<p class="um">a</p><p>b<b>c</b></p>';
        h.children.length + '|' + h.children[0].className + '|' +
            h.children[0].textContent + '|' + h.children[1].textContent + '|' +
            h.children[1].children[0].tagName
    `, root)
    s, _ := r.(string)
    testing.expect_value(t, s, "2|um|a|bc|B")
}
