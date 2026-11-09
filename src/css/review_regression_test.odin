package css

import "core:testing"
import "core:strings"

@(test)
review_pseudo_specificity_single_parse_regressions :: proc(t: ^testing.T) {
    cases := []struct { text: string, want: [3]int }{
        // Rejeitar :hover no matching não pode ocultar #id posterior.
        {".x:is(:hover, #id)", {1, 1, 0}},
        {".x:is(#id, :hover)", {1, 1, 0}},
        {".x:not(:hover, #id):not(:focus)", {1, 2, 0}},
        // Grupos adicionais aproximados no matching ainda somam especificidade.
        {":is(.a):is(#id):matches(.b):-webkit-any(div)", {1, 2, 1}},
        {":where(#id):where(:not(#other)):is(.a)", {0, 1, 0}},
        {"div:has(> .a, + #id):has(~ .b)", {1, 1, 1}},
        {":not(.a.b.c.d.e.f.g.h.i.j.k, #id)", {1, 0, 0}},
    }
    for c in cases {
        sel, ok := parse_complex(c.text)
        testing.expect(t, ok, c.text)
        if !ok do continue
        testing.expect(t, sel.specificity == c.want, c.text)
        free_selector(&sel)
    }
    sel, ok := parse_complex(".x:is(:hover, #id)")
    testing.expect(t, ok)
    if ok {
        testing.expect_value(t, len(sel.parts[0].ors), 0)
        testing.expect(t, sel.parts[0].is_unresolved)
        free_selector(&sel)
    }
}

@(test)
review_pseudo_deep_nesting_no_duplicate_parse_tree :: proc(t: ^testing.T) {
    // Antes, cada nível duplicava recursivamente todo o parse do argumento.
    // Profundidade 28 torna essa regressão impraticável no caminho antigo.
    for pseudo in ([]string{"is", "where", "not", "has"}) {
        sb := strings.builder_make(context.temp_allocator)
        for _ in 0..<28 {
            strings.write_string(&sb, ".guard:")
            strings.write_string(&sb, pseudo)
            strings.write_byte(&sb, '(')
        }
        strings.write_string(&sb, "#id")
        for _ in 0..<28 do strings.write_byte(&sb, ')')
        sel, ok := parse_complex(strings.to_string(sb))
        testing.expect(t, ok, pseudo)
        if !ok do continue
        want := [3]int{1, 28, 0}
        if pseudo == "where" do want = {0, 1, 0}
        testing.expect(t, sel.specificity == want, pseudo)
        free_selector(&sel)
    }
}

@(test)
review_layers_decode_escapes_and_keep_token_boundaries :: proc(t: ^testing.T) {
    rules, keys := parse(`
        @layer foo\31 , later, foo\.bar, foo.bar, a\,b, semi\;colon;
        @layer foo1 { p {color:red} }
        @layer foo\000031 { p {color:blue} }
        @layer foo\31 { p {color:green} }
        @layer foo\.bar { p {color:red} }
        @layer foo\2e bar { p {color:blue} }
        @layer foo.bar { p {color:green} }
        @layer a\2c b { p {color:red} }
        @layer a\,b { p {color:blue} }
        @layer semi\3b colon { p {color:red} }
        @layer semi\;colon { p {color:blue} }
        @layer later { p {color:black} }
    `)
    defer free_rules(&rules)
    defer free_keyframes(&keys)
    testing.expect_value(t, len(rules), 11)
    if len(rules) != 11 do return
    expected := []int{0, 0, 0, 2, 2, 3, 5, 5, 6, 6, 1}
    for rank, i in expected do testing.expect_value(t, rules[i].layer_rank, rank)
}

@(test)
review_layers_validate_decoded_keywords_atomically :: proc(t: ^testing.T) {
    rules, keys := parse(`
        @layer ghost, \69 nitial;
        @layer later { p {color:red} }
        @layer ghost { p {color:blue} }
        @layer \69 nherit { p {color:green} }
        @layer 1bad { p {color:green} }
        @layer \31 good { p {color:red} }
        @layer \000031good { p {color:blue} }
        @layer root { @layer foo\31 { p {color:red} } }
        @layer root.foo1 { p {color:blue} }
    `)
    defer free_rules(&rules)
    defer free_keyframes(&keys)
    testing.expect_value(t, len(rules), 6)
    if len(rules) != 6 do return
    expected := []int{0, 1, 2, 2, 3, 3}
    for rank, i in expected do testing.expect_value(t, rules[i].layer_rank, rank)
}

@(test)
review_layers_hex_whitespace_unicode_and_invalid_escapes :: proc(t: ^testing.T) {
    for source in ([]string{"foo\\31 \tbar", "foo\\31\nbar", "foo\\31\r\nbar", "foo\\31\fbar"}) {
        name, end, ok := layer_ident(source, 0)
        // Apenas UM whitespace terminador (CRLF conta como um) é consumido.
        if source == "foo\\31 \tbar" {
            testing.expect(t, ok && name == "foo1" && end == 7)
        } else {
            testing.expect(t, ok && name == "foo1bar" && end == len(source))
        }
    }
    for source in ([]string{`\0`, `\d800`, `\110000`}) {
        name, _, ok := layer_ident(source, 0)
        testing.expect(t, ok && name == "�")
    }
    for source in ([]string{"foo\\", "foo\\\nbar", "foo\\\rbar", "foo\\\fbar"}) {
        _, _, ok := layer_ident(source, 0)
        testing.expect(t, !ok)
    }
    a, _, ok_a := layer_ident(`caf\e9`, 0)
    b, _, ok_b := layer_ident("café", 0)
    testing.expect(t, ok_a && ok_b && a == b)
}
