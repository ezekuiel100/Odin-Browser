package css

import "core:testing"
import "core:strings"
import "core:fmt"

@(test)
variables_syntax_and_empty_values :: proc(t: ^testing.T) {
    for v in ([]string{"var()", "var(x)", "var(--)", "var(--x y)", "var(--x, var())", "var(--x,;)", "var(--x,!)"}) {
        _, ok := variable_syntax(v)
        testing.expectf(t, !ok, "malformed reference %s", v)
        d := parse_decls(fmt.tprintf("--a:green; --a:%s", v), context.temp_allocator)
        testing.expect_value(t, d["--a"], "green")
    }
    d := parse_decls("--empty:; --other: !important", context.temp_allocator)
    testing.expect_value(t, len(d), 2)
    testing.expect_value(t, d["--empty"], "")
    computed := compute_custom_properties(d)
    value, ok := substitute_vars("var(--empty,wrong)", computed)
    testing.expect(t, ok && value == "")
}

@(test)
variables_tokens_and_fallback_lists :: proc(t: ^testing.T) {
    props := make(map[string]string, context.temp_allocator)
    props["--X"] = "green"; props["--x"] = "red"
    for c in ([][2]string{
        {"VAR(--X)", "green"}, {`v\61 r(--X)`, "green"},
        {`"var(--x)" myvar(--x)`, `"var(--x)" myvar(--x)`},
        {`var(--none, "a)b,c")`, `"a)b,c"`},
        {"var(--none, red, blue)", "red, blue"},
        {"var(--none,)", ""}, {"var(--none, var(--other, green))", "green"},
    }) {
        v, ok := substitute_vars(c[0], props)
        testing.expectf(t, ok && v == c[1], "%s => %s (%v)", c[0], v, ok)
    }
    _, ok := substitute_vars("1px var(--missing)", props)
    testing.expect(t, !ok)
}

@(test)
variables_cycles_include_unused_fallbacks :: proc(t: ^testing.T) {
    raw := parse_decls("--ok:green; --a:var(--ok,var(--b)); --b:var(--a); --c:var(--a,blue)", context.temp_allocator)
    computed := compute_custom_properties(raw)
    testing.expect_value(t, computed["--a"], VARIABLE_INVALID)
    testing.expect_value(t, computed["--b"], VARIABLE_INVALID)
    testing.expect_value(t, computed["--c"], "blue")
}

@(test)
variables_expansion_is_bounded :: proc(t: ^testing.T) {
    raw := make(map[string]string, context.temp_allocator)
    raw["--v0"] = "x"
    for i in 1..<25 do raw[fmt.tprintf("--v%d", i)] = fmt.tprintf("var(--v%d) var(--v%d)", i-1, i-1)
    computed := compute_custom_properties(raw)
    testing.expect_value(t, computed["--v24"], VARIABLE_INVALID)
    value, ok := substitute_vars("var(--v24, green)", computed)
    testing.expect(t, ok && value == "green")
    _, ok = substitute_vars(strings.repeat("x", VARIABLE_MAX_BYTES+1, context.temp_allocator), nil)
    testing.expect(t, !ok)
}
