package ui

import "core:math"
import "core:strings"
import dompkg "../dom"
import im "../../vendor/imgui"
import la "core:math/linalg"

XMatrix :: matrix[4,4]f32
XKind :: enum { Matrix, Translate, Scale, Rotate, Skew, Perspective }
XOp :: struct {
    kind:XKind,
    m: XMatrix,
    pct: [2]f32,
    rotate: bool,
    axis: [3]f32,
    angle: f32,
    skew:[2]f32,
}
XList :: struct { ops: [dynamic]XOp, spatial: bool }

x_lift :: proc(m: matrix[3,3]f32) -> XMatrix {
    r: XMatrix = 1
    for i in 0..<3 { for j in 0..<3 { r[i,j] = m[i,j] } }
    return r
}
x_translation :: proc(x,y,z:f32) -> XMatrix {
    m: XMatrix = 1; m[0,3]=x; m[1,3]=y; m[2,3]=z; return m
}
x_rotation :: proc(axis:[3]f32, angle:f32) -> XMatrix {
    x,y,z := axis[0],axis[1],axis[2]
    l := math.sqrt(x*x+y*y+z*z)
    if l == 0 do return 1
    x/=l; y/=l; z/=l
    c,s := math.cos(angle),math.sin(angle); t:=1-c
    return {t*x*x+c,t*x*y-s*z,t*x*z+s*y,0,
            t*x*y+s*z,t*y*y+c,t*y*z-s*x,0,
            t*x*z-s*y,t*y*z+s*x,t*z*z+c,0,
            0,0,0,1}
}
x_resolve :: proc(list:^XList,w,h:f32) -> XMatrix {
    m:XMatrix=1
    if list == nil do return m
    for op in list.ops {
        n:=op.m
        n[0,3]+=op.pct[0]*w; n[1,3]+=op.pct[1]*h
        m=m*n
    }
    return m
}
x_op_matrix :: proc(op:XOp,w,h:f32) -> XMatrix {
    n:=op.m; n[0,3]+=op.pct[0]*w; n[1,3]+=op.pct[1]*h; return n
}

x_is_2d :: proc(m:XMatrix) -> bool {
    return m[0,2]==0 && m[1,2]==0 && m[2,0]==0 && m[2,1]==0 && m[2,2]==1 && m[2,3]==0 &&
        m[3,0]==0 && m[3,1]==0 && m[3,2]==0 && m[3,3]==1
}
x_mix_2d :: proc(a,b:XMatrix,t:f32) -> XMatrix {
    decomp :: proc(m:XMatrix) -> (angle:f32,scale:[2]f32,residual:matrix[2,2]f32,ok:bool) {
        scale={math.sqrt(m[0,0]*m[0,0]+m[1,0]*m[1,0]),math.sqrt(m[0,1]*m[0,1]+m[1,1]*m[1,1])}
        det:=m[0,0]*m[1,1]-m[0,1]*m[1,0]
        if abs(det)<1e-8 || scale[0]<1e-8 || scale[1]<1e-8 do return
        if det<0 { if m[0,0]<m[1,1] { scale[0]=-scale[0] } else { scale[1]=-scale[1] } }
        angle=math.atan2(m[1,0]/scale[0],m[0,0]/scale[0])
        cs,sn:=math.cos(angle),math.sin(angle)
        residual={
            (cs*m[0,0]+sn*m[1,0])/scale[0],(cs*m[0,1]+sn*m[1,1])/scale[1],
            (-sn*m[0,0]+cs*m[1,0])/scale[0],(-sn*m[0,1]+cs*m[1,1])/scale[1],
        }
        ok=true; return
    }
    ar,as,am,ao:=decomp(a); br,bs,bm,bo:=decomp(b)
    if !ao || !bo do return t<0.5 ? a : b
    if br-ar>math.PI do br-=2*math.PI
    if ar-br>math.PI do ar-=2*math.PI
    r:=x_rotation({0,0,1},ar+(br-ar)*t)
    sc:=as+(bs-as)*t
    residual:XMatrix=1
    for i in 0..<2 { for j in 0..<2 { residual[i,j]=(am[i,j]+(bm[i,j]-am[i,j])*t)*sc[j] } }
    r=r*residual
    r[0,3]=a[0,3]+(b[0,3]-a[0,3])*t
    r[1,3]=a[1,3]+(b[1,3]-a[1,3])*t
    return r
}

// CSS affine decomposition keeps rotations orthogonal through a matrix tween.
// Singular endpoints use a discrete change, rather than dividing by zero.
x_mix_matrix :: proc(a,b:XMatrix,t:f32) -> XMatrix {
    if t <= 0 do return a
    if t >= 1 do return b
    if x_is_2d(a) && x_is_2d(b) do return x_mix_2d(a,b,t)
    decompose :: proc(m:XMatrix) -> (tr,sc,sk:[3]f32, q:quaternion128, ok:bool) {
        if abs(m[3,3]) < 1e-8 do return
        n:=m*XMatrix(1/m[3,3])
        tr={n[0,3],n[1,3],n[2,3]}
        x:=[3]f32{n[0,0],n[1,0],n[2,0]}
        y:=[3]f32{n[0,1],n[1,1],n[2,1]}
        z:=[3]f32{n[0,2],n[1,2],n[2,2]}
        sc[0]=la.length(x)
        if sc[0]<1e-8 do return
        x/=sc[0]; sk[0]=la.dot(x,y); y-=x*sk[0]
        sc[1]=la.length(y)
        if sc[1]<1e-8 do return
        y/=sc[1]; sk[0]/=sc[1]
        sk[1]=la.dot(x,z); z-=x*sk[1]
        sk[2]=la.dot(y,z); z-=y*sk[2]
        sc[2]=la.length(z)
        if sc[2]<1e-8 do return
        z/=sc[2]; sk[1]/=sc[2]; sk[2]/=sc[2]
        if la.dot(x,la.cross(y,z))<0 { sc=-sc; x=-x; y=-y; z=-z }
        r:=matrix[3,3]f32{x[0],y[0],z[0], x[1],y[1],z[1], x[2],y[2],z[2]}
        q=la.quaternion_from_matrix3(r)
        ok=true; return
    }
    at,as,ak,aq,ao:=decompose(a)
    bt,bs,bk,bq,bo:=decompose(b)
    if !ao || !bo do return t<0.5 ? a : b
    tr:=at+(bt-at)*t; sc:=as+(bs-as)*t; sk:=ak+(bk-ak)*t
    q:=la.quaternion_slerp(aq,bq,t)
    rot:=la.matrix3_from_quaternion(q)
    r:=x_translation(tr[0],tr[1],tr[2])*x_lift(rot)
    shear:XMatrix=1; shear[0,1]=sk[0]; shear[0,2]=sk[1]; shear[1,2]=sk[2]
    scale:XMatrix=1; scale[0,0]=sc[0]; scale[1,1]=sc[1]; scale[2,2]=sc[2]
    r=r*shear*scale
    // Factor the projective row from the affine component before blending.
    aa:=a; bb:=b
    for j in 0..<4 { aa[3,j]=j==3 ? 1 : 0; bb[3,j]=j==3 ? 1 : 0 }
    pa:=a*la.inverse(aa); pb:=b*la.inverse(bb)
    mix:=pa
    for i in 0..<4 { for j in 0..<4 { mix[i,j]+=(pb[i,j]-pa[i,j])*t } }
    return mix*r
}

x_interpolate :: proc(a,b:^XList,t,w,h:f32) -> XMatrix {
    if a == b do return x_resolve(a,w,h)
    na:=a!=nil ? len(a.ops) : 0; nb:=b!=nil ? len(b.ops) : 0
    // Matching primitives preserve explicit rotation winding. Otherwise CSS
    // falls back to decomposition of the remaining matrix product.
    m:XMatrix=1
    for i in 0..<max(na,nb) {
        ao,bo:=XOp{m=1},XOp{m=1}
        if i<na do ao=a.ops[i]
        if i<nb do bo=b.ops[i]
        if ao.m==bo.m && ao.pct==bo.pct && ao.angle==bo.angle && ao.skew==bo.skew {
            m=m*x_op_matrix(ao,w,h)
            continue
        }
        kind:=i<na ? ao.kind : bo.kind
        if (i>=na || i>=nb || ao.kind==bo.kind) && kind!=.Matrix && kind!=.Rotate && kind!=.Skew {
            am,bm:=x_op_matrix(ao,w,h),x_op_matrix(bo,w,h)
            n:=am
            for r in 0..<4 { for c in 0..<4 { n[r,c]+=(bm[r,c]-am[r,c])*t } }
            m=m*n
            continue
        }
        if (i>=na || i>=nb || ao.kind==bo.kind) && kind==.Skew {
            v:=ao.skew+(bo.skew-ao.skew)*t
            n:XMatrix=1; n[0,1]=math.tan(v[0]); n[1,0]=math.tan(v[1])
            m=m*n; continue
        }
        if (ao.rotate && bo.rotate && ao.axis==bo.axis) || (ao.rotate && i>=nb) || (bo.rotate && i>=na) {
            axis:=ao.rotate ? ao.axis : bo.axis
            m=m*x_rotation(axis,ao.angle+(bo.angle-ao.angle)*t)
        } else {
            am,bm:XMatrix=1,1
            for j in i..<na do am=am*x_op_matrix(a.ops[j],w,h)
            for j in i..<nb do bm=bm*x_op_matrix(b.ops[j],w,h)
            return m*x_mix_matrix(am,bm,t)
        }
    }
    return m
}

x_base :: proc(c:Computed) -> XOp {
    cs,sn:=math.cos(c.transform_rot),math.sin(c.transform_rot)
    op:=XOp{m=1}
    op.m[0,0]=cs*c.transform_sx; op.m[0,1]=-sn*c.transform_sy
    op.m[1,0]=sn*c.transform_sx; op.m[1,1]=cs*c.transform_sy
    if c.transform_tx_pct { op.pct[0]=c.transform_tx } else { op.m[0,3]=c.transform_tx }
    if c.transform_ty_pct { op.pct[1]=c.transform_ty } else { op.m[1,3]=c.transform_ty }
    return op
}

x_box_translation :: proc(b:^Box) -> (x,y:f32) {
    x=(b.transform_tx_pct ? b.transform_tx*b.w : b.transform_tx)+b.xf_percent[0]*b.w+b.xf_percent[1]*b.h
    y=(b.transform_ty_pct ? b.transform_ty*b.h : b.transform_ty)+b.xf_percent[2]*b.w+b.xf_percent[3]*b.h
    return
}

XChan :: struct { start,target:XList, prog,wait:f32, init:bool, w,h:f32 }
x_copy :: proc(dst:^XList,src:^XList) {
    clear(&dst.ops)
    if src!=nil { append(&dst.ops,..src.ops[:]); dst.spatial=src.spatial }
}
x_step :: proc(ch:^XChan,target:^XList,tr:Transition,dt,w,h:f32) -> XMatrix {
    changed:=ch.w!=w || ch.h!=h
    n:=target!=nil ? len(target.ops) : 0
    if len(ch.target.ops)!=n { changed=true } else {
        for i in 0..<n { if ch.target.ops[i]!=target.ops[i] { changed=true; break } }
    }
    if !ch.init || !tr.on {
        x_copy(&ch.start,target); x_copy(&ch.target,target)
        ch.init=true; ch.prog=1; ch.wait=0; ch.w=w; ch.h=h
        return x_resolve(target,w,h)
    }
    if changed {
        cur:=x_interpolate(&ch.start,&ch.target,timing_eval(tr.timing,ch.prog),w,h)
        if ch.prog>=1 { x_copy(&ch.start,&ch.target) } else {
            clear(&ch.start.ops); append(&ch.start.ops,XOp{m=cur})
        }
        x_copy(&ch.target,target); ch.prog=0; ch.wait=0; ch.w=w; ch.h=h
    }
    if ch.wait<tr.delay { ch.wait+=dt; return x_resolve(&ch.start,w,h) }
    ch.prog=tr.dur>0 ? min(1,ch.prog+dt/tr.dur) : 1
    return x_interpolate(&ch.start,&ch.target,timing_eval(tr.timing,ch.prog),w,h)
}

x_free_styles :: proc(styles:map[^dompkg.Node]Computed) {
    seen:=make(map[^XList]bool,context.temp_allocator)
    defer delete(seen)
    visit :: proc(c:Computed,seen:^map[^XList]bool) {
        add :: proc(x:^XList,seen:^map[^XList]bool) { if x!=nil do seen[x]=true }
        add(c.xform,seen); add(c.hover.xform,seen)
        add(c.anim.underlying.xform,seen)
        for i in 0..<c.anim.n do add(c.anim.stops[i].xform,seen)
        for a in c.anim_more {
            add(a.underlying.xform,seen)
            for i in 0..<a.n do add(a.stops[i].xform,seen)
        }
        if c.before!=nil do visit(c.before^,seen)
        if c.after!=nil do visit(c.after^,seen)
        if c.first_letter!=nil do visit(c.first_letter^,seen)
        if c.placeholder!=nil do visit(c.placeholder^,seen)
    }
    for _,c in styles do visit(c,&seen)
    for x in seen { delete(x.ops); free(x) }
}

g_x_keep_depth:bool

x_project_vertices :: proc(dl:^im.DrawList,v0:int,m:XMatrix,keep:bool,depth:^map[int][4]f32) {
    verts:=([^]im.DrawVert)(dl.VtxBuffer.Data)
    bad:=make(map[int]bool,context.temp_allocator)
    defer delete(bad)
    for i in v0..<int(dl.VtxBuffer.Size) {
        p,ok:=depth[i]
        if !ok do p={verts[i].pos.x,verts[i].pos.y,0,1}
        q:=m*p
        if q[3]<=1e-5 {
            bad[i]=true
            verts[i].pos={0,0}
        } else { verts[i].pos={q[0]/q[3],q[1]/q[3]} }
        if keep { depth[i]=q } else { delete_key(depth,i) }
    }
    // Discard triangles crossing the eye plane. Do not let division by zero
    // emit unbounded screen coordinates into the software rasterizer.
    if len(bad)>0 {
        cmds:=([^]im.DrawCmd)(dl.CmdBuffer.Data)
        idx:=([^]im.DrawIdx)(dl.IdxBuffer.Data)
        for c in 0..<int(dl.CmdBuffer.Size) {
            cmd:=cmds[c]
            for j:=int(cmd.IdxOffset); j+2<int(cmd.IdxOffset+cmd.ElemCount); j+=3 {
                off:=int(cmd.VtxOffset)
                if off+int(idx[j]) in bad || off+int(idx[j+1]) in bad || off+int(idx[j+2]) in bad {
                    idx[j+1]=idx[j]; idx[j+2]=idx[j]
                }
            }
        }
    }
}

// Origins retain both the reference-box fraction and an absolute offset.
x_parse_origin :: proc(value:string,fs,vw,vh:f32) -> (x,y,px,py,pz:f32) {
    x,y=0.5,0.5
    toks:=split_top_level(strings.to_lower(strings.trim_space(value),context.temp_allocator))
    if len(toks)==0 do return
    if len(toks)>=2 {
        if (toks[0]=="top" || toks[0]=="bottom") && (toks[1]=="left" || toks[1]=="right" || toks[1]=="center") do toks[0],toks[1]=toks[1],toks[0]
    } else if toks[0]=="top" || toks[0]=="bottom" {
        x=0.5; y=toks[0]=="top" ? 0 : 1; return
    }
    for i in 0..<min(2,len(toks)) {
        pc,off:f32
        switch toks[i] {
        case "left","top": pc=0
        case "right","bottom": pc=1
        case "center": pc=0.5
        case:
            v,p,k:=parse_len_linear(toks[i],fs,vw,vh)
            if !k do continue
            off=v; pc=p
        }
        if i==0 { x=pc; px=off } else { y=pc; py=off }
    }
    if len(toks)>=3 { if z,p,k:=parse_len_linear(toks[2],fs,vw,vh); k && p==0 do pz=z }
    return
}

x_preserves :: proc(b:^Box) -> bool {
    return b.preserve_3d && b.opacity>=1 && b.n_filters==0 && !b.overflow_hidden &&
        b.blend_mode==.Normal && !b.isolate && b.clip_path.kind==.None && !b.mask_grad.active
}
