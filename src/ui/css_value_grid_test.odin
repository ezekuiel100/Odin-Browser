package ui

import "core:testing"
import "core:fmt"
import css "../css"

@(test)
css_grid_value_validation :: proc(t: ^testing.T) {
    Case :: struct { prop, value: string, valid: bool }
    cases := []Case{
        {"grid-template-columns", "[a b] 1fr minmax(10px, 2fr) [end]", true},
        {"grid-template-columns", "repeat(auto-fit, minmax(100px, 1fr))", true},
        {"grid-template-columns", "repeat(3, [a] 1fr 20%)", true},
        {"grid-template-rows", "subgrid [start] [end]", true},
        {"grid-auto-rows", "minmax(10px, auto) 2fr", true},
        {"grid-column", "span 2 foo / -1", true},
        {"grid-area", "header", true}, {"grid-area", "1 / 2 / span 2 / -1", true},
        {"grid-template-areas", `"a a b" "c c b"`, true},
        {"grid-template-areas", `"a..b" "a..b"`, true},
        {"grid-template", `"a a" 1fr "b b" auto / 100px 1fr`, true},
        {"grid-template", "auto / 1fr 2fr", true}, {"grid-auto-flow", "dense column", true},
        {"grid-template-columns", "1fr garbage", false},
        {"grid-template-columns", "repeat(0, 1fr)", false},
        {"grid-template-columns", "repeat(2,repeat(2,1fr))", false},
        {"grid-template-columns", "repeat(auto-fill,1fr)", false},
        {"grid-template-columns", "repeat(auto-fill,100px) 1fr", false},
        {"grid-template-columns", "minmax(1fr,2fr)", false},
        {"grid-template-columns", "minmax(10px,)", false},
        {"grid-template-columns", "[a]", false},
        {"grid-template-columns", "1fr none", false},
        {"grid-template-columns", "-1fr", false}, {"grid-template-columns", "fit-content(auto)", false},
        {"grid-auto-rows", "repeat(2,10px)", false},
        {"grid-column", "span 0", false}, {"grid-column", "span -2", false},
        {"grid-column", "span", false}, {"grid-row", "1 /", false},
        {"grid-row", "auto extra", false}, {"grid-column-start", "0", false},
        {"grid-area", "1/2/3/4/5", false}, {"grid-auto-flow", "row column", false},
        {"grid-template-areas", `"a a" "a b"`, false},
        {"grid-template-areas", `"a a" "b"`, false},
        {"grid-template-areas", `""`, false}, {"grid-template", "1fr /", false},
    }
    for c in cases {
        valid, checked := css_value_valid(c.prop, c.value)
        testing.expectf(t, checked && valid == c.valid, "%s:%s => %v", c.prop, c.value, valid)
        testing.expectf(t, css_supports_decl(c.prop, c.value) == c.valid, "supports %v", c)
        d := css.parse_decls(fmt.tprintf("%s:initial; %s:%s !important", c.prop, c.prop, c.value), context.temp_allocator)
        if !c.valid do testing.expect_value(t, d[c.prop], "initial")
    }
}
