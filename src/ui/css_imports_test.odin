package ui

import "core:strings"
import "core:testing"
import csspkg "../css"

@(private = "file")
imports_fixture :: proc(url: string) -> (string, bool) {
    switch url {
    case "https://imports.test/a.css": return `@import "b.css"; a { color: red }`, true
    case "https://imports.test/b.css": return `@import "a.css"; b { color: blue }`, true
    case "https://imports.test/plain.css": return `p { color: red }`, true
    }
    return "", false
}

@(private = "file")
imports_expand_fixture :: proc(css: string) -> (string, int) {
    count := 0
    st := css_import_state(&count, imports_fixture)
    b := strings.builder_make(context.temp_allocator)
    css_expand_imports(css, "https://imports.test/root.css", &b, &st)
    return strings.to_string(b), count
}

@(test)
imports_modifiers_and_escaped_url :: proc(t: ^testing.T) {
    url, cond := parse_import_stmt(`url("a);b\22 c.css") /* x */ layer(theme.base) supports(display: grid) screen and (width > 1px)`)
    testing.expect_value(t, url, "a);b\"c.css")
    c := css_import_conditions(cond)
    testing.expect(t, c.ok && c.layer)
    testing.expect_value(t, c.name, "theme.base")
    testing.expect_value(t, c.supports, "display: grid")
    testing.expect_value(t, c.media, "screen and (width > 1px)")
    testing.expect(t, css_import_conditions("layer supports((display: grid) and (color: red)) print").ok)
    for bad in ([]string{"layer()", "layer(a,b)", "supports()", "supports(x) layer(a)", "layer(a) layer(b)", "supports((x)"}) {
        testing.expect(t, !css_import_conditions(bad).ok, bad)
    }
    testing.expect_value(t, import_media_cond("layer(a) supports(display: grid) print"), "print")
}

@(test)
imports_repeated_occurrences_cache_and_cycle_stack :: proc(t: ^testing.T) {
    out, downloads := imports_expand_fixture(`@import "a.css" layer(first); @import "a.css" layer(second); @import "plain.css"; @import "plain.css";`)
    testing.expect_value(t, downloads, 3)
    // Um ciclo corta A->B->A, não a segunda ocorrência de A nem de plain.
    testing.expect_value(t, strings.count(out, "a { color: red }"), 2)
    testing.expect_value(t, strings.count(out, "b { color: blue }"), 2)
    testing.expect_value(t, strings.count(out, "p { color: red }"), 2)
    testing.expect(t, strings.contains(out, "@layer first") && strings.contains(out, "@layer second"))
}

@(test)
imports_scanner_header_strings_comments_and_blocks :: proc(t: ^testing.T) {
    for source in ([]string{
        `a { content: '@import "plain.css";'; }`,
        `@media screen { @import "plain.css"; }`,
        `@layer block { @import "plain.css"; }`,
        `a {} @import "plain.css";`,
        `@namespace x "urn:test"; @import "plain.css";`,
        `@imported "plain.css";`,
    }) {
        out, downloads := imports_expand_fixture(source)
        testing.expect_value(t, downloads, 0)
        testing.expect(t, strings.has_suffix(out, source), source)
    }
    out, downloads := imports_expand_fixture(`/* @import "missing.css"; */ @LaYeR first, second; @ImPoRt "plain.css" layer(first) supports(display: grid) screen;`)
    testing.expect_value(t, downloads, 1)
    testing.expect(t, strings.contains(out, "@LaYeR first, second;"))
    layer := strings.index(out, "@layer first {")
    supports := strings.index(out, "@supports (display: grid)")
    media := strings.index(out, "@media screen")
    testing.expect(t, layer >= 0 && supports > layer && media > supports)
    testing.expect_value(t, strings.count(out, " {"), strings.count(out, "}"))
    _, downloads = imports_expand_fixture(`@import url("x);y.css") supports((display: grid) and (content: ";)")) print;`)
    testing.expect_value(t, downloads, 1) // statement não termina no ; da string
}

@(test)
imports_layer_registration_and_anonymous_occurrences :: proc(t: ^testing.T) {
    out, downloads := imports_expand_fixture(`@import "missing.css" layer(first) supports(display: none); @import "plain.css" layer; @import "plain.css" layer;`)
    testing.expect_value(t, downloads, 2)
    testing.expect(t, strings.contains(out, "@layer first {"))
    rules, _ := csspkg.parse(out)
    defer csspkg.free_rules(&rules)
    testing.expect_value(t, len(rules), 2)
    if len(rules) == 2 {
        testing.expect(t, rules[0].layer_rank != rules[1].layer_rank, "cada layer anônima é distinta")
        testing.expect(t, rules[0].layer_rank > 0, "camada vazia anterior permanece registrada")
    }
}
