package ui

// Legacy scalar projections remain covered alongside full homogeneous
// transforms. The final tests exercise perspective and Z translation through
// the same 4x4 resolution that paint and animations consume.

import "core:testing"
import "core:math"
import htmlp "../html"
import csspkg "../css"
import dompkg "../dom"

@(private = "file")
perto :: proc(a, b: f32) -> bool {
    d := a - b
    if d < 0 do d = -d
    return d < 1e-4
}

@(private = "file")
xf :: proc(valor: string) -> Computed {
    return test_compute_one(fmt_regra(".i{transform:", valor, "}"), "div", "i")
}

// `fmt.tprintf` não monta CSS (o `{` é chave de formatação): concatena à mão.
@(private = "file")
fmt_regra :: proc(partes: ..string) -> string {
    n := 0
    for p in partes do n += len(p)
    buf := make([]u8, n, context.temp_allocator)
    i := 0
    for p in partes { copy(buf[i:], p); i += len(p) }
    return string(buf)
}

// Matriz 2×2 que a PINTURA vai aplicar: `xf_*` quando a matriz manda, senão
// R·S dos campos escalares — a mesma conta do paint_box.
@(private = "file")
pintada :: proc(c: Computed) -> (a, b, cc, d: f32) {
    if c.has_xform_matrix do return c.xf_a, c.xf_b, c.xf_c, c.xf_d
    cs, sn := f32(math.cos(f64(c.transform_rot))), f32(math.sin(f64(c.transform_rot)))
    return cs * c.transform_sx, -sn * c.transform_sy, sn * c.transform_sx, cs * c.transform_sy
}

@(private = "file")
mesma_pintura :: proc(t: ^testing.T, tresd, doisd: string, loc := #caller_location) {
    x, y := xf(tresd), xf(doisd)
    xa, xb, xc, xd := pintada(x)
    ya, yb, yc, yd := pintada(y)
    testing.expectf(t, perto(xa, ya) && perto(xb, yb) && perto(xc, yc) && perto(xd, yd),
        "%q devia pintar como %q: [%v %v; %v %v] × [%v %v; %v %v]",
        tresd, doisd, xa, xb, xc, xd, ya, yb, yc, yd, loc = loc)
    testing.expectf(t, perto(x.transform_tx, y.transform_tx) && perto(x.transform_ty, y.transform_ty) &&
        x.transform_tx_pct == y.transform_tx_pct && x.transform_ty_pct == y.transform_ty_pct,
        "%q devia transladar como %q: (%v%s, %v%s) × (%v%s, %v%s)", tresd, doisd,
        x.transform_tx, x.transform_tx_pct ? "·w" : "px", x.transform_ty, x.transform_ty_pct ? "·h" : "px",
        y.transform_tx, y.transform_tx_pct ? "·w" : "px", y.transform_ty, y.transform_ty_pct ? "·h" : "px", loc = loc)
    testing.expectf(t, x.has_transform && y.has_transform, "os dois têm de marcar has_transform (%q)", tresd, loc = loc)
}

// ── 1. cada grafia 3D × o controle 2D ───────────────────────────────────────

@(test)
xform3d_grafia_3d_igual_ao_controle_2d :: proc(t: ^testing.T) {
    mesma_pintura(t, "translate3d(10px, 20px, 0)",      "translate(10px, 20px)")
    mesma_pintura(t, "translate3d(-50%, -50%, 0)",      "translate(-50%, -50%)")
    mesma_pintura(t, "translate3d(calc(1px + 2px), 4px, 9px)", "translate(3px, 4px)")
    mesma_pintura(t, "scale3d(2, 3, 4)",                "scale(2, 3)")
    mesma_pintura(t, "rotate3d(0, 0, 1, 30deg)",        "rotate(30deg)")
    mesma_pintura(t, "rotate3d(0, 0, -2, 30deg)",       "rotate(-30deg)")
    mesma_pintura(t, "rotateY(180deg)",                 "scaleX(-1)")
    mesma_pintura(t, "rotateX(60deg)",                  "scaleY(0.5)")
    mesma_pintura(t, "rotate3d(1, 0, 0, 60deg)",        "scaleY(0.5)")
    mesma_pintura(t, "rotate3d(0, 5, 0, 60deg)",        "scaleX(0.5)")
    mesma_pintura(t, "matrix3d(1,2,0,0, 3,4,0,0, 0,0,1,0, 5,6,0,1)", "matrix(1,2,3,4,5,6)")
    // v15 é o divisor homogêneo: tudo dividido por 2.
    mesma_pintura(t, "matrix3d(2,4,0,0, 6,8,0,0, 0,0,2,0, 10,12,0,2)", "matrix(1,2,3,4,5,6)")
    // 3D no meio de uma lista 2D não derruba as vizinhas (era o defeito original:
    // a função 3D sumia e o resto ficava).
    mesma_pintura(t, "translate3d(5px, 6px, 0) rotate(20deg) scale3d(2, 2, 1)", "translate(5px, 6px) rotate(20deg) scale(2)")
}

// O defeito original, dito com todas as letras: antes desta mudança os três
// asserts abaixo falhavam (tx=0, has_transform=false).
@(test)
xform3d_translate3d_nao_e_mais_descartado :: proc(t: ^testing.T) {
    c := xf("translate3d(-50%, -50%, 0)")
    testing.expectf(t, c.transform_tx == -0.5 && c.transform_tx_pct, "tx devia ser -50%% do próprio tamanho; veio %v pct=%v", c.transform_tx, c.transform_tx_pct)
    testing.expectf(t, c.transform_ty == -0.5 && c.transform_ty_pct, "ty devia ser -50%%; veio %v pct=%v", c.transform_ty, c.transform_ty_pct)
    // `translateZ(0)`: nada a desenhar, mas o elemento É transformado — é o que
    // faz dele stacking context e containing block de `fixed`.
    z := xf("translateZ(0)")
    testing.expect(t, z.has_transform, "translateZ(0) tem de marcar has_transform")
    testing.expect(t, !z.has_xform_matrix && z.xf_a == 1 && z.xf_d == 1 && z.transform_tx == 0, "…e não desenha transformação nenhuma")
    // controle: sem transform, nada marca
    n := test_compute_one(".i{color:red}", "div", "i")
    testing.expect(t, !n.has_transform, "controle: sem transform não há has_transform")
}

// ── 2. o lado: o bit que a projeção perde ───────────────────────────────────

@(test)
xform3d_lado_distingue_giro_de_espelho :: proc(t: ^testing.T) {
    // MESMA pintura (provada acima), lados DIFERENTES.
    testing.expect(t, xf("rotateY(180deg)").xf_back,  "rotateY(180deg) mostra o verso")
    testing.expect(t, !xf("scaleX(-1)").xf_back,      "controle: scaleX(-1) espelha mas continua de frente")
    testing.expect(t, xf("rotateX(180deg)").xf_back,  "rotateX(180deg) mostra o verso")
    testing.expect(t, !xf("scaleY(-1)").xf_back,      "controle: scaleY(-1) continua de frente")
    testing.expect(t, !xf("rotateY(60deg)").xf_back,  "60° ainda é a frente")
    testing.expect(t, xf("rotateY(120deg)").xf_back,  "120° já é o verso")
    testing.expect(t, !xf("rotate(180deg)").xf_back,  "giro no plano nunca mostra o verso")
    testing.expect(t, xf("rotate3d(1, 1, 0, 180deg)").xf_back, "eixo oblíquo no plano, 180°: verso")
    // dois meios-giros voltam à frente — o lado sai do PRODUTO, não de uma
    // contagem de funções "que viram".
    testing.expect(t, !xf("rotateY(180deg) rotateY(180deg)").xf_back, "360° é a frente")
    testing.expect(t, !xf("rotateY(180deg) rotateX(180deg)").xf_back, "Y180·X180 = Z180: frente")
    testing.expect(t, xf("rotateY(100deg) rotateY(100deg)").xf_back,  "100°+100°: cada um é frente, o produto é verso")
    // Inverter só o eixo Z não muda UM pixel do plano e mesmo assim vira a face:
    // o critério é a normal transformada (cofator/det), o mesmo do Chromium.
    testing.expect(t, xf("scaleZ(-1)").xf_back,          "scaleZ(-1): verso")
    testing.expect(t, xf("scale3d(1, 1, -1)").xf_back,   "scale3d(1,1,-1): verso")
    testing.expect(t, xf("matrix3d(1,0,0,0, 0,1,0,0, 0,0,-1,0, 0,0,0,1)").xf_back, "matrix3d que inverte Z: verso")
    testing.expect(t, !xf("scaleZ(2)").xf_back,          "controle: scaleZ(2) é a frente")
    testing.expect(t, !xf("scaleZ(-1)").has_xform_matrix && xf("scaleZ(-1)").transform_sx == 1, "…e não pinta transformação nenhuma")
}

// ── 3. o produto é projetado no FIM, não função a função ────────────────────

@(test)
xform3d_projeta_o_produto_e_nao_cada_fator :: proc(t: ^testing.T) {
    // rotateX(90°)·rotateX(−90°) = identidade. Projetando cada fator vira
    // scaleY(0)·scaleY(0) — o elemento SOME. (Os campos escalares dão exatamente
    // esse zero; por isso a conferência do fim liga a matriz.)
    c := xf("rotateX(90deg) rotateX(-90deg)")
    a, b, cc, d := pintada(c)
    testing.expectf(t, perto(a, 1) && perto(b, 0) && perto(cc, 0) && perto(d, 1), "devia ser a identidade; veio [%v %v; %v %v]", a, b, cc, d)
    testing.expect(t, c.has_xform_matrix, "os campos escalares não representam a lista: a matriz tem de mandar")

    // Ordem importa (caso NÃO-comutativo): RY(180)·RZ(90) × RZ(90)·RY(180).
    p := xf("rotateY(180deg) rotate(90deg)")
    pa, pb, pc, pd := pintada(p)
    testing.expectf(t, perto(pa, 0) && perto(pb, 1) && perto(pc, 1) && perto(pd, 0), "Y180·Z90 = [0 1; 1 0]; veio [%v %v; %v %v]", pa, pb, pc, pd)
    q := xf("rotate(90deg) rotateY(180deg)")
    qa, qb, qc, qd := pintada(q)
    testing.expectf(t, perto(qa, 0) && perto(qb, -1) && perto(qc, -1) && perto(qd, 0), "Z90·Y180 = [0 -1; -1 0]; veio [%v %v; %v %v]", qa, qb, qc, qd)

    // Um giro só cabe nos campos escalares e fica ANIMÁVEL (a matriz é estática:
    // se ligasse aqui, o flip no :hover deixaria de transicionar).
    testing.expect(t, !xf("rotateY(180deg)").has_xform_matrix, "rotateY sozinho fica nos campos escalares")
    testing.expect(t, !xf("translate3d(1px,2px,3px) scale3d(2,2,2)").has_xform_matrix, "translate3d/scale3d também")
}

// ── 4. propriedade individual `rotate` com eixo ─────────────────────────────

@(test)
xform3d_prop_rotate_com_eixo :: proc(t: ^testing.T) {
    Caso :: struct { v: string, sx, sy, rot: f32, back: bool }
    casos := []Caso{
        {"y 180deg",          -1,  1, 0, true},
        {"180deg y",          -1,  1, 0, true},   // eixo depois do ângulo também é válido
        {"0 1 0 180deg",      -1,  1, 0, true},
        {"x 60deg",            1, .5, 0, false},
        {"1 0 0 180deg",       1, -1, 0, true},
        {"z 90deg",            1,  1, 1.5707964, false},
        {"0 0 1 90deg",        1,  1, 1.5707964, false},
        {"90deg 0 0 -1",       1,  1, -1.5707964, false}, // vetor depois do ângulo, eixo -z
        {"90deg",              1,  1, 1.5707964, false}, // controle: a forma 2D de sempre
        {"45deg 30deg",        1,  1, 0, false},         // inválido: não gira nada
        {"1 0 90deg",          1,  1, 0, false},         // vetor incompleto: idem
    }
    for k in casos {
        c := test_compute_one(fmt_regra(".i{rotate:", k.v, "}"), "div", "i")
        testing.expectf(t, perto(c.transform_sx, k.sx) && perto(c.transform_sy, k.sy) && perto(c.transform_rot, k.rot) && c.xf_back == k.back,
            "rotate:%s → sx=%v sy=%v rot=%v back=%v; veio sx=%v sy=%v rot=%v back=%v",
            k.v, k.sx, k.sy, k.rot, k.back, c.transform_sx, c.transform_sy, c.transform_rot, c.xf_back)
    }
}

// ── 5. backface-visibility / transform-style: valor e (não-)herança ─────────

@(private = "file")
computado :: proc(html_src, css, id: string) -> Computed {
    dom := htmlp.parse(html_src)
    rules, _ := csspkg.parse(css)
    styles, _ := compute_styles(dom, &rules, 800, 600)
    alvo: ^dompkg.Node
    walk :: proc(n: ^dompkg.Node, id: string, out: ^^dompkg.Node) {
        if n.kind == .Element && out^ == nil {
            if v, ok := n.attrs["id"]; ok && v == id do out^ = n
        }
        for c in n.children do walk(c, id, out)
    }
    walk(dom, id, &alvo)
    if alvo == nil do return Computed{}
    return styles[alvo]
}

@(test)
xform3d_backface_e_preserve3d_nao_herdam :: proc(t: ^testing.T) {
    HTML :: `<html><body><div id="pai"><div id="filho"><div id="neto"></div></div></div><div id="fora"></div></body></html>`
    CSS  :: `#pai{transform-style:preserve-3d; backface-visibility:hidden; -webkit-backface-visibility:hidden}`
    pai, filho, neto, fora := computado(HTML, CSS, "pai"), computado(HTML, CSS, "filho"), computado(HTML, CSS, "neto"), computado(HTML, CSS, "fora")
    testing.expect(t, pai.preserve_3d && pai.backface_hidden, "o pai tem as duas")
    testing.expect(t, !filho.preserve_3d && !filho.backface_hidden, "nenhuma das duas herda")
    testing.expect(t, filho.in_p3d, "o filho DIRETO sabe que o pai é preserve-3d")
    testing.expect(t, !neto.in_p3d, "o neto não: o filho não é preserve-3d, achata")
    testing.expect(t, !pai.in_p3d && !fora.in_p3d, "controle: quem não tem pai preserve-3d não marca")

    // grafia prefixada sozinha (é a que os geradores antigos emitem)
    w := test_compute_one(".i{-webkit-backface-visibility:hidden; -webkit-transform-style:preserve-3d}", "div", "i")
    testing.expect(t, w.backface_hidden && w.preserve_3d, "os aliases -webkit- chegam às mesmas props")
    v := test_compute_one(".i{backface-visibility:visible; transform-style:flat}", "div", "i")
    testing.expect(t, !v.backface_hidden && !v.preserve_3d, "controle: visible/flat não ligam nada")
}

// ── 6. o lado em tempo de pintura (hover + transition) ──────────────────────

@(test)
xform3d_lado_na_pintura :: proc(t: ^testing.T) {
    // matriz estática, ou sem transform de hover: vale o bit do estilo
    b := Box{xf_back = true}
    testing.expect(t, box_face_back(&b, false, 1, 1), "sem hover: xf_back")
    b = Box{xf_back = true, has_xform_matrix = true}
    b.hover.has_transform = true
    testing.expect(t, box_face_back(&b, true, -1, 1), "matriz: xf_back, o hover não entra")

    // base de frente, hover rotateY(180deg): sx vai de 1 a -1
    b = Box{}
    b.hover.has_transform = true; b.hover.back = true
    testing.expect(t, !box_face_back(&b, false,  1,  1), "parado na base: frente")
    testing.expect(t, !box_face_back(&b, true,   .4, -1), "indo p/ o verso, antes de cruzar o zero: ainda frente")
    testing.expect(t,  box_face_back(&b, true,  -.4, -1), "depois de cruzar: verso")
    testing.expect(t,  box_face_back(&b, true,  -1,  -1), "chegou: verso")
    testing.expect(t,  box_face_back(&b, false, -.4,  1), "voltando, antes de cruzar: ainda verso")
    testing.expect(t, !box_face_back(&b, false,  .4,  1), "voltando, depois de cruzar: frente")

    // CONTROLE: hover scaleX(-1). O sinal faz o MESMO percurso e o lado não muda
    // — é o que separa "inverteu o sinal" de "virou a face".
    b = Box{}
    b.hover.has_transform = true; b.hover.back = false
    testing.expect(t, !box_face_back(&b, true, -1, -1), "espelho no hover não mostra o verso")
    testing.expect(t, !box_face_back(&b, true, .4, -1), "…nem no meio do caminho")
}

@(test)
xform3d_hover_guarda_o_lado :: proc(t: ^testing.T) {
    c := test_compute_one(".i:hover{transform:rotateY(180deg)}", "div", "i")
    testing.expect(t, c.hover.has_transform, "o hover tem transform")
    testing.expectf(t, perto(c.hover.sx, -1) && c.hover.back, "hover: sx=-1 e verso; veio sx=%v back=%v", c.hover.sx, c.hover.back)
    testing.expect(t, !c.xf_back && c.transform_sx == 1, "a base fica de frente")
    k := test_compute_one(".i:hover{transform:scaleX(-1)}", "div", "i")
    testing.expectf(t, perto(k.hover.sx, -1) && !k.hover.back, "controle: scaleX(-1) no hover não é verso; veio sx=%v back=%v", k.hover.sx, k.hover.back)
}

// O transform do :hover SUBSTITUI o da base. Antes ele ACUMULAVA sobre a cópia
// já transformada: os três primeiros asserts davam 90°, "sem delta" e verso=false.
@(test)
xform3d_hover_substitui_o_transform_da_base :: proc(t: ^testing.T) {
    c := test_compute_one(".i{transform:rotate(45deg)} .i:hover{transform:rotate(45deg) scale(1.2)}", "div", "i")
    testing.expectf(t, perto(c.hover.rot, 0.7853982) && perto(c.hover.sx, 1.2),
        "hover: rot=45° (não 90°) e sx=1.2; veio rot=%v sx=%v", c.hover.rot, c.hover.sx)

    n := test_compute_one(".i{transform:scale(2)} .i:hover{transform:none}", "div", "i")
    testing.expectf(t, n.hover.has_transform && perto(n.hover.sx, 1) && perto(n.hover.sy, 1),
        "hover com transform:none desfaz a escala da base; veio has=%v sx=%v", n.hover.has_transform, n.hover.sx)

    f := test_compute_one(".i{transform:rotateY(180deg)} .i:hover{transform:rotateY(180deg) scale(1.1)}", "div", "i")
    testing.expectf(t, f.hover.back && perto(f.hover.sx, -1.1),
        "o verso continua verso no hover; veio back=%v sx=%v", f.hover.back, f.hover.sx)

    // O que o :hover NÃO tocou vem da base: as props individuais são outras
    // propriedades, e `transform` no hover não as apaga…
    m := test_compute_one(".i{rotate:45deg} .i:hover{transform:scale(1.2)}", "div", "i")
    testing.expectf(t, perto(m.hover.rot, 0.7853982) && perto(m.hover.sx, 1.2),
        "rotate da base sobrevive ao transform do hover; veio rot=%v sx=%v", m.hover.rot, m.hover.sx)
    // …e vice-versa: `scale` no hover mantém o `transform` da base.
    v := test_compute_one(".i{transform:rotate(45deg)} .i:hover{scale:1.2}", "div", "i")
    testing.expectf(t, perto(v.hover.rot, 0.7853982) && perto(v.hover.sx, 1.2),
        "transform da base sobrevive ao scale do hover; veio rot=%v sx=%v", v.hover.rot, v.hover.sx)

    // CONTROLE: sem transform na base o hover já dava certo, e continua.
    k := test_compute_one(".i:hover{transform:rotate(45deg) scale(1.2)}", "div", "i")
    testing.expectf(t, perto(k.hover.rot, 0.7853982) && perto(k.hover.sx, 1.2), "controle; veio rot=%v sx=%v", k.hover.rot, k.hover.sx)
    // CONTROLE: hover que não fala de transform não cria delta de transform.
    z := test_compute_one(".i{transform:rotate(45deg)} .i:hover{color:red}", "div", "i")
    testing.expect(t, !z.hover.has_transform || perto(z.hover.rot, 0.7853982), "hover sem transform não mexe na rotação")
}

// ── 7. DEGRADAÇÕES — o que NÃO fazemos, dito pelo teste ─────────────────────

// Full matrices now preserve projective W and translation in Z.
@(test)
xform3d_perspective_projects_homogeneous_coordinates :: proc(t:^testing.T) {
    c:=xf("perspective(500px) translateZ(100px)")
    m:=x_resolve(c.xform,200,100)
    p:=m*([4]f32{100,0,0,1})
    testing.expect(t,perto(p[0]/p[3],125))
    testing.expect(t,css_supports_decl("perspective","500px"))
    // Plane intersections and a shared nested 3D display list remain incomplete.
    testing.expect(t,!css_supports_decl("transform-style","preserve-3d"))
}

@(test)
xform3d_z_after_rotation_moves_on_screen :: proc(t:^testing.T) {
    c:=xf("rotateY(90deg) translateZ(100px)")
    m:=x_resolve(c.xform,200,100)
    testing.expect(t,perto(m[0,3],100) && perto(m[2,3],0))
}
