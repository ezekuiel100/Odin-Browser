package ui

// Testes de gravação: sem renderer/SDL, com SVG já entregue no cache.
import "core:testing"
import sdl2 "vendor:sdl2"
import htmlp "../html"
import dompkg "../dom"

@(private="file")
bg_svg_test_cache :: proc() -> (map[string]^Img, ^dompkg.Node, ^Img) {
    dom := htmlp.parse(`<svg width="8" height="4" viewBox="0 0 8 4"><path fill="#12ab34" d="M0 0H8V4H0Z"/></svg>`)
    img := new(Img)
    img^ = Img{state = .Ready, is_svg = true, w = 8, h = 4, svg_root = dompkg.find_first(dom, "svg")}
    cache := make(map[string]^Img)
    cache["bg-test.svg"] = img
    return cache, dom, img
}

@(test)
test_bg_svg_records_vector_and_opacity :: proc(t: ^testing.T) {
    previous := g_images
    cache, dom, img := bg_svg_test_cache()
    g_images = cache
    defer { g_images = previous; delete(cache); free(img); dompkg.free_tree(dom) }
    b := Box{bg_img = "bg-test.svg", bg_pos_x = 0.5, bg_pos_y = 0.5}
    pt: Painter
    defer delete(pt.cmds)
    emit_bg_image(&pt, {10, 20}, {50, 40}, {10, 20}, {50, 40}, &b, 0.5)
    if !testing.expect(t, len(pt.cmds) >= 3, "SVG deve emitir geometria, nao sumir por falta de textura") do return
    if c, ok := pt.cmds[0].(PC_PushClip); ok {
        testing.expect(t, c.min.x == 26 && c.min.y == 28 && c.max.x == 34 && c.max.y == 32, "auto centrado nas dimensoes intrinsecas")
    } else { testing.expect(t, false, "clip abre o tile") }
    geometry := false
    for cmd in pt.cmds {
        #partial switch v in cmd {
        case PC_BgImage: testing.expect(t, false, "SVG nao pode ir ao painter de textura")
        case PC_RectFilled:
            geometry = true
            testing.expect(t, (v.col >> 24) >= 127 && (v.col >> 24) <= 128, "opacidade chega ao preenchimento")
        case PC_Polyline:
            geometry = true
            testing.expect(t, (v.col >> 24) >= 127 && (v.col >> 24) <= 128, "opacidade chega aos vertices")
        case:
        }
    }
    testing.expect(t, geometry, "path do SVG foi expandido na tape")
    _, closed := pt.cmds[len(pt.cmds)-1].(PC_PopClip)
    testing.expect(t, closed, "clip fecha sem vazar para a proxima camada")
}

@(test)
test_bg_svg_repeat_clips_each_tile :: proc(t: ^testing.T) {
    previous := g_images
    cache, dom, img := bg_svg_test_cache()
    g_images = cache
    defer { g_images = previous; delete(cache); free(img); dompkg.free_tree(dom) }
    b := Box{bg_img = "bg-test.svg", bg_repeat = true}
    pt: Painter
    defer delete(pt.cmds)
    // Origin deslocada em relacao ao clip, como fundo propagado ao canvas.
    emit_bg_image(&pt, {4, 2}, {20, 10}, {0, 0}, {20, 10}, &b)
    clips, pops := 0, 0
    for cmd in pt.cmds {
        #partial switch v in cmd {
        case PC_PushClip:
            clips += 1
            testing.expect(t, v.min.x >= 0 && v.min.y >= 0 && v.max.x <= 20 && v.max.y <= 10, "tile intersectado com background-clip")
            testing.expect(t, v.max.x-v.min.x <= 8 && v.max.y-v.min.y <= 4, "nenhum tile invade seu vizinho")
        case PC_PopClip: pops += 1
        case PC_BgImage: testing.expect(t, false, "repeat SVG continua vetorial")
        case:
        }
    }
    testing.expect_value(t, clips, 9)
    testing.expect_value(t, pops, clips)
}

@(test)
test_bg_svg_cover_contain_and_extra_layer :: proc(t: ^testing.T) {
    previous := g_images
    cache, dom, img := bg_svg_test_cache()
    g_images = cache
    defer { g_images = previous; delete(cache); free(img); dompkg.free_tree(dom) }
    b := Box{bg_img = "bg-test.svg", bg_size = .Contain, bg_pos_x = 0.5, bg_pos_y = 0.5}
    pt: Painter
    defer delete(pt.cmds)
    emit_bg_image(&pt, {0, 0}, {40, 40}, {0, 0}, {40, 40}, &b)
    if !testing.expect(t, len(pt.cmds) > 0, "contain gera comandos") do return
    if c, ok := pt.cmds[0].(PC_PushClip); ok {
        testing.expect(t, c.min.x == 0 && c.min.y == 10 && c.max.x == 40 && c.max.y == 30, "contain preserva proporcao")
    }
    clear(&pt.cmds)
    b.bg_size = .Cover
    emit_bg_image(&pt, {0, 0}, {40, 40}, {0, 0}, {40, 40}, &b)
    if c, ok := pt.cmds[0].(PC_PushClip); ok {
        testing.expect(t, c.min.x == 0 && c.min.y == 0 && c.max.x == 40 && c.max.y == 40, "cover recortado a caixa")
    }
    clear(&pt.cmds)
    extra := [1]Bg_Layer{{img = "bg-test.svg", size = .Contain, pos_x = 0.5, pos_y = 0.5}}
    b.bg_extra = extra[:]
    b.bg_img = ""
    emit_bg_image(&pt, {0, 0}, {40, 40}, {0, 0}, {40, 40}, &b, 1, 0)
    testing.expect(t, len(pt.cmds) > 0, "camada extra tambem expande SVG")
    clear(&pt.cmds)
    img.state = .Loading
    emit_bg_image(&pt, {0, 0}, {40, 40}, {0, 0}, {40, 40}, &b, 1, 0)
    testing.expect_value(t, len(pt.cmds), 0)
}

@(test)
test_bg_raster_keeps_existing_command :: proc(t: ^testing.T) {
    previous := g_images
    cache := make(map[string]^Img)
    img := Img{state = .Ready, w = 8, h = 8, tex = cast(^sdl2.Texture)uintptr(0xF00D)}
    cache["raster.png"] = &img
    g_images = cache
    defer { g_images = previous; delete(cache) }
    b := Box{bg_img = "raster.png"}
    pt: Painter
    defer delete(pt.cmds)
    emit_bg_image(&pt, {0, 0}, {20, 20}, {0, 0}, {20, 20}, &b)
    if !testing.expect_value(t, len(pt.cmds), 1) do return
    _, ok := pt.cmds[0].(PC_BgImage)
    testing.expect(t, ok, "raster preserva PC_BgImage")
}
