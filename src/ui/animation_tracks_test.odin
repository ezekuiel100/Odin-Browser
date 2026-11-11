package ui

import "core:testing"

@(test)
animation_sparse_property_tracks :: proc(t: ^testing.T) {
    c := test_compute_anim(".x{animation:a 4s linear both}@keyframes a{from{opacity:0;background-color:black}50%{background-color:red}to{opacity:1;background-color:white}}","div","x")
    testing.expect(t, abs(test_eval_anim(&c.anim,1).op-0.25)<0.001)
    testing.expect(t, abs(test_eval_anim(&c.anim,3).op-0.75)<0.001)
    testing.expect_value(t,test_eval_anim(&c.anim,2).bg,u32(0xff0000))
}

@(test)
animation_single_stop_underlying_endpoints :: proc(t: ^testing.T) {
    c := test_compute_anim(".x{opacity:0.2;transform:translateX(20px) scale(2);animation:a 4s linear both}@keyframes a{50%{opacity:1;transform:translateX(100px) scale(4)}}","div","x")
    testing.expect(t,c.anim.active)
    e := test_eval_anim(&c.anim,1)
    testing.expect(t,abs(e.op-0.6)<0.001 && abs(e.tx-60)<0.001 && abs(e.sx-3)<0.001)
    e = test_eval_anim(&c.anim,3)
    testing.expect(t,abs(e.op-0.6)<0.001 && abs(e.tx-60)<0.001)
    e = test_eval_anim(&c.anim,4)
    testing.expect(t,abs(e.op-0.2)<0.001 && abs(e.tx-20)<0.001)
}

@(test)
animation_translate_mixed_units_and_identity :: proc(t: ^testing.T) {
    c := test_compute_anim(".x{animation:a 2s linear both}@keyframes a{from{transform:translate(20px,50%)}to{transform:translate(100%,40px)}}","div","x")
    e := test_eval_anim(&c.anim,1)
    testing.expect(t,e.has_translate)
    testing.expect(t,abs(e.tx-10)<0.001 && abs(e.tx_percent-0.5)<0.001)
    testing.expect(t,abs(e.ty-20)<0.001 && abs(e.ty_percent-0.25)<0.001)
    c = test_compute_anim(".x{transform:translateX(90px);animation:a 2s linear both}@keyframes a{to{transform:none}}","div","x")
    testing.expect(t,abs(test_eval_anim(&c.anim,1).tx-45)<0.001)
    testing.expect(t,abs(test_eval_anim(&c.anim,2).tx)<0.001)
}

@(test)
animation_curve_belongs_to_property_segment :: proc(t: ^testing.T) {
    c := test_compute_anim(".x{animation:a 4s linear both}@keyframes a{from{opacity:0;animation-timing-function:steps(2,end)}25%{background:red}to{opacity:1}}","div","x")
    testing.expect(t,abs(test_eval_anim(&c.anim,1.5).op)<0.001)
    testing.expect(t,abs(test_eval_anim(&c.anim,2.5).op-0.5)<0.001)
}

@(test)
animation_duplicate_offset_property_cascade :: proc(t: ^testing.T) {
    c := test_compute_anim(".x{animation:a 4s linear both}@keyframes a{from{opacity:0}50%{opacity:0.4}50%{opacity:0.8;background:red}to{opacity:1}}","div","x")
    testing.expect(t,abs(test_eval_anim(&c.anim,1).op-0.4)<0.001)
    testing.expect(t,abs(test_eval_anim(&c.anim,2).op-0.8)<0.001)
    testing.expect(t,abs(test_eval_anim(&c.anim,3).op-0.9)<0.001)
}

@(test)
animation_opacity_variables :: proc(t: ^testing.T) {
    c := test_compute_anim(".x{--a:0.2;animation:a 2s linear both}@keyframes a{from{opacity:var(--a)}to{opacity:1}}","div","x")
    testing.expect(t,abs(test_eval_anim(&c.anim,1).op-0.6)<0.001)
}

@(test)
animation_translation_shared_stacking_origin :: proc(t: ^testing.T) {
    c := test_compute_anim(".x{animation:a 2s linear both}@keyframes a{from{transform:translateX(0)}to{transform:translateX(100%)}}","div","x")
    b := Box{w=80,rel_dx=7,rel_dy=9}
    b.animations = make([]Animation_Player,1)
    defer delete(b.animations)
    b.animations[0] = Animation_Player{anim=c.anim,elapsed=1}
    x,y := stacking_offset(&b,10,20)
    testing.expect(t,abs(x-57)<0.001 && abs(y-29)<0.001)
    b.w=160
    dx,_ := animation_translation_delta(&b)
    testing.expect(t,abs(dx-80)<0.001,"percentage resolves against current border-box")
}

@(test)
animation_unbounded_stops_and_important :: proc(t: ^testing.T) {
    c := test_compute_anim(".x{animation:a 10s linear both}@keyframes a{0%{opacity:0}10%{opacity:0.1}20%{opacity:0.2}30%{opacity:0.3}40%{opacity:0.4}50%{opacity:0.5}60%{opacity:0.6}70%{opacity:0.7}80%{opacity:0.8}90%{opacity:0.9}100%{opacity:1}}", "div", "x")
    testing.expect_value(t, c.anim.n, 11)
    testing.expect(t, abs(test_eval_anim(&c.anim,9.5).op-0.95)<0.001)
    d := test_compute_anim(".x{opacity:0.3!important;transform:skewX(10deg)!important;animation:a 2s linear both}@keyframes a{from{opacity:0;transform:none}to{opacity:1;transform:skewX(40deg)}}", "div", "x")
    e := test_eval_anim(&d.anim,1)
    testing.expect(t, !e.has_op && !e.has_xform && !e.has_rot && !e.has_scale && !e.has_translate)
}
