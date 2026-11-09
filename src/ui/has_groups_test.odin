package ui

import "core:testing"
import "core:strings"
import csspkg "../css"
import dompkg "../dom"

@(private = "file")
has_group_matches :: proc(selector: string, node: ^dompkg.Node) -> bool {
    rules, frames := csspkg.parse(strings.concatenate({selector, "{color:red}"}, context.temp_allocator))
    defer csspkg.free_rules(&rules)
    defer delete(frames)
    if len(rules) != 1 || len(rules[0].selectors) != 1 do return false
    candidates := []int{0}
    decls := collect_decls(node, &rules, candidates, 1280)
    color, matched := decls["color"]
    return matched && color == "red"
}

@(test)
has_list_alternatives_and_chained_groups :: proc(t: ^testing.T) {
    card := dompkg.Node{kind = .Element, tag = "div"}
    image := dompkg.Node{kind = .Element, tag = "img"}
    video := dompkg.Node{kind = .Element, tag = "video"}
    defer delete(card.children)

    // Nenhum argumento corresponde: a lista não pode casar por estar vazia.
    testing.expect(t, !has_group_matches("div:has(img, video)", &card))
    dompkg.kids_append(&card, &image)
    testing.expect(t, has_group_matches("div:has(img, video)", &card))
    testing.expect(t, has_group_matches("div:has(video, img)", &card))
    testing.expect(t, has_group_matches("div:has(> video, > img)", &card))
    testing.expect(t, !has_group_matches("div:has(img):has(video)", &card))
    testing.expect(t, !has_group_matches("div:has(img, video):has(span, a)", &card))

    dompkg.kids_append(&card, &video)
    testing.expect(t, has_group_matches("div:has(img):has(video)", &card))
    testing.expect(t, has_group_matches("div:has(span, img):has(a, video)", &card))
}
