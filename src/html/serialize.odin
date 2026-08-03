package html

// Serializa a árvore DOM no formato do html5lib-tests (secção #document dos
// tree-construction tests). Usado pelo modo `browser.exe --parsetree`, que o
// html5lib-test.ps1 compara com o #document esperado.
//
// Formato (cada nível = 2 espaços; prefixo "| " + profundidade*2 espaços):
//   | <html>
//   |   <head>
//   |   <body>
//   |     <p>
//   |       class="a"          (atributos: uma linha, ORDENADOS por nome)
//   |       "texto"
//   |     <!-- comentário -->
//
// LIMITAÇÕES CONHECIDAS (o parser é um subconjunto — ver parser.odin):
//   - não sintetiza <html>/<head>/<body> nem <!DOCTYPE> (ignorado) → esses
//     testes dão DIFF, não são bug;
//   - &nbsp; vira espaço normal (0x20), não U+00A0;
//   - runes fora do BMP são descartadas (sanitize_text).

import "core:strings"
import "core:slice"
import dom "../dom"

html5lib_serialize :: proc(doc: ^dom.Node) -> string {
    sb := strings.builder_make()
    // os filhos do Document ficam no nível 0
    for c in doc.children {
        ser_node(&sb, c, 0)
    }
    return strings.to_string(sb)
}

@(private = "file")
ser_indent :: proc(sb: ^strings.Builder, depth: int) {
    strings.write_string(sb, "| ")
    for _ in 0 ..< depth do strings.write_string(sb, "  ")
}

@(private = "file")
ser_node :: proc(sb: ^strings.Builder, n: ^dom.Node, depth: int) {
    switch n.kind {
    case .Element:
        // nó sintético de DOCTYPE (tree construction): tag "!doctype",
        // n.text = o miolo já formatado (ex.: `html` ou `html "pub" "sys"`).
        if n.tag == "!doctype" {
            ser_indent(sb, depth)
            strings.write_string(sb, "<!DOCTYPE ")
            strings.write_string(sb, n.text)
            strings.write_string(sb, ">\n")
            return
        }
        // document-fragment "content" de um <template>: imprime `content`
        // (sem < >) e recursa nos filhos.
        if n.tag == "#content" {
            ser_indent(sb, depth)
            strings.write_string(sb, "content\n")
            for c in n.children do ser_node(sb, c, depth + 1)
            return
        }
        ser_indent(sb, depth)
        strings.write_byte(sb, '<')
        // prefixo de namespace estrangeiro: `<svg rect>`, `<math mi>`.
        // Tags SVG são guardadas em minúsculas; o ajuste de caixa
        // ("foreignObject" etc.) é aplicado aqui, na serialização.
        if n.ns == "svg" {
            strings.write_string(sb, "svg ")
            strings.write_string(sb, svg_tag_adjust(n.tag))
        } else if n.ns == "math" {
            strings.write_string(sb, "math ")
            strings.write_string(sb, n.tag)
        } else {
            strings.write_string(sb, n.tag)
        }
        strings.write_string(sb, ">\n")
        // atributos ordenados por nome (Unicode codepoint) — o html5lib exige
        if len(n.attrs) > 0 {
            keys := make([dynamic]string)
            defer delete(keys)
            for k in n.attrs do append(&keys, k)
            slice.sort(keys[:])
            for k in keys {
                ser_indent(sb, depth + 1)
                strings.write_string(sb, k)
                strings.write_string(sb, "=\"")
                strings.write_string(sb, n.attrs[k])
                strings.write_string(sb, "\"\n")
            }
        }
        for c in n.children do ser_node(sb, c, depth + 1)
    case .Text:
        ser_indent(sb, depth)
        strings.write_byte(sb, '"')
        strings.write_string(sb, n.text)
        strings.write_string(sb, "\"\n")
    case .Comment:
        ser_indent(sb, depth)
        strings.write_string(sb, "<!-- ")
        strings.write_string(sb, n.text)
        strings.write_string(sb, " -->\n")
    case .Document:
        for c in n.children do ser_node(sb, c, depth)
    }
}
