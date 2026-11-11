package ui

import "core:c"
import "core:math"
import "core:strings"
import win "core:sys/windows"
import im "../../vendor/imgui"
import sdl "vendor:sdl2"
import tt "vendor:stb/truetype"

foreign import textgdi "system:gdi32.lib"
@(default_calling_convention="system")
foreign textgdi {
    GdiFlush :: proc() -> i32 ---
    RemoveFontMemResourceEx :: proc(handle:win.HANDLE) -> i32 ---
}

foreign import usp "system:usp10.lib"
foreign import icubidi "system:icu.lib"
@(default_calling_convention="system")
foreign usp {
    ScriptStringAnalyse :: proc(dc: win.HDC, text: rawptr, count, glyphs, charset: i32, flags: u32, width: i32, control, state, dx, tabs, classes: rawptr, result: ^rawptr) -> i32 ---
    ScriptString_pSize :: proc(analysis: rawptr) -> ^win.SIZE ---
    ScriptStringOut :: proc(analysis: rawptr, x,y: i32, options: u32, rect: rawptr, min_sel,max_sel: i32, disabled: i32) -> i32 ---
    ScriptStringFree :: proc(analysis: ^rawptr) -> i32 ---
}
foreign icubidi {
    u_getIntPropertyValue :: proc "c" (codepoint:i32,property:i32) -> i32 ---
    ubidi_open :: proc "c" () -> rawptr ---
    ubidi_close :: proc "c" (bidi: rawptr) ---
    ubidi_setPara :: proc "c" (bidi: rawptr, text: ^u16, length: i32, level: u8, embedding: ^u8, error: ^i32) ---
    ubidi_getLevelAt :: proc "c" (bidi: rawptr, index: i32) -> u8 ---
    ubidi_reorderVisual :: proc "c" (levels: ^u8, length: i32, indices: ^i32) ---
}

Native_Text :: struct {
    font: ^im.Font,
    size: f32,
    text: string,
    advance: f32,
    w,h: int,
    pixels: []u32,
    texture: ^sdl.Texture,
    frame: int,
}
g_shaped_text: [dynamic]Native_Text
Shaped_Font :: struct { data:rawptr, handle:win.HANDLE }
g_shaped_fonts: [dynamic]Shaped_Font

text_needs_shaping :: proc(text: string) -> bool {
    for r in text {
        if (r >= 0x590 && r <= 0x1cff) || (r >= 0x200c && r <= 0x2069) ||
           (r >= 0x2e80 && r <= 0xd7ff) || (r >= 0xfb1d && r <= 0xfeff) { return true }
    }
    return false
}

shaped_text_clear :: proc() {
    for &entry in g_shaped_text {
        if entry.texture != nil do sdl.DestroyTexture(entry.texture)
        delete(entry.text); delete(entry.pixels)
    }
    delete(g_shaped_text); g_shaped_text = nil
    for f in g_shaped_fonts do RemoveFontMemResourceEx(f.handle)
    delete(g_shaped_fonts); g_shaped_fonts=nil
}

// One analysis supplies BOTH the advance and the raster. GDI/Uniscribe own the
// fallback selection and glyph positioning; the text remains in logical order.
shaped_text :: proc(font: ^im.Font, size: f32, text: string) -> ^Native_Text {
    if font == nil || font.Sources == nil || size <= 0 || size > 512 || len(text) == 0 || len(text)>16384 do return nil
    for &entry in g_shaped_text {
        if entry.font==font && entry.size==size && entry.text==text { entry.frame=g_frame; return &entry }
    }
    if len(g_shaped_text)>=256 {
        victim := -1
        for e,i in g_shaped_text do if e.frame != g_frame && (victim<0 || e.frame<g_shaped_text[victim].frame) do victim=i
        if victim<0 do return nil
        e:= &g_shaped_text[victim]
        if e.texture!=nil do sdl.DestroyTexture(e.texture)
        delete(e.text); delete(e.pixels)
        unordered_remove(&g_shaped_text,victim)
    }
    dc:=win.CreateCompatibleDC(nil)
    if dc==nil do return nil
    defer win.DeleteDC(dc)
    face: [128]u16
    info: tt.fontinfo
    src:=font.Sources
    if src.FontData==nil || !bool(tt.InitFont(&info,cast([^]u8)src.FontData,0)) do return nil
    registered:=false
    for f in g_shaped_fonts do if f.data==src.FontData do registered=true
    if !registered && len(g_shaped_fonts)<128 {
        count:u32
        handle:=win.AddFontMemResourceEx(src.FontData,u32(src.FontDataSize),nil,&count)
        if handle!=nil do append(&g_shaped_fonts,Shaped_Font{src.FontData,handle})
    }
    name_len:c.int
    name:=tt.GetFontNameString(&info,&name_len,.PLATFORM_ID_MICROSOFT,1,0x409,1)
    if name!=nil {
        data:=(cast([^]u8)name)[:int(name_len)]
        for i in 0..<min(len(data)/2,len(face)-1) do face[i]=u16(data[2*i])<<8|u16(data[2*i+1])
    }
    // Negative CreateFont height is the em, whereas size includes ascent/descent.
    ascent,descent,gap:c.int
    tt.GetFontVMetrics(&info,&ascent,&descent,&gap)
    em_size:=size * (1 / tt.ScaleForMappingEmToPixels(&info,1)) / f32(max(1,ascent-descent))
    hf:=win.CreateFontW(-i32(math.round(em_size)),0,0,0,400,0,0,0,1,0,0,4,0,cast(cstring16)&face[0])
    if hf==nil do return nil
    defer win.DeleteObject(win.HGDIOBJ(hf))
    old:=win.SelectObject(dc,win.HGDIOBJ(hf))
    defer win.SelectObject(dc,old)
    text16:=win.utf8_to_utf16(text)
    analysis:rawptr
    if ScriptStringAnalyse(dc,raw_data(text16),i32(len(text16)),i32(len(text16)*2+32),-1,0x80|0x20|0x1000,0,nil,nil,nil,nil,nil,&analysis)<0 do return nil
    defer ScriptStringFree(&analysis)
    extent:=ScriptString_pSize(analysis)
    if extent==nil || extent.cx<0 || extent.cx>8192 || extent.cy<=0 || extent.cy>1024 do return nil
    w,h:=int(extent.cx)+8,int(extent.cy)+8
    if w*h>2*1024*1024 do return nil
    total:=w*h
    for e in g_shaped_text do total+=len(e.pixels)
    if total>4*1024*1024 do return nil
    bi:=win.BITMAPINFO{}
    bi.bmiHeader.biSize=size_of(win.BITMAPINFOHEADER)
    bi.bmiHeader.biWidth=i32(w); bi.bmiHeader.biHeight=-i32(h)
    bi.bmiHeader.biPlanes=1; bi.bmiHeader.biBitCount=32
    bits:rawptr
    bitmap:=win.CreateDIBSection(dc,&bi,0,&bits,nil,0)
    if bitmap==nil || bits==nil do return nil
    defer win.DeleteObject(win.HGDIOBJ(bitmap))
    previous:=win.SelectObject(dc,win.HGDIOBJ(bitmap))
    defer win.SelectObject(dc,previous)
    pixels:=(cast([^]u32)bits)[:w*h]
    for &p in pixels do p=0
    win.SetBkColor(dc,0); win.SetTextColor(dc,0xffffff)
    if ScriptStringOut(analysis,4,4,0,nil,0,0,0)<0 do return nil
    GdiFlush()
    copy_pixels:=make([]u32,w*h)
    for p,i in pixels {
        alpha:=max(p&255,max((p>>8)&255,(p>>16)&255))
        copy_pixels[i]=0xffffff|(alpha<<24)
    }
    append(&g_shaped_text,Native_Text{font=font,size=size,text=strings.clone(text),advance=f32(extent.cx),w=w,h=h,pixels=copy_pixels,frame=g_frame})
    return &g_shaped_text[len(g_shaped_text)-1]
}

draw_shaped_text :: proc(dl: ^im.DrawList,font:^im.Font,size:f32,pos:im.Vec2,color:u32,text:string) -> bool {
    if !text_needs_shaping(text) || g_renderer==nil do return false
    entry:=shaped_text(font,size,text)
    if entry==nil do return false
    if entry.texture==nil {
        entry.texture=sdl.CreateTexture(g_renderer,.RGBA32,.STATIC,c.int(entry.w),c.int(entry.h))
        if entry.texture==nil do return false
        sdl.UpdateTexture(entry.texture,nil,raw_data(entry.pixels),c.int(entry.w*4))
        sdl.SetTextureBlendMode(entry.texture,.BLEND)
    }
    shaped_image_clipped(dl,im.TextureID(uintptr(entry.texture)),pos.x-4,pos.y-4,pos.x+f32(entry.w)-4,pos.y+f32(entry.h)-4,color,im.DrawList_GetClipRectMin(dl),im.DrawList_GetClipRectMax(dl))
    return true
}

shaped_image_clipped :: proc(dl:^im.DrawList,tex:im.TextureID,x0,y0,x1,y1:f32,tint:u32,lo,hi:im.Vec2) {
    a,b:=im.Vec2{max(x0,lo.x),max(y0,lo.y)},im.Vec2{min(x1,hi.x),min(y1,hi.y)}
    if a.x>=b.x || a.y>=b.y do return
    im.DrawList_AddImage(dl,tex,a,b,{(a.x-x0)/(x1-x0),(a.y-y0)/(y1-y0)},{(b.x-x0)/(x1-x0),(b.y-y0)/(y1-y0)},tint)
}

// Resolve a whole paragraph before line wrapping. Keep the logical item array
// intact: event targets, decorations and subsequent reflow still use that order.
bidi_paragraph :: proc(b:^Box) {
    active:=b.direction==.Rtl || b.unicode_bidi!=.Normal
    for it in b.inlines do if text_needs_shaping(it.text) || it.bidi_scope_n>0 do active=true
    for &it in b.inlines { it.bidi_level=0; it.bidi_space_level=0; it.bidi_override=false }
    if !active do return
    text:=make([dynamic]u16,context.temp_allocator)
    offsets:=make([]int,len(b.inlines),context.temp_allocator)
    space_offsets:=make([]int,len(b.inlines),context.temp_allocator)
    bidi_open_scope(&text,b.unicode_bidi,b.direction)
    previous: [8]Bidi_Scope
    previous_n:=0
    for it,i in b.inlines {
        common:=0
        for common<min(previous_n,int(it.bidi_scope_n)) && previous[common]==it.bidi_scopes[common] do common+=1
        for k:=previous_n-1;k>=common;k-=1 do bidi_close_scope(&text,previous[k].mode)
        space_offsets[i]=len(text)
        if it.space_before do append(&text,u16(' '))
        for k in common..<int(it.bidi_scope_n) do bidi_open_scope(&text,it.bidi_scopes[k].mode,it.bidi_scopes[k].direction)
        it_mode:=b.unicode_bidi
        if it.bidi_scope_n>0 do it_mode=it.bidi_scopes[int(it.bidi_scope_n)-1].mode
        b.inlines[i].bidi_override=it_mode==.Override || it_mode==.Isolate_Override
        previous=it.bidi_scopes; previous_n=int(it.bidi_scope_n)
        offsets[i]=len(text)
        if it.kind==.Break { append(&text,u16('\n')) }
        else if it.kind==.Word { append(&text,..win.utf8_to_utf16(it.text)) }
        else { append(&text,u16(0xfffc)) }
    }
    for k:=previous_n-1;k>=0;k-=1 do bidi_close_scope(&text,previous[k].mode)
    bidi_close_scope(&text,b.unicode_bidi)
    if len(text)==0 do return
    state:=ubidi_open()
    if state==nil do return
    defer ubidi_close(state)
    error:i32
    base:u8=b.direction==.Rtl ? 1 : 0
    if b.unicode_bidi==.Plaintext do base=0xfe
    ubidi_setPara(state,raw_data(text),i32(len(text)),base,nil,&error)
    if error>0 do return
    for &it,i in b.inlines {
        if offsets[i]<len(text) do it.bidi_level=ubidi_getLevelAt(state,i32(offsets[i]))
        if it.space_before do it.bidi_space_level=ubidi_getLevelAt(state,i32(space_offsets[i]))
    }
}

bidi_open_scope :: proc(text:^[dynamic]u16,mode:Unicode_Bidi,dir:Directionality) {
    switch mode {
    case .Normal:
    case .Embed: append(text,u16(dir==.Rtl ? 0x202b : 0x202a))
    case .Override: append(text,u16(dir==.Rtl ? 0x202e : 0x202d))
    case .Isolate: append(text,u16(dir==.Rtl ? 0x2067 : 0x2066))
    case .Plaintext: append(text,u16(0x2068))
    case .Isolate_Override:
        append(text,u16(dir==.Rtl ? 0x2067 : 0x2066),u16(dir==.Rtl ? 0x202e : 0x202d))
    }
}
bidi_close_scope :: proc(text:^[dynamic]u16,mode:Unicode_Bidi) {
    switch mode {
    case .Normal:
    case .Embed,.Override: append(text,u16(0x202c))
    case .Isolate,.Plaintext: append(text,u16(0x2069))
    case .Isolate_Override: append(text,u16(0x202c),u16(0x2069))
    }
}

bidi_line :: proc(b:^Box,start,end:int) {
    if end-start<2 do return
    levels:=make([dynamic]u8,context.temp_allocator)
    widths:=make([dynamic]f32,context.temp_allocator)
    owners:=make([dynamic]int,context.temp_allocator)
    active:=false
    x:=b.inlines[start].x-b.inlines[start].pad_before
    for i in start..<end {
        it:= &b.inlines[i]
        prev:=i==start ? x : b.inlines[i-1].x+b.inlines[i-1].w+b.inlines[i-1].pad_after
        gap:=max(0,it.x-prev-it.pad_before)
        if gap>0 {
            append(&levels,it.bidi_space_level); append(&widths,gap); append(&owners,-1)
        }
        append(&levels,it.bidi_level); append(&widths,it.w+it.pad_before+it.pad_after); append(&owners,i)
        if it.bidi_level!=0 do active=true
    }
    if !active do return
    indices:=make([]i32,len(levels),context.temp_allocator)
    ubidi_reorderVisual(raw_data(levels),i32(len(levels)),raw_data(indices))
    for idx in indices {
        k:=int(idx)
        if owners[k]>=0 {
            it:= &b.inlines[owners[k]]
            it.x=x+it.pad_before
        }
        x+=widths[k]
    }
}

bidi_display_text :: proc(text:string,level:u8,override:bool) -> string {
    if override do return strings.concatenate({level%2==1 ? "\u202e" : "\u202d",text,"\u202c"},context.temp_allocator)
    if level%2==1 do return strings.concatenate({"\u202b",text,"\u202c"},context.temp_allocator)
    return text
}
