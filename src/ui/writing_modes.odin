package ui

import "core:strings"
import "core:unicode/utf8"

logical_physical :: proc(physical,logical:string,mode:Writing_Mode,dir:Directionality) -> string {
    left,right,top,bottom:="left","right","top","bottom"
    if mode==.Horizontal {
        if dir==.Rtl { left="right"; right="left" }
    } else {
        left=dir==.Rtl ? "bottom" : "top"; right=dir==.Rtl ? "top" : "bottom"
        top=mode==.Vertical_Rl ? "right" : "left"; bottom=mode==.Vertical_Rl ? "left" : "right"
    }
    if strings.has_suffix(logical,"radius") {
        block:=strings.contains(logical,"border-start-") ? top : bottom
        inline:=strings.contains(logical,"-start-radius") ? left : right
        return mode==.Horizontal ? strings.concatenate({"border-",block,"-",inline,"-radius"},context.temp_allocator) : strings.concatenate({"border-",inline,"-",block,"-radius"},context.temp_allocator)
    }
    parts:=strings.split(physical,"-",context.temp_allocator)
    for &p in parts {
        switch p {
        case "left": p=left
        case "right": p=right
        case "top": p=top
        case "bottom": p=bottom
        case "width": if mode!=.Horizontal && strings.contains(logical,"size") do p="height"
        case "height": if mode!=.Horizontal && strings.contains(logical,"size") do p="width"
        case "x": if mode!=.Horizontal do p="y"
        case "y": if mode!=.Horizontal do p="x"
        }
    }
    return strings.join(parts,"-",context.temp_allocator)
}

vertical_upright :: proc(text:string,orientation:Text_Orientation) -> bool {
    if orientation==.Upright do return true
    if orientation==.Sideways do return false
    r,_:=utf8.decode_rune_in_string(text)
    // ICU exposes the Unicode Vertical_Orientation property (UAX #50).
    return u_getIntPropertyValue(i32(r),0x1018)>=2
}

layout_vertical_inline :: proc(b:^Box,limit:f32,defined_width:bool) -> f32 {
    restore_text_fragments(b)
    // Split upright text into indivisible clusters. split_tail lets reflow join
    // these owned strings again before choosing a new orientation or extent.
    for i:=0;i<len(b.inlines);i+=1 {
        it:= &b.inlines[i]
        it.vertical_sideways=false
        if it.kind!=.Word || it.text=="" do continue
        orientation:=it.orientation_set ? it.orientation : b.text_orientation
        if orientation==.Sideways do continue
        end:=text_cluster_end(it.text,0)
        if !vertical_upright(it.text,orientation) {
            for end<len(it.text) && !vertical_upright(it.text[end:],orientation) do end=text_cluster_end(it.text,end)
        }
        if end>=len(it.text) do continue
        tail:=it^; tail.text=strings.clone(it.text[end:]); tail.split_tail=true; tail.source_start+=end
        tail.href=it.href!="" ? strings.clone(it.href) : ""; tail.pad_before=0; tail.space_before=false; tail.text_w=0
        head:=strings.clone(it.text[:end]); delete(it.text); it.text=head; it.text_w=0; it.pad_after=0
        inject_at(&b.inlines,i+1,tail)
    }
    col,along,col_width,extent:f32=0,0,0,0
    first:=0
    indent:=b.text_indent_pct ? b.text_indent*limit : b.text_indent
    if !b.indent_hanging do along=indent
    finish :: proc(b:^Box,start,end:int,offset,width,used,limit:f32) {
        align:=align_physical(b.align,b.direction)
        shift:=align==.Right ? max(0,limit-used) : (align==.Center ? max(0,(limit-used)/2) : 0)
        for i in start..<end {
            it:= &b.inlines[i]
            it.line_id=start
            it.x=offset+(width-it.w)/2
            it.y+=shift
        }
    }
    for &it,i in b.inlines {
        it.hidden=false; it.ellipsized=false; it.draw_bytes=0
        if it.kind==.Break {
            finish(b,first,i,col,col_width,along,limit)
            extent=max(extent,along); col+=max(col_width,b.strut); col_width=0
            along=(b.indent_each_line!=b.indent_hanging) ? indent : 0; first=i+1
            continue
        }
        across,advance:f32
        if it.kind==.Word {
            word_width(&it)
            orientation:=it.orientation_set ? it.orientation : b.text_orientation
            upright:=vertical_upright(it.text,orientation)
            across=it.fsize*(it.lh>0 ? it.lh : 1.3)
            advance=upright ? it.fsize : it.text_w
            it.vertical_sideways=!upright
            if it.tab_columns!=0 do advance=tab_advance(&it,along,b.word_spacing)
        } else if it.kind==.InlineBox && it.box!=nil {
            layout_box(it.box,0,0,b.content_w)
            across=it.box.w; advance=it.box.h
        } else { across=it.req_w; advance=it.req_h }
        gap:=it.space_before ? space_adv(&it)+b.word_spacing : 0
        if along>0 && along+gap+advance>limit+WRAP_EPS && !it.nowrap && i>first {
            finish(b,first,i,col,col_width,along,limit)
            extent=max(extent,along); col+=col_width; col_width=0; first=i
            along=b.indent_hanging ? indent : 0; gap=0
        }
        it.x=col; it.y=along+gap; it.w=across; it.h=advance
        col_width=max(col_width,across); along+=gap+advance
    }
    finish(b,first,len(b.inlines),col,col_width,along,limit)
    extent=max(extent,along)
    b.vertical_block_extent=col+col_width
    width:=defined_width ? b.content_w : b.vertical_block_extent
    for &it in b.inlines do if b.writing_mode==.Vertical_Rl do it.x=width-it.x-it.w
    return min(limit,extent)
}

layout_vertical_blocks :: proc(b:^Box,limit:f32,defined_width:bool) -> f32 {
    total,used:f32=0,0
    for child in b.children {
        if child.pos==.Absolute || child.pos==.Fixed {
            child.static_x=b.content_x; child.static_y=b.content_y; child.has_static=true
            continue
        }
        force_h:=!child.has_height && child.writing_mode!=.Horizontal ? limit : -1
        layout_box(child,0,0,b.content_w,force_h=force_h,cb_h=limit)
        total+=child.w+child.margin[1]+child.margin[3]
        used=max(used,child.h+child.margin[0]+child.margin[2])
    }
    width:=defined_width ? b.content_w : total
    cursor:f32=0
    for child in b.children {
        if child.pos==.Absolute || child.pos==.Fixed do continue
        target:=b.writing_mode==.Vertical_Rl ? width-cursor-child.margin[1]-child.w : cursor+child.margin[3]
        translate_box(child,b.content_x+target-child.x,b.content_y+child.margin[0]-child.y)
        cursor+=child.w+child.margin[1]+child.margin[3]
    }
    b.vertical_block_extent=total
    return min(limit,used)
}
