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
    // Computed survives frame/worker temp arenas. Keep animation arrays alive
    // until this traversal has collected their transforms, then free each once.
    stops:=make(map[rawptr][]Anim_Stop,context.temp_allocator)
    lists:=make(map[rawptr][]Anim,context.temp_allocator)
    defer delete(stops)
    defer delete(lists)
    visit :: proc(c:Computed,seen:^map[^XList]bool,stops:^map[rawptr][]Anim_Stop,lists:^map[rawptr][]Anim) {
        add :: proc(x:^XList,seen:^map[^XList]bool) { if x!=nil do seen[x]=true }
        if len(c.anim.stops)>0 do stops[raw_data(c.anim.stops)]=c.anim.stops
        if len(c.anim_more)>0 do lists[raw_data(c.anim_more)]=c.anim_more
        add(c.xform,seen); add(c.hover.xform,seen)
        add(c.anim.underlying.xform,seen)
        for i in 0..<c.anim.n do add(c.anim.stops[i].xform,seen)
        for a in c.anim_more {
            if len(a.stops)>0 do stops[raw_data(a.stops)]=a.stops
            add(a.underlying.xform,seen)
            for i in 0..<a.n do add(a.stops[i].xform,seen)
        }
        if c.before!=nil do visit(c.before^,seen,stops,lists)
        if c.after!=nil do visit(c.after^,seen,stops,lists)
        if c.first_letter!=nil do visit(c.first_letter^,seen,stops,lists)
        if c.placeholder!=nil do visit(c.placeholder^,seen,stops,lists)
    }
    for _,c in styles do visit(c,&seen,&stops,&lists)
    for x in seen { delete(x.ops); free(x) }
    for _,s in stops do delete(s)
    for _,s in lists do delete(s)
}

g_x_keep_depth:bool

X_EYE_EPS :: f32(1e-5)
X_Clip_Vertex :: struct { q:[4]f32, uv:im.Vec2, col:u32 }

// Clip before dividing by W. Attributes use the same edge parameter as position.
x_clip_eye :: proc(input:[3]X_Clip_Vertex) -> (out:[4]X_Clip_Vertex,n:int) {
    prev:=input[2]
    for cur in input {
        inside,was_inside:=cur.q[3]>=X_EYE_EPS,prev.q[3]>=X_EYE_EPS
        if inside!=was_inside {
            t:=(X_EYE_EPS-prev.q[3])/(cur.q[3]-prev.q[3])
            v:=X_Clip_Vertex{q=prev.q+(cur.q-prev.q)*t,uv=prev.uv+(cur.uv-prev.uv)*t}
            v.q[3]=X_EYE_EPS
            for shift:u32=0;shift<32;shift+=8 {
                a,b:=f32((prev.col>>shift)&255),f32((cur.col>>shift)&255)
                v.col|=u32(clamp(a+(b-a)*t+0.5,0,255))<<shift
            }
            out[n]=v; n+=1
        }
        if inside { out[n]=cur; n+=1 }
        prev=cur
    }
    return
}

// ImGui owns these allocations; its allocator must also own replacement buffers.
x_draw_buffer :: proc(dst:^$V,src:[]$T) {
    if len(src)>int(dst.Capacity) {
        data:=cast(^T)im.MemAlloc(uint(len(src)*size_of(T)))
        im.MemFree(dst.Data)
        dst.Data=data; dst.Capacity=i32(len(src))
    }
    copy(([^]T)(dst.Data)[:len(src)],src)
    dst.Size=i32(len(src))
}

x_project_vertices :: proc(dl:^im.DrawList,v0:int,m:XMatrix,keep:bool,depth:^map[int][4]f32) {
    verts:=([^]im.DrawVert)(dl.VtxBuffer.Data)
    projected:[][4]f32
    if !keep do projected=make([][4]f32,int(dl.VtxBuffer.Size)-v0,context.temp_allocator)
    defer delete(projected,context.temp_allocator)
    bad:=false
    for i in v0..<int(dl.VtxBuffer.Size) {
        p,ok:=depth[i]
        if !ok do p={verts[i].pos.x,verts[i].pos.y,0,1}
        q:=m*p
        if q[3]<X_EYE_EPS { bad=true; verts[i].pos={0,0} }
        else { verts[i].pos={q[0]/q[3],q[1]/q[3]} }
        if keep { depth[i]=q } else { projected[i-v0]=q; delete_key(depth,i) }
    }
    // An ancestor in the same 3D context may bring a vertex back in front.
    if keep || !bad do return
    cmds:=([^]im.DrawCmd)(dl.CmdBuffer.Data)
    idx:=([^]im.DrawIdx)(dl.IdxBuffer.Data)
    indices:=make([dynamic]im.DrawIdx,0,int(dl.IdxBuffer.Size),context.temp_allocator)
    commands:=make([dynamic]im.DrawCmd,context.temp_allocator)
    added:=make([dynamic]im.DrawVert,context.temp_allocator)
    defer { delete(indices); delete(commands); delete(added) }
    for c in 0..<int(dl.CmdBuffer.Size) {
        cmd:=cmds[c]
        batch:=cmd; batch.IdxOffset=u32(len(indices)); batch.ElemCount=0
        for j:=int(cmd.IdxOffset);j+2<int(cmd.IdxOffset+cmd.ElemCount);j+=3 {
            tri:[3]X_Clip_Vertex
            crossing:=false
            for k in 0..<3 {
                i:=int(cmd.VtxOffset)+int(idx[j+k])
                v:=verts[i]
                q:=[4]f32{v.pos.x,v.pos.y,0,1}
                if i>=v0 do q=projected[i-v0]
                tri[k]={q,v.uv,v.col}
                if q[3]<X_EYE_EPS do crossing=true
            }
            if !crossing {
                append(&indices,idx[j],idx[j+1],idx[j+2]); batch.ElemCount+=3
                continue
            }
            poly,n:=x_clip_eye(tri)
            if n<3 do continue
            if batch.ElemCount>0 { append(&commands,batch); batch.ElemCount=0 }
            // Give the new polygon its own base, keeping 16-bit indices valid
            // even when the original command already contains 64K vertices.
            clipped:=cmd; clipped.IdxOffset=u32(len(indices)); clipped.VtxOffset=u32(int(dl.VtxBuffer.Size)+len(added)); clipped.ElemCount=u32((n-2)*3)
            for k in 0..<n {
                v:=poly[k]
                append(&added,im.DrawVert{pos={v.q[0]/v.q[3],v.q[1]/v.q[3]},uv=v.uv,col=v.col})
            }
            for k in 1..<n-1 do append(&indices,im.DrawIdx(0),im.DrawIdx(k),im.DrawIdx(k+1))
            append(&commands,clipped)
            batch.IdxOffset=u32(len(indices))
        }
        if batch.ElemCount>0 || cmd.UserCallback!=nil do append(&commands,batch)
    }
    all_verts:=make([dynamic]im.DrawVert,0,int(dl.VtxBuffer.Size)+len(added),context.temp_allocator)
    defer delete(all_verts)
    append(&all_verts,..verts[:dl.VtxBuffer.Size]); append(&all_verts,..added[:])
    x_draw_buffer(&dl.VtxBuffer,all_verts[:])
    x_draw_buffer(&dl.IdxBuffer,indices[:])
    x_draw_buffer(&dl.CmdBuffer,commands[:])
    dl._CmdHeader.VtxOffset=u32(dl.VtxBuffer.Size)
    dl._VtxCurrentIdx=0
    dl._VtxWritePtr=&([^]im.DrawVert)(dl.VtxBuffer.Data)[dl.VtxBuffer.Size]
    dl._IdxWritePtr=&([^]im.DrawIdx)(dl.IdxBuffer.Data)[dl.IdxBuffer.Size]
    im.DrawList_AddDrawCmd(dl)
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
        b.blend_mode==.Normal && !b.isolate && b.clip_path.kind==.None && !b.mask_grad.active && b.mask_image.url == ""
}

// Geometry uses the same screen-space pivot and baked translation as paint.
// Retain a homography for the local border plane, rather than its bounding box:
// a rotated box must not catch clicks in the empty corners of that bounding box.
x_geometry_tree :: proc(root:^Box, ox,oy,sx,sy:f32) {
    identity:matrix[4,4]f64=1
    x_geometry_rec(root,ox,oy,sx,sy,identity)
}
x_geometry_rec :: proc(b:^Box,ox,oy,sx,sy:f32,parent:matrix[4,4]f64) {
    if b==nil do return
    dx,dy:=animation_translation_delta(b)
    xx,yy:=ox+b.rel_dx+dx,oy+b.rel_dy+dy
    if b.pos==.Fixed { xx+=sx; yy+=sy }
    else if b.pos==.Sticky && b.inset_has[0] && !b.inset_pct[0] {
        d:=sy+b.inset[0]-(b.y+yy)
        if d>0 do yy+=min(d,b.sticky_max_dy)
    }
    target:=b.xform
    if b.x_hovered && b.hover.has_transform do target=b.hover.xform
    m:=x_resolve(target,b.w,b.h)
    if st,ok:=g_trans[b.node]; ok && st.xform.init && b.trans[.Transform].on {
        ch:=st.xform
        m=x_interpolate(&ch.start,&ch.target,timing_eval(b.trans[.Transform].timing,ch.prog),b.w,b.h)
    }
    for &player in b.animations {
        if !player.anim.active do continue
        ev:=eval_anim(&player.anim,player.elapsed,b.w,b.h)
        if ev.has_xform do m=ev.xform
    }
    if target==nil && b.xform==nil && !b.hover.has_transform && len(b.animations)==0 {
        cs,sn:=f32(math.cos(b.transform_rot)),f32(math.sin(b.transform_rot))
        m[0,0]=cs*b.transform_sx; m[0,1]=-sn*b.transform_sy
        m[1,0]=sn*b.transform_sx; m[1,1]=cs*b.transform_sy
        if b.has_xform_matrix { m[0,0]=b.xf_a; m[0,1]=b.xf_b; m[1,0]=b.xf_c; m[1,1]=b.xf_d }
        tx,ty:=x_box_translation(b); m[0,3]=tx; m[1,3]=ty
    }
    if b.motion_rotation!=0 do m=x_rotation({0,0,1},b.motion_rotation)*m
    tx,ty:=x_box_translation(b)
    // Translation is already included in the layout offset.
    xx+=m[0,3]-tx-dx; yy+=m[1,3]-ty-dy
    x,y:=b.x+xx-sx,b.y+yy-sy
    px,py:=x-m[0,3]+b.w*b.transform_ox+b.transform_opx,y-m[1,3]+b.h*b.transform_oy+b.transform_opy
    project:=x_translation64(px,py,b.transform_opz)*(cast(matrix[4,4]f64)m)*x_translation64(-px-m[0,3],-py-m[1,3],-b.transform_opz)
    world:=parent*project
    b.x_world=world*x_translation64(x,y,0)
    descendants:=world
    if !x_preserves(b) {
        flat:matrix[4,4]f64=1; flat[2,2]=0
        descendants=descendants*flat
    }
    if b.perspective>0 {
        p:matrix[4,4]f64=1; p[3,2]=-1/f64(b.perspective)
        cx,cy:=x+b.w*b.perspective_ox+b.perspective_opx,y+b.h*b.perspective_oy+b.perspective_opy
        descendants=descendants*x_translation64(cx,cy,0)*p*x_translation64(-cx,-cy,0)
    }
    if b.overflow_scroll { xx-=b.scroll_x; yy-=b.scroll_y }
    for child in b.children do x_geometry_rec(child,xx,yy,sx,sy,descendants)
    for it in b.inlines {
        if it.box!=nil do x_geometry_rec(it.box,b.content_x+xx+it.x,b.content_y+yy+it.y,sx,sy,descendants)
    }
}

x_unproject :: proc(m:matrix[4,4]$T,x,y:f32) -> (u,v:f32,ok:bool) {
    // Solve the inverse plane homography without inverting a singular 4D
    // flattening matrix. Edge-on and zero-scale planes have no hit area.
    px,py:=T(x),T(y)
    a,b:=m[0,0]-px*m[3,0],m[0,1]-px*m[3,1]
    c,d:=m[1,0]-py*m[3,0],m[1,1]-py*m[3,1]
    e,f:=px*m[3,3]-m[0,3],py*m[3,3]-m[1,3]
    det:=a*d-b*c
    if abs(det)<1e-8 do return 0,0,false
    local_x,local_y:=(e*d-b*f)/det,(a*f-e*c)/det
    return f32(local_x),f32(local_y),m[3,0]*local_x+m[3,1]*local_y+m[3,3]>T(X_EYE_EPS)
}
x_contains :: proc(m:matrix[4,4]$T,w,h,x,y:f32) -> bool {
    u,v,ok:=x_unproject(m,x,y)
    return ok && u>=0 && v>=0 && u<w && v<h
}
x_bounds :: proc(m:matrix[4,4]$T,w,h:f32) -> (x0,y0,x1,y1:f32) {
    lo_x,lo_y:=T(3.402823e38),T(3.402823e38)
    hi_x,hi_y:=-lo_x,-lo_y
    points:=[4][4]T{{0,0,0,1},{T(w),0,0,1},{T(w),T(h),0,1},{0,T(h),0,1}}
    for v in points {
        q:=m*v
        // DOM rectangles project all corners, including negative W. They are
        // not the bounds of the eye-clipped painted polygon. At exactly zero
        // W, retain X/Y (as Chromium does); small nonzero W must still divide.
        divisor:=q[3]==0 ? T(1) : q[3]
        x,y:=q[0]/divisor,q[1]/divisor
        lo_x=min(lo_x,x); lo_y=min(lo_y,y); hi_x=max(hi_x,x); hi_y=max(hi_y,y)
    }
    return f32(lo_x),f32(lo_y),f32(hi_x),f32(hi_y)
}
x_mouse_over :: proc(b:^Box,screen:im.Vec2,ox,oy:f32) -> bool {
    // Convert ImGui window coordinates to the viewport coordinates used by DOM.
    origin:=im.Vec2{screen.x-b.x-ox+im.GetScrollX(),screen.y-b.y-oy+im.GetScrollY()}
    mouse:=im.GetMousePos()
    if !x_contains(b.x_world,b.w,b.h,mouse.x-origin.x,mouse.y-origin.y) do return false
    dl:=im.GetWindowDrawList()
    lo,hi:=im.DrawList_GetClipRectMin(dl),im.DrawList_GetClipRectMax(dl)
    return mouse.x>=lo.x && mouse.y>=lo.y && mouse.x<hi.x && mouse.y<hi.y
}

// Rectangles passed here are in the untransformed draw-list coordinates.
x_mouse_rect :: proc(b:^Box,lo,hi:im.Vec2) -> bool {
    mouse:=im.GetMousePos()
    dl:=im.GetWindowDrawList()
    clip0,clip1:=im.DrawList_GetClipRectMin(dl),im.DrawList_GetClipRectMax(dl)
    if mouse.x<clip0.x || mouse.y<clip0.y || mouse.x>=clip1.x || mouse.y>=clip1.y do return false
    u,v,ok:=x_unproject(b.x_world,mouse.x-b.x_view_origin.x,mouse.y-b.x_view_origin.y)
    x,y:=u+b.x_paint_origin.x,v+b.x_paint_origin.y
    return ok && x>=lo.x && y>=lo.y && x<hi.x && y<hi.y
}
XMouse :: struct { pos,prev,delta:im.Vec2, clicked:[5]im.Vec2 }
x_widget_point :: proc(b:^Box,point:im.Vec2) -> im.Vec2 {
    u,v,ok:=x_unproject(b.x_world,point.x-b.x_view_origin.x,point.y-b.x_view_origin.y)
    if !ok do return {-1e20,-1e20}
    return {u+b.x_paint_origin.x,v+b.x_paint_origin.y}
}
x_widget_mouse :: proc(b:^Box) -> XMouse {
    io:=im.GetIO()
    saved:=XMouse{io.MousePos,io.MousePosPrev,io.MouseDelta,io.MouseClickedPos}
    dl:=im.GetWindowDrawList()
    lo,hi:=im.DrawList_GetClipRectMin(dl),im.DrawList_GetClipRectMax(dl)
    io.MousePos=x_widget_point(b,saved.pos)
    if saved.pos.x<lo.x || saved.pos.y<lo.y || saved.pos.x>=hi.x || saved.pos.y>=hi.y do io.MousePos={-1e20,-1e20}
    io.MousePosPrev=x_widget_point(b,saved.prev)
    io.MouseDelta=io.MousePos-io.MousePosPrev
    for i in 0..<5 do io.MouseClickedPos[i]=x_widget_point(b,saved.clicked[i])
    return saved
}
x_widget_restore :: proc(saved:XMouse) {
    io:=im.GetIO()
    io.MousePos=saved.pos; io.MousePosPrev=saved.prev; io.MouseDelta=saved.delta; io.MouseClickedPos=saved.clicked
}

// Geometry composition needs extra precision when translation terms nearly
// cancel at very small W. Paint matrices and vertex buffers remain f32.
x_translation64 :: proc(x,y,z:f32) -> matrix[4,4]f64 {
    m:matrix[4,4]f64=1
    m[0,3]=f64(x); m[1,3]=f64(y); m[2,3]=f64(z)
    return m
}
