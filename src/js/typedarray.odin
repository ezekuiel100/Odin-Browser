package js

// TypedArrays, ArrayBuffer e DataView (M69). Base de libs de compressão/cripto/
// binário (fflate, hashing, canvas). O bloqueador do ultra-photo era `Uint8Array`
// faltando (`ms=Uint8Array; new ms([...])`).
//
// REPRESENTAÇÃO: cada view é um ^Object com ab (^Array_Buffer compartilhado),
// ta_kind (tipo do elemento), ta_off (offset em bytes) e ta_len (nº de elementos);
// hooks get/set interceptam o acesso por índice inteiro (com semântica do tipo:
// wrap p/ inteiros, clamp p/ Uint8Clamped, float p/ Float*). length/byteLength/
// byteOffset/BYTES_PER_ELEMENT/buffer ficam em props; os métodos, num prototype
// por tipo (ta_protos[kind]) — instanceof por tipo funciona. Bytes em little-endian
// (nativo x64); DataView faz endianness explícita (default big-endian, como a spec).

import "core:fmt"
import "core:math"
import "core:strings"
import "core:math/rand"

TA_Kind :: enum u8 {
    None = 0, // ArrayBuffer (sem tipo de elemento)
    I8, U8, U8C, I16, U16, I32, U32, F32, F64, F16, I64, U64,
    DataView,
}

@(private = "file")
ta_bpe :: proc(k: TA_Kind) -> int {
    #partial switch k {
    case .I8, .U8, .U8C: return 1
    case .I16, .U16, .F16: return 2
    case .I32, .U32, .F32: return 4
    case .F64, .I64, .U64: return 8
    }
    return 1
}

@(private = "file")
ta_name :: proc(k: TA_Kind) -> string {
    #partial switch k {
    case .I8:  return "Int8Array"
    case .U8:  return "Uint8Array"
    case .U8C: return "Uint8ClampedArray"
    case .I16: return "Int16Array"
    case .U16: return "Uint16Array"
    case .I32: return "Int32Array"
    case .U32: return "Uint32Array"
    case .F32: return "Float32Array"
    case .F64: return "Float64Array"
    case .F16: return "Float16Array"
    case .I64: return "BigInt64Array"
    case .U64: return "BigUint64Array"
    }
    return "TypedArray"
}

// ── leitura/escrita de bytes little-endian ───────────────────────────────────

@(private = "file")
rd_u32 :: proc(d: []u8, o: int) -> u32 {
    return u32(d[o]) | u32(d[o+1])<<8 | u32(d[o+2])<<16 | u32(d[o+3])<<24
}
@(private = "file")
rd_u64 :: proc(d: []u8, o: int) -> u64 {
    lo := u64(rd_u32(d, o)); hi := u64(rd_u32(d, o+4))
    return lo | hi<<32
}
@(private = "file")
wr_u32 :: proc(d: []u8, o: int, v: u32) {
    d[o] = u8(v); d[o+1] = u8(v>>8); d[o+2] = u8(v>>16); d[o+3] = u8(v>>24)
}
@(private = "file")
wr_u64 :: proc(d: []u8, o: int, v: u64) {
    wr_u32(d, o, u32(v)); wr_u32(d, o+4, u32(v>>32))
}

// ToUint32 (JS): NaN/Inf → 0; trunca; módulo 2^32.
@(private = "file")
to_u32 :: proc(v: f64) -> u32 {
    if v != v do return 0
    if v == math.inf_f64(1) || v == math.inf_f64(-1) do return 0
    t := math.trunc(v)
    m := math.mod(t, 4294967296.0)
    if m < 0 do m += 4294967296.0
    return u32(m)
}

@(private = "file")
to_u8_clamped :: proc(v: f64) -> u8 {
    if v != v do return 0 // NaN
    if v <= 0 do return 0
    if v >= 255 do return 255
    f := math.floor(v)
    if v > f + 0.5 || (v == f + 0.5 && int(f) % 2 != 0) do f += 1
    return u8(f)
}

// lê o elemento i como f64.
ta_read_number :: proc(o: ^Object, i: int) -> f64 {
    if o.ab.detached || i < 0 || i >= o.ta_len do return math.nan_f64()
    d := o.ab.data[:]
    off := o.ta_off + i * ta_bpe(o.ta_kind)
    #partial switch o.ta_kind {
    case .I8:  return f64(i8(d[off]))
    case .U8, .U8C: return f64(d[off])
    case .I16: return f64(i16(u16(d[off]) | u16(d[off+1])<<8))
    case .U16: return f64(u16(d[off]) | u16(d[off+1])<<8)
    case .I32: return f64(i32(rd_u32(d, off)))
    case .U32: return f64(rd_u32(d, off))
    case .F16: return f64(transmute(f16)(u16(d[off]) | u16(d[off+1])<<8))
    case .F32: return f64(transmute(f32)rd_u32(d, off))
    case .F64: return transmute(f64)rd_u64(d, off)
    }
    return 0
}

// escreve v (já ToNumber) no elemento i, com a semântica do tipo.
ta_write_number :: proc(o: ^Object, i: int, v: f64) {
    if o.ab.detached || i < 0 || i >= o.ta_len do return
    d := o.ab.data[:]
    off := o.ta_off + i * ta_bpe(o.ta_kind)
    #partial switch o.ta_kind {
    case .U8C: d[off] = to_u8_clamped(v)
    case .I8, .U8:  d[off] = u8(to_u32(v))
    case .I16, .U16:
        n := to_u32(v); d[off] = u8(n); d[off+1] = u8(n>>8)
    case .I32, .U32:
        wr_u32(d, off, to_u32(v))
    case .F16:
        n := ta_float16_bits(v); d[off] = u8(n); d[off+1] = u8(n>>8)
    case .F32:
        wr_u32(d, off, transmute(u32)f32(v))
    case .F64:
        wr_u64(d, off, transmute(u64)v)
    }
}

// "0","7","42" → índice; rejeita "07"/"1.5"/"-1"/"".  (espelha is_index_key)
@(private = "file")
parse_ta_index :: proc(name: string) -> (int, bool) {
    if len(name) == 0 || len(name) > 10 do return 0, false
    if len(name) > 1 && name[0] == '0' do return 0, false
    n := 0
    for c in transmute([]u8)name {
        if c < '0' || c > '9' do return 0, false
        n = n*10 + int(c - '0')
    }
    return n, true
}

// ── hooks de índice ──────────────────────────────────────────────────────────

typedarray_get :: proc(vm: ^Interp, o: ^Object, name: string) -> (Value, bool) {
    if o.ab.detached {
        if name == "length" || name == "byteLength" || name == "byteOffset" do return f64(0), true
        if _, ok := parse_ta_index(name); ok do return nil, true
    }
    if i, ok := parse_ta_index(name); ok {
        if i >= 0 && i < o.ta_len do return ta_value(vm, o, i), true
        return nil, true // fora do range → undefined (mas "handled": não é prop)
    }
    return nil, false // length/buffer/métodos: caem em props/proto
}

typedarray_set :: proc(vm: ^Interp, o: ^Object, name: string, val: Value) -> bool {
    if i, ok := parse_ta_index(name); ok {
        n := ta_convert(vm, o.ta_kind, val)
        if !vm.throwing && i >= 0 && i < o.ta_len do ta_store(vm, o, i, n)
        return true // dentro ou fora do range: TypedArray nunca cria prop numérica
    }
    return false
}

// ── construção ───────────────────────────────────────────────────────────────

@(private = "file")
new_buffer :: proc(vm: ^Interp, byte_len: int) -> ^Array_Buffer {
    ab := new(Array_Buffer)
    resize(&ab.data, byte_len) // zerado
    append(&vm.all_buffers, ab)
    return ab
}

// envolve um ^Array_Buffer num objeto JS ArrayBuffer.
@(private = "file")
wrap_buffer :: proc(vm: ^Interp, ab: ^Array_Buffer) -> ^Object {
    o := new_object(vm)
    o.ab = ab
    o.ta_kind = .None
    o.proto = vm.array_buffer_proto
    return o
}

// monta o objeto view (TypedArray) sobre ab, com off (bytes) e len (elementos).
@(private = "file")
make_view :: proc(vm: ^Interp, kind: TA_Kind, ab: ^Array_Buffer, buf_obj: ^Object, off, length: int) -> ^Object {
    o := new_object(vm)
    o.ab = ab
    o.ta_kind = kind
    o.ta_off = off
    o.ta_len = length
    o.ta_fixed_len = length
    o.proto = vm.ta_protos[kind]
    o.get = typedarray_get
    o.set = typedarray_set
    // buffer/length/byteLength/byteOffset NÃO são props próprias (spec): vêm dos
    // acessores do %TypedArray%.prototype, e BYTES_PER_ELEMENT do protótipo do tipo.
    // Como próprias, `Object.keys(new Uint8Array(3))` dava "buffer,byteLength,…" em
    // vez de "0,1,2". O buffer fica numa chave interna (`#…` não enumera).
    o.props[TA_BUFFER_KEY] = buf_obj
    return o
}

// Coerce before accessing backing storage; numeric TypedArrays reject BigInt.
@(private = "file")
ta_number :: proc(vm: ^Interp, value: Value) -> f64 {
    v := to_primitive(vm, value, true)
    if vm.throwing do return math.nan_f64()
    #partial switch _ in v {
    case ^Symbol, ^BigInt:
        throw_type_error(vm, "Cannot convert value to a TypedArray number")
        return math.nan_f64()
    }
    return as_number(v)
}

@(private = "file")
ta_range_error :: proc(vm: ^Interp) {
    vm.thrown = mk_error(vm, "RangeError", "TypedArray offset or length is out of bounds")
    vm.throwing = true
}

@(private = "file")
ta_integer :: proc(vm: ^Interp, v: Value) -> f64 {
    n := ta_number(vm, v)
    if n != n || n == 0 do return 0
    return math.trunc(n)
}

@(private = "file")
ta_index :: proc(vm: ^Interp, v: Value) -> int {
    n := ta_integer(vm, v)
    if vm.throwing do return 0
    if n < 0 || n > 9007199254740991.0 {
        ta_range_error(vm)
        return 0
    }
    return int(n)
}

@(private = "file")
ta_length :: proc(vm: ^Interp, src: Value) -> int {
    v := get_member(vm, src, "length")
    if vm.throwing do return 0
    n := ta_integer(vm, v)
    if vm.throwing || n <= 0 do return 0
    return int(min(n, 9007199254740991.0))
}

@(private = "file")
ta_allocate :: proc(vm: ^Interp, kind: TA_Kind, length: int) -> ^Object {
    // Backing-store implementation limit: check before multiplication/allocation.
    if length > 2147483647 / ta_bpe(kind) {
        ta_range_error(vm)
        return nil
    }
    ab := new_buffer(vm, length * ta_bpe(kind))
    return make_view(vm, kind, ab, wrap_buffer(vm, ab), 0, length)
}

// GetMethod(@@iterator) and IterableToList, including observable getters.
@(private = "file")
ta_iterable_list :: proc(vm: ^Interp, src: Value, items: ^[dynamic]Value) -> bool {
    method := get_member(vm, src, vm.sym_iterator_key)
    if vm.throwing do return true
    if is_nullish(method) do return false
    fn, ok := method.(^Function)
    if !ok { throw_type_error(vm, "Symbol.iterator is not callable"); return true }
    iter := call_function(vm, fn, src, nil)
    if vm.throwing do return true
    if is_primitive(iter) { throw_type_error(vm, "Iterator is not an object"); return true }
    next := get_member(vm, iter, "next")
    if vm.throwing do return true
    next_fn, callable := next.(^Function)
    if !callable { throw_type_error(vm, "Iterator next is not callable"); return true }
    for {
        if step_guard(vm) do return true
        step := call_function(vm, next_fn, iter, nil)
        if vm.throwing do return true
        if is_primitive(step) { throw_type_error(vm, "Iterator result is not an object"); return true }
        done := get_member(vm, step, "done")
        if vm.throwing || truthy(done) do return true
        value := get_member(vm, step, "value")
        if vm.throwing do return true
        append(items, value)
    }
}

// new <Kind>Array(length | iterable | array-like | buffer[, offset, length])
make_typed_array :: proc(vm: ^Interp, kind: TA_Kind, args: []Value) -> Value {
    bpe := ta_bpe(kind)
    src := arg(args, 0)
    if is_primitive(src) {
        length := ta_index(vm, src)
        if vm.throwing do return nil
        return ta_allocate(vm, kind, length)
    }
    if o, ok := src.(^Object); ok && o.ab != nil {
        if o.ta_kind == .None {
            off := ta_index(vm, arg(args, 1))
            if vm.throwing do return nil
            if off % bpe != 0 { ta_range_error(vm); return nil }
            length := 0
            explicit_length := arg(args, 2) != nil
            if explicit_length {
                length = ta_index(vm, args[2])
                if vm.throwing do return nil
            }
            if o.ab.detached { throw_type_error(vm, "ArrayBuffer is detached"); return nil }
            byte_len := len(o.ab.data)
            if off > byte_len { ta_range_error(vm); return nil }
            if !explicit_length {
                if byte_len % bpe != 0 { ta_range_error(vm); return nil }
                length = (byte_len - off) / bpe
            }
            if length > (byte_len - off) / bpe { ta_range_error(vm); return nil }
            view := make_view(vm, kind, o.ab, o, off, length)
            view.ta_auto = o.ab.resizable && !explicit_length
            return view
        }
        if o.ta_kind != .DataView {
            if ta_big(kind) != ta_big(o.ta_kind) { throw_type_error(vm, "Cannot mix BigInt and Number TypedArrays"); return nil }
            if o.ab.detached { throw_type_error(vm, "ArrayBuffer is detached"); return nil }
            out := ta_allocate(vm, kind, o.ta_len)
            if vm.throwing do return nil
            if kind == o.ta_kind {
                copy(out.ab.data[:], o.ab.data[o.ta_off:o.ta_off + o.ta_len * bpe])
            } else {
                for i in 0 ..< o.ta_len do ta_store(vm, out, i, ta_value(vm, o, i))
            }
            return out
        }
    }
    items: [dynamic]Value
    defer delete(items)
    if ta_iterable_list(vm, src, &items) {
        if vm.throwing do return nil
        out := ta_allocate(vm, kind, len(items))
        if vm.throwing do return nil
        for v, i in items {
            n := ta_convert(vm, kind, v)
            if vm.throwing do return nil
            ta_store(vm, out, i, n)
        }
        return out
    }
    if vm.throwing do return nil
    length := ta_length(vm, src)
    if vm.throwing do return nil
    out := ta_allocate(vm, kind, length)
    if vm.throwing do return nil
    for i in 0 ..< length {
        v := array_like_get(vm, src, i)
        if vm.throwing do return nil
        n := ta_convert(vm, kind, v)
        if vm.throwing do return nil
        ta_store(vm, out, i, n)
    }
    return out
}

// chave-string de um índice (owned), p/ get_member(src, "3").
@(private = "file")
int_key :: proc(vm: ^Interp, i: int) -> string {
    return key_string(vm, f64(i))
}

// ── métodos do prototype de TypedArray ───────────────────────────────────────

@(private = "file")
this_ta :: proc(this: Value) -> (^Object, bool) {
    o, ok := this.(^Object)
    if !ok || o.ab == nil || o.ta_kind == .None || o.ta_kind == .DataView do return nil, false
    return o, true
}

// normaliza um índice relativo (negativo conta do fim), clampeado a [0, len].
@(private = "file")
rel_index :: proc(v: Value, length: int, def: int) -> int {
    if v == nil do return def
    n := as_int(v)
    if n < 0 do n += length
    if n < 0 do n = 0
    if n > length do n = length
    return n
}

@(private = "file")
ta_set_method :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := this_ta(this)
    if !ok { throw_type_error(vm, "Receiver is not a TypedArray"); return nil }
    offset := ta_integer(vm, arg(args, 1))
    if vm.throwing do return nil
    if offset < 0 { ta_range_error(vm); return nil }
    if o.ab.detached { throw_type_error(vm, "ArrayBuffer is detached"); return nil }
    src := arg(args, 0)
    if s2, sok := this_ta(src); sok {
        if ta_big(o.ta_kind) != ta_big(s2.ta_kind) { throw_type_error(vm, "Cannot mix BigInt and Number TypedArrays"); return nil }
        if s2.ab.detached { throw_type_error(vm, "ArrayBuffer is detached"); return nil }
        if offset > f64(o.ta_len) || s2.ta_len > o.ta_len - int(offset) {
            ta_range_error(vm); return nil
        }
        off := int(offset)
        // Snapshot aliased views; identical element types preserve NaN payloads.
        data := s2.ab.data[s2.ta_off:s2.ta_off + s2.ta_len * ta_bpe(s2.ta_kind)]
        snapshot: []u8
        if s2.ab == o.ab {
            snapshot = make([]u8, len(data))
            copy(snapshot, data)
            data = snapshot
        }
        defer if snapshot != nil do delete(snapshot)
        if s2.ta_kind == o.ta_kind {
            start := o.ta_off + off * ta_bpe(o.ta_kind)
            copy(o.ab.data[start:start + len(data)], data)
        } else {
            buffer := Array_Buffer{}
            buffer.data = make([dynamic]u8)
            defer delete(buffer.data)
            append(&buffer.data, ..data)
            view := Object{ab = &buffer, ta_kind = s2.ta_kind, ta_len = s2.ta_len}
            for i in 0 ..< s2.ta_len do ta_store(vm, o, off+i, ta_value(vm, &view, i))
        }
        return nil
    }
    if is_nullish(src) { throw_type_error(vm, "Cannot convert null or undefined to object"); return nil }
    n := ta_length(vm, src)
    if vm.throwing do return nil
    // LengthOfArrayLike (including side effects) precedes the range check.
    if offset > f64(o.ta_len) || n > o.ta_len - int(offset) { ta_range_error(vm); return nil }
    off := int(offset)
    for i in 0 ..< n {
        v := array_like_get(vm, src, i)
        if vm.throwing do return nil
        value := ta_convert(vm, o.ta_kind, v)
        if vm.throwing do return nil
        ta_store(vm, o, off+i, value)
    }
    return nil
}

@(private = "file")
ta_subarray :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := this_ta(this); if !ok do return nil
    begin := rel_index(arg(args, 0), o.ta_len, 0)
    end   := rel_index(len(args) >= 2 ? args[1] : nil, o.ta_len, o.ta_len)
    if end < begin do end = begin
    // VIEW compartilhando o buffer (offset em bytes)
    buf_obj, _ := o.props[TA_BUFFER_KEY].(^Object)
    view := make_view(vm, o.ta_kind, o.ab, buf_obj, o.ta_off + begin*ta_bpe(o.ta_kind), end - begin)
    view.ta_auto = o.ta_auto && arg(args, 1) == nil
    return view
}

@(private = "file")
ta_slice :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := this_ta(this); if !ok do return nil
    begin := rel_index(arg(args, 0), o.ta_len, 0)
    end   := rel_index(len(args) >= 2 ? args[1] : nil, o.ta_len, o.ta_len)
    if end < begin do end = begin
    res := make_typed_array(vm, o.ta_kind, []Value{f64(end - begin)})
    ro := res.(^Object)
    for i in begin ..< end do ta_store(vm, ro, i - begin, ta_value(vm, o, i))
    return res
}

@(private = "file")
ta_fill :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := this_ta(this); if !ok do return this
    v := ta_convert(vm, o.ta_kind, arg(args, 0))
    if vm.throwing do return nil
    start := rel_index(len(args) >= 2 ? args[1] : nil, o.ta_len, 0)
    end   := rel_index(len(args) >= 3 ? args[2] : nil, o.ta_len, o.ta_len)
    for i in start ..< end do ta_store(vm, o, i, v)
    return this
}

@(private = "file")
ta_require :: proc(vm: ^Interp, this: Value) -> (^Object, bool) {
    o, ok := this_ta(this)
    if !ok { throw_type_error(vm, "Receiver is not a TypedArray"); return nil, false }
    if o.ab.detached || o.ta_oob { throw_type_error(vm, "TypedArray is out of bounds or detached"); return nil, false }
    return o, true
}

@(private = "file")
ta_at :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := ta_require(vm, this); if !ok do return nil
    i := as_int(to_number(vm, arg(args, 0)))
    if vm.throwing do return nil
    if i < 0 do i += o.ta_len
    if i < 0 || i >= o.ta_len do return nil
    return ta_value(vm, o, i)
}

// Search values are not coerced; includes uses SameValueZero (including NaN).
@(private = "file")
ta_search :: proc(vm: ^Interp, this: Value, args: []Value, backwards, includes: bool) -> Value {
    o, ok := ta_require(vm, this); if !ok do return nil
    missing: Value = f64(-1)
    if includes do missing = false
    if o.ta_len == 0 do return missing
    i := 0
    if backwards do i = o.ta_len - 1
    if len(args) > 1 && (backwards || args[1] != nil) {
        i = as_int(to_number(vm, args[1]))
        if vm.throwing do return nil
        if i < 0 do i += o.ta_len
        if backwards { i = min(i, o.ta_len - 1) } else { i = max(i, 0) }
    }
    target := arg(args, 0)
    step := 1; if backwards do step = -1
    for i >= 0 && i < o.ta_len {
        el := ta_value(vm, o, i)
        number, numeric := el.(f64)
        if same_value_zero(el, target) && (includes || (el != nil && (!numeric || number == number))) {
            if includes do return true
            return f64(i)
        }
        i += step
    }
    return missing
}

@(private = "file")
ta_index_of :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return ta_search(vm, this, args, false, false) }
@(private = "file")
ta_last_index_of :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return ta_search(vm, this, args, true, false) }
@(private = "file")
ta_includes :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return ta_search(vm, this, args, false, true) }

// Copy bytes in the appropriate direction: preserve float bit patterns and
// handle overlapping ranges, including views with a nonzero byteOffset.
@(private = "file")
ta_copy_within :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := ta_require(vm, this); if !ok do return nil
    length := o.ta_len
    target := rel_index(to_number(vm, arg(args, 0)), length, 0)
    if vm.throwing do return nil
    start := rel_index(to_number(vm, arg(args, 1)), length, 0)
    if vm.throwing do return nil
    end := length
    if arg(args, 2) != nil do end = rel_index(to_number(vm, args[2]), length, length)
    if vm.throwing do return nil
    if _, valid := ta_require(vm, this); !valid do return nil
    count := max(0, min(end - start, length - target, o.ta_len - target, o.ta_len - start)) * ta_bpe(o.ta_kind)
    dst := o.ta_off + target * ta_bpe(o.ta_kind)
    src := o.ta_off + start * ta_bpe(o.ta_kind)
    if dst > src {
        for i := count - 1; i >= 0; i -= 1 do o.ab.data[dst+i] = o.ab.data[src+i]
    } else {
        for i in 0 ..< count do o.ab.data[dst+i] = o.ab.data[src+i]
    }
    return this
}

@(private = "file")
ta_to_reversed :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := ta_require(vm, this); if !ok do return nil
    res := make_typed_array(vm, o.ta_kind, []Value{f64(o.ta_len)})
    ro := res.(^Object)
    for i in 0 ..< o.ta_len do ta_store(vm, ro, i, ta_value(vm, o, o.ta_len-1-i))
    return res
}

@(private = "file")
ta_with :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := ta_require(vm, this); if !ok do return nil
    i := as_int(to_number(vm, arg(args, 0)))
    if vm.throwing do return nil
    // Value conversion precedes the range check, even for an invalid index.
    v := ta_convert(vm, o.ta_kind, arg(args, 1))
    if vm.throwing do return nil
    if i < 0 do i += o.ta_len
    if i < 0 || i >= o.ta_len {
        vm.thrown = mk_error(vm, "RangeError", "Invalid index")
        vm.throwing = true
        return nil
    }
    res := make_typed_array(vm, o.ta_kind, []Value{o})
    ta_store(vm, res.(^Object), i, v)
    return res
}

@(private = "file")
ta_to_sorted :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    _, has_cmp := arg(args, 0).(^Function)
    if arg(args, 0) != nil && !has_cmp { throw_type_error(vm, "Comparator is not a function"); return nil }
    o, ok := ta_require(vm, this); if !ok do return nil
    res := make_typed_array(vm, o.ta_kind, []Value{o})
    return ta_sort(vm, res, args)
}

@(private = "file")
ta_join :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := this_ta(this); if !ok do return own_str(vm, "")
    sep := ","
    if s, sok := arg(args, 0).(string); sok do sep = s
    sb: strings.Builder
    strings.builder_init(&sb); defer strings.builder_destroy(&sb)
    for i in 0 ..< o.ta_len {
        if i > 0 do strings.write_string(&sb, sep)
        to_text(&sb, ta_value(vm, o, i))
    }
    return own_str(vm, strings.to_string(sb))
}

@(private = "file")
ta_to_locale_string :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := ta_require(vm, this); if !ok do return nil
    sb: strings.Builder
    strings.builder_init(&sb); defer strings.builder_destroy(&sb)
    for i in 0 ..< o.ta_len {
        if i > 0 do strings.write_string(&sb, ",")
        el: Value = ta_value(vm, o, i)
        // Read Number.prototype directly: numeric member dispatch otherwise
        // prioritizes the native method over user overrides.
        method: Value
        proto_start := vm.number_proto
        if ta_big(o.ta_kind) do proto_start = vm.bigint_proto
        for proto := proto_start; proto != nil; proto = proto.proto {
            if getter, found := proto.getters["toLocaleString"]; found {
                if getter != nil do method = call_function(vm, getter, el, nil)
                break
            }
            if value, found := proto.props["toLocaleString"]; found { method = value; break }
        }
        if vm.throwing do return nil
        cb, callable := method.(^Function)
        if !callable { throw_type_error(vm, "toLocaleString is not a function"); return nil }
        result := call_function(vm, cb, el, args)
        if vm.throwing do return nil
        to_text(&sb, result)
    }
    return own_str(vm, strings.to_string(sb))
}

@(private = "file")
ta_to_array :: proc(vm: ^Interp, o: ^Object) -> ^Array {
    a := new_array(vm)
    for i in 0 ..< o.ta_len do append(&a.items, ta_value(vm, o, i))
    return a
}

// forEach/map/filter/reduce/some/every/find/findIndex reusam a leitura elemento-a-elemento.
@(private = "file")
ta_for_each :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := this_ta(this); if !ok do return nil
    length := o.ta_len
    cb, cok := arg(args, 0).(^Function); if !cok do return nil
    for i in 0 ..< length {
        call_function(vm, cb, nil, []Value{ta_value(vm, o, i), f64(i), this})
        if vm.throwing do break
    }
    return nil
}

@(private = "file")
ta_map :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := this_ta(this); if !ok do return nil
    length := o.ta_len
    cb, cok := arg(args, 0).(^Function); if !cok do return nil
    res := make_typed_array(vm, o.ta_kind, []Value{f64(length)})
    ro := res.(^Object)
    for i in 0 ..< length {
        ta_store(vm, ro, i, call_function(vm, cb, nil, []Value{ta_value(vm, o, i), f64(i), this}))
        if vm.throwing do break
    }
    return res
}

@(private = "file")
ta_filter :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := this_ta(this); if !ok do return nil
    length := o.ta_len
    cb, cok := arg(args, 0).(^Function); if !cok do return nil
    keep: [dynamic]Value; defer delete(keep)
    for i in 0 ..< length {
        el := ta_value(vm, o, i)
        if truthy(call_function(vm, cb, nil, []Value{el, f64(i), this})) do append(&keep, el)
        if vm.throwing do return nil
    }
    res := make_typed_array(vm, o.ta_kind, []Value{f64(len(keep))})
    ro := res.(^Object)
    for el, i in keep do ta_store(vm, ro, i, el)
    return res
}

@(private = "file")
ta_reduce :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := this_ta(this); if !ok do return nil
    length := o.ta_len
    cb, cok := arg(args, 0).(^Function); if !cok do return nil
    acc: Value; start := 0
    if len(args) >= 2 { acc = args[1] } else {
        if length == 0 { throw_type_error(vm, "Reduce of empty array with no initial value"); return nil }
        acc = ta_value(vm, o, 0); start = 1
    }
    for i in start ..< length {
        acc = call_function(vm, cb, nil, []Value{acc, ta_value(vm, o, i), f64(i), this})
        if vm.throwing do break
    }
    return acc
}

@(private = "file")
ta_some :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := this_ta(this); if !ok do return false
    length := o.ta_len
    cb, cok := arg(args, 0).(^Function); if !cok do return false
    for i in 0 ..< length {
        if truthy(call_function(vm, cb, nil, []Value{ta_value(vm, o, i), f64(i), this})) do return true
        if vm.throwing do return false
    }
    return false
}

@(private = "file")
ta_every :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := this_ta(this); if !ok do return true
    length := o.ta_len
    cb, cok := arg(args, 0).(^Function); if !cok do return true
    for i in 0 ..< length {
        if !truthy(call_function(vm, cb, nil, []Value{ta_value(vm, o, i), f64(i), this})) do return false
        if vm.throwing do return false
    }
    return true
}

@(private = "file")
ta_find_direction :: proc(vm: ^Interp, this: Value, args: []Value, backwards, index: bool) -> Value {
    o, ok := ta_require(vm, this); if !ok do return nil
    length := o.ta_len
    cb, cok := arg(args, 0).(^Function)
    if !cok { throw_type_error(vm, "Callback is not a function"); return nil }
    i := 0; step := 1
    if backwards { i = length - 1; step = -1 }
    for i >= 0 && i < length {
        el := ta_value(vm, o, i)
        result := call_function(vm, cb, arg(args, 1), []Value{el, f64(i), this})
        if vm.throwing do return nil
        if truthy(result) {
            if index do return f64(i)
            return el
        }
        i += step
    }
    if index do return f64(-1)
    return nil
}

@(private = "file")
ta_find :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return ta_find_direction(vm, this, args, false, false) }
@(private = "file")
ta_find_index :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return ta_find_direction(vm, this, args, false, true) }
@(private = "file")
ta_find_last :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return ta_find_direction(vm, this, args, true, false) }
@(private = "file")
ta_find_last_index :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return ta_find_direction(vm, this, args, true, true) }

@(private = "file")
ta_reduce_right :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := ta_require(vm, this); if !ok do return nil
    length := o.ta_len
    cb, cok := arg(args, 0).(^Function)
    if !cok { throw_type_error(vm, "Callback is not a function"); return nil }
    acc: Value; i := length - 1
    if len(args) >= 2 { acc = args[1] } else {
        if i < 0 { throw_type_error(vm, "Reduce of empty array with no initial value"); return nil }
        acc = ta_value(vm, o, i); i -= 1
    }
    for i >= 0 {
        acc = call_function(vm, cb, nil, []Value{acc, ta_value(vm, o, i), f64(i), this})
        if vm.throwing do return nil
        i -= 1
    }
    return acc
}

@(private = "file")
ta_reverse :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := this_ta(this); if !ok do return this
    n := o.ta_len
    for i in 0 ..< n/2 {
        a := ta_value(vm, o, i); b := ta_value(vm, o, n-1-i)
        ta_store(vm, o, i, b); ta_store(vm, o, n-1-i, a)
    }
    return this
}

// "o valor a deve vir DEPOIS de b na ordenação?" (predicado do insertion sort).
// Sem comparador: ordem NUMÉRICA crescente (≠ Array.sort, que é por string), com
// NaN empurrado ao fim. Com comparador: usa o sinal do retorno (NaN vira 0).
@(private = "file")
ta_sort_after :: proc(vm: ^Interp, cmp: ^Function, has_cmp: bool, av, bv: Value) -> bool {
    a, b := as_number(av), as_number(bv)
    if has_cmp {
        result := call_function(vm, cmp, nil, []Value{av, bv})
        if vm.throwing do return false
        r := to_number(vm, result)
        if vm.throwing do return false
        if r != r do return false // comparador NaN → trata como 0 (não move)
        return r > 0
    }
    if x, ok := av.(^BigInt); ok {
        y, _ := bv.(^BigInt)
        return bigint_compare(x, y) > 0
    }
    a_nan := a != a
    b_nan := b != b
    if a_nan do return !b_nan // a=NaN vai p/ o fim, exceto se b também for NaN
    if b_nan do return false  // b=NaN e a não: a vem antes
    if a == 0 && b == 0 do return !math.sign_bit(a) && math.sign_bit(b)
    return a > b
}

// Clona ArrayBuffer / TypedArray / DataView para structuredClone: objeto NOVO com
// os bytes COPIADOS (independente do original). Devolve nil se `o` não é view/buffer.
ta_structured_clone :: proc(vm: ^Interp, o: ^Object) -> ^Object {
    if o.ab == nil do return nil
    if o.ta_kind == .None { // ArrayBuffer puro
        nb := new_buffer(vm, len(o.ab.data))
        if len(o.ab.data) > 0 do copy(nb.data[:], o.ab.data[:])
        return wrap_buffer(vm, nb)
    }
    if o.ta_kind == .DataView { // reconstrói a view sobre um buffer copiado
        nb := new_buffer(vm, len(o.ab.data))
        if len(o.ab.data) > 0 do copy(nb.data[:], o.ab.data[:])
        d := new_object(vm)
        d.ab = nb;  d.ta_kind = .DataView;  d.ta_off = o.ta_off;  d.ta_len = o.ta_len
        d.proto = vm.dataview_proto
        d.props[TA_BUFFER_KEY] = wrap_buffer(vm, nb)
        d.ta_fixed_len = o.ta_len
        return d
    }
    // TypedArray: reusa make_typed_array (novo buffer + cópia elemento a elemento)
    obj, _ := make_typed_array(vm, o.ta_kind, []Value{o}).(^Object)
    return obj
}

// TypedArray.prototype.sort([cmp]) — ordena os elementos IN-PLACE e devolve this.
@(private = "file")
ta_sort :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := ta_require(vm, this); if !ok do return nil
    cmp, has_cmp := arg(args, 0).(^Function)
    if arg(args, 0) != nil && !has_cmp { throw_type_error(vm, "Comparator is not a function"); return nil }
    n := o.ta_len
    values := make([]Value, n)
    defer delete(values)
    for i in 0 ..< n do values[i] = ta_value(vm, o, i)
    for i := 1; i < n; i += 1 {
        v := values[i]
        j := i - 1
        for j >= 0 && ta_sort_after(vm, cmp, has_cmp, values[j], v) {
            values[j + 1] = values[j]
            j -= 1
        }
        if vm.throwing do return nil
        values[j + 1] = v
    }
    for v, i in values do ta_store(vm, o, i, v)
    return this
}

@(private = "file")
ta_values :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := this_ta(this); if !ok do return make_array_iterator(vm, new_array(vm))
    return make_array_iterator(vm, ta_to_array(vm, o))
}

@(private = "file")
ta_keys :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := this_ta(this); if !ok do return make_array_iterator(vm, new_array(vm))
    a := new_array(vm)
    for i in 0 ..< o.ta_len do append(&a.items, f64(i))
    return make_array_iterator(vm, a)
}

@(private = "file")
ta_entries :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := this_ta(this); if !ok do return make_array_iterator(vm, new_array(vm))
    a := new_array(vm)
    for i in 0 ..< o.ta_len {
        pair := new_array(vm)
        append(&pair.items, f64(i), ta_value(vm, o, i))
        append(&a.items, pair)
    }
    return make_array_iterator(vm, a)
}

// ── construtores por tipo (9 wrappers p/ passar o kind) ──────────────────────

@(private = "file") ctor_i8  :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return make_typed_array(vm, .I8, a) }
@(private = "file") ctor_u8  :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return make_typed_array(vm, .U8, a) }
@(private = "file") ctor_u8c :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return make_typed_array(vm, .U8C, a) }
@(private = "file") ctor_i16 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return make_typed_array(vm, .I16, a) }
@(private = "file") ctor_u16 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return make_typed_array(vm, .U16, a) }
@(private = "file") ctor_i32 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return make_typed_array(vm, .I32, a) }
@(private = "file") ctor_u32 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return make_typed_array(vm, .U32, a) }
@(private = "file") ctor_f32 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return make_typed_array(vm, .F32, a) }
@(private = "file") ctor_f64 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return make_typed_array(vm, .F64, a) }

@(private = "file") ctor_f16 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return make_typed_array(vm, .F16, a) }

@(private = "file") ctor_i64 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return make_typed_array(vm, .I64, a) }

@(private = "file") ctor_u64 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return make_typed_array(vm, .U64, a) }

@(private = "file")
kind_ctor :: proc(k: TA_Kind) -> Native_Fn {
    #partial switch k {
    case .I8:  return ctor_i8
    case .U8:  return ctor_u8
    case .U8C: return ctor_u8c
    case .I16: return ctor_i16
    case .U16: return ctor_u16
    case .I32: return ctor_i32
    case .U32: return ctor_u32
    case .F32: return ctor_f32
    case .F64: return ctor_f64
    case .F16: return ctor_f16
    case .I64: return ctor_i64
    case .U64: return ctor_u64
    }
    return ctor_u8
}

// <Kind>Array.from(arrayLike[, mapFn]) / .of(...items)
@(private = "file")
ta_from :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    // this = a função construtora; descobrimos o kind pelo prototype apontado
    kind := ctor_kind_of(vm, this)
    src := arg(args, 0)
    mapfn, has_map := arg(args, 1).(^Function)
    items: [dynamic]Value; defer delete(items)
    #partial switch s in src {
    case ^Array: for it in s.items do append(&items, it)
    case ^Object:
        if so, sok := this_ta(s); sok {
            for i in 0 ..< so.ta_len do append(&items, ta_value(vm, so, i))
        } else {
            n := int(as_number(get_member(vm, s, "length")))
            for i in 0 ..< n do append(&items, get_member(vm, s, int_key(vm, i)))
        }
    }
    if has_map do for &it, i in items do it = call_function(vm, mapfn, nil, []Value{it, f64(i)})
    arr := new_array(vm)
    for it in items do append(&arr.items, it)
    return make_typed_array(vm, kind, []Value{arr})
}

@(private = "file")
ta_of :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    kind := ctor_kind_of(vm, this)
    arr := new_array(vm)
    for it in args do append(&arr.items, it)
    return make_typed_array(vm, kind, []Value{arr})
}

// descobre o TA_Kind de uma função construtora comparando seu prototype.
@(private = "file")
ctor_kind_of :: proc(vm: ^Interp, ctor: Value) -> TA_Kind {
    f, ok := ctor.(^Function); if !ok do return .U8
    proto, _ := f.props["prototype"].(^Object)
    for k in TA_Kind.I8 ..= TA_Kind.U64 do if vm.ta_protos[k] == proto do return k // .None guarda o %TypedArray%.prototype
    return .U8
}

// ── ArrayBuffer ──────────────────────────────────────────────────────────────

@(private = "file")
array_buffer_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    n := ta_index(vm, arg(args, 0))
    if vm.throwing do return nil
    if n > 2147483647 { ta_range_error(vm); return nil }
    ab := new_buffer(vm, n)
    opts := arg(args, 1)
    if !is_primitive(opts) {
        max_value := get_member(vm, opts, "maxByteLength")
        if vm.throwing do return nil
        if max_value != nil {
            maximum := ta_index(vm, max_value)
            if vm.throwing do return nil
            if maximum < n || maximum > 2147483647 { ta_range_error(vm); return nil }
            ab.resizable = true
            ab.max_byte_length = maximum
        }
    }
    return wrap_buffer(vm, ab)
}

@(private = "file")
array_buffer_slice :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o := ab_receiver(vm, this); if o == nil do return nil
    if o.ab.detached { throw_type_error(vm, "ArrayBuffer is detached"); return nil }
    total := len(o.ab.data)
    begin := rel_index(arg(args, 0), total, 0)
    end   := rel_index(len(args) >= 2 ? args[1] : nil, total, total)
    if end < begin do end = begin
    nab := new_buffer(vm, end - begin)
    for i in 0 ..< (end - begin) do nab.data[i] = o.ab.data[begin + i]
    return wrap_buffer(vm, nab)
}

// ── DataView ─────────────────────────────────────────────────────────────────

@(private = "file")
dataview_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    buf, ok := arg(args, 0).(^Object); if !ok || buf.ab == nil {
        throw_type_error(vm, "First argument to DataView constructor must be an ArrayBuffer")
        return nil
    }
    if buf.ta_kind != .None || buf.proto == vm.blob_proto { throw_type_error(vm, "Expected ArrayBuffer"); return nil }
    off := ta_index(vm, arg(args, 1)); if vm.throwing do return nil
    if buf.ab.detached { throw_type_error(vm, "ArrayBuffer is detached"); return nil }
    if off > len(buf.ab.data) { ta_range_error(vm); return nil }
    length := len(buf.ab.data) - off
    if arg(args, 2) != nil do length = ta_index(vm, args[2])
    if vm.throwing do return nil
    if buf.ab.detached { throw_type_error(vm, "ArrayBuffer is detached"); return nil }
    if off > len(buf.ab.data) || length > len(buf.ab.data) - off { ta_range_error(vm); return nil }
    o := new_object(vm)
    o.ab = buf.ab
    o.ta_kind = .DataView
    o.ta_off = off
    o.ta_len = length
    o.ta_fixed_len = length
    o.proto = vm.dataview_proto
    o.props[TA_BUFFER_KEY] = buf
    o.ta_auto = buf.ab.resizable && arg(args, 2) == nil
    return o
}

// helpers de leitura DataView com endianness (le=true → little-endian).
@(private = "file")
dv_bytes :: proc(vm: ^Interp, o: ^Object, byte_off, n: int) -> (int, bool) {
    if o == nil || o.ta_kind != .DataView || o.ab == nil || o.ab.detached || o.ta_oob {
        throw_type_error(vm, "DataView method requires a DataView with an attached buffer")
        return 0, false
    }
    if byte_off < 0 || n > o.ta_len || byte_off > o.ta_len - n {
        vm.thrown = mk_error(vm, "RangeError", "Offset is outside the bounds of the DataView")
        vm.throwing = true
        return 0, false
    }
    return o.ta_off + byte_off, true
}

@(private = "file")
dv_read_u :: proc(vm: ^Interp, o: ^Object, byte_off, n: int, le: bool) -> (u64, bool) {
    base, ok := dv_bytes(vm, o, byte_off, n); if !ok do return 0, false
    d := o.ab.data[:]
    v: u64 = 0
    if le { for i in 0 ..< n do v |= u64(d[base+i]) << uint(8*i) }
    else  { for i in 0 ..< n do v = v<<8 | u64(d[base+i]) }
    return v, true
}

@(private = "file")
dv_write_u :: proc(vm: ^Interp, o: ^Object, byte_off, n: int, v: u64, le: bool) {
    base, ok := dv_bytes(vm, o, byte_off, n); if !ok do return
    d := o.ab.data[:]
    if le { for i in 0 ..< n do d[base+i] = u8(v >> uint(8*i)) }
    else  { for i in 0 ..< n do d[base+n-1-i] = u8(v >> uint(8*i)) }
}

@(private = "file") dv_le :: proc(args: []Value, idx: int) -> bool { return truthy(arg(args, idx)) }

@(private = "file") dv_get_i8 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return dv_access(vm, this, a, .I8, false) }
@(private = "file") dv_set_i8 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return dv_access(vm, this, a, .I8, true) }
@(private = "file") dv_get_u8 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return dv_access(vm, this, a, .U8, false) }
@(private = "file") dv_set_u8 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return dv_access(vm, this, a, .U8, true) }
@(private = "file") dv_get_i16 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return dv_access(vm, this, a, .I16, false) }
@(private = "file") dv_set_i16 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return dv_access(vm, this, a, .I16, true) }
@(private = "file") dv_get_u16 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return dv_access(vm, this, a, .U16, false) }
@(private = "file") dv_set_u16 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return dv_access(vm, this, a, .U16, true) }
@(private = "file") dv_get_i32 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return dv_access(vm, this, a, .I32, false) }
@(private = "file") dv_set_i32 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return dv_access(vm, this, a, .I32, true) }
@(private = "file") dv_get_u32 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return dv_access(vm, this, a, .U32, false) }
@(private = "file") dv_set_u32 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return dv_access(vm, this, a, .U32, true) }
@(private = "file") dv_get_f16 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return dv_access(vm, this, a, .F16, false) }
@(private = "file") dv_set_f16 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return dv_access(vm, this, a, .F16, true) }
@(private = "file") dv_get_f32 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return dv_access(vm, this, a, .F32, false) }
@(private = "file") dv_set_f32 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return dv_access(vm, this, a, .F32, true) }
@(private = "file") dv_get_f64 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return dv_access(vm, this, a, .F64, false) }
@(private = "file") dv_set_f64 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return dv_access(vm, this, a, .F64, true) }
@(private = "file") dv_get_i64 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return dv_access(vm, this, a, .I64, false) }
@(private = "file") dv_set_i64 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return dv_access(vm, this, a, .I64, true) }
@(private = "file") dv_get_u64 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return dv_access(vm, this, a, .U64, false) }
@(private = "file") dv_set_u64 :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return dv_access(vm, this, a, .U64, true) }

// ── crypto (Web Crypto: getRandomValues + randomUUID) ────────────────────────
// Libs de ID (uuidv7, nanoid) fazem `crypto.getRandomValues(new Uint8Array(n))`.
// Sem isto, os campos aleatórios saíam NaN/fora do range e a lib lançava
// RangeError. NÃO é cripto de verdade (rand comum, determinístico p/ o render).

@(private = "file")
crypto_get_random_values :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := arg(args, 0).(^Object)
    if !ok || o.ab == nil || o.ta_kind == .None || o.ta_kind == .DataView {
        throw_type_error(vm, "crypto.getRandomValues requires an integer TypedArray")
        return arg(args, 0)
    }
    byte_len := o.ta_len * ta_bpe(o.ta_kind)
    for i in 0 ..< byte_len do o.ab.data[o.ta_off + i] = u8(rand.uint32())
    return o // devolve o MESMO array (spec)
}

@(private = "file")
crypto_random_uuid :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    hex := "0123456789abcdef"
    b: [16]u8
    for i in 0 ..< 16 do b[i] = u8(rand.uint32())
    b[6] = (b[6] & 0x0f) | 0x40 // versão 4
    b[8] = (b[8] & 0x3f) | 0x80 // variante
    sb: strings.Builder
    strings.builder_init(&sb); defer strings.builder_destroy(&sb)
    for i in 0 ..< 16 {
        if i == 4 || i == 6 || i == 8 || i == 10 do strings.write_byte(&sb, '-')
        strings.write_byte(&sb, hex[b[i] >> 4])
        strings.write_byte(&sb, hex[b[i] & 0x0f])
    }
    return own_str(vm, strings.to_string(sb))
}

@(private = "file")
install_crypto :: proc(vm: ^Interp) {
    c := new_object(vm)
    c.props["getRandomValues"] = mk_native(vm, crypto_get_random_values)
    c.props["randomUUID"]      = mk_native(vm, crypto_random_uuid)
    env_define(vm.global, "crypto", c)
}

// ── TextEncoder / TextDecoder (UTF-8) ────────────────────────────────────────
// Strings da engine já são UTF-8 (bytes), então encode/decode são reinterpretação
// direta. Só UTF-8 (o rótulo é aceito e reportado como "utf-8"). Faltavam — libs
// decodificam corpos de fetch/stream com `new TextDecoder().decode(buf)` e estouravam
// "TextDecoder is not a constructor" (gap-miner: apnews e cia.).

// Bytes de uma view (TypedArray/DataView) ou de um ArrayBuffer puro.
@(private = "file")
ta_view_bytes :: proc(o: ^Object) -> []u8 {
    if o == nil || o.ab == nil do return nil
    if o.ta_kind == .None do return o.ab.data[:] // ArrayBuffer inteiro
    byte_len := o.ta_len if o.ta_kind == .DataView else o.ta_len * ta_bpe(o.ta_kind)
    start := o.ta_off
    end   := o.ta_off + byte_len
    if start < 0 do start = 0
    if end > len(o.ab.data) do end = len(o.ab.data)
    if end < start do end = start
    return o.ab.data[start:end]
}

@(private = "file")
text_encoder_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o := new_object(vm)
    o.proto = vm.text_encoder_proto
    o.props["encoding"] = own_str(vm, "utf-8")
    return o
}

// Uint8Array com uma cópia de `bytes`.
@(private = "file")
ta_u8_from_bytes :: proc(vm: ^Interp, bytes: []u8) -> Value {
    res := make_typed_array(vm, .U8, []Value{f64(len(bytes))})
    if o, ok := res.(^Object); ok && o.ab != nil {
        for b, i in bytes do o.ab.data[o.ta_off + i] = b
    }
    return res
}

// encode(str) → Uint8Array com os bytes UTF-8. `encode()` sem arg → array vazio.
@(private = "file")
text_encoder_encode :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a0 := arg(args, 0)
    if s, ok := a0.(string); ok do return ta_u8_from_bytes(vm, transmute([]u8)s) // caminho comum
    if a0 == nil do return make_typed_array(vm, .U8, []Value{f64(0)})
    // não-string: coage via to_text (copia os bytes ANTES de destruir o builder)
    sb: strings.Builder; strings.builder_init(&sb); defer strings.builder_destroy(&sb)
    to_text(&sb, a0)
    return ta_u8_from_bytes(vm, transmute([]u8)strings.to_string(sb))
}

@(private = "file")
text_decoder_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o := new_object(vm)
    o.proto = vm.text_decoder_proto
    o.props["encoding"]  = own_str(vm, "utf-8") // só suportamos utf-8
    o.props["fatal"]     = false
    o.props["ignoreBOM"] = false
    return o
}

// decode(view) → string. Reinterpreta os bytes como UTF-8 (aproximação: sem validar
// nem trocar sequências inválidas por U+FFFD). Remove um BOM UTF-8 líder (padrão da
// spec com ignoreBOM=false). `decode()` sem arg → "".
@(private = "file")
text_decoder_decode :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := arg(args, 0).(^Object)
    if !ok || o.ab == nil do return own_str(vm, "")
    b := ta_view_bytes(o)
    if len(b) >= 3 && b[0] == 0xEF && b[1] == 0xBB && b[2] == 0xBF do b = b[3:] // strip BOM
    return own_str(vm, string(b)) // own_str CLONA (o buffer pode mudar/ser liberado)
}

// ── Blob ─────────────────────────────────────────────────────────────────────
// new Blob(parts, {type}) — junta strings (UTF-8) e BufferSources (TypedArray/
// ArrayBuffer/Blob) num blob imutável. Faltava — libs criam blobs p/ downloads,
// workers e object URLs. `.size`/`.type`/`.text()`/`.arrayBuffer()`/`.slice()`.
// Bytes guardados num ^Array_Buffer (reusa new_buffer + o cleanup de all_buffers).

@(private = "file")
blob_collect_bytes :: proc(vm: ^Interp, parts: Value, out: ^[dynamic]u8) {
    a, ok := parts.(^Array); if !ok do return // Blob() / Blob(não-iterável) → vazio
    for it in a.items {
        if s, sok := it.(string); sok {
            for b in transmute([]u8)s do append(out, b)
            continue
        }
        if o, ook := it.(^Object); ook && o.ab != nil { // TypedArray/ArrayBuffer/DataView/Blob
            for b in ta_view_bytes(o) do append(out, b)
            continue
        }
        sb: strings.Builder; strings.builder_init(&sb); defer strings.builder_destroy(&sb)
        to_text(&sb, it) // qualquer outra coisa: stringifica (spec)
        for b in transmute([]u8)strings.to_string(sb) do append(out, b)
    }
}

@(private = "file")
blob_make :: proc(vm: ^Interp, bytes: []u8, type_str: string) -> ^Object {
    ab := new_buffer(vm, len(bytes))
    if len(bytes) > 0 do copy(ab.data[:], bytes)
    o := new_object(vm)
    o.ab = ab
    o.proto = vm.blob_proto
    o.props["size"] = f64(len(bytes))
    o.props["type"] = own_str(vm, type_str)
    return o
}

@(private = "file")
blob_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    bytes: [dynamic]u8; defer delete(bytes)
    blob_collect_bytes(vm, arg(args, 0), &bytes)
    type_str := ""
    if opts, ok := arg(args, 1).(^Object); ok {
        if t, tok := opts.props["type"].(string); tok do type_str = t
    }
    return blob_make(vm, bytes[:], type_str)
}

// text() → Promise<string> (UTF-8). await é bloqueante → resolve na hora.
@(private = "file")
blob_text :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    p := promise_new(vm)
    s := ""
    if o, ok := this.(^Object); ok && o.ab != nil do s = string(o.ab.data[:])
    promise_resolve_with(vm, p, own_str(vm, s))
    return p
}

// arrayBuffer() → Promise<ArrayBuffer> (cópia independente dos bytes).
@(private = "file")
blob_array_buffer :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    p := promise_new(vm)
    n := 0
    o, ok := this.(^Object)
    if ok && o.ab != nil do n = len(o.ab.data)
    nb := new_buffer(vm, n)
    if n > 0 do copy(nb.data[:], o.ab.data[:])
    promise_resolve_with(vm, p, wrap_buffer(vm, nb))
    return p
}

// slice(start, end, contentType) → novo Blob com a fatia de bytes.
@(private = "file")
blob_slice :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := this.(^Object); if !ok || o.ab == nil do return this
    total := len(o.ab.data)
    begin := rel_index(arg(args, 0), total, 0)
    end   := rel_index(len(args) >= 2 ? args[1] : nil, total, total)
    if end < begin do end = begin
    ctype := ""
    if len(args) >= 3 { if t, tok := args[2].(string); tok do ctype = t }
    return blob_make(vm, o.ab.data[begin:end], ctype)
}

// ArrayBuffer.isView(x) — só views (TypedArray/DataView) contam; o buffer em si NÃO.
@(private = "file")
array_buffer_is_view :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := arg(args, 0).(^Object)
    if !ok do return false
    return o.ab != nil && o.ta_kind != .None
}

// ── acessores do %TypedArray%.prototype ─────────────────────────────────────
TA_BUFFER_KEY :: "#buffer" // o objeto ArrayBuffer de uma view (interno: `#` não enumera)

// Nº de índices PRÓPRIOS de `o` se ele é uma view TypedArray (0 com buffer
// destacado); ok=false para qualquer outro objeto. Os índices de uma view não moram
// em `props` (o hook typedarray_get os serve), então quem lista ou testa chaves
// próprias pergunta aqui — Object.keys, for-in, JSON, hasOwnProperty, e o
// HasProperty dos métodos genéricos de Array (`Array.prototype.map.call(ta, f)`).
ta_own_index_count :: proc(o: ^Object) -> (int, bool) {
    if o == nil || o.ab == nil || o.ta_kind == .None || o.ta_kind == .DataView do return 0, false
    return 0 if o.ab.detached else o.ta_len, true
}

// `this` tem de ser uma view TypedArray de verdade (não ArrayBuffer/DataView):
// senão TypeError. Buffer destacado: tamanhos e offset leem 0 (spec).
@(private = "file")
ta_view_of :: proc(vm: ^Interp, this: Value, what: string) -> ^Object {
    o, ok := this.(^Object)
    if !ok || o.ab == nil || o.ta_kind == .None || o.ta_kind == .DataView {
        throw_type_error(vm, fmt.tprintf("get %%TypedArray%%.prototype.%s called on incompatible receiver", what))
        return nil
    }
    return o
}

@(private = "file")
ta_get_buffer :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o := ta_view_of(vm, this, "buffer"); if o == nil do return nil
    return o.props[TA_BUFFER_KEY]
}

@(private = "file")
ta_get_byte_length :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o := ta_view_of(vm, this, "byteLength"); if o == nil do return nil
    return f64(0) if o.ab.detached else f64(o.ta_len * ta_bpe(o.ta_kind))
}

@(private = "file")
ta_get_byte_offset :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o := ta_view_of(vm, this, "byteOffset"); if o == nil do return nil
    return f64(0) if o.ab.detached else f64(0 if o.ta_oob else o.ta_off)
}

@(private = "file")
ta_get_length :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o := ta_view_of(vm, this, "length"); if o == nil do return nil
    return f64(0) if o.ab.detached else f64(o.ta_len)
}

// @@toStringTag: o nome do tipo numa view; undefined para qualquer outra coisa
// (este getter NÃO lança — spec 23.2.3.38).
@(private = "file")
ta_get_to_string_tag :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, ok := this.(^Object)
    if !ok || o.ab == nil || o.ta_kind == .None || o.ta_kind == .DataView do return nil
    return ta_name(o.ta_kind)
}

// ── instalação ───────────────────────────────────────────────────────────────

install_typed_arrays :: proc(vm: ^Interp) {
    // ArrayBuffer
    abp := new_object(vm)
    abp.props["slice"] = mk_builtin_method(vm, array_buffer_slice, "slice", 2)
    abp.props["resize"] = mk_builtin_method(vm, ab_resize, "resize", 1)
    abp.props["transfer"] = mk_builtin_method(vm, ab_transfer, "transfer", 0)
    abp.props["transferToFixedLength"] = mk_builtin_method(vm, ab_transfer_fixed, "transferToFixedLength", 0)
    abp.getters = make(map[string]^Function)
    abp.attrs = make(map[string]Prop_Attrs)
    for g in ([]struct{name: string, fn: Native_Fn}{
        {"byteLength", ab_byte_length}, {"maxByteLength", ab_max_length},
        {"resizable", ab_resizable}, {"detached", ab_detached}}) {
        abp.getters[g.name] = mk_builtin_method(vm, g.fn, own_str_raw(vm, strings.concatenate({"get ", g.name}, context.temp_allocator)), 0)
        abp.attrs[g.name] = {.Configurable}
    }
    abp.props[vm.sym_tostring_tag_key] = "ArrayBuffer"
    abp.attrs[vm.sym_tostring_tag_key] = {.Configurable}
    vm.array_buffer_proto = abp
    ab_ctor := mk_native(vm, array_buffer_ctor)
    ab_ctor.props = make(map[string]Value)
    ab_ctor.props["prototype"] = abp
    abp.props["constructor"] = ab_ctor
    // ArrayBuffer.isView(x): true p/ TypedArray e DataView, false p/ o resto
    // (inclusive p/ o PRÓPRIO ArrayBuffer — ele não é uma "view"). Faltava, e o
    // web player do spotify chama isso ao normalizar entrada binária.
    ab_ctor.props["isView"] = mk_native(vm, array_buffer_is_view)
    env_define(vm.global, "ArrayBuffer", ab_ctor)

    // %TypedArray%.prototype (spec 23.2.3): o protótipo COMUM dos nove, com os
    // acessores buffer/byteLength/byteOffset/length/@@toStringTag. Antes não existia
    // — `Object.getPrototypeOf(Uint8Array.prototype)` era Object.prototype — e o
    // propertyHelper.js do Test262 atual MORRIA ao carregar (lê
    // getOwnPropertyDescriptor(%TypedArray%.prototype, "byteLength").get).
    // As views seguem com as props próprias de sempre (os caminhos de leitura não
    // mudam); os getters servem a quem os pede pelo protótipo. Guardado na vaga
    // ta_protos[.None], já enraizada no GC.
    base := new_object(vm)
    base.proto = vm.object_proto
    base.getters = make(map[string]^Function)
    base.attrs = make(map[string]Prop_Attrs)
    Ta_Getter :: struct { name: string, fn: Native_Fn }
    for g in ([]Ta_Getter{{"buffer", ta_get_buffer}, {"byteLength", ta_get_byte_length},
                          {"byteOffset", ta_get_byte_offset}, {"length", ta_get_length}}) {
        base.getters[g.name] = mk_builtin_method(vm, g.fn, own_str_raw(vm, strings.concatenate({"get ", g.name}, context.temp_allocator)), 0)
        base.attrs[g.name] = {.Configurable}
    }
    if vm.sym_tostring_tag_key != "" {
        base.getters[vm.sym_tostring_tag_key] = mk_builtin_method(vm, ta_get_to_string_tag, "get [Symbol.toStringTag]", 0)
        base.attrs[vm.sym_tostring_tag_key] = {.Configurable}
    }
    vm.ta_protos[.None] = base

    // cada TypedArray
    kinds := []TA_Kind{.I8, .U8, .U8C, .I16, .U16, .I32, .U32, .F32, .F64, .F16, .I64, .U64}
    for k in kinds {
        p := new_object(vm)
        p.proto = base
        p.props["toLocaleString"] = mk_builtin_method(vm, ta_to_locale_string, "toLocaleString", 0)
        p.props["at"] = mk_builtin_method(vm, ta_at, "at", 1)
        p.props["findIndex"] = mk_builtin_method(vm, ta_find_index, "findIndex", 1)
        p.props["findLast"] = mk_builtin_method(vm, ta_find_last, "findLast", 1)
        p.props["findLastIndex"] = mk_builtin_method(vm, ta_find_last_index, "findLastIndex", 1)
        p.props["lastIndexOf"] = mk_builtin_method(vm, ta_last_index_of, "lastIndexOf", 1)
        p.props["reduceRight"] = mk_builtin_method(vm, ta_reduce_right, "reduceRight", 1)
        p.props["copyWithin"] = mk_builtin_method(vm, ta_copy_within, "copyWithin", 2)
        p.props["toReversed"] = mk_builtin_method(vm, ta_to_reversed, "toReversed", 0)
        p.props["toSorted"] = mk_builtin_method(vm, ta_to_sorted, "toSorted", 1)
        p.props["with"] = mk_builtin_method(vm, ta_with, "with", 2)
        p.props["set"]      = mk_native(vm, ta_set_method)
        p.props["subarray"] = mk_native(vm, ta_subarray)
        p.props["slice"]    = mk_native(vm, ta_slice)
        p.props["fill"]     = mk_native(vm, ta_fill)
        p.props["indexOf"]  = mk_native(vm, ta_index_of)
        p.props["includes"] = mk_native(vm, ta_includes)
        p.props["join"]     = mk_native(vm, ta_join)
        p.props["forEach"]  = mk_native(vm, ta_for_each)
        p.props["map"]      = mk_native(vm, ta_map)
        p.props["filter"]   = mk_native(vm, ta_filter)
        p.props["reduce"]   = mk_native(vm, ta_reduce)
        p.props["some"]     = mk_native(vm, ta_some)
        p.props["every"]    = mk_native(vm, ta_every)
        p.props["find"]     = mk_native(vm, ta_find)
        p.props["reverse"]  = mk_native(vm, ta_reverse)
        p.props["sort"]     = mk_native(vm, ta_sort)
        p.props["values"]   = mk_native(vm, ta_values)
        p.props["keys"]     = mk_native(vm, ta_keys)
        p.props["entries"]  = mk_native(vm, ta_entries)
        p.props["toString"] = mk_native(vm, ta_join) // "1,2,3"
        p.props[vm.sym_iterator_key] = mk_native(vm, ta_values) // for-of
        p.props["BYTES_PER_ELEMENT"] = f64(ta_bpe(k))
        vm.ta_protos[k] = p

        ctor := mk_native(vm, kind_ctor(k))
        ctor.name = ta_name(k)
        ctor.props = make(map[string]Value)
        ctor.props["prototype"] = p
        ctor.props["BYTES_PER_ELEMENT"] = f64(ta_bpe(k))
        ctor.props["from"] = mk_native(vm, ta_from)
        ctor.props["of"]   = mk_native(vm, ta_of)
        p.props["constructor"] = ctor
        env_define(vm.global, ta_name(k), ctor)
    }

    // DataView
    dp := new_object(vm)
    dp.props["getInt8"] = mk_builtin_method(vm, dv_get_i8, "getInt8", 1)
    dp.props["getUint8"] = mk_builtin_method(vm, dv_get_u8, "getUint8", 1)
    dp.props["getInt16"] = mk_builtin_method(vm, dv_get_i16, "getInt16", 1)
    dp.props["getUint16"] = mk_builtin_method(vm, dv_get_u16, "getUint16", 1)
    dp.props["getInt32"] = mk_builtin_method(vm, dv_get_i32, "getInt32", 1)
    dp.props["getUint32"] = mk_builtin_method(vm, dv_get_u32, "getUint32", 1)
    dp.props["getFloat32"] = mk_builtin_method(vm, dv_get_f32, "getFloat32", 1)
    dp.props["getFloat64"] = mk_builtin_method(vm, dv_get_f64, "getFloat64", 1)
    dp.props["setInt8"] = mk_builtin_method(vm, dv_set_i8, "setInt8", 2)
    dp.props["setUint8"] = mk_builtin_method(vm, dv_set_u8, "setUint8", 2)
    dp.props["setInt16"] = mk_builtin_method(vm, dv_set_i16, "setInt16", 2)
    dp.props["setUint16"] = mk_builtin_method(vm, dv_set_u16, "setUint16", 2)
    dp.props["setInt32"] = mk_builtin_method(vm, dv_set_i32, "setInt32", 2)
    dp.props["setUint32"] = mk_builtin_method(vm, dv_set_u32, "setUint32", 2)
    dp.props["setFloat32"] = mk_builtin_method(vm, dv_set_f32, "setFloat32", 2)
    dp.props["setFloat64"] = mk_builtin_method(vm, dv_set_f64, "setFloat64", 2)
    dp.getters = make(map[string]^Function)
    dp.attrs = make(map[string]Prop_Attrs)
    for g in ([]struct{name: string, fn: Native_Fn}{{"buffer", dv_buffer}, {"byteLength", dv_length}, {"byteOffset", dv_offset}}) {
        dp.getters[g.name] = mk_builtin_method(vm, g.fn, own_str_raw(vm, strings.concatenate({"get ", g.name}, context.temp_allocator)), 0)
        dp.attrs[g.name] = {.Configurable}
    }
    dp.props["getFloat16"] = mk_builtin_method(vm, dv_get_f16, "getFloat16", 1)
    dp.props["setFloat16"] = mk_builtin_method(vm, dv_set_f16, "setFloat16", 2)
    dp.props["getBigInt64"] = mk_builtin_method(vm, dv_get_i64, "getBigInt64", 1)
    dp.props["setBigInt64"] = mk_builtin_method(vm, dv_set_i64, "setBigInt64", 2)
    dp.props["getBigUint64"] = mk_builtin_method(vm, dv_get_u64, "getBigUint64", 1)
    dp.props["setBigUint64"] = mk_builtin_method(vm, dv_set_u64, "setBigUint64", 2)
    dp.props[vm.sym_tostring_tag_key] = "DataView"
    dp.attrs[vm.sym_tostring_tag_key] = {.Configurable}
    vm.dataview_proto = dp
    dv_ctor := mk_native(vm, dataview_ctor)
    dv_ctor.props = make(map[string]Value)
    dv_ctor.props["prototype"] = dp
    dp.props["constructor"] = dv_ctor
    env_define(vm.global, "DataView", dv_ctor)

    // TextEncoder (encode → Uint8Array) / TextDecoder (decode → string), só UTF-8.
    tep := new_object(vm)
    tep.props["encode"] = mk_native(vm, text_encoder_encode)
    vm.text_encoder_proto = tep
    te_ctor := mk_native(vm, text_encoder_ctor); te_ctor.name = "TextEncoder"
    te_ctor.props = make(map[string]Value)
    te_ctor.props["prototype"] = tep
    tep.props["constructor"] = te_ctor
    env_define(vm.global, "TextEncoder", te_ctor)

    tdp := new_object(vm)
    tdp.props["decode"] = mk_native(vm, text_decoder_decode)
    vm.text_decoder_proto = tdp
    td_ctor := mk_native(vm, text_decoder_ctor); td_ctor.name = "TextDecoder"
    td_ctor.props = make(map[string]Value)
    td_ctor.props["prototype"] = tdp
    tdp.props["constructor"] = td_ctor
    env_define(vm.global, "TextDecoder", td_ctor)

    // Blob (parts → bytes; text/arrayBuffer/slice + size/type)
    bp := new_object(vm)
    bp.props["text"]        = mk_native(vm, blob_text)
    bp.props["arrayBuffer"] = mk_native(vm, blob_array_buffer)
    bp.props["slice"]       = mk_native(vm, blob_slice)
    vm.blob_proto = bp
    blob_c := mk_native(vm, blob_ctor); blob_c.name = "Blob"
    blob_c.props = make(map[string]Value)
    blob_c.props["prototype"] = bp
    bp.props["constructor"] = blob_c
    env_define(vm.global, "Blob", blob_c)

    install_crypto(vm) // crypto.getRandomValues/randomUUID (usa TypedArrays)
}

// Preserve the Number/BigInt content type throughout element operations.
@(private = "file")
ta_big :: proc(k: TA_Kind) -> bool { return k == .I64 || k == .U64 }

@(private = "file")
ta_convert :: proc(vm: ^Interp, k: TA_Kind, value: Value) -> Value {
    if !ta_big(k) do return ta_number(vm, value)
    v := to_primitive(vm, value, true)
    if vm.throwing do return nil
    #partial switch x in v {
    case ^BigInt: return x
    case bool: return bigint_from_i64(vm, 1 if x else 0)
    case string:
        b, ok := bigint_from_string(vm, x)
        if ok do return b
        vm.thrown = mk_error(vm, "SyntaxError", "Invalid BigInt string")
        vm.throwing = true
        return nil
    }
    throw_type_error(vm, "Cannot convert value to BigInt")
    return nil
}

@(private = "file")
ta_big_bits :: proc(b: ^BigInt) -> u64 {
    // Accumulation in u64 gives modulo 2^64, including arbitrary precision inputs.
    text := bigint_to_string(b, 16)
    defer delete(text)
    bits: u64
    negative := len(text) > 0 && text[0] == '-'
    for c in text {
        if c == '-' do continue
        digit := u64(c - '0')
        if c >= 'a' do digit = u64(c - 'a' + 10)
        bits = bits * 16 + digit
    }
    return 0 - bits if negative else bits
}

@(private = "file")
ta_bits_big :: proc(vm: ^Interp, bits: u64, signed: bool) -> Value {
    if signed do return bigint_from_i64(vm, i64(bits))
    b, _ := bigint_from_string(vm, fmt.tprintf("%d", bits))
    return b
}

@(private = "file")
ta_value :: proc(vm: ^Interp, o: ^Object, i: int) -> Value {
    if o.ab.detached || o.ta_oob || i < 0 || i >= o.ta_len do return nil
    if ta_big(o.ta_kind) do return ta_bits_big(vm, rd_u64(o.ab.data[:], o.ta_off + i*8), o.ta_kind == .I64)
    return ta_read_number(o, i)
}

@(private = "file")
ta_store :: proc(vm: ^Interp, o: ^Object, i: int, value: Value) {
    if vm.throwing do return
    v := ta_convert(vm, o.ta_kind, value)
    if vm.throwing || o.ab.detached || o.ta_oob || i < 0 || i >= o.ta_len do return
    if b, ok := v.(^BigInt); ok { wr_u64(o.ab.data[:], o.ta_off + i*8, ta_big_bits(b)); return }
    ta_write_number(o, i, v.(f64))
}

// Refresh cached view lengths after resizing; retain the original fixed extent
// so an out-of-bounds view becomes usable again when the buffer grows.
@(private = "file")
ab_refresh_views :: proc(vm: ^Interp, ab: ^Array_Buffer) {
    for o in vm.all_objects {
        if o.ab != ab || o.ta_kind == .None do continue
        bpe := ta_bpe(o.ta_kind)
        available := len(ab.data) - o.ta_off
        o.ta_oob = available < 0 || (!o.ta_auto && o.ta_fixed_len > available / bpe)
        if o.ta_oob || ab.detached { o.ta_len = 0 }
        else if o.ta_auto { o.ta_len = available / bpe }
        else { o.ta_len = o.ta_fixed_len }
    }
}

@(private = "file")
ab_receiver :: proc(vm: ^Interp, this: Value) -> ^Object {
    o, ok := this.(^Object)
    if !ok || o.ab == nil || o.ta_kind != .None || o.proto == vm.blob_proto {
        throw_type_error(vm, "Receiver is not an ArrayBuffer"); return nil
    }
    return o
}

@(private = "file")
ab_byte_length :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    o := ab_receiver(vm, this); if o == nil do return nil
    return f64(0) if o.ab.detached else f64(len(o.ab.data))
}
@(private = "file")
ab_max_length :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    o := ab_receiver(vm, this); if o == nil do return nil
    if o.ab.detached do return f64(0)
    return f64(o.ab.max_byte_length) if o.ab.resizable else f64(len(o.ab.data))
}
@(private = "file")
ab_resizable :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    o := ab_receiver(vm, this); if o == nil do return nil
    return o.ab.resizable
}
@(private = "file")
ab_detached :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    o := ab_receiver(vm, this); if o == nil do return nil
    return o.ab.detached
}
@(private = "file")
ab_resize :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    o := ab_receiver(vm, this); if o == nil do return nil
    if !o.ab.resizable { throw_type_error(vm, "ArrayBuffer is not resizable"); return nil }
    n := ta_index(vm, arg(a, 0)); if vm.throwing do return nil
    if o.ab.detached { throw_type_error(vm, "ArrayBuffer is detached"); return nil }
    if n > o.ab.max_byte_length { ta_range_error(vm); return nil }
    old := len(o.ab.data)
    resize(&o.ab.data, n)
    if n > old do for i in old ..< n do o.ab.data[i] = 0
    ab_refresh_views(vm, o.ab)
    return nil
}
@(private = "file")
ab_transfer_impl :: proc(vm: ^Interp, this: Value, a: []Value, fixed: bool) -> Value {
    o := ab_receiver(vm, this); if o == nil do return nil
    n := len(o.ab.data)
    if arg(a, 0) != nil do n = ta_index(vm, a[0])
    if vm.throwing do return nil
    if o.ab.detached { throw_type_error(vm, "ArrayBuffer is detached"); return nil }
    if n > 2147483647 || (!fixed && o.ab.resizable && n > o.ab.max_byte_length) { ta_range_error(vm); return nil }
    nb := new_buffer(vm, n)
    nb.resizable = o.ab.resizable && !fixed
    nb.max_byte_length = o.ab.max_byte_length if nb.resizable else n
    copy(nb.data[:], o.ab.data[:])
    o.ab.detached = true
    resize(&o.ab.data, 0)
    ab_refresh_views(vm, o.ab)
    return wrap_buffer(vm, nb)
}
@(private = "file")
ab_transfer :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return ab_transfer_impl(vm, this, a, false) }
@(private = "file")
ab_transfer_fixed :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return ab_transfer_impl(vm, this, a, true) }

@(private = "file")
dv_access :: proc(vm: ^Interp, this: Value, a: []Value, kind: TA_Kind, write: bool) -> Value {
    o, ok := this.(^Object)
    if !ok || o.ab == nil || o.ta_kind != .DataView { throw_type_error(vm, "Receiver is not a DataView"); return nil }
    off := ta_index(vm, arg(a, 0)); if vm.throwing do return nil
    value: Value
    if write { value = ta_convert(vm, kind, arg(a, 1)); if vm.throwing do return nil }
    le := dv_le(a, 2 if write else 1)
    n := ta_bpe(kind)
    _, valid := dv_bytes(vm, o, off, n); if !valid do return nil
    if write {
        bits: u64
        if b, big := value.(^BigInt); big { bits = ta_big_bits(b) }
        else {
            v := value.(f64)
            #partial switch kind {
            case .F16: bits = u64(ta_float16_bits(v))
            case .F32: bits = u64(transmute(u32)f32(v))
            case .F64: bits = transmute(u64)v
            case: bits = u64(to_u32(v))
            }
        }
        dv_write_u(vm, o, off, n, bits, le)
        return nil
    }
    bits, _ := dv_read_u(vm, o, off, n, le)
    if ta_big(kind) do return ta_bits_big(vm, bits, kind == .I64)
    #partial switch kind {
    case .I8: return f64(i8(u8(bits)))
    case .U8: return f64(u8(bits))
    case .I16: return f64(i16(u16(bits)))
    case .U16: return f64(u16(bits))
    case .I32: return f64(i32(u32(bits)))
    case .U32: return f64(u32(bits))
    case .F16: return f64(transmute(f16)u16(bits))
    case .F32: return f64(transmute(f32)u32(bits))
    case .F64: return transmute(f64)bits
    }
    return nil
}
@(private = "file")
dv_buffer :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    o, ok := this.(^Object)
    if !ok || o.ta_kind != .DataView || o.ab == nil { throw_type_error(vm, "Receiver is not a DataView"); return nil }
    return o.props[TA_BUFFER_KEY]
}
@(private = "file")
dv_length :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    o, _ := this.(^Object)
    if !is_dv(vm, o) do return nil
    return f64(0) if o.ab.detached || o.ta_oob else f64(o.ta_len)
}
@(private = "file")
dv_offset :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    o, _ := this.(^Object)
    if !is_dv(vm, o) do return nil
    return f64(0) if o.ab.detached || o.ta_oob else f64(o.ta_off)
}

// Round binary64 directly to binary16 using round-to-nearest, ties-to-even.
// The compiler's f16 cast rounds midpoint cases away from zero on this target.
@(private = "file")
ta_float16_bits :: proc(v: f64) -> u16 {
    bits := transmute(u64)v
    sign := u16((bits >> 48) & 0x8000)
    exponent := int((bits >> 52) & 0x7ff)
    fraction := bits & 0x000fffffffffffff
    if exponent == 0x7ff do return sign | (0x7e00 if fraction != 0 else 0x7c00)
    e := exponent - 1023
    if e > 15 do return sign | 0x7c00
    if e < -25 do return sign
    significand := fraction | (u64(1) << 52)
    shift := 42 if e >= -14 else 28 - e
    rounded := significand >> uint(shift)
    remainder := significand & ((u64(1) << uint(shift)) - 1)
    half := u64(1) << uint(shift - 1)
    if remainder > half || (remainder == half && (rounded & 1) != 0) do rounded += 1
    if e < -14 do return sign | u16(rounded)
    return sign | u16((e + 14) * 1024 + int(rounded))
}

@(private = "file")
is_dv :: proc(vm: ^Interp, o: ^Object) -> bool {
    if o == nil || o.ab == nil || o.ta_kind != .DataView { throw_type_error(vm, "Receiver is not a DataView"); return false }
    return true
}
