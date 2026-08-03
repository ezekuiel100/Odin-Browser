package html

// Um parse não pode deixar NADA para trás. O que vai para a ÁRVORE é liberado
// pelo dom.free_tree; todo o resto é ANDAIME do parser (a fila de tokens, as
// pilhas do builder, a raiz <html> sintética do fragmento e o elemento de
// CONTEXTO) e tem de ser liberado por quem o criou.
//
// Por que isto virou gate: `el.innerHTML = '...'` é UM parse_fragment inteiro por
// atribuição, e cada um vazava ~1,6 KiB fixos (1,19 KiB só da fila de tokens)
// mais o texto/atributos do markup. Numa SPA que reescreve innerHTML milhares de
// vezes por sessão isso vira dezenas de MB — e a pressão de RAM já é o problema
// nº 1 deste motor.
//
// O rastreador do runner do Odin NÃO reprova um teste que vaza: ele só imprime
// um WARN, que passa despercebido no meio de 2400 testes. Aqui um vazamento é
// FALHA, com o número de blocos e bytes na mensagem.
//
// O `bad_free_array` é a outra metade do gate, e é a que protege a armadilha
// central: `Token.data` é ALOCADO em comentário/texto e é uma FATIA DO INPUT em
// CDATA, RAWTEXT e no `</` solto. Liberar a fatia corromperia a heap; o
// Tracking_Allocator acusa como bad free porque o input do teste é um literal
// que ele nunca alocou. Todo caminho de token está exercido abaixo.

import "core:mem"
import "core:testing"
import dom "../dom"

// Roda `body` sob um Tracking_Allocator e exige zero vazamento e zero bad free.
@(private = "file")
expect_no_leak :: proc(t: ^testing.T, label: string, body: proc(input: string), input: string) {
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    {
        context.allocator = mem.tracking_allocator(&track)
        body(input)
    }
    bytes := 0
    for _, e in track.allocation_map do bytes += e.size
    testing.expectf(t, len(track.allocation_map) == 0,
        "%s: vazou %d bloco(s) / %d byte(s)", label, len(track.allocation_map), bytes)
    testing.expectf(t, len(track.bad_free_array) == 0,
        "%s: %d free(s) de ponteiro não alocado (fatia do input liberada como se fosse dona?)",
        label, len(track.bad_free_array))
}

@(private = "file")
do_fragment_div :: proc(input: string) { dom.free_tree(parse_fragment(input, "div")) }
@(private = "file")
do_fragment_table :: proc(input: string) { dom.free_tree(parse_fragment(input, "table")) }
@(private = "file")
do_fragment_svg :: proc(input: string) { dom.free_tree(parse_fragment(input, "g", "svg")) }
@(private = "file")
do_fragment_title :: proc(input: string) { dom.free_tree(parse_fragment(input, "title")) }
@(private = "file")
do_fragment_style :: proc(input: string) { dom.free_tree(parse_fragment(input, "style")) }
@(private = "file")
do_fragment_plaintext :: proc(input: string) { dom.free_tree(parse_fragment(input, "plaintext")) }
@(private = "file")
do_document :: proc(input: string) { dom.free_tree(parse_document(input)) }

// ── fragmento (o caminho do innerHTML) ──────────────────────────────────────

@(test)
test_fragmento_nao_vaza_vazio :: proc(t: ^testing.T) {
    // Piso: string vazia é o caso que só paga o ANDAIME (nenhum token de tag).
    // Era 1,60 KiB dos 1,67 KiB do caso real — o grosso do vazamento não vinha
    // do markup, vinha de existir um parse.
    expect_no_leak(t, "fragmento vazio", do_fragment_div, "")
}

@(test)
test_fragmento_nao_vaza_elementos :: proc(t: ^testing.T) {
    expect_no_leak(t, "elementos", do_fragment_div, "<p></p><p></p>")
}

@(test)
test_fragmento_nao_vaza_atributos :: proc(t: ^testing.T) {
    // O map + attr_order do TOKEN são separados dos do elemento (que clona):
    // era o termo mais caro POR ELEMENTO (~576 B com 2 atributos).
    // Inclui atributo sem `=` (valor é o literal "", não pode ser liberado)
    // e atributo DUPLICADO (parse_open_tag descarta o segundo).
    expect_no_leak(t, "atributos", do_fragment_div,
        `<p class="alfa" data-x="beta" hidden id="a" id="b"><a href="#x&amp;y">t</a></p>`)
}

@(test)
test_fragmento_nao_vaza_texto_e_entidades :: proc(t: ^testing.T) {
    // decode_entities ALOCA (clona até no atalho sem '&') e insert_text clona de novo.
    expect_no_leak(t, "texto", do_fragment_div, "texto solto <b>&amp; entidade &#x41; &nao-entidade</b> fim")
}

@(test)
test_fragmento_nao_vaza_comentarios :: proc(t: ^testing.T) {
    // comentário normal, abrupto, bogus (`<!x`, `<?x`, `</1>`) — todos ALOCAM data.
    expect_no_leak(t, "comentários", do_fragment_div, "<!-- a -->x<!--><!--->y<!bogus><?pi><//>z")
}

@(test)
test_fragmento_nao_vaza_rawtext_e_rcdata :: proc(t: ^testing.T) {
    // RAWTEXT entrega FATIA do input; RCDATA aloca (decode_entities). É a
    // assimetria que o owns_data existe para registrar: se alguém marcar o
    // RAWTEXT como dono, o bad_free_array acusa aqui.
    expect_no_leak(t, "style/RAWTEXT", do_fragment_style, "div{color:red} /* & < */")
    expect_no_leak(t, "title/RCDATA", do_fragment_title, "t&amp;t < x")
    expect_no_leak(t, "plaintext", do_fragment_plaintext, "cru <b> & tudo texto")
    expect_no_leak(t, "rawtext aninhado", do_fragment_div,
        "<style>a{}</style><textarea>&amp;</textarea><script>var a='</b>'</script>")
}

@(test)
test_fragmento_nao_vaza_tag_incompleta :: proc(t: ^testing.T) {
    // `</` no fim do input vira token Char com FATIA do input (não é dono);
    // tag aberta sem '>' é abandonada (EOF) — o token descartado tem name+attrs
    // ALOCADOS por parse_open_tag e ninguém mais o lê.
    expect_no_leak(t, "</ solto", do_fragment_div, "a</")
    expect_no_leak(t, "tag sem fechar", do_fragment_div, `x<div class="y" data-z`)
    expect_no_leak(t, "só '<'", do_fragment_div, "<")
}

@(test)
test_fragmento_nao_vaza_svg_e_cdata :: proc(t: ^testing.T) {
    // Em conteúdo estrangeiro o `<![CDATA[…]]>` também é FATIA do input.
    expect_no_leak(t, "svg + CDATA", do_fragment_svg, "<rect x='1'/><![CDATA[ cru & < ]]><circle/>")
}

@(test)
test_fragmento_nao_vaza_tabela_e_adocao :: proc(t: ^testing.T) {
    // foster parenting usa o builder `pending` (in-table text); a adoption agency
    // mexe na lista de elementos de formatação (b.afe) e CLONA elementos.
    expect_no_leak(t, "tabela/foster", do_fragment_table,
        "texto fora<tr><td>a</td></tr><tbody><tr><td>b")
    expect_no_leak(t, "adoption agency", do_fragment_div, "<b>1<p>2</b>3</p><nobr>a<nobr>b")
}

@(test)
test_fragmento_nao_vaza_contexto_com_tag_longa :: proc(t: ^testing.T) {
    // O elemento de CONTEXTO nunca entra na árvore: o `tag` clonado dele era um
    // dos blocos vazados (3 B com ctx "div"). Com uma tag longa, um vazamento do
    // contexto aparece no total de bytes em vez de se esconder no ruído.
    expect_no_leak(t, "ctx longo", do_fragment_div, "<p>x</p>") // ctx curto (controle)
    track: mem.Tracking_Allocator
    mem.tracking_allocator_init(&track, context.allocator)
    defer mem.tracking_allocator_destroy(&track)
    {
        context.allocator = mem.tracking_allocator(&track)
        dom.free_tree(parse_fragment("<p>x</p>", "um-custom-element-de-nome-bem-comprido"))
    }
    testing.expectf(t, len(track.allocation_map) == 0,
        "ctx longo: vazou %d bloco(s)", len(track.allocation_map))
}

// ── documento (o caminho da renderização) ───────────────────────────────────

@(test)
test_documento_nao_vaza :: proc(t: ^testing.T) {
    // parse_document paga o mesmo andaime (fila de tokens + pilhas), só que uma
    // vez por página em vez de uma vez por atribuição.
    expect_no_leak(t, "documento", do_document,
        `<!DOCTYPE html PUBLIC "-//W3C//DTD HTML 4.01//EN" "http://www.w3.org/TR/html4/strict.dtd">` +
        `<html><head><title>t&amp;t</title><style>a{}</style></head>` +
        `<body class="x"><!-- c --><p>oi &amp; tchau<table><tr><td>1</table><input type=hidden name=q>` +
        `<svg><rect/></svg></body></html>`)
}

@(test)
test_documento_vazio_nao_vaza :: proc(t: ^testing.T) {
    expect_no_leak(t, "documento vazio", do_document, "")
}
