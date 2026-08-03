package js

// DOMMatrix / DOMMatrixReadOnly / DOMPoint (+ o alias legado WebKitCSSMatrix).
//
// Era `DOMMatrix is not a constructor`. O uso dominante em site real é
// `new DOMMatrix(getComputedStyle(el).transform)` seguido de leitura de `.a`..`.f`
// ou `.m41`/`.m42`, e composição por `multiply`/`translate`/`scale`/`rotate`.
//
// ── Convenção (a parte fácil de errar) ──────────────────────────────────────
// `mIJ` é COLUNA I, LINHA J. A transformação de um ponto é
//     x' = m11·x + m21·y + m31·z + m41·w
//     y' = m12·x + m22·y + m32·z + m42·w   (idem z' e w')
// Guardamos os 16 valores em COLUNA-MAIOR (`idx = (col-1)*4 + (row-1)`), que é
// exatamente a ordem que `toFloat64Array` tem de devolver — assim não existe uma
// segunda convenção interna para divergir da externa.
// Aliases 2D: a=m11 b=m12 c=m21 d=m22 e=m41 f=m42.
//
// ⚠️ Os 16 valores ficam em PROPS normais do objeto (`m11`..`m44`); só os
// aliases 2D e os derivados (`is2D`/`isIdentity`) passam pelo get/set hook. Sem
// isso haveria duas cópias do estado — o padrão que já mordeu este repo.
//
// Degradações anotadas: sem `skewX`/`skewY` e sem os construtores a partir de
// `DOMMatrixInit` (o dicionário `{a:1,b:0,…}`) — só de array, string, outra
// matriz e vazio. `inverse()` de matriz singular devolve todos NaN, como manda a
// spec (e não uma identidade silenciosa, que seria erro invisível).

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"

@(private = "file")
DM_NAMES := [16]string{
    "m11", "m12", "m13", "m14",
    "m21", "m22", "m23", "m24",
    "m31", "m32", "m33", "m34",
    "m41", "m42", "m43", "m44",
}

// alias 2D → índice no vetor coluna-maior
@(private = "file")
dm_alias_idx :: proc(name: string) -> (int, bool) {
    switch name {
    case "a": return 0, true  // m11
    case "b": return 1, true  // m12
    case "c": return 4, true  // m21
    case "d": return 5, true  // m22
    case "e": return 12, true // m41
    case "f": return 13, true // m42
    }
    return 0, false
}

// Lê uma prop numérica com DEFAULT quando ausente.
// ⚠️ Existe porque `as_number(nil)` é NaN (correto — `Number(undefined)` é NaN),
// e um único campo ausente contamina a conta inteira. Foi o que aconteceu:
// `transformPoint({x,y})` sem `z` devolvia NaN,NaN com a matriz perfeita. Só o
// teste com ORÁCULO DE PONTO pegou; conferir as entradas da matriz não pega.
@(private = "file")
num_or :: proc(o: ^Object, key: string, def: f64) -> f64 {
    if o == nil do return def
    v, has := o.props[key]
    if !has || v == nil do return def
    return as_number(v)
}

@(private = "file")
dm_identity :: proc() -> (m: [16]f64) {
    m[0], m[5], m[10], m[15] = 1, 1, 1, 1
    return
}

@(private = "file")
dm_read :: proc(o: ^Object) -> (m: [16]f64) {
    for n, i in DM_NAMES do m[i] = as_number(o.props[n])
    return
}

@(private = "file")
dm_write :: proc(o: ^Object, m: [16]f64) {
    for n, i in DM_NAMES do o.props[n] = m[i]
}

// A·B — aplica B primeiro, depois A (é o que `a.multiply(b)` significa).
// r[col][row] = Σ_k A[k][row] · B[col][k]
@(private = "file")
dm_mul :: proc(a, b: [16]f64) -> (r: [16]f64) {
    for col in 0 ..< 4 {
        for row in 0 ..< 4 {
            s := 0.0
            for k in 0 ..< 4 do s += a[k * 4 + row] * b[col * 4 + k]
            r[col * 4 + row] = s
        }
    }
    return
}

@(private = "file")
dm_is_2d :: proc(m: [16]f64) -> bool {
    return m[2] == 0 && m[3] == 0 && m[6] == 0 && m[7] == 0 &&
           m[8] == 0 && m[9] == 0 && m[10] == 1 && m[11] == 0 &&
           m[14] == 0 && m[15] == 1
}

@(private = "file")
dm_is_identity :: proc(m: [16]f64) -> bool {
    id := dm_identity()
    for i in 0 ..< 16 do if m[i] != id[i] do return false
    return true
}

// ── parse de string CSS ─────────────────────────────────────────────────────
// "none"/"" → identidade; "matrix(a,b,c,d,e,f)"; "matrix3d(16 valores)".
// Qualquer outra coisa NÃO é aceita em silêncio: a spec manda SyntaxError, e é o
// que o chamador precisa para não seguir com uma identidade inventada.
@(private = "file")
dm_from_string :: proc(s0: string) -> (m: [16]f64, ok: bool) {
    s := strings.trim_space(s0)
    if s == "" || s == "none" do return dm_identity(), true
    lp := strings.index_byte(s, '(')
    if lp < 0 || !strings.has_suffix(s, ")") do return dm_identity(), false
    fn := strings.trim_space(s[:lp])
    body := s[lp + 1:len(s) - 1]
    want := 0
    switch fn {
    case "matrix":   want = 6
    case "matrix3d": want = 16
    case:            return dm_identity(), false
    }
    vals: [16]f64
    n := 0
    for part in strings.split_iterator(&body, ",") {
        if n >= want do return dm_identity(), false
        v, pok := strconv.parse_f64(strings.trim_space(part))
        if !pok do return dm_identity(), false
        vals[n] = v
        n += 1
    }
    if n != want do return dm_identity(), false
    if want == 16 do return vals, true
    m = dm_identity() // matrix(a,b,c,d,e,f) → só os 6 aliases 2D mudam
    m[0], m[1], m[4], m[5], m[12], m[13] = vals[0], vals[1], vals[2], vals[3], vals[4], vals[5]
    return m, true
}

// ── objeto ──────────────────────────────────────────────────────────────────

@(private = "file")
dm_get :: proc(vm: ^Interp, o: ^Object, name: string) -> (Value, bool) {
    if i, ok := dm_alias_idx(name); ok do return as_number(o.props[DM_NAMES[i]]), true
    switch name {
    case "is2D":       return dm_is_2d(dm_read(o)), true
    case "isIdentity": return dm_is_identity(dm_read(o)), true
    }
    return nil, false // m11..m44 e os métodos seguem pelo caminho normal
}

@(private = "file")
dm_set :: proc(vm: ^Interp, o: ^Object, name: string, val: Value) -> bool {
    if truthy(o.props["__ro"]) do return true // DOMMatrixReadOnly: escrita é no-op
    if i, ok := dm_alias_idx(name); ok {
        o.props[DM_NAMES[i]] = to_number(vm, val)
        return true
    }
    return false
}

// Cria a instância. `ro` escolhe o prototype (DOMMatrix × DOMMatrixReadOnly) e
// desliga a escrita.
@(private = "file")
dm_new :: proc(vm: ^Interp, m: [16]f64, ro: bool) -> ^Object {
    o := new_object(vm)
    o.proto = ro ? vm.dommatrix_ro_proto : vm.dommatrix_proto
    o.get, o.set = dm_get, dm_set
    dm_write(o, m)
    if ro do o.props["__ro"] = true
    if ro do mark_non_enumerable(o, "__ro")
    return o
}

// Lê "uma matriz" de um Value: instância nossa, array de 6/16, string CSS ou
// nada (identidade). ok=false só quando a STRING é inválida (aí é SyntaxError).
@(private = "file")
dm_coerce :: proc(vm: ^Interp, v: Value) -> (m: [16]f64, ok: bool) {
    #partial switch t in v {
    case nil:
        return dm_identity(), true
    case string:
        return dm_from_string(t)
    case ^Array:
        if len(t.items) == 16 {
            for i in 0 ..< 16 do m[i] = as_number(t.items[i])
            return m, true
        }
        if len(t.items) == 6 {
            m = dm_identity()
            m[0], m[1], m[4], m[5], m[12], m[13] =
                as_number(t.items[0]), as_number(t.items[1]), as_number(t.items[2]),
                as_number(t.items[3]), as_number(t.items[4]), as_number(t.items[5])
            return m, true
        }
        return dm_identity(), false
    case ^Object:
        // outra DOMMatrix (ou qualquer objeto com m11..m44 / a..f)
        if _, has := t.props["m11"]; has do return dm_read(t), true
        m = dm_identity()
        if _, has := t.props["a"]; has { // dicionário {a,b,c,d,e,f} parcial é legal
            m[0], m[1] = num_or(t, "a", 1), num_or(t, "b", 0)
            m[4], m[5] = num_or(t, "c", 0), num_or(t, "d", 1)
            m[12], m[13] = num_or(t, "e", 0), num_or(t, "f", 0)
        }
        return m, true
    }
    return dm_identity(), true
}

@(private = "file")
dm_throw_syntax :: proc(vm: ^Interp) {
    vm.thrown = mk_error(vm, "SyntaxError", "Failed to construct 'DOMMatrix': the string did not match the expected pattern.")
    vm.throwing = true
}

@(private = "file")
dm_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    m, ok := dm_coerce(vm, arg(args, 0))
    if !ok { dm_throw_syntax(vm); return nil }
    return dm_new(vm, m, false)
}

@(private = "file")
dm_ro_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    m, ok := dm_coerce(vm, arg(args, 0))
    if !ok { dm_throw_syntax(vm); return nil }
    return dm_new(vm, m, true)
}

// ── métodos ─────────────────────────────────────────────────────────────────
// Cada transformação existe em DUAS formas: `x()` devolve uma matriz NOVA e
// `xSelf()` muta o receptor. `dm_apply` centraliza para as duas não divergirem.
@(private = "file")
dm_apply :: proc(vm: ^Interp, this: Value, delta: [16]f64, self: bool, pre := false) -> Value {
    o, ok := this.(^Object); if !ok do return nil
    cur := dm_read(o)
    novo := pre ? dm_mul(delta, cur) : dm_mul(cur, delta)
    if self && !truthy(o.props["__ro"]) {
        dm_write(o, novo)
        return o
    }
    return dm_new(vm, novo, truthy(o.props["__ro"]))
}

@(private = "file")
dm_translation :: proc(tx, ty, tz: f64) -> (m: [16]f64) {
    m = dm_identity()
    m[12], m[13], m[14] = tx, ty, tz
    return
}

@(private = "file")
dm_scaling :: proc(sx, sy, sz: f64) -> (m: [16]f64) {
    m = dm_identity()
    m[0], m[5], m[10] = sx, sy, sz
    return
}

// rotação em torno de Z, em GRAUS (a spec do DOMMatrix usa graus, não radianos —
// trocar isso por radianos daria um número plausível e errado).
@(private = "file")
dm_rotation_z :: proc(deg: f64) -> (m: [16]f64) {
    r := deg * math.PI / 180.0
    c, s := math.cos(r), math.sin(r)
    m = dm_identity()
    m[0], m[1], m[4], m[5] = c, s, -s, c
    return
}

@(private = "file")
dm_arg_or :: proc(args: []Value, i: int, def: f64) -> f64 {
    if i >= len(args) || args[i] == nil do return def
    return as_number(args[i])
}

@(private = "file") dm_translate      :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return dm_apply(vm, this, dm_translation(dm_arg_or(a,0,0), dm_arg_or(a,1,0), dm_arg_or(a,2,0)), false) }
@(private = "file") dm_translate_self :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return dm_apply(vm, this, dm_translation(dm_arg_or(a,0,0), dm_arg_or(a,1,0), dm_arg_or(a,2,0)), true) }
@(private = "file") dm_rotate         :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return dm_apply(vm, this, dm_rotation_z(dm_arg_or(a,0,0)), false) }
@(private = "file") dm_rotate_self    :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return dm_apply(vm, this, dm_rotation_z(dm_arg_or(a,0,0)), true) }

// scale(sx, sy=sx, sz=1): omitir sy copia sx (spec) — passar 1 por default
// deixaria `scale(2)` escalando só em X, que é um erro visualmente sutil.
@(private = "file")
dm_scale_args :: proc(a: []Value) -> [16]f64 {
    sx := dm_arg_or(a, 0, 1)
    return dm_scaling(sx, dm_arg_or(a, 1, sx), dm_arg_or(a, 2, 1))
}
@(private = "file") dm_scale      :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return dm_apply(vm, this, dm_scale_args(a), false) }
@(private = "file") dm_scale_self :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return dm_apply(vm, this, dm_scale_args(a), true) }

@(private = "file")
dm_multiply :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    other, ok := dm_coerce(vm, arg(a, 0))
    if !ok { dm_throw_syntax(vm); return nil }
    return dm_apply(vm, this, other, false)
}
@(private = "file")
dm_multiply_self :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    other, ok := dm_coerce(vm, arg(a, 0))
    if !ok { dm_throw_syntax(vm); return nil }
    return dm_apply(vm, this, other, true)
}
@(private = "file")
dm_pre_multiply_self :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    other, ok := dm_coerce(vm, arg(a, 0))
    if !ok { dm_throw_syntax(vm); return nil }
    return dm_apply(vm, this, other, true, true)
}

// Inversa 4×4 geral (cofatores). Singular → TODOS NaN, como a spec manda: uma
// identidade silenciosa aqui viraria um layout errado sem sintoma.
@(private = "file")
dm_inverse_of :: proc(m: [16]f64) -> [16]f64 {
    inv: [16]f64
    inv[0]  =  m[5]*m[10]*m[15] - m[5]*m[11]*m[14] - m[9]*m[6]*m[15] + m[9]*m[7]*m[14] + m[13]*m[6]*m[11] - m[13]*m[7]*m[10]
    inv[4]  = -m[4]*m[10]*m[15] + m[4]*m[11]*m[14] + m[8]*m[6]*m[15] - m[8]*m[7]*m[14] - m[12]*m[6]*m[11] + m[12]*m[7]*m[10]
    inv[8]  =  m[4]*m[9]*m[15]  - m[4]*m[11]*m[13] - m[8]*m[5]*m[15] + m[8]*m[7]*m[13] + m[12]*m[5]*m[11] - m[12]*m[7]*m[9]
    inv[12] = -m[4]*m[9]*m[14]  + m[4]*m[10]*m[13] + m[8]*m[5]*m[14] - m[8]*m[6]*m[13] - m[12]*m[5]*m[10] + m[12]*m[6]*m[9]
    inv[1]  = -m[1]*m[10]*m[15] + m[1]*m[11]*m[14] + m[9]*m[2]*m[15] - m[9]*m[3]*m[14] - m[13]*m[2]*m[11] + m[13]*m[3]*m[10]
    inv[5]  =  m[0]*m[10]*m[15] - m[0]*m[11]*m[14] - m[8]*m[2]*m[15] + m[8]*m[3]*m[14] + m[12]*m[2]*m[11] - m[12]*m[3]*m[10]
    inv[9]  = -m[0]*m[9]*m[15]  + m[0]*m[11]*m[13] + m[8]*m[1]*m[15] - m[8]*m[3]*m[13] - m[12]*m[1]*m[11] + m[12]*m[3]*m[9]
    inv[13] =  m[0]*m[9]*m[14]  - m[0]*m[10]*m[13] - m[8]*m[1]*m[14] + m[8]*m[2]*m[13] + m[12]*m[1]*m[10] - m[12]*m[2]*m[9]
    inv[2]  =  m[1]*m[6]*m[15]  - m[1]*m[7]*m[14]  - m[5]*m[2]*m[15] + m[5]*m[3]*m[14] + m[13]*m[2]*m[7]  - m[13]*m[3]*m[6]
    inv[6]  = -m[0]*m[6]*m[15]  + m[0]*m[7]*m[14]  + m[4]*m[2]*m[15] - m[4]*m[3]*m[14] - m[12]*m[2]*m[7]  + m[12]*m[3]*m[6]
    inv[10] =  m[0]*m[5]*m[15]  - m[0]*m[7]*m[13]  - m[4]*m[1]*m[15] + m[4]*m[3]*m[13] + m[12]*m[1]*m[7]  - m[12]*m[3]*m[5]
    inv[14] = -m[0]*m[5]*m[14]  + m[0]*m[6]*m[13]  + m[4]*m[1]*m[14] - m[4]*m[2]*m[13] - m[12]*m[1]*m[6]  + m[12]*m[2]*m[5]
    inv[3]  = -m[1]*m[6]*m[11]  + m[1]*m[7]*m[10]  + m[5]*m[2]*m[11] - m[5]*m[3]*m[10] - m[9]*m[2]*m[7]   + m[9]*m[3]*m[6]
    inv[7]  =  m[0]*m[6]*m[11]  - m[0]*m[7]*m[10]  - m[4]*m[2]*m[11] + m[4]*m[3]*m[10] + m[8]*m[2]*m[7]   - m[8]*m[3]*m[6]
    inv[11] = -m[0]*m[5]*m[11]  + m[0]*m[7]*m[9]   + m[4]*m[1]*m[11] - m[4]*m[3]*m[9]  - m[8]*m[1]*m[7]   + m[8]*m[3]*m[5]
    inv[15] =  m[0]*m[5]*m[10]  - m[0]*m[6]*m[9]   - m[4]*m[1]*m[10] + m[4]*m[2]*m[9]  + m[8]*m[1]*m[6]   - m[8]*m[2]*m[5]

    det := m[0]*inv[0] + m[1]*inv[4] + m[2]*inv[8] + m[3]*inv[12]
    if det == 0 {
        nan := math.nan_f64()
        r: [16]f64
        for i in 0 ..< 16 do r[i] = nan
        return r
    }
    for i in 0 ..< 16 do inv[i] /= det
    return inv
}

@(private = "file")
dm_inverse :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    o, ok := this.(^Object); if !ok do return nil
    return dm_new(vm, dm_inverse_of(dm_read(o)), truthy(o.props["__ro"]))
}
@(private = "file")
dm_invert_self :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    o, ok := this.(^Object); if !ok do return nil
    if truthy(o.props["__ro"]) do return dm_new(vm, dm_inverse_of(dm_read(o)), true)
    dm_write(o, dm_inverse_of(dm_read(o)))
    return o
}

@(private = "file")
dm_transform_point :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    o, ok := this.(^Object); if !ok do return nil
    m := dm_read(o)
    px, py, pz, pw := 0.0, 0.0, 0.0, 1.0
    if p, pok := arg(a, 0).(^Object); pok {
        px, py = num_or(p, "x", 0), num_or(p, "y", 0)
        pz, pw = num_or(p, "z", 0), num_or(p, "w", 1)
    }
    return dp_new(vm,
        m[0]*px + m[4]*py + m[8] *pz + m[12]*pw,
        m[1]*px + m[5]*py + m[9] *pz + m[13]*pw,
        m[2]*px + m[6]*py + m[10]*pz + m[14]*pw,
        m[3]*px + m[7]*py + m[11]*pz + m[15]*pw)
}

@(private = "file")
dm_to_string :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    o, ok := this.(^Object); if !ok do return own_str(vm, "")
    m := dm_read(o)
    sb: strings.Builder; strings.builder_init(&sb, context.temp_allocator)
    if dm_is_2d(m) {
        fmt.sbprintf(&sb, "matrix(%v, %v, %v, %v, %v, %v)", m[0], m[1], m[4], m[5], m[12], m[13])
    } else {
        strings.write_string(&sb, "matrix3d(")
        for i in 0 ..< 16 {
            if i > 0 do strings.write_string(&sb, ", ")
            fmt.sbprintf(&sb, "%v", m[i])
        }
        strings.write_string(&sb, ")")
    }
    return own_str(vm, strings.to_string(sb))
}

@(private = "file")
dm_to_float_array :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    o, ok := this.(^Object); if !ok do return nil
    m := dm_read(o)
    arr := new_array(vm)
    for i in 0 ..< 16 do append(&arr.items, m[i])
    return arr
}

@(private = "file")
dm_set_matrix_value :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    o, ok := this.(^Object); if !ok do return nil
    s, sok := arg(a, 0).(string)
    if !sok { dm_throw_syntax(vm); return nil }
    m, mok := dm_from_string(s)
    if !mok { dm_throw_syntax(vm); return nil }
    dm_write(o, m)
    return o
}

@(private = "file")
dm_from_matrix :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    m, ok := dm_coerce(vm, arg(a, 0))
    if !ok { dm_throw_syntax(vm); return nil }
    return dm_new(vm, m, false)
}

// ── DOMPoint ────────────────────────────────────────────────────────────────

@(private = "file")
dp_new :: proc(vm: ^Interp, x, y, z, w: f64) -> ^Object {
    o := new_object(vm)
    o.proto = vm.dompoint_proto
    o.props["x"], o.props["y"], o.props["z"], o.props["w"] = x, y, z, w
    return o
}

@(private = "file")
dp_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    // DOMPoint(x, y, z, w) — também aceita o dicionário {x,y,z,w}
    if o, ok := arg(args, 0).(^Object); ok {
        return dp_new(vm, num_or(o, "x", 0), num_or(o, "y", 0), num_or(o, "z", 0), num_or(o, "w", 1))
    }
    return dp_new(vm, dm_arg_or(args, 0, 0), dm_arg_or(args, 1, 0), dm_arg_or(args, 2, 0), dm_arg_or(args, 3, 1))
}

@(private = "file")
dp_to_json :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    o, ok := this.(^Object); if !ok do return nil
    r := new_object(vm)
    r.props["x"], r.props["y"] = o.props["x"], o.props["y"]
    r.props["z"], r.props["w"] = o.props["z"], o.props["w"]
    return r
}

// ── instalação ──────────────────────────────────────────────────────────────

@(private = "file")
dm_proto_new :: proc(vm: ^Interp, ctor: ^Function) -> ^Object {
    p := new_object(vm)
    p.props["constructor"] = ctor
    mark_non_enumerable(p, "constructor")
    ctor.props["prototype"] = p
    return p
}

@(private = "file")
dm_put_methods :: proc(vm: ^Interp, p: ^Object, com_self: bool) {
    base := [?]struct{ n: string, f: Native_Fn }{
        {"multiply", dm_multiply}, {"translate", dm_translate}, {"scale", dm_scale},
        {"rotate", dm_rotate}, {"inverse", dm_inverse}, {"transformPoint", dm_transform_point},
        {"toString", dm_to_string}, {"toFloat32Array", dm_to_float_array},
        {"toFloat64Array", dm_to_float_array}, {"toJSON", dm_to_float_array},
    }
    for m in base {
        p.props[m.n] = mk_native(vm, m.f)
        mark_non_enumerable(p, m.n)
    }
    if !com_self do return
    // As formas que MUTAM só existem em DOMMatrix (a ReadOnly não as tem — e é
    // por isso que `com_self` é parâmetro em vez de sempre-ligado).
    mut := [?]struct{ n: string, f: Native_Fn }{
        {"multiplySelf", dm_multiply_self}, {"preMultiplySelf", dm_pre_multiply_self},
        {"translateSelf", dm_translate_self}, {"scaleSelf", dm_scale_self},
        {"rotateSelf", dm_rotate_self}, {"invertSelf", dm_invert_self},
        {"setMatrixValue", dm_set_matrix_value},
    }
    for m in mut {
        p.props[m.n] = mk_native(vm, m.f)
        mark_non_enumerable(p, m.n)
    }
}

install_dommatrix :: proc(vm: ^Interp) {
    ctor := mk_native(vm, dm_ctor)
    ctor.name = "DOMMatrix"
    vm.dommatrix_proto = dm_proto_new(vm, ctor)
    dm_put_methods(vm, vm.dommatrix_proto, true)
    ctor.props["fromMatrix"] = mk_native(vm, dm_from_matrix)
    ctor.props["fromFloat32Array"] = mk_native(vm, dm_from_matrix)
    ctor.props["fromFloat64Array"] = mk_native(vm, dm_from_matrix)
    env_define(vm.global, "DOMMatrix", ctor)
    env_define(vm.global, "WebKitCSSMatrix", ctor) // alias legado (mesma interface)
    env_define(vm.global, "SVGMatrix", ctor)       // alias legado do SVG

    ro := mk_native(vm, dm_ro_ctor)
    ro.name = "DOMMatrixReadOnly"
    vm.dommatrix_ro_proto = dm_proto_new(vm, ro)
    dm_put_methods(vm, vm.dommatrix_ro_proto, false)
    ro.props["fromMatrix"] = mk_native(vm, dm_from_matrix)
    env_define(vm.global, "DOMMatrixReadOnly", ro)

    pc := mk_native(vm, dp_ctor)
    pc.name = "DOMPoint"
    vm.dompoint_proto = dm_proto_new(vm, pc)
    vm.dompoint_proto.props["toJSON"] = mk_native(vm, dp_to_json)
    mark_non_enumerable(vm.dompoint_proto, "toJSON")
    env_define(vm.global, "DOMPoint", pc)
    env_define(vm.global, "DOMPointReadOnly", pc)
}

// Usada pelo canvas (ctx.getTransform) — a CTM 2D vira uma DOMMatrix.
dommatrix_from_2d :: proc(vm: ^Interp, a, b, c, d, e, f: f64) -> Value {
    m := dm_identity()
    m[0], m[1], m[4], m[5], m[12], m[13] = a, b, c, d, e, f
    return dm_new(vm, m, false)
}
