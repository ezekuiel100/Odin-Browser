package js

// Stop-the-world collection at host safepoints only. Native temporaries are not
// traced. A suspended generator owns a native stack, so collection is deferred
// until those stacks finish. Strings, source/AST storage and symbols stay VM-owned.
GC_Ref :: union {^Object, ^Array, ^Function, ^Env, ^Array_Buffer, ^Collection, ^Regex, ^BigInt, ^Symbol, ^Module, ^Generator}
GC_State :: struct {
    seen: map[rawptr]bool,
    work: [dynamic]GC_Ref,
}
gc_push :: proc(g: ^GC_State, x: $T) {
    when T == Value {
        switch v in x {
        case ^Object: gc_push(g, v)
        case ^Array: gc_push(g, v)
        case ^Function: gc_push(g, v)
        case ^Collection: gc_push(g, v)
        case ^Regex: gc_push(g, v)
        case ^BigInt: gc_push(g, v)
        case ^Symbol: gc_push(g, v)
        case f64, bool, string, JS_Null:
        }
    } else {
        if x == nil || g.seen[rawptr(x)] do return
        g.seen[rawptr(x)] = true
        append(&g.work, GC_Ref(x))
    }
}
gc_live :: proc(g: ^GC_State, x: Value) -> bool {
    switch v in x {
    case ^Object: return g.seen[rawptr(v)]
    case ^Array: return g.seen[rawptr(v)]
    case ^Function: return g.seen[rawptr(v)]
    case ^Collection: return g.seen[rawptr(v)]
    case ^Regex: return g.seen[rawptr(v)]
    case ^BigInt: return g.seen[rawptr(v)]
    case ^Symbol: return g.seen[rawptr(v)]
    case f64, bool, string, JS_Null:
    }
    return true
}
gc_drain :: proc(gp: ^GC_State) {
    // The worklist avoids recursive marking on deeply nested object graphs.
    g := gp^
    for len(g.work) > 0 {
        ref := pop(&g.work)
        switch x in ref {
        case ^Object:
            for _, v in x.props {
                gc_push(&g, v)
            }
            for _, v in x.getters {
                gc_push(&g, v)
            }
            for _, v in x.setters {
                gc_push(&g, v)
            }
            gc_push(&g, x.proto)
            gc_push(&g, x.proto_x)
            gc_push(&g, x.gen)
            gc_push(&g, x.px_target)
            gc_push(&g, x.px_handler)
            gc_push(&g, x.px_self)
            gc_push(&g, x.ab)
            gc_push(&g, x.prim)
            if x.coll_iter != nil {
                gc_push(&g, x.coll_iter.collection)
                gc_push(&g, x.coll_iter.source)
            }
        case ^Array:
            for v in x.items {
                gc_push(&g, v)
            }
            for _, v in x.props {
                gc_push(&g, v)
            }
            if x.args != nil { // objeto `arguments`: segura o callee e o escopo mapeado
                gc_push(&g, x.args.callee)
                gc_push(&g, x.args.env)
            }
        case ^Function:
            gc_push(&g, x.closure)
            gc_push(&g, x.bound)
            for _, v in x.props {
                gc_push(&g, v)
            }
            gc_push(&g, x.super_ctor)
            gc_push(&g, x.home_super)
            gc_push(&g, x.home_obj)
            gc_push(&g, x.home_static)
            for _, v in x.getters {
                gc_push(&g, v)
            }
            for _, v in x.setters {
                gc_push(&g, v)
            }
            gc_push(&g, x.proxy)
            gc_push(&g, x.bind_target)
            gc_push(&g, x.bind_this)
            for v in x.bind_args {
                gc_push(&g, v)
            }
        case ^Env:
            for _, v in x.vars {
                gc_push(&g, v)
            }
            gc_push(&g, x.parent)
            for _, v in x.aliases {
                gc_push(&g, v.src)
            }
            gc_push(&g, x.mapped_args)
        case ^Array_Buffer:
        case ^Collection:
            if x.kind == .Map || x.kind == .Set {
                for e in x.entries {
                    if e.dead do continue
                    gc_push(&g, e.key); gc_push(&g, e.val)
                }
            }
        case ^Regex:
            for _, v in x.props do gc_push(&g, v) // expandos (re.toString = ...)
        case ^BigInt:
        case ^Symbol:
        case ^Module:
            gc_push(&g, x.ns)
            gc_push(&g, x.env)
            gc_push(&g, x.evaluation)
            gc_push(&g, x.error)
            gc_push(&g, x.parent)
        case ^Generator:
            gc_push(&g, x.program_env)
            gc_push(&g, x.module)
            gc_push(&g, x.program_result)
            gc_push(&g, x.fn)
            gc_push(&g, x.this)
            for v in x.args {
                gc_push(&g, v)
            }
            gc_push(&g, x.obj)
            gc_push(&g, x.transfer)
            gc_push(&g, x.inject_val)
            for v in x.requests {
                gc_push(&g, v.value)
                gc_push(&g, v.promise)
            }
            gc_push(&g, x.async_promise)
            gc_push(&g, x.thrown_out)
        }
    }
    gp^ = g
}

// Hosts holding Values across a collection must pass them as explicit roots.
// Returns false when execution is active and no collection was attempted.
vm_collect :: proc(vm: ^Interp, roots: []Value = nil) -> bool {
    if vm == nil || vm.call_depth != 0 || vm.pump_depth != 0 ||
       vm.mo_task_depth != 0 || vm.draining || vm.current_gen != nil { return false }
    for gen in vm.all_generators {
        if gen.started && !gen.done do return false
    }
    g: GC_State
    g.seen = make(map[rawptr]bool)
    defer delete(g.seen)
    defer delete(g.work)
    for v in roots do gc_push(&g, v)
    for _, c in vm.canvases do gc_push(&g, c.obj)
    // Native side tables retain their wrapper identities until VM destruction.
    for key in vm.dom_colls do gc_push(&g, cast(^Object)key)
    for sym in vm.all_symbols do gc_push(&g, sym)
    gc_push(&g, vm.global)
    for v in vm.ta_protos {
        gc_push(&g, v)
    }
    gc_push(&g, vm.array_buffer_proto)
    gc_push(&g, vm.dataview_proto)
    gc_push(&g, vm.text_encoder_proto)
    gc_push(&g, vm.text_decoder_proto)
    gc_push(&g, vm.blob_proto)
    gc_push(&g, vm.idle_deadline)
    gc_push(&g, vm.bigint_proto)
    for _, v in vm.symbol_registry {
        gc_push(&g, v)
    }
    for _, v in vm.symbol_keys {
        gc_push(&g, v)
    }
    for _, v in vm.custom_elements {
        gc_push(&g, v)
    }
    for _, v in vm.listeners {
        for listener in v {
            gc_push(&g, listener.fn)
        }
    }
    gc_push(&g, vm.console_log_fn)
    gc_push(&g, vm.fn_call_fn)
    gc_push(&g, vm.fn_tostring_fn)
    gc_push(&g, vm.fn_apply_fn)
    gc_push(&g, vm.fn_bind_fn)
    gc_push(&g, vm.eval_fn)
    gc_push(&g, vm.iter_next_fn)
    for _, v in vm.array_methods {
        gc_push(&g, v)
    }
    gc_push(&g, vm.array_ctor)
    for _, v in vm.string_methods {
        gc_push(&g, v)
    }
    for _, v in vm.number_methods {
        gc_push(&g, v)
    }
    for _, v in vm.boolean_methods {
        gc_push(&g, v)
    }
    gc_push(&g, vm.function_proto)
    gc_push(&g, vm.global_this)
    gc_push(&g, vm.date_proto)
    for _, v in vm.error_protos {
        gc_push(&g, v)
    }
    for _, v in vm.object_methods {
        gc_push(&g, v)
    }
    for _, v in vm.collection_methods {
        gc_push(&g, v)
    }
    for proto in vm.collection_protos do gc_push(&g, proto)
    for proto in vm.collection_iter_protos do gc_push(&g, proto)
    gc_push(&g, vm.regex_test_fn)
    gc_push(&g, vm.regex_exec_fn)
    gc_push(&g, vm.regex_proto)
    gc_push(&g, vm.regex_tostring_fn)
    gc_push(&g, vm.dom_element_ctor)
    gc_push(&g, vm.dom_element_proto)
    gc_push(&g, vm.dom_htmlcollection_proto)
    gc_push(&g, vm.dom_nodelist_proto)
    gc_push(&g, vm.dom_namednodemap_proto)
    gc_push(&g, vm.dom_attr_proto)
    gc_push(&g, vm.dom_fragment_proto)
    gc_push(&g, vm.dom_shadowroot_proto)
    for _, v in vm.dom_tag_protos {
        gc_push(&g, v)
    }
    for _, v in vm.dom_element_methods {
        gc_push(&g, v)
    }
    for _, v in vm.dom_classlist_methods {
        gc_push(&g, v)
    }
    for _, v in vm.dom_style_methods {
        gc_push(&g, v)
    }
    for _, v in vm.node_wrappers {
        gc_push(&g, v)
    }
    for v in vm.mo_pending {
        gc_push(&g, v)
    }
    for v in vm.mut_observers {
        gc_push(&g, v)
    }
    for v in vm.int_observers {
        gc_push(&g, v)
    }
    for v in vm.media_lists {
        gc_push(&g, v)
    }
    gc_push(&g, vm.dommatrix_proto)
    gc_push(&g, vm.dommatrix_ro_proto)
    gc_push(&g, vm.dompoint_proto)
    for v in vm.size_observers {
        gc_push(&g, v)
    }
    for v in vm.timers {
        gc_push(&g, v.fn)
    }
    gc_push(&g, vm.native_bound)
    gc_push(&g, vm.pending_new_target)
    gc_push(&g, vm.promise_then_fn)
    gc_push(&g, vm.promise_catch_fn)
    gc_push(&g, vm.promise_finally_fn)
    gc_push(&g, vm.promise_proto)
    gc_push(&g, vm.resp_text_fn)
    gc_push(&g, vm.resp_json_fn)
    gc_push(&g, vm.web_headers_proto)
    gc_push(&g, vm.web_request_proto)
    gc_push(&g, vm.web_response_proto)
    gc_push(&g, vm.web_usp_proto)
    gc_push(&g, vm.web_formdata_proto)
    gc_push(&g, vm.web_url_proto)
    gc_push(&g, vm.web_signal_proto)
    gc_push(&g, vm.web_rstream_proto)
    gc_push(&g, vm.web_wstream_proto)
    gc_push(&g, vm.event_proto)
    for v in vm.pending_fetches {
        gc_push(&g, v.promise)
    }
    for _, v in vm.modules {
        gc_push(&g, v)
    }
    for v in vm.all_modules {
        gc_push(&g, v)
    }
    gc_push(&g, vm.current_module)
    gc_push(&g, vm.event_prevent_fn)
    gc_push(&g, vm.event_stop_fn)
    gc_push(&g, vm.ret_val)
    gc_push(&g, vm.thrown)
    for v in vm.reaction_queue {
        gc_push(&g, v.microtask)
        gc_push(&g, v.onf)
        gc_push(&g, v.onr)
        gc_push(&g, v.next)
        gc_push(&g, v.val)
    }
    for v in vm.all_generators {
        gc_push(&g, v)
    }
    gc_push(&g, vm.current_gen)
    gc_push(&g, vm.gen_next_fn)
    gc_push(&g, vm.gen_return_fn)
    gc_push(&g, vm.gen_throw_fn)
    gc_push(&g, vm.gen_iter_fn)
    gc_push(&g, vm.async_gen_next_fn)
    gc_push(&g, vm.async_gen_return_fn)
    gc_push(&g, vm.async_gen_throw_fn)
    gc_push(&g, vm.object_proto)
    gc_push(&g, vm.iter_proto)
    gc_push(&g, vm.array_iter_proto)
    gc_push(&g, vm.symbol_proto)
    gc_drain(&g)
    // Ephemeron fixed point: only a live weak key keeps its value alive.
    for {
        before := len(g.seen)
        for c in vm.all_collections {
            if !g.seen[rawptr(c)] || c.kind != .Weak_Map do continue
            for e in c.entries {
                if !e.dead && gc_live(&g, e.key) do gc_push(&g, e.val)
            }
        }
        gc_drain(&g)
        if len(g.seen) == before do break
    }
    for c in vm.all_collections {
        if !g.seen[rawptr(c)] || (c.kind != .Weak_Map && c.kind != .Weak_Set) do continue
        gc_prune_weak(c, &g)
    }
    live_all_envs := 0
    for e in vm.all_envs {
        if g.seen[rawptr(e)] { vm.all_envs[live_all_envs] = e; live_all_envs += 1; continue }

        delete(e.vars)
        if e.aliases != nil do delete(e.aliases)
        if e.uninitialized != nil do delete(e.uninitialized)
        if e.consts != nil do delete(e.consts)
        free(e)
        }
    resize(&vm.all_envs, live_all_envs)
    live_all_funcs := 0
    for f in vm.all_funcs {
        if g.seen[rawptr(f)] { vm.all_funcs[live_all_funcs] = f; live_all_funcs += 1; continue }

        delete(f.attrs)
        delete(f.props)
        if f.class_keys != nil do delete(f.class_keys)
        if f.bind_args != nil do delete(f.bind_args)
        if f.getters != nil do delete(f.getters)
        if f.setters != nil do delete(f.setters)
        free(f)
        }
    resize(&vm.all_funcs, live_all_funcs)
    live_all_objects := 0
    for o in vm.all_objects {
        if g.seen[rawptr(o)] { vm.all_objects[live_all_objects] = o; live_all_objects += 1; continue }

        coll_iterator_destroy(o)
        delete(o.props)
        delete(o.korder)
        if o.getters != nil do delete(o.getters)
        if o.setters != nil do delete(o.setters)
        if o.attrs != nil do delete(o.attrs)
        free(o)
        }
    resize(&vm.all_objects, live_all_objects)
    live_all_arrays := 0
    for a in vm.all_arrays {
        if g.seen[rawptr(a)] { vm.all_arrays[live_all_arrays] = a; live_all_arrays += 1; continue }

        delete(a.items)
        if a.props != nil do delete(a.props)
        delete(a.holes)
        if a.args != nil do free(a.args)
        free(a)
        }
    resize(&vm.all_arrays, live_all_arrays)
    n_all_buffers := 0
    for x in vm.all_buffers {
        if g.seen[rawptr(x)] { vm.all_buffers[n_all_buffers] = x; n_all_buffers += 1 } else { delete(x.data); free(x) }
    }
    resize(&vm.all_buffers, n_all_buffers)
    n_all_regexes := 0
    for x in vm.all_regexes {
        if g.seen[rawptr(x)] { vm.all_regexes[n_all_regexes] = x; n_all_regexes += 1 } else { regex_destroy(x) }
    }
    resize(&vm.all_regexes, n_all_regexes)
    n_all_bigints := 0
    for x in vm.all_bigints {
        if g.seen[rawptr(x)] { vm.all_bigints[n_all_bigints] = x; n_all_bigints += 1 } else { bigint_destroy(x) }
    }
    resize(&vm.all_bigints, n_all_bigints)
    n_all_collections := 0
    for x in vm.all_collections {
        if g.seen[rawptr(x)] { vm.all_collections[n_all_collections] = x; n_all_collections += 1 } else { delete(x.entries); delete(x.index); free(x) }
    }
    resize(&vm.all_collections, n_all_collections)
    vm.gc_threshold = max(4096, 2 * gc_heap_count(vm))
    return true
}
gc_heap_count :: proc(vm: ^Interp) -> int {
    return len(vm.all_objects) + len(vm.all_arrays) + len(vm.all_funcs) + len(vm.all_envs) + len(vm.all_collections) + len(vm.all_buffers) + len(vm.all_regexes) + len(vm.all_bigints)
}

