package js

// ── canvas.getContext('2d') REAL (M232) ─────────────────────────────────────
//
// O último item do Tier 1 da auditoria de 28/07: `<canvas>` não tinha
// `getContext` NENHUM, então todo código de gráfico/sparkline/jogo morria na
// primeira linha com TypeError — este era o único dos cinco que NÃO era stub
// silencioso, e sim uma exceção que derruba o bundle inteiro.
//
// ── A DIVISÃO ENTRE OS DOIS PACOTES ─────────────────────────────────────────
// Aqui fica TUDO que é matemática: estado (cores, espessura, alfa, fonte), a
// pilha de save/restore, a matriz corrente (CTM) e o achatamento de curvas/arcos
// em polilinha. O que sai daqui é uma lista de comandos com pontos **já
// transformados para o espaço do bitmap** — nenhum deles precisa de janela, e é
// por isso que dá para testar tudo com `odin test src/js`.
//
// O pacote ui só REPLICA essa lista no draw list do ImGui (src/ui/canvas2d.odin):
// polígono preenchido, polilinha, texto e imagem. Ele não sabe o que é um bézier.
//
// ── POR QUE LISTA DE COMANDOS, E NÃO UM BITMAP ──────────────────────────────
// O canvas do navegador é um BITMAP retido: o JS desenha uma vez e o resultado
// persiste. Guardar um bitmap aqui exigiria um rasterizador próprio (fill de
// polígono côncavo com AA, juntas de traço, texto) — marco inteiro. Guardando a
// LISTA e repintando-a a cada frame chega-se ao MESMO resultado visual, porque o
// idioma universal do canvas animado é "limpa tudo e redesenha": um
// `clearRect` que cobre a superfície TRUNCA a lista (é o `dispose` natural), e o
// que sobra é sempre o desenho corrente.
// ⚠️ A degradação disso está nomeada lá embaixo: `clearRect` PARCIAL não apaga.

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import dom "../dom"

// Cor CSS → ARGB da engine. Hook porque o parser de cor mora no pacote css e o
// js não pode importá-lo (mesma razão de ciclo do g_dom_query). nil ⇒ preto.
Parse_Color_Fn :: proc(s: string) -> (u32, bool)
g_parse_color: Parse_Color_Fn

// Largura de um texto na fonte real (measureText). Sem o ui, cai numa
// aproximação — ver `canvas_measure`. Chart lib usa isto para decidir layout.
Measure_Text_Fn :: proc(text: string, px: f32) -> f32
g_measure_text: Measure_Text_Fn

Canvas_Op :: enum u8 {
    Fill_Path,   // polígono preenchido (pts[n0:n1])
    Stroke_Path, // polilinha (pts[n0:n1]), espessura lw
    Fill_Text,   // texto em (x,y)
    Draw_Image,  // imagem `text` no quadrilátero pts[n0:n1] (4 pontos)
}

Canvas_Cmd :: struct {
    op:       Canvas_Op,
    color:    u32, // já com o globalAlpha aplicado no canal alfa
    x, y:     f32, // texto: posição da BASE já transformada
    lw:       f32, // espessura do traço, já na escala da CTM
    n0, n1:   int, // fatia em `pts`
    text:     string, // fillText: o texto; Draw_Image: a URL resolvida
    font_px:  f32,
    closed:   bool,
}

// Estado gráfico (o que save/restore empilha).
Canvas_State :: struct {
    fill, stroke: u32,
    line_w:  f32,
    alpha:   f32,
    font_px: f32,
    align:   u8, // 0=start/left 1=center 2=end/right
    base:    u8, // 0=alphabetic 1=top 2=middle 3=bottom
    m:       [6]f32, // CTM: a b c d e f  (x' = a*x + c*y + e)
}

Canvas_Ctx :: struct {
    node:  rawptr,
    obj:   ^Object, // o objeto JS devolvido por getContext (identidade estável)
    cmds:  [dynamic]Canvas_Cmd,
    pts:   [dynamic][2]f32,
    path:  [dynamic][2]f32, // caminho em construção, JÁ transformado
    subs:  [dynamic]int,    // índice inicial de cada subcaminho em `path`
    st:    Canvas_State,
    stack: [dynamic]Canvas_State,
    w, h:  f32, // tamanho do BITMAP (atributos width/height)
}

// Teto de comandos retidos. Um canvas animado limpa a cada frame e nunca chega
// perto; isto é rede de segurança para quem desenha sem nunca limpar.
@(private = "file") CANVAS_CMD_MAX :: 40000
// Segmentos por curva/arco achatado (o mesmo espírito do SEG=14 do svg.odin).
@(private = "file") CURVE_SEG :: 16

@(private = "file")
canvas_state_init :: proc() -> Canvas_State {
    return Canvas_State{
        fill = 0x000000, stroke = 0x000000, line_w = 1, alpha = 1, font_px = 10,
        m = {1, 0, 0, 1, 0, 0},
    }
}

// ── entrada: el.getContext(tipo) ────────────────────────────────────────────

native_get_context :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    if node == nil do return JS_Null{}
    kind := ""
    if s, ok := arg(args, 0).(string); ok do kind = strings.to_lower(s, context.temp_allocator)
    // WebGL não existe aqui, e a resposta HONESTA é null — é o que a spec manda
    // para contexto não suportado, e todo código sério testa o retorno.
    if kind != "2d" do return JS_Null{}
    c := canvas_ctx_of(vm, node)
    if c == nil do return JS_Null{}
    return c.obj
}

// O contexto é ÚNICO por canvas (spec: duas chamadas devolvem o mesmo objeto).
@(private = "file")
canvas_ctx_of :: proc(vm: ^Interp, node: ^dom.Node) -> ^Canvas_Ctx {
    if vm.canvases == nil do vm.canvases = make(map[rawptr]^Canvas_Ctx)
    if c, ok := vm.canvases[rawptr(node)]; ok do return c
    c := new(Canvas_Ctx)
    c.node = rawptr(node)
    c.st = canvas_state_init()
    c.w, c.h = canvas_bitmap_size(node)
    o := new_object(vm)
    o.host = rawptr(node) // p/ ctx.canvas e p/ os métodos acharem o contexto
    o.get = canvas_get
    o.set = canvas_set
    metodos := [?]struct{n: string, f: Native_Fn}{
        {"save", cv_save}, {"restore", cv_restore},
        {"translate", cv_translate}, {"scale", cv_scale}, {"rotate", cv_rotate},
        {"transform", cv_transform}, {"setTransform", cv_set_transform},
        {"getTransform", cv_get_transform}, {"resetTransform", cv_reset_transform},
        {"beginPath", cv_begin_path}, {"closePath", cv_close_path},
        {"moveTo", cv_move_to}, {"lineTo", cv_line_to},
        {"bezierCurveTo", cv_bezier_to}, {"quadraticCurveTo", cv_quad_to},
        {"arc", cv_arc}, {"arcTo", cv_arc_to}, {"ellipse", cv_ellipse},
        {"rect", cv_rect}, {"roundRect", cv_round_rect},
        {"fill", cv_fill}, {"stroke", cv_stroke}, {"clip", cv_noop},
        {"fillRect", cv_fill_rect}, {"strokeRect", cv_stroke_rect}, {"clearRect", cv_clear_rect},
        {"fillText", cv_fill_text}, {"strokeText", cv_fill_text}, {"measureText", cv_measure_text},
        {"drawImage", cv_draw_image},
        {"createLinearGradient", cv_gradient}, {"createRadialGradient", cv_gradient},
        {"createPattern", cv_null_ret},
        {"setLineDash", cv_noop}, {"getLineDash", cv_empty_array}, {"setLineDashOffset", cv_noop},
    }
    for m in metodos {
        o.props[m.n] = mk_bound_obj(vm, o, m.f)
        mark_non_enumerable(o, m.n)
    }
    c.obj = o
    vm.canvases[rawptr(node)] = c
    return c
}

// Tamanho do BITMAP: os atributos width/height, com o default 300×150 da spec.
@(private = "file")
canvas_bitmap_size :: proc(node: ^dom.Node) -> (f32, f32) {
    w, h: f32 = 300, 150
    if node != nil {
        if s, ok := node.attrs["width"];  ok { if v, k := parse_f32(s); k && v > 0 do w = v }
        if s, ok := node.attrs["height"]; ok { if v, k := parse_f32(s); k && v > 0 do h = v }
    }
    return w, h
}

@(private = "file")
parse_f32 :: proc(s: string) -> (f32, bool) {
    v, ok := strconv.parse_f64(strings.trim_space(s))
    return f32(v), ok
}

// O contexto de um `this` de método nativo.
@(private = "file")
cv_self :: proc(vm: ^Interp, this: Value) -> ^Canvas_Ctx {
    o, ok := vm.native_bound.(^Object)
    if !ok do o, ok = this.(^Object)
    if !ok || o.host == nil || vm.canvases == nil do return nil
    c, has := vm.canvases[o.host]
    if !has do return nil
    return c
}

// `canvas.width = N` (e o height): a spec RESETA a superfície inteira, mesmo que
// o valor não mude. Chamado pelo set-hook do elemento em dom_bindings.
canvas_reset :: proc(vm: ^Interp, node: rawptr) {
    if vm == nil || vm.canvases == nil do return
    c, ok := vm.canvases[node]
    if !ok do return
    clear(&c.cmds)
    clear(&c.pts)
    clear(&c.path)
    clear(&c.subs)
    clear(&c.stack)
    c.st = canvas_state_init()
    c.w, c.h = canvas_bitmap_size(cast(^dom.Node) node)
}

// ── o que o pacote ui lê ────────────────────────────────────────────────────

Canvas_Draw :: struct {
    cmds: []Canvas_Cmd,
    pts:  [][2]f32,
    w, h: f32, // tamanho do bitmap (o ui escala p/ a caixa CSS)
}

canvas_draw_of :: proc(vm: ^Interp, node: rawptr) -> (Canvas_Draw, bool) {
    if vm == nil || vm.canvases == nil do return {}, false
    c, ok := vm.canvases[node]
    if !ok || len(c.cmds) == 0 do return {}, false
    return Canvas_Draw{c.cmds[:], c.pts[:], c.w, c.h}, true
}

canvas_free :: proc(vm: ^Interp) {
    if vm.canvases == nil do return
    for _, c in vm.canvases {
        delete(c.cmds); delete(c.pts); delete(c.path); delete(c.subs); delete(c.stack)
        free(c)
    }
    delete(vm.canvases)
    vm.canvases = nil
}

// ── propriedades (get/set hooks do objeto de contexto) ──────────────────────

@(private = "file")
canvas_get :: proc(vm: ^Interp, o: ^Object, name: string) -> (Value, bool) {
    c: ^Canvas_Ctx
    if vm.canvases != nil do c = vm.canvases[o.host]
    if c == nil {
        if v, has := o.props[name]; has do return v, true
        return nil, false
    }
    switch name {
    case "canvas":        return wrap_element(vm, cast(^dom.Node) c.node), true
    case "fillStyle":     return own_str(vm, css_color_str(c.st.fill)), true
    case "strokeStyle":   return own_str(vm, css_color_str(c.st.stroke)), true
    case "lineWidth":     return f64(c.st.line_w), true
    case "globalAlpha":   return f64(c.st.alpha), true
    case "font":          return own_str(vm, canvas_font_str(c.st.font_px)), true
    case "textAlign":
        nomes := [?]string{"start", "center", "end"}
        return own_str(vm, nomes[c.st.align]), true
    case "textBaseline":
        nomes := [?]string{"alphabetic", "top", "middle", "bottom"}
        return own_str(vm, nomes[c.st.base]), true
    }
    if v, has := o.props[name]; has do return v, true
    return nil, false
}

@(private = "file")
canvas_set :: proc(vm: ^Interp, o: ^Object, name: string, val: Value) -> bool {
    c: ^Canvas_Ctx
    if vm.canvases != nil do c = vm.canvases[o.host]
    if c == nil {
        o.props[name] = val
        return true
    }
    switch name {
    case "fillStyle":
        c.st.fill = canvas_color(vm, val, c.st.fill)
    case "strokeStyle":
        c.st.stroke = canvas_color(vm, val, c.st.stroke)
    case "lineWidth":
        v := to_number(vm, val)
        if v > 0 do c.st.line_w = f32(v)
    case "globalAlpha":
        v := to_number(vm, val)
        if v >= 0 && v <= 1 do c.st.alpha = f32(v)
    case "font":
        if s, ok := val.(string); ok do c.st.font_px = canvas_font_px(s, c.st.font_px)
    case "textAlign":
        if s, ok := val.(string); ok {
            switch s {
            case "center":            c.st.align = 1
            case "right", "end":      c.st.align = 2
            case:                     c.st.align = 0
            }
        }
    case "textBaseline":
        if s, ok := val.(string); ok {
            switch s {
            case "top", "hanging":    c.st.base = 1
            case "middle":            c.st.base = 2
            case "bottom", "ideographic": c.st.base = 3
            case:                     c.st.base = 0
            }
        }
    case:
        o.props[name] = val // lineCap/lineJoin/shadow*/globalCompositeOperation: guardados e IGNORADOS
    }
    return true
}

// `fillStyle` aceita string OU o objeto de gradiente (ver cv_gradient).
@(private = "file")
canvas_color :: proc(vm: ^Interp, val: Value, cur: u32) -> u32 {
    if s, ok := val.(string); ok {
        if g_parse_color != nil {
            if c, k := g_parse_color(s); k do return c
            return cur // string que não parseia: a spec manda IGNORAR (mantém a anterior)
        }
        return 0x000000
    }
    if o, ok := val.(^Object); ok {
        if v, has := o.props["#grad1"]; has do return u32(as_number(v))
    }
    return cur
}

// ⚠️ o buffer TEM de ser da arena temp, não da pilha: a 1ª versão devolvia
// `string(buf[:])` de um array LOCAL, e o `own_str` do chamador clonava memória
// já morta — `ctx.fillStyle` lia vazio. Quem pegou foi a sonda, não os testes de
// unidade (que só olham a cor no COMANDO, não o getter).
@(private = "file")
css_color_str :: proc(c: u32) -> string {
    return fmt.tprintf("#%06x", c & 0xFFFFFF)
}

// `font: bold 12px Arial` → 12. Só o TAMANHO é honrado (ver degradações).
@(private = "file")
canvas_font_px :: proc(s: string, cur: f32) -> f32 {
    i := 0
    for i < len(s) {
        // acha um número seguido de px/pt/em/rem
        if s[i] >= '0' && s[i] <= '9' {
            j := i
            for j < len(s) && ((s[j] >= '0' && s[j] <= '9') || s[j] == '.') do j += 1
            v, ok := strconv.parse_f64(s[i:j])
            if ok {
                unit := s[j:]
                if strings.has_prefix(unit, "pt")       do return f32(v) * 4.0 / 3.0
                if strings.has_prefix(unit, "em")       do return f32(v) * 16
                if strings.has_prefix(unit, "rem")      do return f32(v) * 16
                return f32(v) // px (ou sem unidade)
            }
            i = j
        } else {
            i += 1
        }
    }
    return cur
}

@(private = "file")
canvas_font_str :: proc(px: f32) -> string {
    return fmt.tprintf("%vpx sans-serif", px)
}

// ── matriz e caminho ────────────────────────────────────────────────────────

@(private = "file")
cv_pt :: proc(c: ^Canvas_Ctx, x, y: f32) -> [2]f32 {
    m := c.st.m
    return {m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5]}
}

// Fator de escala da CTM (√|det|) — é o que multiplica a espessura do traço.
@(private = "file")
cv_scale_of :: proc(c: ^Canvas_Ctx) -> f32 {
    m := c.st.m
    d := abs(m[0] * m[3] - m[1] * m[2])
    if d <= 0 do return 1
    return math.sqrt(d)
}

@(private = "file")
cv_mul :: proc(a, b: [6]f32) -> [6]f32 { // b APLICADA ANTES de a (a ∘ b)
    return {
        a[0] * b[0] + a[2] * b[1],
        a[1] * b[0] + a[3] * b[1],
        a[0] * b[2] + a[2] * b[3],
        a[1] * b[2] + a[3] * b[3],
        a[0] * b[4] + a[2] * b[5] + a[4],
        a[1] * b[4] + a[3] * b[5] + a[5],
    }
}

@(private = "file")
cv_argf :: proc(vm: ^Interp, a: []Value, i: int) -> f32 {
    return f32(to_number(vm, arg(a, i)))
}

@(private = "file") cv_noop        :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return nil }
@(private = "file") cv_null_ret    :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return JS_Null{} }
@(private = "file") cv_empty_array :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return new_array(vm) }

@(private = "file")
cv_save :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    c := cv_self(vm, this); if c == nil do return nil
    append(&c.stack, c.st)
    return nil
}

@(private = "file")
cv_restore :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    c := cv_self(vm, this); if c == nil do return nil
    if len(c.stack) == 0 do return nil // restore sem save: no-op (spec)
    c.st = pop(&c.stack)
    return nil
}

@(private = "file")
cv_translate :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    c := cv_self(vm, this); if c == nil do return nil
    c.st.m = cv_mul(c.st.m, {1, 0, 0, 1, cv_argf(vm, a, 0), cv_argf(vm, a, 1)})
    return nil
}

@(private = "file")
cv_scale :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    c := cv_self(vm, this); if c == nil do return nil
    c.st.m = cv_mul(c.st.m, {cv_argf(vm, a, 0), 0, 0, cv_argf(vm, a, 1), 0, 0})
    return nil
}

@(private = "file")
cv_rotate :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    c := cv_self(vm, this); if c == nil do return nil
    r := cv_argf(vm, a, 0)
    s, co := math.sin(r), math.cos(r)
    c.st.m = cv_mul(c.st.m, {co, s, -s, co, 0, 0})
    return nil
}

@(private = "file")
cv_transform :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    c := cv_self(vm, this); if c == nil do return nil
    c.st.m = cv_mul(c.st.m, {cv_argf(vm, a, 0), cv_argf(vm, a, 1), cv_argf(vm, a, 2),
                             cv_argf(vm, a, 3), cv_argf(vm, a, 4), cv_argf(vm, a, 5)})
    return nil
}

@(private = "file")
cv_set_transform :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    c := cv_self(vm, this); if c == nil do return nil
    if len(a) >= 6 {
        c.st.m = {cv_argf(vm, a, 0), cv_argf(vm, a, 1), cv_argf(vm, a, 2),
                  cv_argf(vm, a, 3), cv_argf(vm, a, 4), cv_argf(vm, a, 5)}
    } else if o, ok := arg(a, 0).(^Object); ok {
        // setTransform(DOMMatrix) / setTransform({a,b,c,d,e,f}) — a outra forma
        // da assinatura; sem ela `setTransform(getTransform())` zerava a CTM.
        c.st.m = {f32(as_number(o.props["m11"])), f32(as_number(o.props["m12"])),
                  f32(as_number(o.props["m21"])), f32(as_number(o.props["m22"])),
                  f32(as_number(o.props["m41"])), f32(as_number(o.props["m42"]))}
    } else {
        c.st.m = {1, 0, 0, 1, 0, 0}
    }
    return nil
}

// ctx.getTransform(): a CTM corrente como DOMMatrix. É a fonte CANÔNICA de
// DOMMatrix em código de página — sem ela, `ctx.getTransform().a` continuaria
// TypeError e o construtor novo ficaria sem produtor do lado do DOM.
// ⚠️ `setTransform` já aceitava 6 números; agora aceita também uma matriz (é a
// outra metade da assinatura da spec, e é o que faz `setTransform(getTransform())`
// — o idioma de salvar/restaurar CTM — funcionar).
@(private = "file")
cv_get_transform :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    c := cv_self(vm, this); if c == nil do return nil
    return dommatrix_from_2d(vm, f64(c.st.m[0]), f64(c.st.m[1]), f64(c.st.m[2]),
                                 f64(c.st.m[3]), f64(c.st.m[4]), f64(c.st.m[5]))
}

@(private = "file")
cv_reset_transform :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    c := cv_self(vm, this); if c == nil do return nil
    c.st.m = {1, 0, 0, 1, 0, 0}
    return nil
}

@(private = "file")
cv_begin_path :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    c := cv_self(vm, this); if c == nil do return nil
    clear(&c.path)
    clear(&c.subs)
    return nil
}

@(private = "file")
cv_move_to :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    c := cv_self(vm, this); if c == nil do return nil
    append(&c.subs, len(c.path))
    append(&c.path, cv_pt(c, cv_argf(vm, a, 0), cv_argf(vm, a, 1)))
    return nil
}

@(private = "file")
cv_line_to :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    c := cv_self(vm, this); if c == nil do return nil
    if len(c.path) == 0 do append(&c.subs, 0)
    append(&c.path, cv_pt(c, cv_argf(vm, a, 0), cv_argf(vm, a, 1)))
    return nil
}

@(private = "file")
cv_close_path :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    c := cv_self(vm, this); if c == nil do return nil
    if len(c.subs) == 0 || len(c.path) == 0 do return nil
    start := c.subs[len(c.subs) - 1]
    if start < len(c.path) do append(&c.path, c.path[start])
    return nil
}

// Bézier cúbica achatada (o ponto atual é o de partida).
@(private = "file")
cv_bezier_to :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    c := cv_self(vm, this); if c == nil || len(c.path) == 0 do return nil
    p0 := c.path[len(c.path) - 1]
    p1 := cv_pt(c, cv_argf(vm, a, 0), cv_argf(vm, a, 1))
    p2 := cv_pt(c, cv_argf(vm, a, 2), cv_argf(vm, a, 3))
    p3 := cv_pt(c, cv_argf(vm, a, 4), cv_argf(vm, a, 5))
    for i in 1 ..= CURVE_SEG {
        t := f32(i) / f32(CURVE_SEG)
        u := 1 - t
        x := u*u*u*p0.x + 3*u*u*t*p1.x + 3*u*t*t*p2.x + t*t*t*p3.x
        y := u*u*u*p0.y + 3*u*u*t*p1.y + 3*u*t*t*p2.y + t*t*t*p3.y
        append(&c.path, [2]f32{x, y})
    }
    return nil
}

@(private = "file")
cv_quad_to :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    c := cv_self(vm, this); if c == nil || len(c.path) == 0 do return nil
    p0 := c.path[len(c.path) - 1]
    p1 := cv_pt(c, cv_argf(vm, a, 0), cv_argf(vm, a, 1))
    p2 := cv_pt(c, cv_argf(vm, a, 2), cv_argf(vm, a, 3))
    for i in 1 ..= CURVE_SEG {
        t := f32(i) / f32(CURVE_SEG)
        u := 1 - t
        append(&c.path, [2]f32{u*u*p0.x + 2*u*t*p1.x + t*t*p2.x, u*u*p0.y + 2*u*t*p1.y + t*t*p2.y})
    }
    return nil
}

// arc(x, y, r, a0, a1, ccw): achatado em segmentos no espaço do CANVAS (antes da
// CTM), então uma CTM com escala não-uniforme deforma o arco como deve.
@(private = "file")
cv_arc :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    c := cv_self(vm, this); if c == nil do return nil
    cx, cy, r := cv_argf(vm, a, 0), cv_argf(vm, a, 1), cv_argf(vm, a, 2)
    a0, a1 := cv_argf(vm, a, 3), cv_argf(vm, a, 4)
    ccw := truthy(arg(a, 5))
    cv_arc_pts(c, cx, cy, r, r, 0, a0, a1, ccw)
    return nil
}

@(private = "file")
cv_ellipse :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    c := cv_self(vm, this); if c == nil do return nil
    cx, cy := cv_argf(vm, a, 0), cv_argf(vm, a, 1)
    rx, ry := cv_argf(vm, a, 2), cv_argf(vm, a, 3)
    rot := cv_argf(vm, a, 4)
    a0, a1 := cv_argf(vm, a, 5), cv_argf(vm, a, 6)
    ccw := truthy(arg(a, 7))
    cv_arc_pts(c, cx, cy, rx, ry, rot, a0, a1, ccw)
    return nil
}

@(private = "file")
cv_arc_pts :: proc(c: ^Canvas_Ctx, cx, cy, rx, ry, rot, a0, a1: f32, ccw: bool) {
    sweep := a1 - a0
    TAU :: f32(2 * math.PI)
    if ccw {
        for sweep > 0    do sweep -= TAU
        if sweep < -TAU  do sweep = -TAU
    } else {
        for sweep < 0    do sweep += TAU
        if sweep > TAU   do sweep = TAU
    }
    // nº de segmentos proporcional ao ângulo (arco de 360° não pode ter 16)
    n := int(abs(sweep) / (TAU) * 64) + 2
    if n > 128 do n = 128
    cr, sr := math.cos(rot), math.sin(rot)
    if len(c.path) == 0 do append(&c.subs, 0)
    for i in 0 ..= n {
        t := a0 + sweep * f32(i) / f32(n)
        ex, ey := rx * math.cos(t), ry * math.sin(t)
        append(&c.path, cv_pt(c, cx + ex * cr - ey * sr, cy + ex * sr + ey * cr))
    }
}

// arcTo(x1,y1,x2,y2,r): o arco tangente aos dois segmentos (o idioma de canto
// arredondado feito à mão, que ainda é o mais comum em código de gráfico).
@(private = "file")
cv_arc_to :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    c := cv_self(vm, this); if c == nil do return nil
    x1, y1 := cv_argf(vm, a, 0), cv_argf(vm, a, 1)
    x2, y2 := cv_argf(vm, a, 2), cv_argf(vm, a, 3)
    r := cv_argf(vm, a, 4)
    if len(c.path) == 0 {
        append(&c.subs, 0)
        append(&c.path, cv_pt(c, x1, y1))
        return nil
    }
    // ponto atual em espaço de CANVAS: inverte a CTM sobre o último ponto seria
    // caro; em vez disso guardamos o último ponto do path (já transformado) e
    // fazemos a geometria no espaço transformado, com o raio na escala da CTM.
    p0 := c.path[len(c.path) - 1]
    p1 := cv_pt(c, x1, y1)
    p2 := cv_pt(c, x2, y2)
    rr := r * cv_scale_of(c)
    v1 := [2]f32{p0.x - p1.x, p0.y - p1.y}
    v2 := [2]f32{p2.x - p1.x, p2.y - p1.y}
    l1 := math.sqrt(v1.x * v1.x + v1.y * v1.y)
    l2 := math.sqrt(v2.x * v2.x + v2.y * v2.y)
    if l1 == 0 || l2 == 0 || rr <= 0 {
        append(&c.path, p1)
        return nil
    }
    u1 := [2]f32{v1.x / l1, v1.y / l1}
    u2 := [2]f32{v2.x / l2, v2.y / l2}
    cosang := u1.x * u2.x + u1.y * u2.y
    cosang = clamp(cosang, -1, 1)
    ang := math.acos(cosang)
    if ang < 0.0001 || abs(ang - f32(math.PI)) < 0.0001 {
        append(&c.path, p1)
        return nil
    }
    d := rr / math.tan(ang / 2) // distância do vértice aos pontos de tangência
    if d > l1 do d = l1
    if d > l2 do d = l2
    t1 := [2]f32{p1.x + u1.x * d, p1.y + u1.y * d}
    t2 := [2]f32{p1.x + u2.x * d, p1.y + u2.y * d}
    append(&c.path, t1)
    // arco aproximado por bézier quadrática com controle no vértice: erro < 1%
    // para os ângulos de canto usuais, e sem trigonometria de centro.
    for i in 1 ..= 8 {
        t := f32(i) / 8
        u := 1 - t
        append(&c.path, [2]f32{u*u*t1.x + 2*u*t*p1.x + t*t*t2.x, u*u*t1.y + 2*u*t*p1.y + t*t*t2.y})
    }
    return nil
}

@(private = "file")
cv_rect :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    c := cv_self(vm, this); if c == nil do return nil
    x, y := cv_argf(vm, a, 0), cv_argf(vm, a, 1)
    w, h := cv_argf(vm, a, 2), cv_argf(vm, a, 3)
    append(&c.subs, len(c.path))
    append(&c.path, cv_pt(c, x, y), cv_pt(c, x + w, y), cv_pt(c, x + w, y + h), cv_pt(c, x, y + h), cv_pt(c, x, y))
    return nil
}

@(private = "file")
cv_round_rect :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    c := cv_self(vm, this); if c == nil do return nil
    x, y := cv_argf(vm, a, 0), cv_argf(vm, a, 1)
    w, h := cv_argf(vm, a, 2), cv_argf(vm, a, 3)
    r := cv_argf(vm, a, 4)
    if arr, ok := arg(a, 4).(^Array); ok && len(arr.items) > 0 do r = f32(as_number(arr.items[0]))
    if r <= 0 do return cv_rect(vm, this, a)
    r = min(r, min(abs(w), abs(h)) / 2)
    append(&c.subs, len(c.path))
    append(&c.path, cv_pt(c, x + r, y))
    cv_corner(c, x + w - r, y + r, r, -f32(math.PI) / 2, 0)
    cv_corner(c, x + w - r, y + h - r, r, 0, f32(math.PI) / 2)
    cv_corner(c, x + r, y + h - r, r, f32(math.PI) / 2, f32(math.PI))
    cv_corner(c, x + r, y + r, r, f32(math.PI), 3 * f32(math.PI) / 2)
    append(&c.path, cv_pt(c, x + r, y))
    return nil
}

@(private = "file")
cv_corner :: proc(c: ^Canvas_Ctx, cx, cy, r, a0, a1: f32) {
    for i in 0 ..= 8 {
        t := a0 + (a1 - a0) * f32(i) / 8
        append(&c.path, cv_pt(c, cx + r * math.cos(t), cy + r * math.sin(t)))
    }
}

// ── comandos de desenho ─────────────────────────────────────────────────────

@(private = "file")
cv_emit_path :: proc(c: ^Canvas_Ctx, op: Canvas_Op, color: u32, lw: f32) {
    if len(c.cmds) >= CANVAS_CMD_MAX do return
    // cada SUBCAMINHO vira um comando (preencher subcaminhos separados como um
    // polígono só ligaria formas que não se tocam)
    for si in 0 ..< len(c.subs) {
        start := c.subs[si]
        end := si + 1 < len(c.subs) ? c.subs[si + 1] : len(c.path)
        if end - start < 2 do continue
        n0 := len(c.pts)
        for i in start ..< end do append(&c.pts, c.path[i])
        append(&c.cmds, Canvas_Cmd{op = op, color = color, lw = lw, n0 = n0, n1 = len(c.pts)})
    }
}

// ⚠️ Convenção de cor da engine (ver `vec()` no browser_ui.odin): o byte ALTO é
// o alfa em 0..255, com o valor 0 significando OPACO por retrocompatibilidade
// com as cores 0xRRGGBB. Logo alfa 0 não é representável — vira 1 (invisível na
// prática), e nunca 0, que viraria OPACO e desenharia o que devia sumir.
@(private = "file")
cv_alpha :: proc(color: u32, alpha: f32) -> u32 {
    ab := u32(clamp(alpha, 0, 1) * 255)
    if ab == 0 do ab = 1
    return (color & 0x00FFFFFF) | (ab << 24)
}

@(private = "file")
cv_fill :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    c := cv_self(vm, this); if c == nil do return nil
    cv_emit_path(c, .Fill_Path, cv_alpha(c.st.fill, c.st.alpha), 0)
    return nil
}

@(private = "file")
cv_stroke :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    c := cv_self(vm, this); if c == nil do return nil
    cv_emit_path(c, .Stroke_Path, cv_alpha(c.st.stroke, c.st.alpha), c.st.line_w * cv_scale_of(c))
    return nil
}

// Retângulo como caminho de 4 pontos: assim a CTM com rotação funciona sem que o
// ui precise saber o que é uma matriz.
@(private = "file")
cv_rect_pts :: proc(c: ^Canvas_Ctx, x, y, w, h: f32) -> (int, int) {
    n0 := len(c.pts)
    append(&c.pts, cv_pt(c, x, y), cv_pt(c, x + w, y), cv_pt(c, x + w, y + h), cv_pt(c, x, y + h), cv_pt(c, x, y))
    return n0, len(c.pts)
}

@(private = "file")
cv_fill_rect :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    c := cv_self(vm, this); if c == nil || len(c.cmds) >= CANVAS_CMD_MAX do return nil
    n0, n1 := cv_rect_pts(c, cv_argf(vm, a, 0), cv_argf(vm, a, 1), cv_argf(vm, a, 2), cv_argf(vm, a, 3))
    append(&c.cmds, Canvas_Cmd{op = .Fill_Path, color = cv_alpha(c.st.fill, c.st.alpha), n0 = n0, n1 = n1})
    return nil
}

@(private = "file")
cv_stroke_rect :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    c := cv_self(vm, this); if c == nil || len(c.cmds) >= CANVAS_CMD_MAX do return nil
    n0, n1 := cv_rect_pts(c, cv_argf(vm, a, 0), cv_argf(vm, a, 1), cv_argf(vm, a, 2), cv_argf(vm, a, 3))
    append(&c.cmds, Canvas_Cmd{op = .Stroke_Path, color = cv_alpha(c.st.stroke, c.st.alpha),
                               lw = c.st.line_w * cv_scale_of(c), n0 = n0, n1 = n1})
    return nil
}

// clearRect: quando cobre a superfície inteira, TRUNCA a lista — é o "limpa e
// redesenha" de todo canvas animado, e é o que impede a lista de crescer sem fim.
// ⚠️ DEGRADAÇÃO NOMEADA: clearRect PARCIAL não apaga nada (numa lista de
// comandos não há pixel para apagar). Quem limpa um pedaço e conta com isso vê
// o desenho antigo por baixo.
@(private = "file")
cv_clear_rect :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    c := cv_self(vm, this); if c == nil do return nil
    x, y := cv_argf(vm, a, 0), cv_argf(vm, a, 1)
    w, h := cv_argf(vm, a, 2), cv_argf(vm, a, 3)
    p0 := cv_pt(c, x, y)
    p1 := cv_pt(c, x + w, y + h)
    lo := [2]f32{min(p0.x, p1.x), min(p0.y, p1.y)}
    hi := [2]f32{max(p0.x, p1.x), max(p0.y, p1.y)}
    if lo.x <= 0.5 && lo.y <= 0.5 && hi.x >= c.w - 0.5 && hi.y >= c.h - 0.5 {
        clear(&c.cmds)
        clear(&c.pts)
    }
    return nil
}

@(private = "file")
cv_fill_text :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    c := cv_self(vm, this); if c == nil || len(c.cmds) >= CANVAS_CMD_MAX do return nil
    txt, ok := arg(a, 0).(string)
    if !ok {
        sb: strings.Builder
        strings.builder_init(&sb)
        defer strings.builder_destroy(&sb)
        to_text(&sb, arg(a, 0))
        txt = strings.to_string(sb)
    }
    if txt == "" do return nil
    p := cv_pt(c, cv_argf(vm, a, 1), cv_argf(vm, a, 2))
    sc := cv_scale_of(c)
    px := c.st.font_px * sc
    wid := canvas_measure(txt, px)
    x := p.x
    switch c.st.align {
    case 1: x -= wid / 2
    case 2: x -= wid
    }
    y := p.y
    switch c.st.base { // o ui pinta com o TOPO do glifo em y
    case 0: y -= px * 0.8  // alphabetic: a base fica ~80% abaixo do topo
    case 2: y -= px * 0.5
    case 3: y -= px
    }
    append(&c.cmds, Canvas_Cmd{op = .Fill_Text, color = cv_alpha(c.st.fill, c.st.alpha),
                               x = x, y = y, font_px = px, text = own_str_raw(vm, txt)})
    return nil
}

@(private = "file")
cv_measure_text :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    c := cv_self(vm, this)
    txt, _ := arg(a, 0).(string)
    px := c != nil ? c.st.font_px * cv_scale_of(c) : 10
    o := new_object(vm)
    w := canvas_measure(txt, px)
    o.props["width"] = f64(w)
    // As caixas de metade da spec, aproximadas pela mesma escala do fillText.
    o.props["actualBoundingBoxAscent"]  = f64(px * 0.8)
    o.props["actualBoundingBoxDescent"] = f64(px * 0.2)
    o.props["actualBoundingBoxLeft"]    = f64(0)
    o.props["actualBoundingBoxRight"]   = f64(w)
    o.props["fontBoundingBoxAscent"]    = f64(px * 0.8)
    o.props["fontBoundingBoxDescent"]   = f64(px * 0.2)
    return o
}

// Largura de texto: a fonte REAL pelo hook do ui; sem ele (odin test src/js),
// uma aproximação declarada — nunca zero, que faria todo layout de rótulo
// colapsar em silêncio.
@(private = "file")
canvas_measure :: proc(txt: string, px: f32) -> f32 {
    if g_measure_text != nil do return g_measure_text(txt, px)
    return f32(len(txt)) * px * 0.5
}

@(private = "file")
cv_draw_image :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    c := cv_self(vm, this); if c == nil || len(c.cmds) >= CANVAS_CMD_MAX do return nil
    src, ok := arg(a, 0).(^Object)
    if !ok || src.host == nil do return nil
    node := cast(^dom.Node) src.host
    url, has := node.attrs["src"]
    if !has || url == "" do return nil
    // formas: (img, dx, dy) | (img, dx, dy, dw, dh) | (img, sx,sy,sw,sh, dx,dy,dw,dh)
    dx, dy, dw, dh: f32
    switch len(a) {
    case 3:
        dx, dy = cv_argf(vm, a, 1), cv_argf(vm, a, 2)
        dw, dh = 0, 0 // tamanho natural: o ui resolve pelo cache
    case 5:
        dx, dy = cv_argf(vm, a, 1), cv_argf(vm, a, 2)
        dw, dh = cv_argf(vm, a, 3), cv_argf(vm, a, 4)
    case 9:
        dx, dy = cv_argf(vm, a, 5), cv_argf(vm, a, 6)
        dw, dh = cv_argf(vm, a, 7), cv_argf(vm, a, 8)
    case:
        return nil
    }
    n0, n1 := cv_rect_pts(c, dx, dy, dw, dh)
    append(&c.cmds, Canvas_Cmd{op = .Draw_Image, color = cv_alpha(0xFFFFFF, c.st.alpha),
                               n0 = n0, n1 = n1, text = own_str_raw(vm, url),
                               x = dw, y = dh}) // 0,0 = usar o tamanho natural
    return nil
}

// Gradiente: objeto com addColorStop. ⚠️ DEGRADAÇÃO NOMEADA — usamos a PRIMEIRA
// cor parada como cor sólida. Um gráfico com gradiente sai chapado, mas com a
// cor certa da família; devolver preto (ou nada) seria pior e mais confuso.
@(private = "file")
cv_gradient :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    g := new_object(vm)
    g.props["addColorStop"] = mk_bound_obj(vm, g, cv_add_color_stop)
    mark_non_enumerable(g, "addColorStop")
    return g
}

@(private = "file")
cv_add_color_stop :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    o, ok := vm.native_bound.(^Object)
    if !ok do o, ok = this.(^Object)
    if !ok do return nil
    if _, has := o.props["#grad1"]; has do return nil // só a 1ª parada
    if s, sok := arg(a, 1).(string); sok && g_parse_color != nil {
        if col, k := g_parse_color(s); k do o.props["#grad1"] = f64(col)
    }
    return nil
}
