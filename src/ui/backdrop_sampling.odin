package ui

import im "../../vendor/imgui"

// Keep at least four samples per sigma. Small blurs and non-blur effects keep
// full resolution. Point filters before the first blur are evaluated at native
// resolution before reduction, preserving CSS filter order and clipping.
backdrop_sampling :: proc(filters: []Filter_Op) -> (pad, scale: f32) {
    scale = 1
    min_sigma: f32 = 1e9
    for f in filters {
        if f.kind == .Blur {
            pad += min(f.amount, 100)*3
            min_sigma = min(min_sigma, f.amount)
        } else if f.kind == .DropShadow {
            pad += f.amount*1.5 + max(abs(f.dx),abs(f.dy))
        }
    }
    if min_sigma >= 8 && min_sigma < 1e9 {
        scale = min_sigma >= 16 ? 4 : 2
        for f in filters do if f.kind == .DropShadow { scale = 1; break }
    }
    return
}

// Exact area average of 2x2/4x4 blocks in premultiplied alpha. In particular,
// brightness/saturate before blur must clamp BEFORE averaging these samples.
backdrop_reduce :: proc(src: []u8, w, h, scale: int) -> []u8 {
    nw, nh := w/scale, h/scale
    dst := make([]u8, nw*nh*4, context.temp_allocator)
    for y in 0..<nh do for x in 0..<nw {
        r, g, b, a: int
        for yy in 0..<scale do for xx in 0..<scale {
            i := ((y*scale+yy)*w+x*scale+xx)*4
            al := int(src[i+3])
            r += int(src[i])*al; g += int(src[i+1])*al; b += int(src[i+2])*al; a += al
        }
        i := (y*nw+x)*4
        if a > 0 { dst[i]=u8(r/a); dst[i+1]=u8(g/a); dst[i+2]=u8(b/a) }
        dst[i+3] = u8(a/(scale*scale))
    }
    return dst
}

// Borrow indices, clone only the positions and clips we transform. The parent
// draw list must remain unchanged: it is still submitted at the end of frame.
backdrop_draw_list :: proc(src: ^im.DrawList, x, y, scale: f32) -> im.DrawList {
    dst := src^
    verts := make([]im.DrawVert, int(src.VtxBuffer.Size), context.temp_allocator)
    copy(verts, ([^]im.DrawVert)(src.VtxBuffer.Data)[:src.VtxBuffer.Size])
    for &v in verts { v.pos.x = (v.pos.x-x)/scale; v.pos.y = (v.pos.y-y)/scale }
    dst.VtxBuffer.Data = raw_data(verts)
    cmds := make([]im.DrawCmd, int(src.CmdBuffer.Size), context.temp_allocator)
    copy(cmds, ([^]im.DrawCmd)(src.CmdBuffer.Data)[:src.CmdBuffer.Size])
    for &c in cmds {
        c.ClipRect.x = (c.ClipRect.x-x)/scale; c.ClipRect.z = (c.ClipRect.z-x)/scale
        c.ClipRect.y = (c.ClipRect.y-y)/scale; c.ClipRect.w = (c.ClipRect.w-y)/scale
    }
    dst.CmdBuffer.Data = raw_data(cmds)
    return dst
}
