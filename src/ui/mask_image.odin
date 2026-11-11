package ui

// One positioned image mask. Computed borrows its URL from CSS; Box owns the
// resolved URL. The paint command borrows the Box value until tape replay.
Mask_Image :: struct {
    url: string,
    size: Bg_Size,
    dimensions: [2]f32,
    dimension_set, dimension_pct: [2]bool,
    position, position_px: [2]f32,
    no_repeat: [2]bool,
    luminance: bool,
    origin, clip: Bg_Clip,
    no_clip: bool,
    inset, clip_inset: [4]f32,
}

mask_for_box :: proc(b: ^Box) -> Mask_Image {
    m := b.mask_image
    m.inset = {}; m.clip_inset = {}
    for i in 0..<4 {
        if m.origin != .Border do m.inset[i] = b.border_w[i]
        if m.origin == .Content do m.inset[i] += b.padding[i]
        if m.clip != .Border do m.clip_inset[i] = b.border_w[i]
        if m.clip == .Content do m.clip_inset[i] += b.padding[i]
    }
    return m
}

mask_tile_geometry :: proc(m: Mask_Image, iw, ih, bx, by, bw, bh: f32) -> (x, y, w, h: f32) {
    ow := max(0, bw-m.inset[1]-m.inset[3]); oh := max(0, bh-m.inset[0]-m.inset[2])
    w, h = iw, ih
    if iw <= 0 || ih <= 0 do return
    switch m.size {
    case .Contain: s := min(ow/iw, oh/ih); w, h = iw*s, ih*s
    case .Cover: s := max(ow/iw, oh/ih); w, h = iw*s, ih*s
    case .Auto:
        if m.dimension_set[0] do w = m.dimension_pct[0] ? m.dimensions[0]*ow : m.dimensions[0]
        if m.dimension_set[1] do h = m.dimension_pct[1] ? m.dimensions[1]*oh : m.dimensions[1]
        if m.dimension_set[0] && !m.dimension_set[1] do h = w*ih/iw
        if m.dimension_set[1] && !m.dimension_set[0] do w = h*iw/ih
    }
    x = bx + m.inset[3] + (ow-w)*m.position[0] + m.position_px[0]
    y = by + m.inset[0] + (oh-h)*m.position[1] + m.position_px[1]
    return
}

// A failed or pending image is transparent black, never an unmasked square.
// The resource state participates in the layer hash so delivery invalidates it.
mask_image_hash :: proc(m: Mask_Image) -> u32 {
    h: u32 = 2166136261
    add :: proc(h: ^u32, v: u32) { h^ = (h^ ~ v)*16777619 }
    for b in transmute([]u8)m.url do add(&h, u32(b))
    add(&h, u32(m.size)); add(&h, m.luminance ? 1 : 0); add(&h, m.no_clip ? 1 : 0)
    for i in 0..<2 {
        add(&h, transmute(u32)m.dimensions[i]); add(&h, m.dimension_set[i] ? 1 : 0)
        add(&h, m.dimension_pct[i] ? 1 : 0); add(&h, m.no_repeat[i] ? 1 : 0)
        add(&h, transmute(u32)m.position[i]); add(&h, transmute(u32)m.position_px[i])
    }
    for i in 0..<4 { add(&h, transmute(u32)m.inset[i]); add(&h, transmute(u32)m.clip_inset[i]) }
    if m.url != "" {
        img := image_get(m.url)
        add(&h, u32(img.state)); add(&h, u32(img.w)); add(&h, u32(img.h))
    }
    return h
}

// Mask RGB is irrelevant in alpha mode; luminance uses premultiplied RGB,
// which already includes source alpha. The element keeps its own RGB.
apply_image_mask_pixels :: proc(dst, mask: []u8, luminance: bool) {
    for i in 0..<min(len(dst), len(mask))/4 {
        j := i*4
        a := f32(mask[j+3])
        if luminance do a = 0.2126*f32(mask[j]) + 0.7152*f32(mask[j+1]) + 0.0722*f32(mask[j+2])
        dst[j+3] = u8(clamp(f32(dst[j+3])*a/255+0.5, 0, 255))
    }
}
