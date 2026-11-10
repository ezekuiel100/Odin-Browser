package css

import "core:testing"

@(test)
selector_strict_syntax :: proc(t: ^testing.T) {
    bad := []string{"", ".", "#", "div >", "> div", "div >> a", "div + ~ a", "div,", ",div", "div,,a", "[x", "[x=]", "[]", "[x=y z]", "div:made-up", "div:hover()", ":not()", ":not(.x, :unknown)", ":nth-child(banana)", ":nth-child(n1)", ":nth-child(2 n+1)", ":nth-child(n+1 2)", "div::unknown", "div::before.x", "div{", ":is(.x]"}
    for s in bad {
        testing.expectf(t, !selectors_valid(s), "accepted invalid selector: %s", s)
        sels := parse_selectors(s)
        testing.expect_value(t, len(sels), 0)
        for &sel in sels do free_selector(&sel)
        delete(sels)
        testing.expectf(t, !supports_selector(s), "advertised invalid selector: %s", s)
    }
    good := []string{"*", "div > p + a", "[data-x=\"a],b)\" i]", ":is(.x, :unknown)", ":where()", ":not(.x, #y)", ":has(> img)", ":scope > .x", "li:nth-child(2n + 1)", ".a\\:b", "[x='' s]"}
    for s in good do testing.expectf(t, selectors_valid(s), "rejected valid selector: %s", s)
}

@(test)
selector_escapes_and_quoted_groups :: proc(t: ^testing.T) {
    cases := []struct{s, name: string}{
        {`.\31 23`, "123"}, {`.caf\e9`, "café"}, {`.a\,b`, "a,b"},
        {`.a\:b`, "a:b"}, {`.\1f600`, "😀"},
    }
    for c in cases {
        sels := parse_selectors(c.s)
        if testing.expect_value(t, len(sels), 1) {
            testing.expect(t, compound_matches(sels[0].parts[0], "div", []string{c.name}, ""))
        }
        for &sel in sels do free_selector(&sel)
        delete(sels)
    }
    testing.expect(t, supports_condition_with(`selector([x="a),b]"])`, nil))
    testing.expect(t, supports_condition_with(`(--x: "a) and (b")`, nil))
    testing.expect(t, !supports_condition_with(`selector(div >)`, nil))
}

@(test)
selector_attribute_case_flags :: proc(t: ^testing.T) {
    attrs := make(map[string]string)
    attrs["data-x"] = "AbC def-Z"
    attrs["data-u"] = "Ä"
    defer delete(attrs)
    cases := []struct{s: string, want: bool}{
        {"[data-x='abc DEF-z' i]", true}, {"[data-x='abc' i]", false},
        {"[data-x^='aB' i]", true}, {"[data-x$='f-z' i]", true},
        {"[data-x*='C D' i]", true}, {"[data-x~='DEF-z' i]", true},
        {"[data-x^='ab' s]", false}, {"[data-x^='ab']", false},
        {"[data-u='ä' i]", false}, {"[DATA-X]", true},
    }
    for c in cases {
        sels := parse_selectors(c.s)
        if testing.expect_value(t, len(sels), 1) {
            testing.expectf(t, compound_matches(sels[0].parts[0], "div", nil, "", attrs) == c.want, "%s", c.s)
        }
        for &sel in sels do free_selector(&sel)
        delete(sels)
    }
}
