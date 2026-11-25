package css

import "core:testing"
import "core:strings"

@(test)
declaration_order_keeps_winning_valid_positions :: proc(t: ^testing.T) {
    order: []Decl_Position
    decls := parse_decls(`padding-left:1px; padding:2px; padding-left:3px;
        color:red !important; color:blue;
        background:red; background:linear-gradient(bogus)`, context.allocator, &order)
    defer {
        delete(order)
        for k, v in decls { delete(k); delete(v) }
        delete(decls)
    }
    testing.expect_value(t, len(order), 4)
    if len(order) != 4 do return
    indices := []int{1, 2, 3, 5}
    for name, i in ([]string{"padding", "padding-left", "color", "background"}) {
        testing.expect_value(t, order[i].name, name)
        testing.expect_value(t, order[i].index, indices[i])
    }
    testing.expect_value(t, decls["padding-left"], "3px")
    testing.expect_value(t, decls["color"], "red !important")
    testing.expect_value(t, decls["background"], "red")
}

@(test)
declaration_order_nesting_emits_source_sequence :: proc(t: ^testing.T) {
    source := strings.clone(`.x { color:red; & { color:blue } color:green;
        @media (min-width:600px) { color:yellow; & { color:black } color:white }
        color:purple }`)
    rules, keys := parse(source)
    delete(source)
    defer free_rules(&rules)
    defer free_keyframes(&keys)
    expected := []string{"red", "blue", "green", "yellow", "black", "white", "purple"}
    testing.expect_value(t, len(rules), len(expected))
    if len(rules) != len(expected) do return
    for r, i in rules {
        testing.expect_value(t, r.order, i)
        testing.expect_value(t, r.decls["color"], expected[i])
        testing.expect_value(t, len(r.decl_order), 1)
        if len(r.decl_order) == 1 do testing.expect_value(t, r.decl_order[0].name, "color")
        testing.expect_value(t, r.media_min, i >= 3 && i <= 5 ? 600 : -1)
    }
}

@(test)
declaration_order_nesting_keeps_layer_and_conditions :: proc(t: ^testing.T) {
    rules, keys := parse(`@layer base {
        .x { margin:1px; @supports (display:grid) { margin:2px } margin-left:3px }
    }
    @layer later { .x { margin:4px } }`)
    defer free_rules(&rules)
    defer free_keyframes(&keys)
    testing.expect_value(t, len(rules), 4)
    if len(rules) != 4 do return
    testing.expect_value(t, rules[0].layer_rank, rules[2].layer_rank)
    testing.expect(t, rules[3].layer_rank > rules[2].layer_rank)
    for r, i in rules do testing.expect_value(t, r.order, i)
}

@(test)
declaration_order_nesting_keeps_tokens_and_dynamic_states :: proc(t: ^testing.T) {
    rules, keys := parse(`.x { [data-label="a&b"] { color:red } .foo\& { color:blue } }`)
    defer free_rules(&rules)
    defer free_keyframes(&keys)
    testing.expect_value(t, len(rules), 3)
    if len(rules) != 3 do return
    red := rules[1].selectors[0].parts
    blue := rules[2].selectors[0].parts
    testing.expect_value(t, len(red), 2)
    testing.expect_value(t, len(blue), 2)
    if len(red) == 2 && len(red[1].attrs) == 1 do testing.expect_value(t, red[1].attrs[0].val, "a&b")
    if len(blue) == 2 && len(blue[1].classes) == 1 do testing.expect_value(t, blue[1].classes[0], "foo&")

    dynamic_rules, dynamic_keys := parse(`.x:hover, .y:hover { & { color:red } }`)
    defer free_rules(&dynamic_rules)
    defer free_keyframes(&dynamic_keys)
    testing.expect_value(t, len(dynamic_rules), 2)
    if len(dynamic_rules) != 2 do return
    testing.expect_value(t, len(dynamic_rules[1].selectors), 2)
    for s in dynamic_rules[1].selectors do testing.expect(t, s.parts[len(s.parts)-1].state == .Hover)
}
