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
