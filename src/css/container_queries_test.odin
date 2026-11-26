package css

import "core:testing"

@(test)
container_conditions_parse_ranges_logic_and_axes :: proc(t: ^testing.T) {
    q := container_query_parse("Card (100px < width <= 20em) and (not (height < 50px))")
    testing.expect(t, q.valid && q.name == "Card")
    testing.expect(t, .Width in q.axes && .Height in q.axes)
    testing.expect_value(t, q.nodes[q.root].op, Container_Op.And)
    for text in ([]string{"", "Card", "(width > 1px) and garbage", "(width > 1px) or (width < 3px) and (height > 0px)", "(width > 1px"}) {
        invalid := container_query_parse(text)
        testing.expectf(t, !invalid.valid,"accepted malformed query %s",text)
    }
}

@(test)
container_nested_conditions_and_media_are_independent :: proc(t: ^testing.T) {
    rules, keys := parse(`@container Outer (width > 200px){@media (min-width:500px){@container Inner (height > 100px){div{color:red}}}}
        section{@container Outer (width > 200px){color:blue;@container Inner (height > 100px){&{color:green}}}}`)
    defer free_rules(&rules); defer free_keyframes(&keys)
    seen := 0
    for r in rules {
        if len(r.cq_queries) != 2 do continue
        testing.expect_value(t,r.cq_queries[0].name,"Outer")
        testing.expect_value(t,r.cq_queries[1].name,"Inner")
        testing.expect(t,.Width in r.cq_queries[0].axes && .Height in r.cq_queries[1].axes)
        if r.decls["color"] == "red" do testing.expect_value(t,r.media_min,500)
        if r.decls["color"] == "green" do testing.expect(t,r.media_min < 0)
        if r.decls["color"] == "" do continue
        seen += 1
    }
    testing.expect_value(t,seen,2)
}

@(test)
container_conditions_own_all_retained_text :: proc(t: ^testing.T) {
    rules, keys := parse(`@container Card (width > 12em){div{color:red}}`)
    defer free_rules(&rules); defer free_keyframes(&keys)
    free_all(context.temp_allocator)
    trash := make([]u8,65536,context.temp_allocator)
    for &b in trash do b='X'
    testing.expect_value(t,rules[0].cq_queries[0].name,"Card")
    testing.expect_value(t,rules[0].cq_queries[0].nodes[0].value,"12em")
}
