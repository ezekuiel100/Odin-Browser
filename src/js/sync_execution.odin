package js

import "core:fmt"
import "core:strings"

// Stable addresses are required by the Error.stack chain: Exec_Frame's dynamic
// array can move as calls push more operands. Completed calls reuse a small pool.
Exec_Call :: struct {
    stack: Stack_Frame,
    env_mark: int,
    esc_mark: u64,
    args: []Value,
    this, new_target: Value,
    next: ^Exec_Call,
}

SYNC_FRAME_CACHE_MAX :: 1024 // do not retain a rare deep call tree between tasks

exec_sync_function :: #force_inline proc(fn: ^Function) -> bool {
    return fn != nil && fn.native == nil && fn.proxy == nil &&
        fn.bind_target == nil && !fn.is_async && !fn.is_generator
}

// Common call/apply/bind wrappers must not reintroduce native recursion between
// JS functions. Only unwrap when the final target can run on this trampoline.
// Other built-ins, callable proxies and async functions retain their dispatch.
exec_prepare_sync_call :: proc(vm: ^Interp, f: ^Exec_Frame, fn: ^Function) -> (^Function, bool) {
    fn := fn
    target := fn
    indirect := fn == vm.fn_call_fn || fn == vm.fn_apply_fn
    if indirect {
        var_ok: bool
        target, var_ok = f.values[0].(^Function)
        if !var_ok do return fn, false
    }
    depth := 0
    for target != nil && target.bind_target != nil {
        depth += 1
        if depth >= vm.call_depth_limit do return fn, false
        target = target.bind_target
    }
    if !exec_sync_function(target) do return fn, false
    if indirect {
        wrapper := fn
        fn = f.values[0].(^Function)
        receiver := arg(f.items[:], 0)
        if wrapper == vm.fn_call_fn {
            if len(f.items) > 0 do ordered_remove(&f.items, 0)
        } else {
            copied: [dynamic]Value
            if a, ok := arg(f.items[:], 1).(^Array); ok do append(&copied, ..a.items[:])
            delete(f.items)
            f.items = copied
        }
        f.values[0], f.values[1] = receiver, fn
        when JSPROF { g_prof.chamadas += 1; g_prof.chamadas_nat += 1 }
    }
    for fn.bind_target != nil {
        combined := make([dynamic]Value, 0, len(fn.bind_args)+len(f.items))
        append(&combined, ..fn.bind_args[:])
        append(&combined, ..f.items[:])
        delete(f.items)
        f.items = combined
        f.values[0], f.values[1] = fn.bind_this, fn.bind_target
        fn = fn.bind_target
        when JSPROF { g_prof.chamadas += 1 }
    }
    return target, true
}

// Native entry/reentry starts a trampoline. Calls made by that trampoline push
// onto the same frame array instead of recursively invoking call_function.
exec_sync_call :: proc(vm: ^Interp, fn: ^Function, this: Value, args: []Value) -> Value {
    g := Generator{vm = vm, frames = vm.sync_frames}
    vm.sync_frames = nil
    exec_enter_call(vm, &g, fn, this, args)
    exec_run(vm, &g)
    result := g.result
    // A native callback may have returned its own idle storage in the meantime.
    if cap(g.frames) <= SYNC_FRAME_CACHE_MAX && cap(g.frames) > cap(vm.sync_frames) {
        delete(vm.sync_frames)
        vm.sync_frames = g.frames
    } else { delete(g.frames) }
    return result
}

exec_enter_call :: proc(vm: ^Interp, g: ^Generator, fn: ^Function, this: Value, args: []Value) {
    when JSPROF { g_prof.chamadas += 1 }
    stack_probe: int
    if vm.call_depth >= vm.call_depth_limit || stack_near_limit(vm, uintptr(&stack_probe)) {
        if !vm.throwing {
            vm.thrown = mk_error(vm, "RangeError", "Maximum call stack size exceeded")
            vm.throwing = true
        }
        g.result = nil
        return
    }
    nt := vm.pending_new_target
    vm.pending_new_target = nil
    if fn.class_node != nil && nt == nil {
        name := fn.class_node.name
        if name == "" do name = "(anonymous)"
        throw_type_error(vm, fmt.tprintf("Class constructor %s cannot be invoked without 'new'", name))
        g.result = nil
        return
    }
    c := vm.sync_call_pool
    if c == nil { c = new(Exec_Call) }
    else { vm.sync_call_pool = c.next; vm.sync_call_pool_count -= 1 }
    c^ = Exec_Call{
        stack = {parent = vm.frame, fn = fn, call_pos = vm.cur_pos,
                 call_script = vm.cur_script, is_new = nt != nil},
        env_mark = len(vm.all_envs), esc_mark = vm.env_escapes,
        args = args, this = this, new_target = nt,
    }
    vm.call_depth += 1
    vm.frame, vm.cur_script, vm.cur_pos = &c.stack, fn.script, 0
    when #config(MEMBERPROBE, false) {
        append(&vm.probe_stack, fmt.tprintf("%s(%s)", fn.name, strings.join(fn.params[:], ",")))
    }
    // Install cleanup before any initializer/default can invoke user code or throw.
    append(&g.frames, Exec_Frame{mode = .Call, call = c})
    if fn.class_node != nil && fn.super_ctor == nil && !fn.super_null {
        if obj, ok := this.(^Object); ok do init_instance_fields(vm, fn, obj)
        if vm.throwing do return
    }
    scope := setup_call_scope(vm, fn, this, args, nt, false)
    g.frames[len(g.frames)-1].env = scope
}

// Parameter defaults and destructuring may call other functions too. Evaluate
// them on the trampoline, before entering the body, in the same parameter scope.
exec_call_frame :: proc(vm: ^Interp, g: ^Generator, f: ^Exec_Frame) {
    c := f.call
    fn, scope := c.stack.fn, f.env
    if vm.throwing || f.state == 5 { exec_finish_call(vm, g, c); return }
    if f.state == 2 {
        f.values[0] = g.result
        if fn.params[f.index] != "" do infer_binding_name(fn.param_defaults[f.index], g.result, fn.params[f.index])
        f.state = 1
    } else if f.state == 3 { f.index += 1; f.state = 0 }
    else if f.state == 4 { f.state = 6 }
    for f.index < len(fn.params) {
        i := f.index
        if f.state == 0 {
            f.values[0] = c.args[i] if i < len(c.args) else nil
            if f.values[0] == nil && i < len(fn.param_defaults) && fn.param_defaults[i] != nil {
                f.state = 2
                exec_push(g, fn.param_defaults[i], scope)
                return
            }
        }
        if i < len(fn.param_pats) && fn.param_pats[i] != nil {
            f.state = 3
            exec_push_pattern(g, fn.param_pats[i], f.values[0], scope, true, false)
            return
        }
        scope.vars[fn.params[i]] = f.values[0]
        f.index += 1
        f.state = 0
    }
    if f.state != 6 && (fn.rest_param != "" || fn.rest_pat != nil) {
        rest := new_array(vm)
        for i := len(fn.params); i < len(c.args); i += 1 do append(&rest.items, c.args[i])
        if fn.rest_pat != nil {
            f.state = 4
            exec_push_pattern(g, fn.rest_pat, rest, scope, true, false)
            return
        }
        scope.vars[fn.rest_param] = rest
    }
    f.state = 5 // the next visit completes this call, including an empty body
    if fn.auto_super && fn.super_null {
        throw_type_error(vm, "Super constructor null of anonymous class is not a constructor")
        return
    }
    if fn.auto_super && fn.super_ctor != nil {
        super_construct(vm, fn.super_ctor, c.this, c.args, c.new_target)
        if vm.throwing do return
        if obj, ok := c.this.(^Object); ok do init_instance_fields(vm, fn, obj)
        if vm.throwing do return
    }
    if fn.body != nil {
        if !exec_needs_frame(vm, fn.body) {
            // A leaf body cannot push another JS call. Reuse the tree walker
            // directly without scheduling a frame for its statement list.
            hoist_functions(vm, fn.body.body[:], scope)
            hoist_vars_body(fn.body.body[:], scope)
            for s in fn.body.body {
                if is_hoisted_func(s) do continue
                eval(vm, s, scope)
                if vm.returning || vm.throwing do break
            }
            exec_finish_call(vm, g, c)
        } else { append(&g.frames, Exec_Frame{mode = .Body, node = fn.body, env = scope}) }
    }
}

exec_finish_call :: proc(vm: ^Interp, g: ^Generator, c: ^Exec_Call) {
    result: Value
    if vm.returning { result = vm.ret_val; vm.returning = false; vm.ret_val = nil }
    // Only exceptions cross a function boundary. Return/break/continue are local.
    vm.breaking, vm.continuing = false, false
    vm.break_label, vm.continue_label, vm.pending_label = "", "", ""
    vm.frame, vm.cur_pos, vm.cur_script = c.stack.parent, c.stack.call_pos, c.stack.call_script
    vm.call_depth -= 1
    when #config(MEMBERPROBE, false) { pop(&vm.probe_stack) }
    if vm.env_escapes == c.esc_mark do recycle_envs(vm, c.env_mark)
    exec_pop(g, result)
    if vm.sync_call_pool_count < ENV_POOL_MAX {
        c^ = Exec_Call{next = vm.sync_call_pool}
        vm.sync_call_pool = c
        vm.sync_call_pool_count += 1
    } else { free(c) }
}
