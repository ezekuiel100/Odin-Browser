package ui

import "core:testing"
import "core:os"
import im "../../vendor/imgui"

@(test)
native_shaping_measure_and_raster :: proc(t:^testing.T) {
    data,err:=os.read_entire_file_from_path("C:/Windows/Fonts/segoeui.ttf",context.allocator)
    testing.expect(t,err==nil)
    if err!=nil do return
    defer delete(data)
    defer shaped_text_clear()
    source:=im.FontConfig{FontData=raw_data(data),FontDataSize=i32(len(data))}
    font:=im.Font{Sources=&source,SourcesCount=1}
    for text in ([]string{"سلام","עברית","नमस्ते","ภาษาไทย"}) {
        result:=shaped_text(&font,40,text)
        testing.expectf(t,result!=nil,"native analysis: %s",text)
        if result==nil do continue
        testing.expect(t,result.advance>0 && result.w>0 && result.h>0)
        ink:=0
        for p in result.pixels do if p>>24!=0 do ink+=1
        testing.expectf(t,ink>0,"raster contains ink: %s",text)
        it:=Inline_Item{font=&font,fsize=40,em=1,text=text}
        testing.expect(t,word_width(&it)==result.advance)
        testing.expect(t,shaped_text(&font,40,text)==result)
    }
}

@(test)
native_bidi_paragraph_and_line :: proc(t:^testing.T) {
    b:=Box{direction=.Rtl}
    append(&b.inlines,Inline_Item{kind=.Word,text="אחד",x=0,w=30})
    append(&b.inlines,Inline_Item{kind=.Word,text="שתיים",space_before=true,x=40,w=50})
    append(&b.inlines,Inline_Item{kind=.Word,text="123",space_before=true,x=100,w=30})
    defer delete(b.inlines)
    bidi_paragraph(&b)
    testing.expect(t,b.inlines[0].bidi_level%2==1 && b.inlines[2].bidi_level%2==0)
    bidi_line(&b,0,len(b.inlines))
    testing.expect(t,b.inlines[2].x<b.inlines[1].x && b.inlines[1].x<b.inlines[0].x)
    testing.expect(t,b.inlines[0].text=="אחד" && b.inlines[2].text=="123")
}

@(test)
native_bidi_alignment_after_reordering :: proc(t:^testing.T) {
    advances:[128]f32
    for &a in advances do a=10
    font:=im.Font{FontSize=20,FallbackAdvanceX=10,IndexAdvanceX={Size=128,Capacity=128,Data=&advances[0]}}
    b:=Box{is_inline=true,has_width=true,width=100,direction=.Rtl,align=.Start}
    append(&b.inlines,Inline_Item{kind=.Word,font=&font,fsize=20,em=1,lh=1,text="אב"})
    append(&b.inlines,Inline_Item{kind=.Word,font=&font,fsize=20,em=1,lh=1,text="גד",space_before=true})
    defer delete(b.inlines)
    defer text_metrics_clear()
    layout_box(&b,0,0,100)
    testing.expectf(t,b.inlines[0].x+b.inlines[0].w==100,"right edge %v",b.inlines[0].x+b.inlines[0].w)
    testing.expect(t,b.inlines[1].x<b.inlines[0].x)
}
