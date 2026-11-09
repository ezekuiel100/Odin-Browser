package ui
import "core:testing"
import htmlp "../html"
import csspkg "../css"
import dompkg "../dom"

@(test)
stacking_auto_and_zero :: proc(t: ^testing.T) {
    root := htmlp.parse(`<style>#a{position:relative;z-index:auto}#z{position:relative;z-index:0}#s{z-index:3}#p{z-index:5}#p>div{z-index:inherit}</style><div id="a"></div><div id="z"></div><div id="s"></div><div id="p"><div id="i"></div></div>`)
    defer dompkg.free_tree(root)
    rules, _ := csspkg.parse("#a{position:relative;z-index:auto}#z{position:relative;z-index:0}#s{z-index:3}#p{z-index:5}#p>div{z-index:inherit}")
    defer csspkg.free_rules(&rules)
    styles, _ := compute_styles(root, &rules, 400, 400)
    defer free_styles(styles)
    js_style_source_set(styles, nil, 400, 400)
    defer js_style_source_free()
    for id in ([?]string{"a", "z", "s", "i"}) {
        node := stacking_test_id(root, id)
        c := styles[node]
        b := Box{opacity = 1}
        b.pos = c.position; b.z_index = c.z_index; b.z_index_set = c.z_index_set
        switch id {
        case "a":
            testing.expect(t, !c.z_index_set && !creates_stacking_context(&b))
            testing.expect_value(t, js_computed_style(node, "z-index"), "auto")
        case "z":
            testing.expect(t, c.z_index_set && c.z_index == 0 && creates_stacking_context(&b))
            testing.expect_value(t, js_computed_style(node, "z-index"), "0")
        case "s": testing.expect(t, c.z_index_set && !creates_stacking_context(&b), "static z-index alone is inert")
        case "i": testing.expect(t, c.z_index_set && c.z_index == 5, "explicit inherit retains integer type")
        }
    }
}

@(test)
stacking_context_triggers :: proc(t: ^testing.T) {
    b := Box{opacity = 1}
    testing.expect(t, !creates_stacking_context(&b))
    b.z_index_set = true; b.stacking_item = true
    testing.expect(t, creates_stacking_context(&b), "static flex/grid item with integer z-index")
    b = Box{opacity = 0.999}
    testing.expect(t, creates_stacking_context(&b), "all opacity below one isolates")
    b = Box{opacity = 1, isolate = true}
    testing.expect(t, creates_stacking_context(&b), "absolute hoisting cannot cross isolation")
    b = Box{opacity = 1, pos = .Sticky}
    testing.expect(t, creates_stacking_context(&b), "sticky auto isolates")
    b = Box{opacity = 1, pos = .Fixed}
    testing.expect(t, creates_stacking_context(&b), "fixed auto isolates")
    b = Box{opacity = 1, n_backdrop = 1}
    testing.expect(t, creates_stacking_context(&b))
}

@(test)
stacking_collect_ancestor_scope :: proc(t: ^testing.T) {
    root := Box{opacity = 1}
    parent := Box{opacity = 1, pos = .Relative, rel_dx = 12, rel_dy = 7}
    high := Box{opacity = 1, pos = .Relative, z_index_set = true, z_index = 10}
    low := Box{opacity = 1, pos = .Relative, z_index_set = true, z_index = 1}
    append(&root.children, &parent, &low); defer delete(root.children)
    append(&parent.children, &high); defer delete(parent.children)
    scope := Stacking_Scope{deferred = make(map[^Box]bool)}
    defer { delete(scope.deferred); delete(scope.entries); delete(scope.clips) }
    collect_stacking(&scope, &root, 0, 0, -1)
    sort_stacking(scope.entries[:])
    testing.expect_value(t, len(scope.entries), 3)
    testing.expect(t, scope.entries[2].box == &high && scope.entries[2].ox == 12 && scope.entries[2].oy == 7, "relative offsets survive promotion to ancestor context")
    clear(&scope.deferred); clear(&scope.entries); clear(&scope.clips)
    parent.z_index_set = true
    collect_stacking(&scope, &root, 0, 0, -1)
    testing.expect_value(t, len(scope.entries), 2)
    testing.expect(t, &high not_in scope.deferred, "explicit zero owns descendant context")
}

@(private="file")
stacking_test_id :: proc(n: ^dompkg.Node, id: string) -> ^dompkg.Node {
    if value, ok := n.attrs["id"]; ok && value == id do return n
    for child in n.children {
        if result := stacking_test_id(child, id); result != nil do return result
    }
    return nil
}

@(test)
stacking_inline_absolute_origin :: proc(t: ^testing.T) {
    root := Box{opacity = 1, content_x = 20, content_y = 30, is_inline = true}
    atom := Box{opacity = 1, pos = .Relative}
    high := Box{opacity = 1, pos = .Absolute, z_index_set = true, z_index = 2}
    append(&atom.children, &high); defer delete(atom.children)
    append(&root.inlines, Inline_Item{kind = .InlineBox, box = &atom, x = 7, y = 9})
    defer delete(root.inlines)
    scope := Stacking_Scope{deferred = make(map[^Box]bool)}
    defer { delete(scope.deferred); delete(scope.entries); delete(scope.clips) }
    collect_stacking(&scope, &root, 0, 0, -1)
    testing.expect_value(t, len(scope.entries), 2)
    entry := scope.entries[1]
    testing.expect(t, entry.box == &high && entry.ox == 27 && entry.oy == 39)
    testing.expect(t, entry.origin.x == 27 && entry.origin.y == 39, "absolute boxes inside inline atoms use the atom coordinate origin")
}
