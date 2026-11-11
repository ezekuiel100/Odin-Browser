package css

import "core:testing"

@(test)
tokenizer_spans_and_escapes :: proc(t: ^testing.T) {
    s := "/* ) */.a\\2c b[title=\"x;})\"]"
    l := Tokenizer{source = s}
    kinds := []Token_Kind{.Comment, .Delim, .Name, .Delim, .Name, .Delim, .String, .Delim}
    pos := 0
    for kind in kinds {
        tok := next_token(&l)
        testing.expect_value(t, tok.kind, kind)
        testing.expect_value(t, tok.start, pos)
        testing.expect(t, tok.end > tok.start)
        pos = tok.end
    }
    testing.expect_value(t, pos, len(s))
    testing.expect_value(t, next_token(&l).kind, Token_Kind.EOF)
    escapes := []struct{s: string, cp: rune, end: int}{
        {"\\000061\r\nx", 'a', 9}, {"\\0", 0xfffd, 2},
        {"\\d800", 0xfffd, 5}, {"\\110000", 0xfffd, 7}, {"\\é", 'é', 3},
    }
    for c in escapes {
        cp, end, ok := consume_escape(c.s, 0)
        testing.expect(t, ok)
        testing.expect_value(t, cp, c.cp)
        testing.expect_value(t, end, c.end)
    }
}

@(test)
tokenizer_groups_and_separators :: proc(t: ^testing.T) {
    bad := []string{`([)]`, `("unterminated)`, "('bad\nstring')", `(abc\)`, `({]})`}
    for s in bad {
        testing.expectf(t, !tokens_balanced(s), "accepted %s", s)
        testing.expect_value(t, token_group_end(s, 0), -1)
    }
    good := []string{`(["),;}"] /* ) */ {x})`, "('a\\\r\nb')", `(a\29 b)`}
    for s in good {
        testing.expectf(t, tokens_balanced(s), "rejected %s", s)
        testing.expect_value(t, token_group_end(s, 0), len(s)-1)
    }
    s := `--x: {a: [b;c]}; color: red`
    testing.expect_value(t, declaration_end(s), 15)
    d := parse_decls(s)
    defer { for k, v in d { delete(k); delete(v) }; delete(d) }
    testing.expect_value(t, d["--x"], "{a: [b;c]}")
    testing.expect_value(t, d["color"], "red")
    _, important := split_important(`"!important"`)
    testing.expect(t, !important)
}

@(test)
tokenizer_stylesheet_and_selector_consistency :: proc(t: ^testing.T) {
    rules, keys := parse(`@media (min-width: 1px) {
        .a/**/.b { content: "};/*literal*/{"; color: red; }
        .c { --x: {a: [b;c]}; color: blue; }
    } .d {color: green}`)
    defer free_rules(&rules)
    defer free_keyframes(&keys)
    if !testing.expect_value(t, len(rules), 3) do return
    testing.expect_value(t, rules[0].decls["content"], `"};/*literal*/{"`)
    testing.expect_value(t, rules[0].decls["color"], "red")
    testing.expect_value(t, rules[1].decls["color"], "blue")
    testing.expect_value(t, rules[1].decls["--x"], "{a: [b;c]}")
    sels := parse_selectors(`.a/**/.b`)
    defer { for &s in sels do free_selector(&s); delete(sels) }
    if testing.expect_value(t, len(sels), 1) {
        testing.expect(t, compound_matches(sels[0].parts[0], "div", []string{"a", "b"}, ""))
    }
    testing.expect(t, supports_selector(`.a/**/.b`))
}

@(test)
tokenizer_attribute_escapes_match :: proc(t: ^testing.T) {
    attrs := make(map[string]string)
    defer delete(attrs)
    attrs["a=b"] = "'"
    attrs["data-x"] = "ab"
    cases := []string{`[a\=b="\'"]`, "[data-x='a\\\r\nb']"}
    for text in cases {
        sels := parse_selectors(text)
        if testing.expect_value(t, len(sels), 1) {
            testing.expect(t, compound_matches(sels[0].parts[0], "div", nil, "", attrs))
        }
        for &sel in sels do free_selector(&sel)
        delete(sels)
    }
}
