package html

// Testes do parser HTML. Rodar:  odin test src/html
// O foco é ROBUSTEZ (não travar/crashar) + casos básicos de árvore — a suíte
// externa html5lib-tests (html5lib-test.ps1) cobre conformância ampla.

import "core:testing"
import "core:strings"
import dom "../dom"

// Serializa a árvore no formato html5lib e devolve string aparada (p/ asserts).
@(private = "file")
tree :: proc(input: string) -> string {
    doc := parse(input)
    defer dom.free_tree(doc)
    s := html5lib_serialize(doc)
    defer delete(s)
    return strings.clone(strings.trim_right(s, "\n"))
}

// ── ROBUSTEZ: inputs que ANTES travavam em loop infinito ─────────────────────
// html5lib-tests (tests1.dat#36) achou: um '<' que não vira tag caía no ramo de
// texto, que reencontrava o mesmo '<' e não avançava i → hang. Estes garantem
// terminação (o próprio testing.T falharia por timeout se voltasse a travar).

@(test)
test_lone_lt :: proc(t: ^testing.T) {
    r := tree("<")
    defer delete(r)
    testing.expect_value(t, r, `| "<"`)
}

@(test)
test_lt_space :: proc(t: ^testing.T) {
    r := tree("< ")
    defer delete(r)
    testing.expect_value(t, r, `| "< "`)
}

@(test)
test_lt_bang_eof :: proc(t: ^testing.T) {
    // "<!" sozinho: declaração/comentário sem fecho — consome até o fim, sem travar
    r := tree("<!")
    defer delete(r)
    testing.expect_value(t, r, "") // nenhum nó
}

@(test)
test_text_with_stray_lt :: proc(t: ^testing.T) {
    // "a<b" → texto "a" + elemento <b> (b é nome de tag válido)
    r := tree("a<b")
    defer delete(r)
    testing.expect(t, strings.contains(r, `| "a"`) && strings.contains(r, "| <b>"),
        "esperava texto 'a' e elemento <b>")
}

// ── casos básicos de árvore ──────────────────────────────────────────────────

@(test)
test_basic_element_text :: proc(t: ^testing.T) {
    r := tree("<p>oi</p>")
    defer delete(r)
    testing.expect_value(t, r, "| <p>\n|   \"oi\"")
}

@(test)
test_attrs_sorted :: proc(t: ^testing.T) {
    // atributos saem ORDENADOS por nome (id antes de zebra), minúsculos
    r := tree(`<div ZEBRA="1" id="a">x</div>`)
    defer delete(r)
    testing.expect_value(t, r, "| <div>\n|   id=\"a\"\n|   zebra=\"1\"\n|   \"x\"")
}

@(test)
test_void_element :: proc(t: ^testing.T) {
    r := tree("<br>after")
    defer delete(r)
    testing.expect_value(t, r, "| <br>\n| \"after\"")
}

@(test)
test_entities_in_text :: proc(t: ^testing.T) {
    r := tree("a &amp; b &lt;c&gt;")
    defer delete(r)
    testing.expect_value(t, r, `| "a & b <c>"`)
}

@(test)
test_comment :: proc(t: ^testing.T) {
    r := tree("<!--hi-->")
    defer delete(r)
    testing.expect_value(t, r, "| <!-- hi -->")
}

// ── emissor de tokens (html5lib tokenizer) ───────────────────────────────────

@(private = "file")
toks :: proc(input: string) -> string {
    s := html5lib_tokenize(input)
    defer delete(s)
    return strings.clone(strings.trim_right(s, "\n"))
}

@(private = "file")
toks_st :: proc(input, state, last: string) -> string {
    s := html5lib_tokenize(input, state, last)
    defer delete(s)
    return strings.clone(strings.trim_right(s, "\n"))
}

// ── estados iniciais não-Data (RCDATA/RAWTEXT/PLAINTEXT/CDATA/script) ─────────
@(test)
test_state_rcdata :: proc(t: ^testing.T) { // decodifica entidades, fecha em </last>
    r := toks_st("a&amp;b</title>", "rcdata", "title")
    defer delete(r)
    testing.expect_value(t, r, "[\"Character\",\"a&b\"]\n[\"EndTag\",\"title\"]")
}
@(test)
test_state_rawtext :: proc(t: ^testing.T) { // NÃO decodifica
    r := toks_st("a&amp;b</style>", "rawtext", "style")
    defer delete(r)
    testing.expect_value(t, r, "[\"Character\",\"a&amp;b\"]\n[\"EndTag\",\"style\"]")
}
@(test)
test_state_plaintext :: proc(t: ^testing.T) { // tudo literal, nunca fecha
    r := toks_st("<b>&x;</plaintext>", "plaintext", "plaintext")
    defer delete(r)
    testing.expect_value(t, r, `["Character","<b>&x;</plaintext>"]`)
}
@(test)
test_state_cdata :: proc(t: ^testing.T) { // raw até ]]>, sem decode; depois Data
    r := toks_st("a&#32;]]>&#32;", "cdata", "")
    defer delete(r)
    testing.expect_value(t, r, `["Character","a&#32; "]`) // cdata cru + data decodificado
}
@(test)
test_state_rcdata_no_close_at_eof :: proc(t: ^testing.T) { // </xmp sem '>' → abandona
    r := toks_st("foo</xmp ", "rcdata", "xmp")
    defer delete(r)
    testing.expect_value(t, r, `["Character","foo"]`)
}
@(test)
test_state_script_double_escaped :: proc(t: ^testing.T) { // </script> interno não fecha
    r := toks_st("<!-- <script></script> --></script>", "script", "script")
    defer delete(r)
    testing.expect_value(t, r, "[\"Character\",\"<!-- <script></script> -->\"]\n[\"EndTag\",\"script\"]")
}

// coalescing: runs de texto adjacentes (incl. um '<' literal) = 1 Character
// (html5lib tokenizer test2#34). Antes emitíamos dois tokens.
@(test)
test_tok_coalesce :: proc(t: ^testing.T) {
    r := toks("foo < bar")
    defer delete(r)
    testing.expect_value(t, r, `["Character","foo < bar"]`)
}

// self-closing SÓ com '/>' — `<h/a='b'>` NÃO é self-closing (test2#28). Antes
// qualquer '/' marcava self-closing (bug real, afetava a tree-construction).
@(test)
test_tok_stray_solidus_not_self_closing :: proc(t: ^testing.T) {
    r := toks("<h/a='b'>")
    defer delete(r)
    testing.expect_value(t, r, `["StartTag","h",{"a":"b"}]`)
}

@(test)
test_tok_real_self_closing :: proc(t: ^testing.T) {
    r := toks("<br/>")
    defer delete(r)
    testing.expect_value(t, r, `["StartTag","br",{},true]`)
}

// char ref numérico NUL / fora de faixa → U+FFFD (test2#16/#19)
@(test)
test_tok_charref_nul_fffd :: proc(t: ^testing.T) {
    r := toks("&#0;")
    defer delete(r)
    testing.expect_value(t, r, "[\"Character\",\"�\"]")
}

@(test)
test_tok_charref_out_of_range_fffd :: proc(t: ^testing.T) {
    // > U+10FFFF → FFFD. (Usamos &#x110000; e não um valor mais longo: há um teto
    // pré-existente de ~10 chars no comprimento da entidade em decode_entities.)
    r := toks("&#x110000;")
    defer delete(r)
    testing.expect_value(t, r, "[\"Character\",\"�\"]")
}

// "&#;" sem dígitos NÃO é char ref → texto literal
@(test)
test_tok_charref_no_digits_literal :: proc(t: ^testing.T) {
    r := toks("&#;")
    defer delete(r)
    testing.expect_value(t, r, `["Character","&#;"]`)
}

// ── tabela COMPLETA de entidades nomeadas (entities_gen.odin) ─────────────────

// entidade que não estava na tabela hand-made antiga
@(test)
test_named_entity_full_table :: proc(t: ^testing.T) {
    r := toks("&bigstar;")
    defer delete(r)
    testing.expect_value(t, r, "[\"Character\",\"★\"]")
}

// entidade de DOIS codepoints (~93 no HTML5)
@(test)
test_named_entity_two_codepoints :: proc(t: ^testing.T) {
    r := toks("&NotEqualTilde;")
    defer delete(r)
    testing.expect_value(t, r, "[\"Character\",\"≂̸\"]") // U+2242 U+0338
}

// nome mais longo do HTML5 (31 chars) — guarda o teto de comprimento em decode
@(test)
test_named_entity_longest_name :: proc(t: ^testing.T) {
    r := toks("&CounterClockwiseContourIntegral;")
    defer delete(r)
    testing.expect_value(t, r, "[\"Character\",\"∳\"]")
}

// busca binária: nome inexistente → literal
@(test)
test_named_entity_unknown_literal :: proc(t: ^testing.T) {
    r := toks("&naoexiste;")
    defer delete(r)
    testing.expect_value(t, r, `["Character","&naoexiste;"]`)
}

// ── longest-match de entidades legadas (sem ';') ─────────────────────────────

// entidade legada sem ';' resolve em texto
@(test)
test_named_legacy_no_semicolon :: proc(t: ^testing.T) {
    r := toks("&copy")
    defer delete(r)
    testing.expect_value(t, r, "[\"Character\",\"©\"]")
}

// longest-match: "&notit;" = "not" (legado) + "it;" literal
@(test)
test_named_longest_match_prefix :: proc(t: ^testing.T) {
    r := toks("&notit;")
    defer delete(r)
    testing.expect_value(t, r, "[\"Character\",\"¬it;\"]")
}

// '&' que não inicia entidade fica literal (não estraga "AT&T")
@(test)
test_amp_not_entity_literal :: proc(t: ^testing.T) {
    r := toks("AT&T & U")
    defer delete(r)
    testing.expect_value(t, r, `["Character","AT&T & U"]`)
}

// ambiguous ampersand: em ATRIBUTO, "&copy=" (seguido de '=') NÃO decodifica
@(test)
test_ambiguous_ampersand_attr :: proc(t: ^testing.T) {
    r := tree(`<a href="?x&copy=1">t</a>`)
    defer delete(r)
    testing.expect(t, strings.contains(r, `href="?x&copy=1"`),
        "entidade legada seguida de '=' em atributo deve ficar literal")
}

// mas em atributo sem '='/alnum depois, decodifica normalmente
@(test)
test_legacy_entity_attr_decodes :: proc(t: ^testing.T) {
    r := tree(`<a href="?x&copy">t</a>`)
    defer delete(r)
    testing.expect(t, strings.contains(r, "?x©"),
        "entidade legada sem '='/alnum depois deve decodificar em atributo")
}

// ── ref numérica sem ';', zeros à esquerda, remap C1 ─────────────────────────
@(test)
test_numeric_no_semicolon :: proc(t: ^testing.T) {
    r := toks("&#38")
    defer delete(r); testing.expect_value(t, r, `["Character","&"]`)
}
@(test)
test_numeric_leading_zeros :: proc(t: ^testing.T) {
    r := toks("&#00065;")
    defer delete(r); testing.expect_value(t, r, `["Character","A"]`)
}
@(test)
test_numeric_c1_remap :: proc(t: ^testing.T) {
    r := toks("&#128;") // → € (windows-1252)
    defer delete(r); testing.expect_value(t, r, "[\"Character\",\"€\"]")
}

// ── end tag com atributos/lixo fecha o elemento (nome real) ──────────────────
@(test)
test_end_tag_with_junk_closes :: proc(t: ^testing.T) {
    r := tree(`<div>a</div class=x>b`)
    defer delete(r)
    // 'b' deve ser IRMÃO do div (div fechado), não filho
    testing.expect(t, strings.contains(r, "| \"b\""), "end tag com lixo deve fechar o <div>")
}

// ── atributo duplicado mantém o primeiro ─────────────────────────────────────
@(test)
test_duplicate_attr_first_wins :: proc(t: ^testing.T) {
    r := toks("<x a=1 a=2 A=3>")
    defer delete(r); testing.expect_value(t, r, `["StartTag","x",{"a":"1"}]`)
}

// ── DOCTYPE: máquina de estados (correctness + ids) ──────────────────────────
@(test)
test_doctype_correct :: proc(t: ^testing.T) {
    r := toks("<!DOCTYPE html>")
    defer delete(r); testing.expect_value(t, r, `["DOCTYPE","html",null,null,true]`)
}
@(test)
test_doctype_public_system :: proc(t: ^testing.T) {
    r := toks(`<!DOCTYPE a PUBLIC "p" "s">`)
    defer delete(r); testing.expect_value(t, r, `["DOCTYPE","a","p","s",true]`)
}
@(test)
test_doctype_eof_quirks :: proc(t: ^testing.T) {
    r := toks("<!DOCTYPE a PUBLIC") // EOF sem id → force-quirks, pub null
    defer delete(r); testing.expect_value(t, r, `["DOCTYPE","a",null,null,false]`)
}

// ── comentário: máquina de estados ───────────────────────────────────────────
@(test)
test_comment_abrupt_empty :: proc(t: ^testing.T) {
    r := toks("<!---") // dash de abertura + EOF → comentário vazio
    defer delete(r); testing.expect_value(t, r, `["Comment",""]`)
}
@(test)
test_comment_bang_close :: proc(t: ^testing.T) {
    r := toks("<!--x--!>") // --!> fecha
    defer delete(r); testing.expect_value(t, r, `["Comment","x"]`)
}

// ── bogus comment (<! e <?), CR→LF ───────────────────────────────────────────
@(test)
test_bogus_comment :: proc(t: ^testing.T) {
    r := toks("<?pi?>")
    defer delete(r); testing.expect_value(t, r, `["Comment","?pi?"]`)
}
@(test)
test_cr_normalized :: proc(t: ^testing.T) {
    r := toks("a\r\nb\rc") // CRLF e CR → LF
    defer delete(r); testing.expect_value(t, r, "[\"Character\",\"a\\nb\\nc\"]")
}

// ── tokenizer emite codepoints REAIS (astral); parser sanitiza p/ render ──────
@(test)
test_tok_astral_real :: proc(t: ^testing.T) {
    r := toks("&#x10000;&Afr;") // U+10000 + U+1D504 (fraktur A astral)
    defer delete(r); testing.expect_value(t, r, "[\"Character\",\"𐀀𝔄\"]")
}

// nbsp: o TOKENIZER reporta U+00A0 real...
@(test)
test_tok_nbsp_real_u00a0 :: proc(t: ^testing.T) {
    r := toks("&nbsp;")
    defer delete(r); testing.expect_value(t, r, "[\"Character\",\" \"]")
}

// ...mas o PARSER (render) troca U+00A0 por espaço via sanitize_text
@(test)
test_parser_nbsp_becomes_space :: proc(t: ^testing.T) {
    r := tree("<p>a&nbsp;b</p>")
    defer delete(r); testing.expect_value(t, r, "| <p>\n|   \"a b\"")
}

// ASTRAL (fora do BMP) é PRESERVADO — mudou no M188.
//
// Este teste dizia o contrário ("test_parser_drops_astral"): o `sanitize_text`
// apagava todo rune > 0xFFFF porque o ImWchar de 16 bits do ImGui não o
// representa e ele apareceria como `?`. Desde que o emoji virou TEXTURA
// (src/ui/emoji.odin) apagá-lo aqui é que quebrava o desenho — o caractere sumia
// antes de chegar ao layout, e nenhum conserto rio abaixo tinha o que desenhar.
@(test)
test_parser_keeps_astral :: proc(t: ^testing.T) {
    r := tree("<p>x&#x10000;y</p>")
    defer delete(r); testing.expect_value(t, r, "| <p>\n|   \"x\U00010000y\"")
}

// ── NUL→U+FFFD em nome/atributo; NUL mantido em texto (data state) ───────────
@(test)
test_tok_nul_in_tagname :: proc(t: ^testing.T) {
    r := toks("<a\x00>")
    defer delete(r); testing.expect_value(t, r, "[\"StartTag\",\"a�\",{}]")
}
@(test)
test_tok_nul_in_attrval :: proc(t: ^testing.T) {
    r := toks("<a b=\x00>")
    defer delete(r); testing.expect_value(t, r, "[\"StartTag\",\"a\",{\"b\":\"�\"}]")
}
// data state: NUL em texto NÃO vira FFFD (só em nome de tag/atributo e valor)
@(test)
test_tok_text_nul_not_fffd :: proc(t: ^testing.T) {
    r := toks("<p>x\x00y</p>")
    defer delete(r)
    testing.expect(t, !strings.contains(r, "�"), "NUL em texto (data state) não deve virar FFFD")
}

// ── '=' inicia nome de atributo ──────────────────────────────────────────────
@(test)
test_tok_equals_starts_attr :: proc(t: ^testing.T) {
    r := toks("<a =>")
    defer delete(r); testing.expect_value(t, r, `["StartTag","a",{"=":""}]`)
}

// ── TREE CONSTRUCTION (parse_document): esqueleto html/head/body, doctype,
//    tabelas, adoption agency, conteúdo estrangeiro, template ────────────────
// A suíte externa html5lib-test.ps1 (tree-construction) cobre 1494/1709; estes
// travam a espinha dorsal do treebuild.odin como guarda de regressão local.
@(private = "file")
treedoc :: proc(input: string) -> string {
    doc := parse_document(input)
    s := html5lib_serialize(doc)
    defer delete(s)
    return strings.clone(strings.trim_right(s, "\n"))
}

@(test)
test_td_scaffold :: proc(t: ^testing.T) {
    r := treedoc("Test")
    defer delete(r)
    testing.expect_value(t, r, "| <html>\n|   <head>\n|   <body>\n|     \"Test\"")
}

@(test)
test_td_doctype :: proc(t: ^testing.T) {
    r := treedoc("<!DOCTYPE html>x")
    defer delete(r)
    testing.expect_value(t, r, "| <!DOCTYPE html>\n| <html>\n|   <head>\n|   <body>\n|     \"x\"")
}

@(test)
test_td_implied_p :: proc(t: ^testing.T) {
    r := treedoc("<p>One<p>Two")
    defer delete(r)
    testing.expect_value(t, r, "| <html>\n|   <head>\n|   <body>\n|     <p>\n|       \"One\"\n|     <p>\n|       \"Two\"")
}

@(test)
test_td_table_implied :: proc(t: ^testing.T) {
    // <table><td> sintetiza tbody + tr em volta do td
    r := treedoc("<table><td>")
    defer delete(r)
    testing.expect_value(t, r, "| <html>\n|   <head>\n|   <body>\n|     <table>\n|       <tbody>\n|         <tr>\n|           <td>")
}

@(test)
test_td_adoption :: proc(t: ^testing.T) {
    // adoption agency clássico: <b>1<p>2</b>3
    r := treedoc("<b>1<p>2</b>3")
    defer delete(r)
    exp := "| <html>\n|   <head>\n|   <body>\n|     <b>\n|       \"1\"\n|     <p>\n|       <b>\n|         \"2\"\n|       \"3\""
    testing.expect_value(t, r, exp)
}

@(test)
test_td_foreign_svg :: proc(t: ^testing.T) {
    // namespace + ajuste de caixa do nome (foreignObject)
    r := treedoc("<svg><foreignObject></foreignObject></svg>")
    defer delete(r)
    exp := "| <html>\n|   <head>\n|   <body>\n|     <svg svg>\n|       <svg foreignObject>"
    testing.expect_value(t, r, exp)
}

@(test)
test_td_foreign_endtag_breakout :: proc(t: ^testing.T) {
    // §13.2.6.5: end tags </p> e </br> compartilham a entrada de BREAKOUT das
    // start tags — saem do conteúdo estrangeiro e reprocessam em HTML (o <p> e
    // o <foo> viram IRMÃOS do svg, não filhos). Era o cluster tests26 #17-#20.
    r := treedoc("<svg></p><foo>")
    defer delete(r)
    exp := "| <html>\n|   <head>\n|   <body>\n|     <svg svg>\n|     <p>\n|     <foo>"
    testing.expect_value(t, r, exp)
    r2 := treedoc("<math></br><foo>")
    defer delete(r2)
    exp2 := "| <html>\n|   <head>\n|   <body>\n|     <math math>\n|     <br>\n|     <foo>"
    testing.expect_value(t, r2, exp2)
}

@(test)
test_td_template_content :: proc(t: ^testing.T) {
    // <template> ganha o document-fragment "content"
    r := treedoc("<body><template>Hi</template>")
    defer delete(r)
    exp := "| <html>\n|   <head>\n|   <body>\n|     <template>\n|       content\n|         \"Hi\""
    testing.expect_value(t, r, exp)
}

// ── FRAGMENT PARSING (parse_fragment): innerHTML/insertAdjacentHTML ──────────
// A suíte externa cobre 169/192 (tests_innerHTML_1 + foreign-fragment + os
// #document-fragment espalhados). Estes travam o que o setter de innerHTML
// depende: o modo vem do elemento de CONTEXTO, não do início de um documento.
@(private = "file")
treefrag :: proc(input, ctx: string, ns := "") -> string {
    doc := parse_fragment(input, ctx, ns)
    s := html5lib_serialize(doc)
    defer delete(s)
    return strings.clone(strings.trim_right(s, "\n"))
}

@(test)
test_frag_sem_scaffold :: proc(t: ^testing.T) {
    // fragmento NÃO ganha html/head/body — é a diferença central p/ o documento
    r := treefrag("<p>oi", "div")
    defer delete(r)
    testing.expect_value(t, r, "| <p>\n|   \"oi\"")
}

@(test)
test_frag_contexto_decide_tr :: proc(t: ^testing.T) {
    // em <tbody> o <tr> sobrevive (modo InRow via reset_insertion_mode)...
    r := treefrag("<tr><td>x", "tbody")
    defer delete(r)
    testing.expect_value(t, r, "| <tr>\n|   <td>\n|     \"x\"")
}

@(test)
test_frag_contexto_decide_div :: proc(t: ^testing.T) {
    // ...e no mesmo input dentro de <div> as tags de tabela são DESCARTADAS,
    // sobrando só o texto. Mesmo HTML, árvore diferente: é o ponto do fragmento.
    r := treefrag("<tr><td>x", "div")
    defer delete(r)
    testing.expect_value(t, r, "| \"x\"")
}

@(test)
test_frag_contexto_svg :: proc(t: ^testing.T) {
    // contexto estrangeiro: o adjusted current node é o contexto, então <rect>
    // nasce no namespace SVG mesmo com a pilha só tendo a raiz sintética.
    r := treefrag("<rect/>", "svg", "svg")
    defer delete(r)
    testing.expect_value(t, r, "| <svg rect>")
}

@(test)
test_frag_svg_breakout_html :: proc(t: ^testing.T) {
    // caso de fragmento da regra de breakout: em contexto estrangeiro o <nobr>
    // é processado pelas regras de HTML. Antes do fix isto era LOOP INFINITO.
    r := treefrag("<nobr>X", "path", "svg")
    defer delete(r)
    testing.expect_value(t, r, "| <nobr>\n|   \"X\"")
}

@(test)
test_frag_contexto_rcdata :: proc(t: ^testing.T) {
    // o estado inicial do tokenizador vem do contexto: dentro de <title> o
    // conteúdo é RCDATA, então <b> é TEXTO e não vira elemento.
    r := treefrag("a<b>c", "title")
    defer delete(r)
    testing.expect_value(t, r, "| \"a<b>c\"")
}

@(test)
test_td_texto_grande_em_um_no :: proc(t: ^testing.T) {
    // Guarda do caminho EM LOTE (insert_text): o corpo de um <script> chega como
    // UM token de caractere e tem de virar UM nó de texto ÍNTEGRO. Antes era
    // anexado rune a rune (O(L²) + leak de cada intermediário).
    // 64K de corpo: com o bug isto levava segundos; em lote é instantâneo.
    body := strings.repeat("x", 64 * 1024)
    defer delete(body)
    src := strings.concatenate({"<body><script>", body, "</script>"})
    defer delete(src)
    doc := parse_document(src)
    // html > body > script > #text
    html := doc.children[0]
    b := html.children[1]
    script := b.children[0]
    testing.expect_value(t, script.tag, "script")
    testing.expect_value(t, len(script.children), 1)
    testing.expect_value(t, script.children[0].kind, dom.Node_Kind.Text)
    testing.expect_value(t, len(script.children[0].text), len(body))
}

@(test)
test_td_texto_em_body_um_no :: proc(t: ^testing.T) {
    // Mesmo lote no modo InBody, que passa por reconstruct_afe/frameset_ok: o
    // texto tem de sair num nó só e com o conteúdo exato (inclusive o espaço).
    r := treedoc("<p>ab cd</p>")
    defer delete(r)
    testing.expect_value(t, r, "| <html>\n|   <head>\n|   <body>\n|     <p>\n|       \"ab cd\"")
}

@(test)
test_frag_sem_appropriate_end_tag :: proc(t: ^testing.T) {
    // No fragmento NÃO existe "appropriate end tag" (é definida contra a última
    // start tag emitida pelo TOKENIZER, e nenhuma foi — §13.4 só seta o estado):
    // `</script>`/`</title>` do input não fecham nada, tudo é texto. Era o
    // cluster tests4 (last_start vinha do contexto e fechava cedo).
    r := treefrag("<!-- inside </script> -->", "script")
    defer delete(r)
    testing.expect_value(t, r, "| \"<!-- inside </script> -->\"")
    r2 := treefrag("a</title>b", "title")
    defer delete(r2)
    testing.expect_value(t, r2, "| \"a</title>b\"")
    // ...mas uma start tag ANINHADA no fragmento ainda arma o fechamento dela
    // (o tree builder seta last_start ao processar <script>): o par fecha normal.
    r3 := treefrag("<script>x</script>y", "div")
    defer delete(r3)
    testing.expect_value(t, r3, "| <script>\n|   \"x\"\n| \"y\"")
}

@(test)
test_frag_head_nao_esvazia_pilha :: proc(t: ^testing.T) {
    // contexto <head>: o modo InHead manda popar "o head", mas o fundo da pilha
    // é a raiz sintética — sem o guarda do pop_open isto CRASHAVA (índice -1).
    r := treefrag("<title>x</title>", "head")
    defer delete(r)
    testing.expect_value(t, r, "| <title>\n|   \"x\"")
}

@(test)
test_frag_contexto_html_tem_body :: proc(t: ^testing.T) {
    // contra-caso do teste acima: com contexto <html> o fragmento É o miolo de
    // um documento, então o par head/body implícito CONTINUA sendo criado.
    r := treefrag("", "html")
    defer delete(r)
    testing.expect_value(t, r, "| <head>\n| <body>")
}
