package ui

import "core:testing"
import im "../../vendor/imgui"

@(test)
backdrop_transform_preserves_parent_draw_list :: proc(t: ^testing.T) {
    // A backdrop reads the accumulated draw list, which must still draw in its
    // original coordinates after the filtered region has been composited.
    verts := [2]im.DrawVert{{pos={100,80}, uv={0.25,0.75}}, {pos={120,100}}}
    cmds := [1]im.DrawCmd{{ClipRect={80,60,160,140}}}
    source := im.DrawList{}
    source.VtxBuffer.Data = &verts[0]; source.VtxBuffer.Size = 2
    source.CmdBuffer.Data = &cmds[0]; source.CmdBuffer.Size = 1
    transformed := backdrop_draw_list(&source, 80, 60, 2)
    testing.expect_value(t, verts[0].pos, im.Vec2{100,80})
    testing.expect_value(t, cmds[0].ClipRect, im.Vec4{80,60,160,140})
    testing.expect_value(t, transformed.VtxBuffer.Data.pos, im.Vec2{10,10})
    testing.expect_value(t, transformed.VtxBuffer.Data.uv, verts[0].uv)
    testing.expect_value(t, transformed.CmdBuffer.Data.ClipRect, im.Vec4{0,0,40,40})
}

@(test)
backdrop_sampling_retains_sharp_effects :: proc(t: ^testing.T) {
    for filters in ([][2]Filter_Op{
        {{kind=.Blur, amount=16}, {kind=.DropShadow, amount=8}},
        {{kind=.Blur, amount=0}, {kind=.Contrast, amount=2}},
    }) {
        fs := filters
        _, scale := backdrop_sampling(fs[:])
        testing.expect(t, scale == 1, "sharp input operations cannot be evaluated at reduced resolution")
    }
}

@(test)
backdrop_reduction_preserves_premultiplied_coverage :: proc(t: ^testing.T) {
    // Transparent blue must not tint the opaque red samples when minifying.
    pixels := [16]u8{255,0,0,255, 0,0,255,0, 255,0,0,255, 0,0,255,0}
    reduced := backdrop_reduce(pixels[:], 2, 2, 2)
    testing.expect_value(t, reduced[0], u8(255))
    testing.expect_value(t, reduced[2], u8(0))
    testing.expect_value(t, reduced[3], u8(127))
}
