package ui

import "core:testing"
import csspkg "../css"
import dompkg "../dom"

// `:defined` (Selectors 4 / HTML): era PERMISSIVA (casava tudo), então
// `:not(:defined)` casava TODO elemento. O reddit tem
//     :not(:defined):not(faceplate-…){visibility:hidden}
// e a página inteira — a começar pelo <html> — saía em branco.

@(private = "file")
cor_de :: proc(css: string, tag: string, ns := "", defined := false) -> u32 {
    rules, _ := csspkg.parse(css)
    defer csspkg.free_rules(&rules)
    n := dompkg.make_node(.Element)
    defer free(n) // tag/attrs não são do nó (literal/temp): só a struct
    n.tag = tag
    n.ns = ns
    n.attrs = make(map[string]string, context.temp_allocator)
    n.ce_defined = defined
    styles, _ := compute_styles(n, &rules)
    c := styles[n].color
    free_styles(styles)
    return c & 0xFFFFFF
}

VERMELHO :: 0xFF0000

@(test)
defined_nao_custom_e_sempre_definido :: proc(t: ^testing.T) {
    css := `:not(:defined){color:rgb(255,0,0)}`
    // o caso do reddit: <html>/<div> NUNCA casam :not(:defined)
    testing.expect(t, cor_de(css, "html") != VERMELHO, "html não pode casar :not(:defined)")
    testing.expect(t, cor_de(css, "div") != VERMELHO, "div não pode casar :not(:defined)")
    // SVG com hífen (font-face) não é custom element
    testing.expect(t, cor_de(css, "font-face", ns = "svg") != VERMELHO, "svg font-face é definido")
}

@(test)
defined_custom_depende_do_upgrade :: proc(t: ^testing.T) {
    css := `:not(:defined){color:rgb(255,0,0)}`
    testing.expect_value(t, cor_de(css, "x-widget", defined = false), u32(VERMELHO))
    testing.expect(t, cor_de(css, "x-widget", defined = true) != VERMELHO, "promovido deixa de casar :not(:defined)")
    // e a forma positiva
    pos := `x-widget:defined{color:rgb(255,0,0)}`
    testing.expect_value(t, cor_de(pos, "x-widget", defined = true), u32(VERMELHO))
    testing.expect(t, cor_de(pos, "x-widget", defined = false) != VERMELHO, ":defined não casa custom não promovido")
}

// O formato EXATO do reddit: dois :not encadeados, o 2º com lista de tags.
@(test)
defined_regra_do_reddit :: proc(t: ^testing.T) {
    css := `:not(:defined):not(x-livre,x-outro){color:rgb(255,0,0)}`
    testing.expect(t, cor_de(css, "html") != VERMELHO, "html visível")
    testing.expect_value(t, cor_de(css, "x-nunca"), u32(VERMELHO))
    testing.expect(t, cor_de(css, "x-livre") != VERMELHO, "tag excluída pelo 2º :not")
}

// Upgrade sem outra mutação tem de mudar o fingerprint de estilo do nó — é o que
// faz o restyle INCREMENTAL reavaliar `:defined`.
@(test)
defined_upgrade_muda_fingerprint :: proc(t: ^testing.T) {
    n := dompkg.make_node(.Element)
    defer free(n)
    n.tag = "x-widget"
    antes := dompkg.style_fingerprint(n)
    n.ce_defined = true
    testing.expect(t, dompkg.style_fingerprint(n) != antes, "ce_defined tem de entrar no style_fingerprint")
}
