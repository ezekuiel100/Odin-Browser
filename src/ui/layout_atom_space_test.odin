package ui

// Espaço colapsado entre ÁTOMOS inline (inline-block/img). Era um 4px FIXO, seja
// qual fosse o tamanho da fonte: o título do github.com (o SplitText põe cada
// palavra num inline-block separado por " ") saía "Softwarestill" a 40px, em vez
// do espaço de ~10px da fonte. O espaço é texto do PAI → mede-se na fonte do pai.
//
// ⚠️ sem atlas de fontes em `odin test` a fonte vem nil e o espaço cai no
// fallback `fsize*0.28` — por isso as asserções são de ESCALA (o espaço segue o
// font-size do pai), não de pixel exato.

import "core:fmt"
import "core:testing"
import htmlp "../html"
import csspkg "../css"

@(private = "file")
gap_entre_atomos :: proc(t: ^testing.T, fs: int, atomo: string) -> f32 {
    html := fmt.tprintf(`<div id="w" style="width:600px;font-size:%dpx">%s %s</div>`, fs, atomo, atomo)
    dom := htmlp.parse(html)
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(dom, &rules, 800, 600)
    root := build_layout(dom, styles, "")
    layout_box(root, 0, 0, 800)
    w := find_box_by_id(root, "w")
    if w == nil || len(w.inlines) != 2 {
        testing.expectf(t, false, "esperados 2 átomos na linha (fs=%d)", fs)
        return -1
    }
    return w.inlines[1].x - (w.inlines[0].x + w.inlines[0].w)
}

@(private = "file")
find_box_by_id :: proc(b: ^Box, want: string) -> ^Box {
    if b == nil do return nil
    if b.node != nil && b.node.attrs != nil {
        if v, ok := b.node.attrs["id"]; ok && v == want do return b
    }
    for c in b.children {
        if r := find_box_by_id(c, want); r != nil do return r
    }
    return nil
}

@(test)
test_espaco_entre_inline_blocks_segue_a_fonte_do_pai :: proc(t: ^testing.T) {
    atomo := `<span style="display:inline-block;width:50px;height:10px"></span>`
    g20 := gap_entre_atomos(t, 20, atomo)
    g40 := gap_entre_atomos(t, 40, atomo)
    testing.expectf(t, g40 > 8, "a 40px o espaço entre inline-blocks devia ter ~10px, tem %.2f", g40)
    testing.expectf(t, abs(g40 - 2 * g20) < 0.01, "o espaço devia dobrar com a fonte: 20px→%.2f, 40px→%.2f", g20, g40)
    // o truque clássico p/ tirar o vão entre inline-blocks: font-size:0 no pai
    g0 := gap_entre_atomos(t, 0, atomo)
    testing.expectf(t, g0 == 0, "pai com font-size:0 não deixa vão, deixou %.2f", g0)
}

@(test)
test_espaco_entre_imagens_segue_a_fonte_do_pai :: proc(t: ^testing.T) {
    atomo := `<img width="50" height="10">`
    g20 := gap_entre_atomos(t, 20, atomo)
    g40 := gap_entre_atomos(t, 40, atomo)
    testing.expectf(t, g40 > 8, "a 40px o espaço entre imagens devia ter ~10px, tem %.2f", g40)
    testing.expectf(t, abs(g40 - 2 * g20) < 0.01, "o espaço devia dobrar com a fonte: 20px→%.2f, 40px→%.2f", g20, g40)
}
