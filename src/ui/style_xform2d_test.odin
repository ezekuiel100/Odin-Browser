package ui

import "core:testing"
import "core:fmt"
import "core:math"
import htmlp "../html"
import csspkg "../css"

@(private="file")
perto :: proc(a,b:f32) -> bool { return abs(a-b) < 1e-4 }

@(private="file")
pintada :: proc(c:Computed) -> (a,b,cc,d:f32) {
    if c.has_xform_matrix do return c.xf_a,c.xf_b,c.xf_c,c.xf_d
    cs,sn := f32(math.cos(c.transform_rot)),f32(math.sin(c.transform_rot))
    return cs*c.transform_sx,-sn*c.transform_sy,sn*c.transform_sx,cs*c.transform_sy
}

@(test)
xform2d_affine_order :: proc(t: ^testing.T) {
    cases := [?]struct { value: string, tx, ty, a, b, c, d: f32 }{
        {"rotate(90deg) translateX(10px)", 0, 10, 0, -1, 1, 0},
        {"translateX(10px) rotate(90deg)", 10, 0, 0, -1, 1, 0},
        {"translateX(10px) translateX(20px)", 30, 0, 1, 0, 0, 1},
        {"scale(2,3) translate(10px,20px)", 20, 60, 2, 0, 0, 3},
        {"scale(2,3) rotate(90deg)", 0, 0, 0, -2, 3, 0},
        {"rotate(90deg) matrix(1,0,0,1,10,20)", -20, 10, 0, -1, 1, 0},
        {"matrix(1,0,0,1,10,20) translate(5px,6px)", 15, 26, 1, 0, 0, 1},
    }
    for v in cases {
        c := test_apply(fmt.tprintf("transform:%s", v.value))
        a,b,cc,d := pintada(c)
        testing.expectf(t, perto(c.transform_tx,v.tx) && perto(c.transform_ty,v.ty) &&
            perto(a,v.a) && perto(b,v.b) && perto(cc,v.c) && perto(d,v.d), "%s", v.value)
    }
}

@(test)
xform2d_percentage_reference_box :: proc(t: ^testing.T) {
    c := test_apply("transform:rotate(90deg) translate(50%,25%) translateX(10px)")
    testing.expect(t, perto(c.transform_tx,0) && perto(c.transform_ty,10))
    testing.expect(t, perto(c.xf_percent[1],-0.25) && perto(c.xf_percent[2],0.5))
}

@(test)
xform2d_individual_properties_compose :: proc(t: ^testing.T) {
    c := test_apply("translate: 5px 6px; rotate:90deg; scale:2 3; transform:translateX(10px)")
    testing.expect(t, perto(c.transform_tx,5) && perto(c.transform_ty,26))
}

@(test)
xform2d_layout_resolves_percentages :: proc(t: ^testing.T) {
    dom := htmlp.parse("<div style='width:200px;height:80px;transform:rotate(90deg) translate(50%,25%) translateX(10px)'></div>")
    rules,_ := csspkg.parse("")
    styles,_ := compute_styles(dom,&rules)
    root := build_layout(dom,styles,"")
    layout_box(root,0,0,800)
    visit :: proc(t:^testing.T,b:^Box) -> bool {
        if b.has_transform {
            testing.expectf(t, perto(b.rel_dx,-20) && perto(b.rel_dy,110),
                "reference 200x80: expected (-20,110), got (%v,%v)",b.rel_dx,b.rel_dy)
            return true
        }
        for child in b.children { if visit(t,child) do return true }
        return false
    }
    testing.expect(t,visit(t,root))
}
