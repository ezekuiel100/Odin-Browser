package css

import "core:testing"

@(test)
specificity_tuple_helpers :: proc(t: ^testing.T) {
    testing.expect(t, specificity_add({1, 12, 3}, {2, 4, 8}) == [3]int{3, 16, 11})
    testing.expect(t, specificity_compare({1, 0, 0}, {0, 11, 0}) > 0)
    testing.expect(t, specificity_compare({0, 1, 0}, {0, 0, 11}) > 0)
    testing.expect(t, specificity_compare({0, 0, 11}, {0, 1, 0}) < 0)
    testing.expect(t, specificity_compare({2, 3, 4}, {2, 3, 4}) == 0)
    testing.expect_value(t, specificity_legacy({2, 3, 4}), 234)
}

@(test)
specificity_tuple_parser :: proc(t: ^testing.T) {
    cases := []struct { selector: string, want: [3]int }{
        {".a.b.c.d.e.f.g.h.i.j.k", {0, 11, 0}},
        {"#x#y", {2, 0, 0}},
        {":is(.a.b.c.d.e.f.g.h.i.j.k, #x)", {1, 0, 0}},
        {"div:has(.a, #b):has(.c)", {1, 1, 1}},
        {".x:where(#a):not(.b, #c)", {1, 1, 0}},
        {"a:hover::before", {0, 1, 2}},
        {"section > .a.b + #x", {1, 2, 1}},
    }
    for c in cases {
        sel, ok := parse_complex(c.selector)
        testing.expect(t, ok, c.selector)
        if !ok do continue
        testing.expect(t, sel.specificity == c.want, c.selector)
        testing.expect_value(t, sel.spec, specificity_legacy(c.want))
        free_selector(&sel)
    }
}
