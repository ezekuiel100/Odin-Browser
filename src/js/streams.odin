package js

// Streams API (mínima, funcional) — ReadableStream + controller/reader/asyncIterator,
// e stubs leves de WritableStream/TransformStream/estratégias de fila.
//
// MOTIVAÇÃO (gap-report pós-triagem anti-bot, M117): docker/medium/shopify fazem
// `new ReadableStream(...)` INCONDICIONAL (bundles evergreen) → "is not a
// constructor" quando ausente. A engine não tinha nada de Streams.
//
// APROXIMAÇÕES (net.fetch não faz streaming; sem backpressure real):
//  - `pull(controller)` é chamado SÍNCRONO antes de cada read — funciona p/ fontes
//    que enfileiram em start/pull de forma síncrona (wrappers de buffer, o caso comum).
//  - `read()` devolve uma Promise já assentada: {value,chunk} se há dado; {done:true}
//    quando a fila esvazia e a fonte não produziu mais (não há evento async p/ esperar).
//  - `tee()` duplica o buffer ATUAL; `pipeTo` resolve vazio; `pipeThrough` devolve
//    `transform.readable`; TransformStream.readable nasce fechado (termina limpo em vez
//    de pendurar o consumidor).

install_streams :: proc(vm: ^Interp) {
    // ── ReadableStream ──
    rp := new_object(vm)
    rp.props["getReader"]   = mk_native(vm, rs_get_reader)
    rp.props["cancel"]      = mk_native(vm, rs_cancel_stream)
    rp.props["tee"]         = mk_native(vm, rs_tee)
    rp.props["pipeTo"]      = mk_native(vm, rs_pipe_to)
    rp.props["pipeThrough"] = mk_native(vm, rs_pipe_through)
    rp.props["locked"]      = false
    rp.proto = vm.object_proto // instâncias herdam Object.prototype (instanceof Object, hasOwnProperty…)
    if vm.sym_async_iterator_key != "" do rp.props[vm.sym_async_iterator_key] = mk_native(vm, rs_async_iterator)
    vm.web_rstream_proto = rp
    rctor := mk_native(vm, readable_stream_ctor)
    rctor.props = make(map[string]Value)
    rctor.props["prototype"] = rp
    env_define(vm.global, "ReadableStream", rctor)

    // ── WritableStream (stub funcional) ──
    wp := new_object(vm)
    wp.props["getWriter"] = mk_native(vm, ws_get_writer)
    wp.props["close"]     = mk_native(vm, ws_resolved_undef)
    wp.props["abort"]     = mk_native(vm, ws_resolved_undef)
    wp.props["locked"]    = false
    wp.proto = vm.object_proto
    vm.web_wstream_proto = wp
    wctor := mk_native(vm, writable_stream_ctor)
    wctor.props = make(map[string]Value)
    wctor.props["prototype"] = wp
    env_define(vm.global, "WritableStream", wctor)

    // ── TransformStream + TextEncoder/DecoderStream / estratégias (stubs) ──
    // TextEncoder/DecoderStream aparecem NA MESMA cadeia de uso do ReadableStream
    // (docker/medium/shopify: `new TextEncoderStream()` logo após). Como o pipeThrough
    // aqui é passthrough e o fetch não faz streaming, são transform-shaped inertes
    // (readable fechado): limpam o throw sem prometer streaming real.
    env_define(vm.global, "TransformStream",    mk_native(vm, transform_stream_ctor))
    env_define(vm.global, "TextEncoderStream",  mk_native(vm, text_encoder_stream_ctor))
    env_define(vm.global, "TextDecoderStream",  mk_native(vm, text_decoder_stream_ctor))
    env_define(vm.global, "CountQueuingStrategy",      mk_native(vm, count_qs_ctor))
    env_define(vm.global, "ByteLengthQueuingStrategy", mk_native(vm, bytelen_qs_ctor))
}

// transform-stub: { readable: <ReadableStream fechado/vazio>, writable: <WS stub> }
@(private = "file")
make_transform_stub :: proc(vm: ^Interp) -> ^Object {
    obj := new_object(vm)
    rd := new_object(vm)
    rd.proto = vm.web_rstream_proto
    rd.props["_chunks"] = new_array(vm)
    rd.props["_closed"] = true
    rd.props["_error"]  = nil
    obj.props["readable"] = rd
    wr := new_object(vm)
    wr.proto = vm.web_wstream_proto
    obj.props["writable"] = wr
    return obj
}

// ── helpers ──────────────────────────────────────────────────────────────────

@(private = "file")
rs_iter_result :: proc(vm: ^Interp, value: Value, done: bool) -> ^Object {
    r := new_object(vm)
    r.props["value"] = value
    r.props["done"]  = done
    return r
}

@(private = "file")
rs_resolved :: proc(vm: ^Interp, v: Value) -> ^Object {
    p := promise_new(vm)
    promise_resolve_with(vm, p, v)
    return p
}

// o objeto-stream referenciado por um controller/reader/iterator (via `_stream`).
@(private = "file")
rs_stream_of :: proc(this: Value) -> ^Object {
    if o, ok := this.(^Object); ok {
        if st, ok2 := o.props["_stream"].(^Object); ok2 do return st
    }
    return nil
}

@(private = "file")
rs_is_closed :: proc(st: ^Object) -> bool {
    if b, ok := st.props["_closed"].(bool); ok do return b
    return false
}

// ── ReadableStream ───────────────────────────────────────────────────────────

@(private = "file")
readable_stream_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    obj := new_object(vm)
    obj.proto = vm.web_rstream_proto
    obj.props["_chunks"] = new_array(vm)
    obj.props["_closed"] = false
    obj.props["_error"]  = nil
    src: ^Object = nil
    if len(args) >= 1 { src, _ = args[0].(^Object) }
    if src != nil do obj.props["_source"] = src

    ctrl := new_object(vm)
    ctrl.props["_stream"]     = obj
    ctrl.props["enqueue"]     = mk_native(vm, rs_ctrl_enqueue)
    ctrl.props["close"]       = mk_native(vm, rs_ctrl_close)
    ctrl.props["error"]       = mk_native(vm, rs_ctrl_error)
    ctrl.props["desiredSize"] = f64(1)
    obj.props["_controller"]  = ctrl

    if src != nil { // underlyingSource.start(controller) — costuma enfileirar aqui
        if startfn, ok := get_member(vm, src, "start").(^Function); ok {
            call_function(vm, startfn, src, []Value{ctrl})
        }
    }
    return obj
}

@(private = "file")
rs_ctrl_enqueue :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    st := rs_stream_of(this)
    if st == nil do return nil
    if arr, ok := st.props["_chunks"].(^Array); ok {
        append(&arr.items, len(args) >= 1 ? args[0] : nil)
    }
    return nil
}

@(private = "file")
rs_ctrl_close :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if st := rs_stream_of(this); st != nil do st.props["_closed"] = true
    return nil
}

@(private = "file")
rs_ctrl_error :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if st := rs_stream_of(this); st != nil {
        st.props["_error"]  = len(args) >= 1 ? args[0] : nil
        st.props["_closed"] = true
    }
    return nil
}

@(private = "file")
rs_get_reader :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    st, ok := this.(^Object)
    if !ok do return nil
    rd := new_object(vm)
    rd.props["_stream"]     = st
    rd.props["read"]        = mk_native(vm, rs_read)
    rd.props["releaseLock"] = mk_native(vm, ws_noop)
    rd.props["cancel"]      = mk_native(vm, rs_cancel_stream) // this=reader → _stream
    rd.props["closed"]      = rs_resolved(vm, nil)
    return rd
}

// read(): assenta síncrono. Serve tanto o reader quanto o async-iterator (ambos
// têm `_stream`).
@(private = "file")
rs_read :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    st := rs_stream_of(this)
    if st == nil do return rs_resolved(vm, rs_iter_result(vm, nil, true))

    arr, _ := st.props["_chunks"].(^Array)
    closed := rs_is_closed(st)
    // dá uma chance de a fonte produzir (pull síncrono) se está vazio e aberto
    if (arr == nil || len(arr.items) == 0) && !closed {
        if src, ok := st.props["_source"].(^Object); ok {
            if pull, ok2 := get_member(vm, src, "pull").(^Function); ok2 {
                call_function(vm, pull, src, []Value{st.props["_controller"]})
                closed = rs_is_closed(st)
            }
        }
    }
    p := promise_new(vm)
    if arr != nil && len(arr.items) > 0 {
        v := arr.items[0]
        ordered_remove(&arr.items, 0)
        promise_resolve_with(vm, p, rs_iter_result(vm, v, false))
    } else if errv, has := st.props["_error"]; has && errv != nil {
        promise_settle(vm, p, PROMISE_REJECTED, errv)
    } else {
        promise_resolve_with(vm, p, rs_iter_result(vm, nil, true))
    }
    return p
}

@(private = "file")
rs_cancel_stream :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    // this pode ser o stream (stream.cancel) ou um reader (reader.cancel → _stream)
    st, ok := this.(^Object)
    if ok {
        if inner := rs_stream_of(this); inner != nil do st = inner
    }
    if st != nil {
        st.props["_closed"] = true
        if arr, aok := st.props["_chunks"].(^Array); aok do clear(&arr.items)
        if src, sok := st.props["_source"].(^Object); sok {
            if cfn, cok := get_member(vm, src, "cancel").(^Function); cok {
                call_function(vm, cfn, src, args)
            }
        }
    }
    return rs_resolved(vm, nil)
}

@(private = "file")
rs_clone :: proc(vm: ^Interp, st: ^Object) -> ^Object {
    c := new_object(vm)
    c.proto = vm.web_rstream_proto
    ca := new_array(vm)
    if arr, ok := st.props["_chunks"].(^Array); ok {
        for it in arr.items do append(&ca.items, it)
    }
    c.props["_chunks"] = ca
    c.props["_closed"] = rs_is_closed(st)
    c.props["_error"]  = st.props["_error"]
    return c
}

@(private = "file")
rs_tee :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    res := new_array(vm)
    if st, ok := this.(^Object); ok {
        append(&res.items, rs_clone(vm, st))
        append(&res.items, rs_clone(vm, st))
    }
    return res
}

@(private = "file")
rs_pipe_to :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return rs_resolved(vm, nil) // aproximação: consome/descarta
}

@(private = "file")
rs_pipe_through :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if len(args) >= 1 {
        if t, ok := args[0].(^Object); ok do return get_member(vm, t, "readable")
    }
    return nil
}

@(private = "file")
rs_async_iterator :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    st, ok := this.(^Object)
    if !ok do return nil
    it := new_object(vm)
    it.props["_stream"] = st
    it.props["next"]    = mk_native(vm, rs_read) // reusa read (usa _stream)
    it.props["return"]  = mk_native(vm, rs_aiter_return)
    if vm.sym_async_iterator_key != "" do it.props[vm.sym_async_iterator_key] = mk_native(vm, rs_aiter_self)
    return it
}

@(private = "file")
rs_aiter_self :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return this }

@(private = "file")
rs_aiter_return :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return rs_resolved(vm, rs_iter_result(vm, len(args) >= 1 ? args[0] : nil, true))
}

// ── WritableStream / TransformStream / estratégias (stubs) ────────────────────

@(private = "file")
ws_noop :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return nil }

@(private = "file")
ws_resolved_undef :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return rs_resolved(vm, nil) }

@(private = "file")
writable_stream_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    obj := new_object(vm)
    obj.proto = vm.web_wstream_proto
    if len(args) >= 1 { if s, ok := args[0].(^Object); ok do obj.props["_sink"] = s }
    return obj
}

@(private = "file")
ws_get_writer :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    st, _ := this.(^Object)
    w := new_object(vm)
    if st != nil do w.props["_stream"] = st
    w.props["write"]       = mk_native(vm, ws_write)
    w.props["close"]       = mk_native(vm, ws_resolved_undef)
    w.props["abort"]       = mk_native(vm, ws_resolved_undef)
    w.props["releaseLock"] = mk_native(vm, ws_noop)
    w.props["ready"]       = rs_resolved(vm, nil)
    w.props["closed"]      = rs_resolved(vm, nil)
    w.props["desiredSize"] = f64(1)
    return w
}

@(private = "file")
ws_write :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    // encaminha p/ sink.write(chunk) se houver; sempre resolve
    if w, ok := this.(^Object); ok {
        if st, sok := w.props["_stream"].(^Object); sok {
            if sink, k := st.props["_sink"].(^Object); k {
                if wfn, wok := get_member(vm, sink, "write").(^Function); wok {
                    call_function(vm, wfn, sink, args)
                }
            }
        }
    }
    return rs_resolved(vm, nil)
}

@(private = "file")
transform_stream_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return make_transform_stub(vm)
}

@(private = "file")
text_encoder_stream_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    obj := make_transform_stub(vm)
    obj.props["encoding"] = own_str(vm, "utf-8")
    return obj
}

@(private = "file")
text_decoder_stream_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    obj := make_transform_stub(vm)
    obj.props["encoding"] = own_str(vm, "utf-8")
    obj.props["fatal"]     = false
    obj.props["ignoreBOM"] = false
    return obj
}

@(private = "file")
count_qs_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    obj := new_object(vm)
    if len(args) >= 1 { if o, ok := args[0].(^Object); ok do obj.props["highWaterMark"] = get_member(vm, o, "highWaterMark") }
    obj.props["size"] = mk_native(vm, qs_size_one)
    return obj
}

@(private = "file")
bytelen_qs_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    obj := new_object(vm)
    if len(args) >= 1 { if o, ok := args[0].(^Object); ok do obj.props["highWaterMark"] = get_member(vm, o, "highWaterMark") }
    obj.props["size"] = mk_native(vm, qs_size_bytelen)
    return obj
}

@(private = "file")
qs_size_one :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return f64(1) }

@(private = "file")
qs_size_bytelen :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    if len(args) >= 1 {
        if o, ok := args[0].(^Object); ok {
            if bl := get_member(vm, o, "byteLength"); bl != nil do return as_number(bl)
            if l := get_member(vm, o, "length"); l != nil do return as_number(l)
        }
    }
    return f64(0)
}
