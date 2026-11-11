package ui

import "core:testing"
import htmlp "../html"
import dompkg "../dom"

@(test)
svg_mask_style_and_shorthand :: proc(t: ^testing.T) {
    c := test_apply(`-webkit-mask:var(--icon); -webkit-mask-size:contain; -webkit-mask-repeat:no-repeat`, `--icon:url(data:image/svg+xml,%3Csvg%2F%3E)`)
    testing.expect_value(t, c.mask_image.url, "data:image/svg+xml,%3Csvg%2F%3E")
    testing.expect(t, c.mask_image.size == .Contain && c.mask_image.no_repeat == [2]bool{true,true})
    s := test_apply(`mask:url(icon.svg) center / 50% auto no-repeat luminance content-box border-box`)
    testing.expect_value(t, s.mask_image.url, "icon.svg")
    testing.expect(t, s.mask_image.position == [2]f32{0.5,0.5})
    testing.expect(t, s.mask_image.dimension_set[0] && s.mask_image.dimension_pct[0])
    testing.expect_value(t, s.mask_image.dimensions[0], f32(0.5))
    testing.expect(t, s.mask_image.luminance && s.mask_image.origin == .Content && s.mask_image.clip == .Border)
    n := test_apply(`mask:url(icon.svg);mask-image:none`)
    testing.expect_value(t, n.mask_image.url, "")
    g := test_apply(`mask:url(icon.svg);mask-image:linear-gradient(black,transparent)`)
    testing.expect(t, g.mask_grad.active && g.mask_image.url == "")
    tight := test_apply(`mask:URL("data:image/svg+xml,<svg transform='rotate(20)'/>") center/contain no-repeat`)
    testing.expect_value(t, tight.mask_image.url, "data:image/svg+xml,<svg transform='rotate(20)'/>")
    testing.expect_value(t, tight.mask_image.size, Bg_Size.Contain)
}

@(test)
svg_mask_cascade_shorthand_resets_size :: proc(t: ^testing.T) {
    a := test_compute_one(`div{mask-size:contain}.x{mask:url(icon.svg)}`, "div", "x")
    testing.expect_value(t, a.mask_image.size, Bg_Size.Auto)
    b := test_compute_one(`.x{mask-size:contain}div{mask:url(icon.svg)}`, "div", "x")
    testing.expect_value(t, b.mask_image.size, Bg_Size.Contain)
    p := test_compute_one(`div{mask-image:none}.x{-webkit-mask-image:url(icon.svg)}`, "div", "x")
    testing.expect_value(t, p.mask_image.url, "icon.svg")
    q := test_compute_one(`.x{mask:none}div{-webkit-mask-image:url(icon.svg)}`, "div", "x")
    testing.expect_value(t, q.mask_image.url, "")
}

@(test)
svg_mask_alpha_and_luminance_preserve_host_color :: proc(t: ^testing.T) {
    src := [12]u8{20,80,160,255, 20,80,160,128, 20,80,160,255}
    mask := [12]u8{0,0,0,255, 128,128,128,128, 0,0,0,0}
    alpha, lum := src, src
    apply_image_mask_pixels(alpha[:], mask[:], false)
    apply_image_mask_pixels(lum[:], mask[:], true)
    testing.expect_value(t, alpha, [12]u8{20,80,160,255, 20,80,160,64, 20,80,160,0})
    testing.expect_value(t, lum, [12]u8{20,80,160,0, 20,80,160,64, 20,80,160,0})
}

@(test)
svg_mask_size_position_and_box_ownership :: proc(t: ^testing.T) {
    c := test_apply(`mask:url(../icons/a.svg) right bottom / contain no-repeat; border:2px solid black; padding:4px; mask-origin:content-box`)
    dom := htmlp.parse(`<div></div>`)
    defer dompkg.free_tree(dom)
    node := dompkg.find_first(dom, "div")
    styles := make(map[^dompkg.Node]Computed)
    defer delete(styles)
    styles[node] = c
    b := build_layout(node, styles, "https://example.test/pages/home.html")
    defer free_layout(b)
    testing.expect_value(t, b.mask_image.url, "https://example.test/icons/a.svg")
    testing.expect(t, raw_data(b.mask_image.url) != raw_data(c.mask_image.url))
    m := mask_for_box(b)
    testing.expect_value(t, m.inset, [4]f32{6,6,6,6})
    x,y,w,h := mask_tile_geometry(m, 20,10, 10,20, 100,100)
    testing.expect(t, x == 16 && y == 70 && w == 88 && h == 44)
    b.preserve_3d = true
    testing.expect(t, creates_stacking_context(b))
    testing.expect(t, !x_preserves(b), "mask flattens the transformed group")
}

@(test)
svg_mask_resource_delivery_invalidates_layer_cache :: proc(t: ^testing.T) {
    prev := g_images
    g_images = make(map[string]^Img)
    defer { images_free_all(); delete(g_images); g_images = prev }
    m := Mask_Image{url="data:image/svg+xml,%3Csvg%2F%3E"}
    loading := mask_image_hash(m)
    img := g_images[m.url]
    img.state = .Ready; img.w = 24; img.h = 24
    ready := mask_image_hash(m)
    testing.expect(t, loading != ready)
    m.size = .Contain
    testing.expect(t, mask_image_hash(m) != ready)
}

@(test)
svg_mask_emits_clipped_vector_tiles :: proc(t: ^testing.T) {
    dom := htmlp.parse(`<svg width="8" height="4" viewBox="0 0 8 4"><path d="M0 0H8V4H0Z"/></svg>`)
    defer dompkg.free_tree(dom)
    img := Img{state=.Ready, is_svg=true, w=8, h=4, svg_root=dompkg.find_first(dom,"svg")}
    pt: Painter
    defer delete(pt.cmds)
    m := Mask_Image{size=.Contain, position={0.5,0.5}, no_repeat={true,true}}
    emit_mask_image(&pt, m, &img, 0,0,40,40)
    if !testing.expect(t, len(pt.cmds) >= 3) do return
    clip, ok := pt.cmds[0].(PC_PushClip)
    testing.expect(t, ok && clip.min.x == 0 && clip.min.y == 10 && clip.max.x == 40 && clip.max.y == 30)
    clear(&pt.cmds)
    m = {}
    emit_mask_image(&pt, m, &img, 0,0,16,8)
    tiles := 0
    for cmd in pt.cmds { if _, ok := cmd.(PC_PushClip); ok do tiles += 1 }
    testing.expect_value(t, tiles, 4)
}
