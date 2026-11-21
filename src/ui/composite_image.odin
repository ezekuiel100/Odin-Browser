package ui

import im "../../vendor/imgui"
import sdl2 "vendor:sdl2"

// The surface remains a GPU render target. Rounded overflow is a textured
// convex mesh, just like rounded images, rather than a CPU alpha-mask pass.
composite_image :: proc(dl: ^im.DrawList, tex: ^sdl2.Texture, x, y: f32, w, h: i32, tint: u32,
                        rounded: bool, bx, by, bw, bh: f32, rounding: Image_Rounding) {
    tid := im.TextureID(uintptr(tex))
    if rounded {
        draw_image_rounded(dl, tid, {bx, by}, {bx+bw, by+bh}, x, y, x+f32(w), y+f32(h), tint,
            im.DrawList_GetClipRectMin(dl), im.DrawList_GetClipRectMax(dl), rounding)
    } else {
        im.DrawList_AddImage(dl, tid, {x, y}, {x+f32(w), y+f32(h)}, {0, 0}, {1, 1}, tint)
    }
}
