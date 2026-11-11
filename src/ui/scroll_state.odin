package ui

import dompkg "../dom"

// ── Scroll de elemento sobrevive ao restyle ─────────────────────────────────
// `scroll_x`/`scroll_y` de container rolável são ESTADO da caixa, e o restyle
// (qualquer mutação de DOM pelo JS, um timer que troca um texto, zoom) joga a
// árvore de caixas fora e constrói outra — que nascia com scroll 0. Sintoma: um
// `overflow:auto` voltava ao topo/início sempre que a página mexia em QUALQUER
// coisa; com um relógio na página, a caixa ficava impossível de rolar.
// Mesmo padrão do animation_restore_tree: casa velho↔novo pelo NÓ DOM (os nós
// sobrevivem ao restyle; as caixas não). O valor volta CRU — o layout_box seguinte
// o reclampa ao scroll_max novo (o conteúdo pode ter mudado).
scroll_restore_tree :: proc(root, old: ^Box) {
    if root == nil || old == nil do return
    index := make(map[^dompkg.Node][2]f32, context.temp_allocator)
    scroll_index(old, &index)
    if len(index) == 0 do return
    scroll_apply(root, index)
}

@(private = "file")
scroll_index :: proc(b: ^Box, index: ^map[^dompkg.Node][2]f32) {
    if b == nil do return
    if b.node != nil && b.overflow_scroll && (b.scroll_x != 0 || b.scroll_y != 0) {
        index[b.node] = {b.scroll_x, b.scroll_y}
    }
    for c in b.children do scroll_index(c, index)
    for it in b.inlines do if it.box != nil do scroll_index(it.box, index)
}

@(private = "file")
scroll_apply :: proc(b: ^Box, index: map[^dompkg.Node][2]f32) {
    if b == nil do return
    if b.node != nil && b.overflow_scroll {
        if v, ok := index[b.node]; ok {
            b.scroll_x = v.x
            b.scroll_y = v.y
        }
    }
    for c in b.children do scroll_apply(c, index)
    for it in b.inlines do if it.box != nil do scroll_apply(it.box, index)
}
