package js

// Continuations use VM-owned objects so pending input promises can resume later.
// No timer pumping or eager collection: each next() follows the previous mapper.
@(private = "file")
from_async_callback :: proc(vm: ^Interp, s: ^Object, stage: string, rejected := false) -> ^Function {
    hold := new_object(vm)
    hold.props["state"] = s
    hold.props["stage"] = stage
    hold.props["rejected"] = rejected
    f := new_function(vm)
    f.native = from_async_resume
    f.bound = hold
    return f
}

@(private = "file")
from_async_await :: proc(vm: ^Interp, s: ^Object, value: Value, stage: string) {
    promise_then_impl(vm, promise_for_await(vm, value),
        from_async_callback(vm, s, stage), from_async_callback(vm, s, stage, true))
}

@(private = "file")
from_async_fail :: proc(vm: ^Interp, s: ^Object, close: bool) {
    exc := vm.thrown
    vm.throwing = false; vm.thrown = nil
    s.props["error"] = exc
    iter := s.props["iterator"]
    if close && iter != nil {
        ret := get_member(vm, iter, "return")
        if fn, ok := ret.(^Function); ok && !vm.throwing {
            result := call_function(vm, fn, iter, nil)
            if !vm.throwing && truthy(s.props["sync"]) {
                if is_primitive(result) {
                    throw_type_error(vm, "Invalid iterator return result")
                } else {
                    get_member(vm, result, "done")
                    if !vm.throwing do result = get_member(vm, result, "value")
                }
            }
            if !vm.throwing {
                from_async_await(vm, s, result, "close")
                return
            }
        }
        // An abrupt completion from return must not replace the original error.
        vm.throwing = false; vm.thrown = nil
    }
    promise_settle(vm, s.props["promise"].(^Object), PROMISE_REJECTED, exc)
}

@(private = "file")
from_async_finish :: proc(vm: ^Interp, s: ^Object) {
    out := s.props["out"]
    if !set_member(vm, out, "length", s.props["index"]) && !vm.throwing {
        throw_type_error(vm, "Cannot set Array.fromAsync result length")
    }
    if vm.throwing { from_async_fail(vm, s, false); return }
    promise_resolve_with(vm, s.props["promise"].(^Object), out)
}

@(private = "file")
from_async_store :: proc(vm: ^Interp, s: ^Object, value: Value) {
    i := as_int(s.props["index"])
    desc := new_object(vm)
    desc.props["value"] = value
    desc.props["writable"] = true
    desc.props["enumerable"] = true
    desc.props["configurable"] = true
    obj_define_property(vm, nil, []Value{s.props["out"], f64(i), desc})
    if vm.throwing { from_async_fail(vm, s, true); return }
    s.props["index"] = f64(i + 1)
    from_async_next(vm, s)
}

@(private = "file")
from_async_map :: proc(vm: ^Interp, s: ^Object, value: Value) {
    if fn, mapped := s.props["mapper"].(^Function); mapped {
        result := call_function(vm, fn, s.props["thisArg"], []Value{value, s.props["index"]})
        if vm.throwing { from_async_fail(vm, s, true); return }
        from_async_await(vm, s, result, "mapped")
    } else {
        from_async_store(vm, s, value)
    }
}

@(private = "file")
from_async_next :: proc(vm: ^Interp, s: ^Object) {
    if step_guard(vm) { from_async_fail(vm, s, false); return }
    if s.props["iterator"] == nil {
        i := as_int(s.props["index"])
        if i >= as_int(s.props["length"]) { from_async_finish(vm, s); return }
        value := array_like_get(vm, s.props["source"], i)
        if vm.throwing { from_async_fail(vm, s, false); return }
        from_async_await(vm, s, value, "value")
        return
    }
    if as_number(s.props["index"]) >= 9007199254740991 {
        throw_type_error(vm, "Array.fromAsync result is too large")
        from_async_fail(vm, s, true)
        return
    }
    fn, callable := s.props["next"].(^Function)
    if !callable { throw_type_error(vm, "Iterator next is not callable"); from_async_fail(vm, s, false); return }
    result := call_function(vm, fn, s.props["iterator"], nil)
    if vm.throwing { from_async_fail(vm, s, false); return }
    if truthy(s.props["sync"]) {
        if is_primitive(result) { throw_type_error(vm, "Invalid iterator result"); from_async_fail(vm, s, false); return }
        done := get_member(vm, result, "done")
        if vm.throwing { from_async_fail(vm, s, false); return }
        value := get_member(vm, result, "value")
        if vm.throwing { from_async_fail(vm, s, false); return }
        s.props["done"] = truthy(done)
        from_async_await(vm, s, value, "syncValue")
    } else {
        from_async_await(vm, s, result, "next")
    }
}

@(private = "file")
from_async_resume :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    hold := vm.native_bound.(^Object)
    s := hold.props["state"].(^Object)
    stage := hold.props["stage"].(string)
    value := arg(args, 0)
    if stage == "close" {
        promise_settle(vm, s.props["promise"].(^Object), PROMISE_REJECTED, s.props["error"])
    } else if truthy(hold.props["rejected"]) {
        vm.throwing = true; vm.thrown = value
        from_async_fail(vm, s, stage == "mapped" || stage == "syncValue" && !truthy(s.props["done"]))
    } else {
        switch stage {
        case "syncValue":
            result := new_object(vm)
            result.props["value"] = value
            result.props["done"] = s.props["done"]
            from_async_await(vm, s, result, "next")
        case "next":
            if is_primitive(value) { throw_type_error(vm, "Invalid iterator result"); from_async_fail(vm, s, false); return nil }
            done := get_member(vm, value, "done")
            if vm.throwing { from_async_fail(vm, s, false); return nil }
            if truthy(done) { from_async_finish(vm, s); return nil }
            item := get_member(vm, value, "value")
            if vm.throwing { from_async_fail(vm, s, false); return nil }
            from_async_map(vm, s, item)
        case "value": from_async_map(vm, s, value)
        case "mapped": from_async_store(vm, s, value)
        }
    }
    return nil
}

arr_from_async :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    s := new_object(vm)
    p := promise_new(vm)
    s.props["promise"] = p
    s.props["source"] = arg(args, 0)
    s.props["mapper"] = arg(args, 1)
    s.props["thisArg"] = arg(args, 2)
    s.props["index"] = f64(0)
    from_async_start(vm, s, this)
    if vm.throwing do from_async_fail(vm, s, false)
    return p
}

@(private = "file")
from_async_start :: proc(vm: ^Interp, s: ^Object, ctor: Value) {
    mapper := s.props["mapper"]
    if _, ok := mapper.(^Function); mapper != nil && !ok { throw_type_error(vm, "Mapper is not callable"); return }
    src := s.props["source"]
    if is_nullish(src) { throw_type_error(vm, "Array.fromAsync called on null or undefined"); return }
    method := get_member(vm, src, vm.sym_async_iterator_key)
    if vm.throwing do return
    if is_nullish(method) {
        s.props["sync"] = true
        method = get_member(vm, src, vm.sym_iterator_key)
        if vm.throwing do return
    }
    ctor_args: []Value
    length_arg: [1]Value
    if !is_nullish(method) {
        fn, ok := method.(^Function)
        if !ok { throw_type_error(vm, "Iterator method is not callable"); return }
        iter := call_function(vm, fn, src, nil)
        if vm.throwing do return
        if is_primitive(iter) { throw_type_error(vm, "Invalid iterator"); return }
        s.props["iterator"] = iter
        s.props["next"] = get_member(vm, iter, "next")
        if vm.throwing do return
    } else {
        n := array_like_len(vm, src)
        if vm.throwing do return
        s.props["length"] = f64(n)
        length_arg[0] = f64(n)
        ctor_args = length_arg[:]
    }
    out: Value = new_array(vm)
    if is_constructor_like(vm, ctor) {
        if fn, ok := ctor.(^Function); ok { out = construct_object(vm, fn, ctor_args) }
        else if obj, ok := ctor.(^Object); ok { out = proxy_construct(vm, obj, ctor_args) }
        if vm.throwing do return
    }
    s.props["out"] = out
    from_async_next(vm, s)
}
