package ui

import "core:testing"
import "core:math"
import im "../../vendor/imgui"

@(private="file")
x_test :: proc(value:string,w:f32=200,h:f32=100) -> XMatrix {
    c:=test_apply(value)
    m:=x_resolve(c.xform,w,h)
    // These isolated tests do not install a style map that owns the list.
    if c.xform!=nil { delete(c.xform.ops); free(c.xform) }
    return m
}
@(test)
xform_full_z_and_perspective :: proc(t:^testing.T) {
    m:=x_test("transform:rotateY(90deg) translateZ(100px)")
    testing.expect(t,abs(m[0,3]-100)<0.001)
    p:=x_test("transform:perspective(500px) translateZ(100px)")*([4]f32{100,0,0,1})
    testing.expect(t,abs(p[0]/p[3]-125)<0.001)
    m=x_test("transform:translateZ(100px) rotateY(90deg)")
    testing.expectf(t,abs(m[0,3])<0.001 && abs(m[2,3]-100)<0.001,"individual result: %v",m)
    m=x_test("translate:50% 25% 100px;rotate:y 90deg;transform:translateZ(20px)")
    testing.expectf(t,abs(m[0,3]-120)<0.001 && abs(m[1,3]-25)<0.001 && abs(m[2,3]-100)<0.001,"individual result: %v",m)
}
@(test)
xform_matrix_decomposition :: proc(t:^testing.T) {
    a:XMatrix=1; b:=x_rotation({0,0,1},math.PI/2)
    m:=x_mix_matrix(a,b,0.5)
    testing.expect(t,abs(m[0,0]-math.sqrt(f32(0.5)))<0.001)
    testing.expect(t,abs(m[1,0]-math.sqrt(f32(0.5)))<0.001)
    testing.expect(t,x_mix_matrix(a,b,0)==a && x_mix_matrix(a,b,1)==b)
    a[0,0]=0
    testing.expect(t,x_mix_matrix(a,b,0.25)==a,"singular decomposition changes discretely")
}
@(test)
xform_keyframes_matrix_and_winding :: proc(t:^testing.T) {
    c:=test_compute_anim(".x{animation:a 2s linear both}@keyframes a{from{transform:translateX(10px) rotate(0deg)}to{transform:translateX(20px) rotate(360deg)}}","div","x")
    ev:=eval_anim(&c.anim,1,200,100)
    testing.expect(t,ev.has_xform && abs(ev.xform[0,0]+1)<0.001 && abs(ev.xform[0,3]-15)<0.001)
    c=test_compute_anim(".x{animation:a 2s linear both}@keyframes a{from{transform:matrix(1,0,0,1,0,0)}to{transform:matrix(0,1,-1,0,100,50)}}","div","x")
    ev=eval_anim(&c.anim,1,200,100)
    testing.expect(t,abs(ev.xform[0,0]-math.sqrt(f32(0.5)))<0.001 && abs(ev.xform[0,3]-50)<0.001)
}
@(test)
xform_transition_interrupts_without_jump :: proc(t:^testing.T) {
    a:=test_apply("transform:skewX(10deg)"); b:=test_apply("transform:rotate(90deg) translateX(100px)")
    ch:XChan
    defer { delete(ch.start.ops); delete(ch.target.ops) }
    tr:=Transition{on=true,dur=2,timing=Timing{kind=.Linear}}
    x_step(&ch,a.xform,tr,0,200,100)
    mid:=x_step(&ch,b.xform,tr,1,200,100)
    reversed:=x_step(&ch,a.xform,tr,0,200,100)
    testing.expect(t,mid==reversed,"interrupt snapshots the currently displayed matrix")
    end:=x_step(&ch,a.xform,tr,2,200,100)
    testing.expect(t,end==x_resolve(a.xform,200,100))
}
@(test)
xform_homogeneous_nested_and_flat_boundary :: proc(t:^testing.T) {
    verts:=[2]im.DrawVert{{pos={100,0}},{pos={100,0}}}
    dl:=im.DrawList{}; dl.VtxBuffer.Data=&verts[0]; dl.VtxBuffer.Size=2
    depth:=make(map[int][4]f32); defer delete(depth)
    x_project_vertices(&dl,0,x_translation(0,0,100),true,&depth)
    persp:XMatrix=1; persp[3,2]=-1.0/500
    x_project_vertices(&dl,0,persp,false,&depth)
    testing.expect(t,abs(verts[0].pos.x-125)<0.001 && len(depth)==0)
    verts[0].pos={100,0}; verts[1].pos={100,0}
    x_project_vertices(&dl,0,x_translation(0,0,100),false,&depth)
    x_project_vertices(&dl,0,persp,false,&depth)
    testing.expect(t,abs(verts[0].pos.x-100)<0.001,"flat boundary removes depth before ancestor perspective")
}
@(test)
xform_depth_order_overrides_dom_order :: proc(t:^testing.T) {
    near:=Box{w=100,h=100,transform_ox=0.5,transform_oy=0.5}
    far:=near
    nc,fc:=test_apply("transform:translateZ(50px)"),test_apply("transform:translateZ(-50px)")
    near.xform=nc.xform; far.xform=fc.xform
    parent:=Box{w=200,h=200,transform_ox=0.5,transform_oy=0.5}
    entries:=[2]Stacking_Entry{{box=&near},{box=&far}}
    stacking_depths(entries[:],&parent,XMatrix(1),0,0)
    sort_stacking(entries[:],true)
    testing.expect(t,entries[0].box==&far && entries[1].box==&near)
    stacking_depths(entries[:],&parent,x_rotation({0,1,0},math.PI),0,0)
    sort_stacking(entries[:],true)
    testing.expect(t,entries[0].box==&near && entries[1].box==&far,"rotated parent reverses depth")
}

@(test)
xform_hover_none_clears_matrix :: proc(t:^testing.T) {
    c:=test_compute_one(".x{transform:skewX(45deg)}.x:hover{transform:none}","div","x")
    testing.expect(t,c.hover.has_transform && c.hover.xform==nil)
    testing.expect(t,x_resolve(c.hover.xform,100,100)==XMatrix(1))
}
@(test)
xform_origins_keep_pixels_and_percentages :: proc(t:^testing.T) {
    c:=test_apply("transform-origin:calc(25% + 10px) 20px 30px;perspective:500px;perspective-origin:0 0")
    testing.expect(t,abs(c.transform_ox-0.25)<0.001 && c.transform_opx==10 && c.transform_oy==0 && c.transform_opy==20 && c.transform_opz==30)
    testing.expect(t,c.perspective_ox==0 && c.perspective_oy==0)
    c=test_apply("transform-origin:top")
    testing.expect(t,c.transform_ox==0.5 && c.transform_oy==0)
}
@(test)
xform_matrix_reflection_and_matching_skew :: proc(t:^testing.T) {
    a:XMatrix=1; b:XMatrix=1; b[0,0]=-1
    m:=x_mix_matrix(a,b,0.5)
    testing.expect(t,abs(m[0,0])<0.001 && abs(m[1,1]-1)<0.001)
    ac,bc:=test_apply("transform:skewX(0deg)"),test_apply("transform:skewX(60deg)")
    m=x_interpolate(ac.xform,bc.xform,0.5,100,100)
    testing.expect(t,abs(m[0,1]-math.tan(f32(math.PI/6)))<0.001)
}

@(test)
xform_hit_plane_and_bounds :: proc(t:^testing.T) {
    m:=x_translation(650,300,0)*x_test("transform:scale(2)")
    testing.expect(t,x_contains(m,40,40,720,360))
    testing.expect(t,!x_contains(m,40,40,731,360))
    x,y,r,b:=x_bounds(m,40,40)
    testing.expect(t,x==650 && y==300 && r==730 && b==380)
    m=x_translation(100,100,0)*x_test("transform:rotate(45deg)")
    testing.expect(t,!x_contains(m,100,100,30,101))
    testing.expect(t,x_contains(m,100,100,100,150))
    m=x_test("transform:scale(0)")
    testing.expect(t,!x_contains(m,100,100,0,0))
    m=x_test("transform:perspective(300px) rotateY(60deg)")
    q:=m*([4]f32{70,30,0,1})
    testing.expect(t,x_contains(m,100,100,q[0]/q[3],q[1]/q[3]))
}
@(test)
xform_geometry_ancestors_and_flattening :: proc(t:^testing.T) {
    c:=test_apply("transform:scale(2);transform-origin:0 0")
    defer if c.xform!=nil { delete(c.xform.ops); free(c.xform) }
    child:=Box{x=10,y=20,w=40,h=30,transform_sx=1,transform_sy=1}
    root:=Box{w=100,h=100,xform=c.xform,transform_sx=2,transform_sy=2,children=make([dynamic]^Box)}
    append(&root.children,&child)
    defer delete(root.children)
    x_geometry_tree(&root,0,0,0,0)
    x,y,r,b:=x_bounds(child.x_world,child.w,child.h)
    testing.expect(t,x==20 && y==40 && r==100 && b==100)
    x_geometry_tree(&root,0,0,5,10)
    x,y,r,b=x_bounds(child.x_world,child.w,child.h)
    testing.expect(t,x==15 && y==30 && r==95 && b==90)
}

@(test)
xform_inline_box_geometry_and_inverse_pointer :: proc(t:^testing.T) {
    child:=Box{w=40,h=20,transform_sx=1,transform_sy=1}
    root:=Box{w=200,h=100,content_x=10,content_y=20,transform_sx=2,transform_sy=2}
    root.inlines=make([dynamic]Inline_Item)
    defer delete(root.inlines)
    append(&root.inlines,Inline_Item{kind=.InlineBox,box=&child,x=30,y=5})
    x_geometry_tree(&root,0,0,0,0)
    x,y,r,b:=x_bounds(child.x_world,40,20)
    testing.expect(t,x==80 && y==50 && r==160 && b==90)
    child.x_paint_origin={40,25}
    local:=x_widget_point(&child,{150,70})
    testing.expect(t,local.x==75 && local.y==35)
    u,v,ok:=x_unproject(child.x_world,150,70)
    testing.expect(t,ok && u==35 && v==10)
    zero:XMatrix
    _,_,ok=x_unproject(zero,0,0)
    testing.expect(t,!ok)
}

@(test)
xform_clip_eye_interpolates_attributes :: proc(t:^testing.T) {
    tri:=[3]X_Clip_Vertex{{q={0,0,0,1},uv={0,0},col=0xff000000},{q={2,0,0,1},uv={1,0},col=0xff0000ff},{q={1,2,0,-1},uv={0.5,1},col=0xffffffff}}
    poly,n:=x_clip_eye(tri)
    testing.expect(t,n==4,"two visible vertices produce a quad")
    cuts:=0
    for v in poly[:n] {
        testing.expect(t,v.q[3]>=X_EYE_EPS)
        if v.q[3]==X_EYE_EPS {
            cuts+=1
            testing.expect(t,abs(v.uv.y-0.5)<0.001)
            testing.expect(t,((v.col>>8)&255)==127 || ((v.col>>8)&255)==128)
            testing.expect(t,v.col>>24==255)
        }
    }
    testing.expect(t,cuts==2)
    tri[0].q[3]=-1
    _,n=x_clip_eye(tri)
    testing.expect(t,n==3,"one visible vertex produces a triangle")
    tri[1].q[3]=-1
    _,n=x_clip_eye(tri)
    testing.expect(t,n==0,"fully hidden triangle is removed")
    for &v in tri do v.q[3]=X_EYE_EPS
    _,n=x_clip_eye(tri)
    testing.expect(t,n==3,"vertices exactly on the clipping plane survive")
}

@(test)
xform_clip_draw_buffers_preserve_offsets :: proc(t:^testing.T) {
    dl:=im.DrawList{}
    defer im.DrawList__ClearFreeMemory(&dl)
    vertices:=make([]im.DrawVert,65538)
    defer delete(vertices)
    vertices[3].pos={0,0}; vertices[4].pos={2,0}; vertices[5].pos={0,2}
    for &v in vertices do v.col=0xffffffff
    indices:=[6]im.DrawIdx{0,1,2,0,1,2}
    commands:=[2]im.DrawCmd{{ClipRect={0,0,100,100},ElemCount=3},{ClipRect={0,0,100,100},TextureId=7,VtxOffset=3,IdxOffset=3,ElemCount=3}}
    x_draw_buffer(&dl.VtxBuffer,vertices)
    x_draw_buffer(&dl.IdxBuffer,indices[:])
    x_draw_buffer(&dl.CmdBuffer,commands[:])
    dl._CmdHeader.ClipRect={0,0,100,100}
    depth:=make(map[int][4]f32); defer delete(depth)
    m:XMatrix=1; m[3,0]=-1
    x_project_vertices(&dl,3,m,false,&depth)
    cmds:=([^]im.DrawCmd)(dl.CmdBuffer.Data)
    idx:=([^]im.DrawIdx)(dl.IdxBuffer.Data)
    testing.expect(t,cmds[0].VtxOffset==0 && cmds[0].IdxOffset==0 && cmds[0].ElemCount==3,"unaffected command retained")
    testing.expect(t,cmds[1].TextureId==7 && cmds[1].VtxOffset==65538 && cmds[1].IdxOffset==3 && cmds[1].ElemCount==6,"clipped quad retains texture and uses its own 32-bit base")
    testing.expect(t,dl.IdxBuffer.Size==9 && dl.VtxBuffer.Size==65542)
    for c in cmds[:dl.CmdBuffer.Size] {
        for j in c.IdxOffset..<c.IdxOffset+c.ElemCount do testing.expect(t,int(c.VtxOffset)+int(idx[j])<int(dl.VtxBuffer.Size))
    }
    testing.expect(t,len(depth)==0 && dl._VtxCurrentIdx==0 && dl._CmdHeader.VtxOffset==u32(dl.VtxBuffer.Size))
}

@(test)
xform_clips_only_after_ancestor_composition :: proc(t:^testing.T) {
    verts:=[1]im.DrawVert{{pos={10,20}}}
    dl:=im.DrawList{}; dl.VtxBuffer.Data=&verts[0]; dl.VtxBuffer.Size=1
    depth:=make(map[int][4]f32); defer delete(depth)
    m:XMatrix=1; m[3,3]=-1
    x_project_vertices(&dl,0,m,true,&depth)
    testing.expect(t,depth[0][3]==-1)
    x_project_vertices(&dl,0,m,false,&depth)
    testing.expect(t,verts[0].pos==im.Vec2{10,20} && len(depth)==0,"negative intermediate W must survive until the final ancestor")
}
