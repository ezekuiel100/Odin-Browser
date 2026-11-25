package js

import "core:strings"
import "core:strconv"

// Only syntax which can suspend needs a continuation. Ordinary subtrees still
// use eval, so native built-ins and synchronous calls keep their existing path.
// A frame owns every operand and environment that survives await/yield. There
// are no pointers into the native stack at a suspension point.
Exec_Signal :: struct {
    throwing, returning, breaking, continuing: bool,
    thrown, returned: Value,
    break_label, continue_label: string,
}

Exec_Frame :: struct {
    mode: enum { Eval, Reference, Pattern, Body },
    node: ^Node,
    env, scope: ^Env,
    state, index, cursor: int,
    label, key: string,
    values: [6]Value,
    items: [dynamic]Value,
    keys: [dynamic]string,
    signal: Exec_Signal,
    flag, flag2, protocol, done: bool,
    ref: Target_Ref,
    ident: Ident_Ref,
}

exec_signal :: proc(vm: ^Interp) -> Exec_Signal {
    return {vm.throwing, vm.returning, vm.breaking, vm.continuing,
            vm.thrown, vm.ret_val, vm.break_label, vm.continue_label}
}

exec_clear_signal :: proc(vm: ^Interp) {
    vm.throwing = false; vm.thrown = nil
    vm.returning = false; vm.ret_val = nil
    vm.breaking = false; vm.continuing = false
    vm.break_label = ""; vm.continue_label = ""
}

exec_restore_signal :: proc(vm: ^Interp, s: Exec_Signal) {
    vm.throwing, vm.returning = s.throwing, s.returning
    vm.breaking, vm.continuing = s.breaking, s.continuing
    vm.thrown, vm.ret_val = s.thrown, s.returned
    vm.break_label, vm.continue_label = s.break_label, s.continue_label
}

exec_abrupt :: proc(vm: ^Interp) -> bool {
    return vm.throwing || vm.returning || vm.breaking || vm.continuing
}

exec_needs_frame :: proc(vm: ^Interp, n: ^Node) -> bool {
    if n == nil do return false
    if cached, ok := vm.exec_suspend_cache[n]; ok do return cached
    result := false
    #partial switch n.kind {
    case .Func: // Its body belongs to another invocation.
    case .Await, .Yield, .ImportDecl: result = true
    case .Class:
        result = exec_needs_frame(vm, n.callee)
        for m in n.body do result = exec_needs_frame(vm, m.left) || result
    case:
        result = n.kind == .ForOf && n.is_generator || n.kind == .ExportDecl && n.str != ""
        result = exec_needs_frame(vm, n.left) || result
        result = exec_needs_frame(vm, n.right) || result
        result = exec_needs_frame(vm, n.third) || result
        result = exec_needs_frame(vm, n.callee) || result
        for c in n.body do result = exec_needs_frame(vm, c) || result
    }
    if vm.exec_suspend_cache == nil do vm.exec_suspend_cache = make(map[^Node]bool)
    vm.exec_suspend_cache[n] = result
    return result
}

exec_push :: proc(g: ^Generator, n: ^Node, env: ^Env) {
    append(&g.frames, Exec_Frame{node = n, env = env})
}

exec_pop :: proc(g: ^Generator, value: Value) {
    f := pop(&g.frames)
    delete(f.items)
    delete(f.keys)
    g.result = value
}

exec_dispose :: proc(g: ^Generator) {
    for f in g.frames { delete(f.items); delete(f.keys) }
    delete(g.frames)
    g.frames = nil
    delete(g.args)
    g.args = nil
    g.result = nil
    g.this = nil
    g.program_env = nil
    g.reference = {}
    g.fn = nil
}

// Captured nodes exist only during one synchronous eval. They are never stored
// in the source AST or in a function's body, and do not increase Node's size.
exec_value_node :: proc(v: ^Value) -> Node {
    return Node{kind = .Captured, left = cast(^Node)v}
}

exec_suspend :: proc(g: ^Generator, value: Value, awaiting: bool) {
    g.transfer = value
    g.awaiting = awaiting
    g.suspended = true
}

exec_inject :: proc(vm: ^Interp, g: ^Generator) -> Value {
    value := g.inject_val
    switch g.inject {
    case .Throw: vm.throwing = true; vm.thrown = value
    case .Return: vm.returning = true; vm.ret_val = value
    case .None:
    }
    g.inject = .None
    g.inject_val = nil
    return value
}

// One trampoline drives the continuation until it suspends or finishes. Pushing
// children can grow frames; never keep an element pointer across exec_push.
exec_run :: proc(vm: ^Interp, g: ^Generator) {
    g.suspended = false
    for len(g.frames) > 0 && !g.suspended {
        f := &g.frames[len(g.frames)-1]
        n, env := f.node, f.env
        if n == nil { exec_pop(g, nil); continue }
        if f.mode == .Reference { exec_reference(vm, g, f); continue }
        if f.mode == .Pattern { exec_pattern(vm, g, f); continue }
        if f.state == 0 {
            if vm.throwing { exec_pop(g, nil); continue }
            if n.pos != 0 do vm.cur_pos = n.pos
            if n.kind != .Member && n.kind != .Index && n.kind != .Call do vm.opt_short = false
            if f.mode != .Body && !exec_needs_frame(vm, n) {
                value := eval(vm, n, env)
                exec_pop(g, value)
                continue
            }
        }
        // Structured handlers consume abrupt completions from their children.
        if exec_abrupt(vm) && n.kind != .Try && n.kind != .Labeled &&
           n.kind != .While && n.kind != .DoWhile && n.kind != .For &&
           n.kind != .ForOf && n.kind != .Switch && n.kind != .Pattern {
            exec_pop(g, nil)
            continue
        }
        #partial switch n.kind {
        case .Await, .Yield:
            if n.kind == .Yield && n.bval { exec_delegate(vm, g, f); continue }
            switch f.state {
            case 0: f.state = 1; exec_push(g, n.left, env)
            case 1:
                f.state = 2
                exec_suspend(g, g.result, n.kind == .Await || g.is_async)
            case 2:
                value := exec_inject(vm, g)
                if n.kind == .Yield && g.is_async && !exec_abrupt(vm) {
                    f.state = 3
                    exec_suspend(g, value, false)
                } else { exec_pop(g, value) }
            case 3: exec_pop(g, exec_inject(vm, g))
            }
        case .Program, .Block:
            if f.state == 0 {
                f.scope = env
                if n.kind == .Block && f.mode != .Body do f.scope = new_env(vm, env)
                if n.kind == .Block || vm.current_module == nil || vm.current_module.env != env {
                    hoist_functions(vm, n.body[:], f.scope)
                }
                if n.kind == .Program || f.mode == .Body do hoist_vars_body(n.body[:], f.scope)
                f.values[0] = empty_completion()
                f.state = 1
            } else if f.state == 2 {
                f.values[0] = update_empty(f.values[0], n.body[f.index-1], g.result)
                f.state = 1
            }
            if exec_abrupt(vm) || f.index >= len(n.body) { exec_pop(g, f.values[0]); continue }
            child := n.body[f.index]
            f.index += 1
            if is_hoisted_func(child) {
                if n.kind == .Block && f.mode != .Body do execute_hoisted_func(vm, child, f.scope)
                continue
            }
            f.state = 2
            exec_push(g, child, f.scope)
        case .ExprStmt, .Seq, .Return, .Throw, .ExportDecl:
            exec_simple_statement(vm, g, f)
        case .VarDecl:
            exec_declaration(vm, g, f)
        case .If, .Ternary, .Logical:
            if f.state == 0 { f.state = 1; exec_push(g, n.left, env); continue }
            if f.state == 2 {
                value := g.result
                if n.kind == .If do value = completion_value(value)
                exec_pop(g, value); continue
            }
            child: ^Node
            if n.kind == .Logical {
                take := truthy(g.result)
                if n.op == .PipePipe do take = !take
                if n.op == .QQuestion do take = is_nullish(g.result)
                if !take { exec_pop(g, g.result); continue }
                child = n.right
            } else {
                child = n.right if truthy(g.result) else n.third
            }
            f.state = 2
            exec_push(g, child, env)
        case .While, .DoWhile, .For:
            exec_loop(vm, g, f)
        case .Try:
            exec_try(vm, g, f)
        case .Labeled:
            if f.state == 0 {
                f.state = 1
                k := n.left.kind
                if k == .While || k == .DoWhile || k == .For || k == .ForOf || k == .Switch do vm.pending_label = n.name
                exec_push(g, n.left, env)
            } else {
                vm.pending_label = ""
                if vm.breaking && vm.break_label == n.name { vm.breaking = false; vm.break_label = "" }
                exec_pop(g, g.result)
            }
        case .With:
            if f.state == 0 { f.state = 1; exec_push(g, n.left, env); continue }
            if f.state == 1 {
                if is_nullish(g.result) { throw_type_error(vm, "Cannot convert undefined or null to object"); continue }
                f.scope = new_env(vm, env)
                f.scope.vars[WITH_OBJ_KEY] = make_wrapper(vm, g.result)
                f.scope.is_with = true
                vm.with_used = true
                f.state = 2
                exec_push(g, n.right, f.scope)
            } else { exec_pop(g, completion_value(g.result)) }
        case .Switch:
            exec_switch(vm, g, f)
        case .ForOf:
            exec_for_of(vm, g, f)
        case .ImportDecl:
            exec_import(vm, g, f)
        case .Assign:
            exec_assignment(vm, g, f)
        case .Call, .New, .Tagged:
            exec_call(vm, g, f)
        case .ArrayLit, .ObjectLit, .Template:
            exec_literal(vm, g, f)
        case .Pattern:
            exec_pattern(vm, g, f)
        case .Class:
            exec_class(vm, g, f)
        case:
            exec_expression(vm, g, f)
        }
    }
}

exec_simple_statement :: proc(vm: ^Interp, g: ^Generator, f: ^Exec_Frame) {
    n, env := f.node, f.env
    if f.state == 0 {
        f.state = 1
        child := n.left
        if n.kind == .Return || n.kind == .Throw do child = n.right
        if n.kind == .ExportDecl && n.str != "" {
            exec_import(vm, g, f)
            return
        }
        exec_push(g, child, env)
        return
    }
    value := g.result
    #partial switch n.kind {
    case .Seq:
        if f.state == 1 { f.state = 2; exec_push(g, n.right, env); return }
    case .Return: vm.returning = true; vm.ret_val = value
    case .Throw: vm.throwing = true; vm.thrown = value
    case .ExportDecl:
        if n.str != "" { exec_import(vm, g, f); return }
        if m := vm.current_module; m != nil {
            if n.bval {
                env_define(m.env, module_local_of(m, "default"), value)
                oput(m.ns, "default", value)
            } else { module_snapshot_exports(vm, m) }
        }
    case:
    }
    exec_pop(g, value)
}

exec_declaration :: proc(vm: ^Interp, g: ^Generator, f: ^Exec_Frame) {
    n, env := f.node, f.env
    switch f.state {
    case 0: f.state = 1; exec_push(g, n.right, env); return
    case 1:
        target := fn_scope_env(env) if n.aux else env
        if n.left == nil do infer_binding_name(n.right, g.result, n.name)
        if n.left != nil && exec_needs_frame(vm, n.left) {
            f.state = 2
            exec_push_pattern(g, n.left, g.result, target, true, n.is_const)
            return
        }
        captured := exec_value_node(&g.result)
        copy := n^
        copy.right = &captured if n.right != nil else nil
        copy.body = nil
        eval(vm, &copy, env)
        f.state = 2
    case:
    }
    if exec_abrupt(vm) || f.index >= len(n.body) { exec_pop(g, empty_completion()); return }
    child := n.body[f.index]
    f.index += 1
    exec_push(g, child, env)
}

exec_try :: proc(vm: ^Interp, g: ^Generator, f: ^Exec_Frame) {
    n, env := f.node, f.env
    switch f.state {
    case 0: f.state = 1; exec_push(g, n.left, env); return
    case 1:
        f.values[0] = g.result
        if vm.throwing && n.right != nil {
            f.scope = new_env(vm, env)
            exc := vm.thrown
            exec_clear_signal(vm)
            if n.name != "" do env_define(f.scope, n.name, exc)
            if n.callee != nil {
                f.state = 4
                exec_push_pattern(g, n.callee, exc, f.scope, true, false)
                return
            }
            f.state = 2
            exec_push(g, n.right, f.scope)
            return
        }
        fallthrough
    case 2:
        if f.state == 2 do f.values[0] = g.result
        if n.third != nil {
            f.signal = exec_signal(vm)
            exec_clear_signal(vm)
            f.state = 3
            exec_push(g, n.third, env)
            return
        }
        exec_pop(g, completion_value(f.values[0]))
    case 3:
        value := f.values[0]
        if !exec_abrupt(vm) do exec_restore_signal(vm, f.signal)
        else do value = g.result
        exec_pop(g, completion_value(value))
    case 4:
        f.state = 2
        if !exec_abrupt(vm) do exec_push(g, n.right, f.scope)
    }
}

exec_loop :: proc(vm: ^Interp, g: ^Generator, f: ^Exec_Frame) {
    n, env := f.node, f.env
    if f.state == 0 {
        f.label = vm.pending_label; vm.pending_label = ""
        f.scope = env
        if n.kind == .For {
            f.scope = new_env(vm, env)
            f.state = 1
            exec_push(g, n.left, f.scope)
            return
        }
        f.state = 2
        if n.kind == .DoWhile do f.state = 4
    }
    switch f.state {
    case 1:
        if exec_abrupt(vm) { exec_pop(g, nil); return }
        f.flag = len(f.scope.vars) > 0 && subtree_has_func(n.callee)
        if f.flag do f.scope = clone_loop_bindings(vm, f.scope, env)
        f.state = 2
    case 3:
        if exec_abrupt(vm) || !truthy(g.result) { exec_pop(g, f.values[0]); return }
        f.state = 4
    case 5:
        if !is_empty_completion(g.result) do f.values[0] = g.result
        if vm.continuing {
            if !loop_take_continue(vm, f.label) { exec_pop(g, f.values[0]); return }
        } else if vm.breaking {
            loop_take_break(vm, f.label)
            exec_pop(g, f.values[0]); return
        } else if vm.returning || vm.throwing { exec_pop(g, f.values[0]); return }
        f.state = 2
        if n.kind == .For {
            if f.flag do f.scope = clone_loop_bindings(vm, f.scope, env)
            f.state = 6
            exec_push(g, n.third, f.scope)
            return
        }
    case 6:
        if exec_abrupt(vm) { exec_pop(g, f.values[0]); return }
        f.state = 2
    case:
    }
    if f.state == 2 {
        cond := n.right if n.kind == .For else n.left
        if cond != nil { f.state = 3; exec_push(g, cond, f.scope); return }
        f.state = 4
    }
    if f.state == 4 {
        if step_guard(vm) { exec_pop(g, f.values[0]); return }
        f.state = 5
        body := n.callee if n.kind == .For else n.right
        exec_push(g, body, f.scope)
    }
}

exec_switch :: proc(vm: ^Interp, g: ^Generator, f: ^Exec_Frame) {
    n := f.node
    switch f.state {
    case 0:
        f.label = vm.pending_label; vm.pending_label = ""
        f.state = 1; exec_push(g, n.left, f.env); return
    case 1:
        if exec_abrupt(vm) { exec_pop(g, nil); return }
        f.values[0] = g.result
        f.scope = new_env(vm, f.env)
        for c in n.body do hoist_functions(vm, c.body[:], f.scope)
        f.cursor = -1
        f.state = 2
    case 3:
        if exec_abrupt(vm) { exec_pop(g, nil); return }
        if g.result == f.values[0] { f.index -= 1; f.cursor = 0; f.state = 4 }
        else do f.state = 2
    case 5:
        c := n.body[f.index]
        f.values[1] = update_empty(f.values[1], c.body[f.cursor-1], g.result)
        f.state = 4
    case:
    }
    if f.state == 2 {
        for f.index < len(n.body) {
            c := n.body[f.index]
            f.index += 1
            if c.left == nil { f.cursor = f.index-1; continue }
            f.state = 3; exec_push(g, c.left, f.scope); return
        }
        if f.cursor < 0 { exec_pop(g, nil); return }
        f.index = f.cursor; f.cursor = 0; f.state = 4
    }
    if f.state == 4 {
        if exec_abrupt(vm) {
            if vm.breaking do loop_take_break(vm, f.label)
            exec_pop(g, f.values[1]); return
        }
        for f.index < len(n.body) {
            c := n.body[f.index]
            if f.cursor >= len(c.body) { f.index += 1; f.cursor = 0; continue }
            child := c.body[f.cursor]; f.cursor += 1
            if is_hoisted_func(child) { execute_hoisted_func(vm, child, f.scope); continue }
            f.state = 5; exec_push(g, child, f.scope); return
        }
        exec_pop(g, f.values[1])
    }
}

exec_expression :: proc(vm: ^Interp, g: ^Generator, f: ^Exec_Frame) {
    n, env := f.node, f.env
    target := n.left
    is_ref := n.kind == .Update || n.kind == .Delete
    if f.state == 0 {
        f.state = 1
        child := n.left
        if is_ref && (target.kind == .Member || target.kind == .Index) do child = target.left
        if n.kind == .Binary && n.op == .In && child.kind == .Ident && is_private_key(child.name) {
            f.state = 2; exec_push(g, n.right, env); return
        }
        exec_push(g, child, env); return
    }
    if f.state == 1 {
        f.values[0] = g.result
        if n.kind == .Member || n.kind == .Index {
            if vm.opt_short { exec_pop(g, nil); return }
            if n.bval && is_nullish(g.result) { vm.opt_short = true; exec_pop(g, nil); return }
        }
        child := n.right
        if is_ref {
            child = nil
            if target.kind == .Index do child = target.right
        }
        if child != nil { f.state = 2; exec_push(g, child, env); return }
    } else { f.values[1] = g.result }
    copy := n^
    left := exec_value_node(&f.values[0])
    right := exec_value_node(&f.values[1])
    copy.left = &left
    if n.right != nil do copy.right = &right
    if n.kind == .Binary && n.op == .In && n.left.kind == .Ident && is_private_key(n.left.name) do copy.left = n.left
    ref: Node
    if is_ref {
        ref = target^
        ref.left = &left
        if target.kind == .Index do ref.right = &right
        copy.left = &ref
    }
    value := eval(vm, &copy, env)
    exec_pop(g, value)
}

exec_assignment :: proc(vm: ^Interp, g: ^Generator, f: ^Exec_Frame) {
    n, env := f.node, f.env
    t := n.left
    switch f.state {
    case 0:
        if t.kind == .Pattern { f.state = 4; exec_push(g, n.right, env); return }
        if t.kind == .Member || t.kind == .Index {
            f.state = 1; exec_push(g, t.left, env); return
        }
        f.state = 3
    case 1:
        f.values[0] = g.result
        if t.kind == .Index { f.state = 2; exec_push(g, t.right, env); return }
        f.state = 3
    case 2: f.values[1] = key_string(vm, g.result); f.state = 3
    case 4:
        f.values[3] = g.result
        f.state = 5
        exec_push_pattern(g, t, g.result, env, false, false)
        return
    case 5: exec_pop(g, f.values[3]); return
    case 6:
        value := g.result
        if n.op != .Assign && n.op != .AmpAmp && n.op != .PipePipe && n.op != .QQuestion {
            value = binop(vm, n.op, f.values[2], value)
        }
        if !vm.throwing {
            if t.kind == .Ident {
                infer_binding_name(n.right, value, t.name)
                if f.flag do ident_ref_put(vm, f.ident, t.name, value, n.strict)
                else do ref_write(vm, t, env, nil, nil, value, n.strict)
            } else { ref_write(vm, t, env, f.values[0], f.values[1], value, n.strict) }
        }
        exec_pop(g, value); return
    }
    if f.state == 3 {
        if vm.throwing { exec_pop(g, nil); return }
        if t.kind == .Ident && vm.with_used {
            r := resolve_ident_ref(vm, env, t.name)
            f.ident, f.flag = r, true
            if n.op != .Assign do f.values[2] = ident_ref_get(vm, r, t.name, n.strict)
        } else if n.op != .Assign {
            f.values[2] = ref_read(vm, t, env, f.values[0], f.values[1])
        }
        if vm.throwing { exec_pop(g, nil); return }
        keep := false
        #partial switch n.op {
        case .AmpAmp: keep = !truthy(f.values[2])
        case .PipePipe: keep = truthy(f.values[2])
        case .QQuestion: keep = !is_nullish(f.values[2])
        }
        if keep { exec_pop(g, f.values[2]); return }
        f.state = 6; exec_push(g, n.right, env)
    }
}

// Resolve the callable and its receiver BEFORE evaluating any argument. Keeping
// both as Values also keeps getters, proxies and receiver identity stable over await.
exec_call :: proc(vm: ^Interp, g: ^Generator, f: ^Exec_Frame) {
    n, env := f.node, f.env
    c := n.callee
    if f.state == 0 {
        if n.kind != .New && (c.kind == .Member || c.kind == .Index) {
            if c.left.kind == .Ident && c.left.name == "super" {
                f.values[0], _ = env_get(env, "this")
                if c.kind == .Member {
                    f.values[1] = eval_super_member(vm, c.name, env)
                    f.state = 4
                } else { f.state = 8; exec_push(g, c.right, env); return }
            } else { f.state = 1; exec_push(g, c.left, env); return }
        } else if c.kind == .Ident && c.name == "super" && n.kind == .Call {
            f.flag = true; f.state = 4
        } else if c.kind == .Ident && vm.with_used && c.name != "eval" && n.kind != .New {
            found: bool
            f.values[1], found, f.values[0] = lookup_ident_base(vm, env, c.name)
            if !found do f.values[1] = eval(vm, c, env)
            f.state = 4
        } else { f.state = 3; exec_push(g, c, env); return }
    }
    if f.state == 1 {
        f.values[0] = g.result
        if vm.opt_short || c.bval && is_nullish(g.result) {
            vm.opt_short = true; exec_pop(g, nil); return
        }
        if c.kind == .Index { f.state = 2; exec_push(g, c.right, env); return }
        f.values[1] = get_member(vm, f.values[0], c.name)
        f.state = 4
    } else if f.state == 2 {
        f.values[1] = get_index(vm, f.values[0], g.result); f.state = 4
    } else if f.state == 3 {
        f.values[1] = g.result
        if vm.opt_short { exec_pop(g, nil); return }
        f.state = 4
    } else if f.state == 8 {
        f.values[1] = eval_super_member(vm, key_string(vm, g.result), env); f.state = 4
    }
    if f.state == 4 {
        if vm.throwing { exec_pop(g, nil); return }
        if !f.flag {
            _, callable := f.values[1].(^Function)
            if !callable && n.bval && is_nullish(f.values[1]) {
                vm.opt_short = true; exec_pop(g, nil); return
            }
        }
        if n.kind == .Tagged {
            append(&f.items, template_object(vm, n.left))
        }
        f.state = 5
    } else if f.state == 6 {
        arg_node := n.body[f.index-1] if n.kind != .Tagged else n.left.body[f.index-1]
        if arg_node.kind == .Spread {
            if !iterate_protocol(vm, g.result, &f.items) do collect_sync_values(vm, g.result, &f.items)
        } else { append(&f.items, g.result) }
        f.state = 5
    }
    nodes := n.body
    if n.kind == .Tagged do nodes = n.left.body
    if f.state == 5 && f.index < len(nodes) {
        child := nodes[f.index]; f.index += 1; f.state = 6
        if child.kind == .Spread do child = child.left
        exec_push(g, child, env); return
    }
    if exec_abrupt(vm) { exec_pop(g, nil); return }
    if n.pos != 0 do vm.cur_pos = n.pos
    value: Value
    fn, callable := f.values[1].(^Function)
    if f.flag {
        // super() consumes the already evaluated arguments through captured nodes.
        nodes := make([dynamic]^Node)
        captured := make([]Node, len(f.items))
        defer delete(nodes); defer delete(captured)
        for _, i in f.items { captured[i] = exec_value_node(&f.items[i]); append(&nodes, &captured[i]) }
        copy := n^; copy.body = nodes
        value, _ = try_eval_super_call(vm, &copy, env)
    } else if n.kind == .New {
        if callable do value = construct_object(vm, fn, f.items[:])
        else if p, ok := f.values[1].(^Object); ok && p.px_handler != nil { value = proxy_construct(vm, p, f.items[:]) }
        else { throw_type_error(vm, "Value is not a constructor") }
    } else if callable {
        if c.kind == .Ident && c.name == "eval" && fn == vm.eval_fn && n.kind == .Call {
            value = do_eval(vm, arg(f.items[:], 0), env, n.strict)
        } else { value = call_function(vm, fn, f.values[0], f.items[:]) }
    } else { throw_type_error(vm, "Value is not a function") }
    vm.opt_short = false
    exec_pop(g, value)
}

exec_literal :: proc(vm: ^Interp, g: ^Generator, f: ^Exec_Frame) {
    n, env := f.node, f.env
    if f.state == 0 {
        #partial switch n.kind {
        case .ArrayLit: f.values[0] = new_array(vm)
        case .ObjectLit: f.values[0] = new_object(vm)
        case .Template: f.values[0] = ""
        case:
        }
        f.state = 1
    } else if f.state == 2 {
        // Computed property keys are converted before their value is evaluated.
        f.key = key_string(vm, g.result)
        if vm.throwing { exec_pop(g, nil); return }
        f.state = 3
        exec_push(g, n.body[f.index].right, env); return
    } else if f.state == 3 {
        child := n.body[f.index]
        #partial switch n.kind {
        case .ArrayLit:
            a := f.values[0].(^Array)
            if child.kind == .Spread {
                values: [dynamic]Value
                if !iterate_protocol(vm, g.result, &values) do collect_sync_values(vm, g.result, &values)
                for v in values do append(&a.items, v)
                delete(values)
            } else { append(&a.items, g.result) }
        case .ObjectLit:
            o := f.values[0].(^Object)
            if child.kind == .Spread {
                keys: [dynamic]string
                own_keys_any(vm, g.result, &keys)
                for k in keys { oput(o, k, get_index(vm, g.result, k)); if vm.throwing do break }
                delete(keys)
            } else {
                vnode := child.right if child.kind == .ComputedKey else child
                if child.kind != .ComputedKey do f.key = n.params[f.index]
                if vnode.acc != 0 {
                    fn, ok := g.result.(^Function)
                    if ok {
                        fn.home_obj = o
                        okey_accessor(o, f.key)
                        if vnode.acc == 1 {
                            if o.getters == nil do o.getters = make(map[string]^Function)
                            o.getters[f.key] = fn
                        } else {
                            if o.setters == nil do o.setters = make(map[string]^Function)
                            o.setters[f.key] = fn
                        }
                    }
                } else if child.kind != .ComputedKey && f.key == "__proto__" { set_proto_value(o, g.result) }
                else { set_home_object(g.result, vnode, o); oput(o, f.key, g.result) }
            }
        case .Template:
            sb: strings.Builder
            strings.builder_init(&sb)
            strings.write_string(&sb, f.values[0].(string))
            if f.index < len(n.params) do strings.write_string(&sb, n.params[f.index])
            write_text_spec(&sb, vm, g.result)
            f.values[0] = own_str(vm, strings.to_string(sb))
            strings.builder_destroy(&sb)
        case:
        }
        f.index += 1; f.state = 1
    }
    if vm.throwing { exec_pop(g, nil); return }
    if f.index >= len(n.body) {
        value := f.values[0]
        if n.kind == .Template && f.index < len(n.params) {
            value = own_taken(vm, strings.concatenate({value.(string), n.params[f.index]}))
        }
        exec_pop(g, value); return
    }
    child := n.body[f.index]
    if n.kind == .ArrayLit && child.kind == .Undef && child.bval {
        a := f.values[0].(^Array)
        arr_mark_hole(a, len(a.items)); append(&a.items, nil)
        f.index += 1; return
    }
    f.state = 3
    if child.kind == .Spread do child = child.left
    if child.kind == .ComputedKey { child = child.left; f.state = 2 }
    exec_push(g, child, env)
}

// Imports may suspend implicitly on an evaluating dependency, even without an
// Await node. Once it settles the existing binding/linking path is synchronous.
exec_import :: proc(vm: ^Interp, g: ^Generator, f: ^Exec_Frame) {
    n := f.node
    if f.state == 0 || f.state == 1 {
        if vm.module_resolve != nil && vm.module_fetch != nil {
            referrer := vm.base_url
            if vm.current_module != nil do referrer = vm.current_module.url
            dep := load_module(vm, n.str, referrer)
            cycle := false
            for ancestor := vm.current_module; ancestor != nil; ancestor = ancestor.parent {
                if ancestor == dep { cycle = true; break }
            }
            if dep != nil && dep.state == .Loading && dep.evaluation != nil && !cycle {
                f.state = 2
                exec_suspend(g, dep.evaluation, true); return
            }
        }
    } else {
        exec_inject(vm, g)
        if vm.throwing { exec_pop(g, nil); return }
    }
    value: Value
    if n.kind == .ImportDecl do eval_import_decl(vm, n, f.env)
    else do value = eval_export_decl(vm, n, f.env)
    exec_pop(g, value)
}

exec_push_reference :: proc(g: ^Generator, node: ^Node, env: ^Env) {
    append(&g.frames, Exec_Frame{mode = .Reference, node = node, env = env})
}

exec_reference :: proc(vm: ^Interp, g: ^Generator, f: ^Exec_Frame) {
    n := f.node
    if exec_abrupt(vm) { exec_pop(g, nil); return }
    if f.state == 0 {
        f.ref.node = n
        if n.kind == .Member || n.kind == .Index { f.state = 1; exec_push(g, n.left, f.env); return }
    } else if f.state == 1 {
        f.ref.obj = g.result
        if n.kind == .Index { f.state = 2; exec_push(g, n.right, f.env); return }
    } else { f.ref.key = key_string(vm, g.result) }
    g.reference = f.ref
    exec_pop(g, nil)
}

exec_for_of :: proc(vm: ^Interp, g: ^Generator, f: ^Exec_Frame) {
    n, env := f.node, f.env
    if f.state == 0 {
        f.label = vm.pending_label; vm.pending_label = ""
        f.state = 1; exec_push(g, n.right, env); return
    }
    switch f.state {
    case 1:
        if exec_abrupt(vm) { exec_pop(g, nil); return }
        f.values[0] = g.result
        if n.bval {
            if n.is_generator && !is_primitive(g.result) {
                method := get_member(vm, g.result, vm.sym_async_iterator_key)
                if !is_nullish(method) && !vm.throwing {
                    if fn, ok := method.(^Function); ok {
                        f.values[1] = call_function(vm, fn, g.result, nil)
                        f.protocol, f.flag2 = true, true
                    } else { throw_type_error(vm, "Symbol.asyncIterator is not callable") }
                }
            }
            if !f.protocol && !vm.throwing do f.values[1], f.protocol = get_iterator(vm, f.values[0])
            if f.protocol { f.values[2] = iterator_next_fn(f.values[1]) }
            else if _, array := f.values[0].(^Array); !array || !n.is_generator { collect_sync_values(vm, f.values[0], &f.items) }
        } else {
            keys: [dynamic]string
            #partial switch v in f.values[0] {
            case ^Object: own_enum_keys(vm, v, &keys)
            case ^Array, ^Function: own_keys_any(vm, v, &keys)
            case string:
                buf: [24]u8
                for i in 0..<str_rlen(v) do append(&keys, own_str(vm, strconv.write_int(buf[:], i64(i), 10)).(string))
            }
            for key in keys do append(&f.items, own_str(vm, key))
            delete(keys)
        }
        f.state = 2
    case 3:
        f.values[4] = exec_inject(vm, g)
        if vm.throwing { exec_pop(g, nil); return }
        f.state = 4
    case 5:
        f.values[5] = exec_inject(vm, g)
        if vm.throwing { exec_pop(g, nil); return }
        if f.done { exec_pop(g, f.values[3]); return }
        f.state = 6
    case 7:
        if exec_abrupt(vm) { exec_for_of_close(vm, g, f); return }
        f.state = 9; exec_push(g, n.callee, f.scope); return
    case 8:
        f.ref = g.reference
        if !exec_abrupt(vm) do put_target_ref(vm, f.ref, f.values[5], env, n.strict)
        f.state = 7
        return
    case 10:
        if !is_empty_completion(g.result) do f.values[3] = g.result
        if vm.continuing {
            if !loop_take_continue(vm, f.label) { exec_for_of_close(vm, g, f); return }
        } else if vm.breaking {
            loop_take_break(vm, f.label)
            exec_for_of_close(vm, g, f); return
        } else if vm.returning || vm.throwing { exec_for_of_close(vm, g, f); return }
        f.state = 2
    case 11:
        result := exec_inject(vm, g)
        if !vm.throwing && is_primitive(result) do throw_type_error(vm, "Iterator result is not an object")
        if f.signal.throwing || !exec_abrupt(vm) do exec_restore_signal(vm, f.signal)
        exec_pop(g, f.values[3]); return
    case:
    }
    if f.state == 9 { f.state = 10; return }
    if vm.throwing { exec_pop(g, nil); return }
    if f.state == 2 {
        if step_guard(vm) { exec_pop(g, f.values[3]); return }
        if f.protocol {
            next, ok := f.values[2].(^Function)
            if !ok { throw_type_error(vm, "Iterator next is not callable"); exec_pop(g, nil); return }
            f.values[4] = call_function(vm, next, f.values[1], nil)
            if vm.throwing { exec_pop(g, nil); return }
            if n.is_generator && f.flag2 {
                f.state = 3; exec_suspend(g, f.values[4], true); return
            }
            f.state = 4
        } else {
            f.done = f.index >= len(f.items)
            f.values[5] = nil
            if array, ok := f.values[0].(^Array); ok && n.is_generator {
                f.done = f.index >= len(array.items)
                if !f.done do f.values[5] = get_index(vm, array, f64(f.index))
            } else if !f.done { f.values[5] = f.items[f.index] }
            f.index += 1
            if n.is_generator {
                f.state = 5; exec_suspend(g, f.values[5], true); return
            }
            if f.done { exec_pop(g, f.values[3]); return }
            f.state = 6
        }
    }
    if f.state == 4 {
        if is_primitive(f.values[4]) { throw_type_error(vm, "Iterator result is not an object"); exec_pop(g, nil); return }
        f.done = truthy(get_member(vm, f.values[4], "done"))
        f.values[5] = nil
        if !f.done || n.is_generator && !f.flag2 do f.values[5] = get_member(vm, f.values[4], "value")
        if vm.throwing { exec_pop(g, nil); return }
        if n.is_generator && !f.flag2 {
            f.state = 5; exec_suspend(g, f.values[5], true); return
        }
        if f.done { exec_pop(g, f.values[3]); return }
        f.state = 6
    }
    if f.state == 6 {
        f.scope = new_env(vm, env)
        f.state = 7
        if n.third != nil {
            if n.third.kind == .Pattern { exec_push_pattern(g, n.third, f.values[5], env, false, false); return }
            f.state = 8; exec_push_reference(g, n.third, env); return
        }
        if n.left != nil {
            exec_push_pattern(g, n.left, f.values[5], env if n.stat else f.scope, !n.stat, n.is_const)
            return
        }
        if n.aux && !n.stat {
            if n.is_const do env_define_const(f.scope, n.name, f.values[5])
            else do env_define(f.scope, n.name, f.values[5])
        } else { env_assign(vm, env, n.name, f.values[5], n.strict) }
    }
}

exec_for_of_close :: proc(vm: ^Interp, g: ^Generator, f: ^Exec_Frame) {
    if !f.protocol { exec_pop(g, f.values[3]); return }
    if !f.node.is_generator {
        iterator_close_completion(vm, f.values[1])
        exec_pop(g, f.values[3]); return
    }
    f.signal = exec_signal(vm)
    exec_clear_signal(vm)
    method := get_member(vm, f.values[1], "return")
    if fn, ok := method.(^Function); ok && !vm.throwing {
        result := call_function(vm, fn, f.values[1], nil)
        if !vm.throwing { f.state = 11; exec_suspend(g, result, true); return }
    } else if !is_nullish(method) && !vm.throwing { throw_type_error(vm, "Iterator return is not callable") }
    if f.signal.throwing || !exec_abrupt(vm) do exec_restore_signal(vm, f.signal)
    exec_pop(g, f.values[3])
}

exec_delegate :: proc(vm: ^Interp, g: ^Generator, f: ^Exec_Frame) {
    n := f.node
    switch f.state {
    case 0: f.state = 1; exec_push(g, n.left, f.env); return
    case 1:
        if g.is_async do f.values[1], f.protocol = get_async_iterator(vm, g.result)
        else do f.values[1], f.protocol = get_iterator(vm, g.result)
        if vm.throwing { exec_pop(g, nil); return }
        if f.protocol { f.values[2] = iterator_next_fn(f.values[1]) }
        else { collect_sync_values(vm, g.result, &f.items) }
        f.state = 2
    case 3:
        f.values[4] = exec_inject(vm, g)
        if vm.throwing { exec_pop(g, nil); return }
        f.state = 4
    case 5:
        value := exec_inject(vm, g)
        if vm.throwing { exec_pop(g, nil); return }
        f.state = 6; exec_suspend(g, value, false); return
    case 6:
        if !f.protocol {
            exec_inject(vm, g)
            if exec_abrupt(vm) { exec_pop(g, nil); return }
        } else {
            f.cursor = 1 if g.inject == .Throw else (2 if g.inject == .Return else 0)
            f.values[3] = g.inject_val
            g.inject = .None; g.inject_val = nil
        }
        f.state = 2
    case 7:
        exec_inject(vm, g)
        vm.throwing = false; vm.thrown = nil
        throw_type_error(vm, "The iterator does not provide a 'throw' method")
        exec_pop(g, nil); return
    }
    if f.state == 2 {
        if step_guard(vm) { exec_pop(g, nil); return }
        if f.protocol {
            method := f.values[2]
            if f.cursor == 1 do method = get_member(vm, f.values[1], "throw")
            if f.cursor == 2 do method = get_member(vm, f.values[1], "return")
            if vm.throwing { exec_pop(g, nil); return }
            if is_nullish(method) && f.cursor == 2 {
                vm.returning = true; vm.ret_val = f.values[3]
                exec_pop(g, f.values[3]); return
            }
            if is_nullish(method) && f.cursor == 1 {
                if ret := iterator_method_fn(f.values[1], "return"); ret != nil {
                    result := call_function(vm, ret, f.values[1], nil)
                    if g.is_async && !vm.throwing { f.state = 7; exec_suspend(g, result, true); return }
                }
                if !vm.throwing do throw_type_error(vm, "The iterator does not provide a 'throw' method")
                exec_pop(g, nil); return
            }
            fn, ok := method.(^Function)
            if !ok { throw_type_error(vm, "Iterator method is not callable"); exec_pop(g, nil); return }
            f.values[4] = call_function(vm, fn, f.values[1], []Value{f.values[3]})
            if vm.throwing { exec_pop(g, nil); return }
            if g.is_async { f.state = 3; exec_suspend(g, f.values[4], true); return }
            f.state = 4
        } else {
            if f.index >= len(f.items) { exec_pop(g, nil); return }
            value := f.items[f.index]; f.index += 1
            f.state = 5 if g.is_async else 6
            exec_suspend(g, value, g.is_async); return
        }
    }
    if f.state == 4 {
        if is_primitive(f.values[4]) { throw_type_error(vm, "Iterator result is not an object"); exec_pop(g, nil); return }
        done := truthy(get_member(vm, f.values[4], "done"))
        if vm.throwing { exec_pop(g, nil); return }
        value := get_member(vm, f.values[4], "value")
        if vm.throwing { exec_pop(g, nil); return }
        if done {
            if f.cursor == 2 { vm.returning = true; vm.ret_val = value }
            exec_pop(g, value); return
        }
        f.state = 5 if g.is_async else 6
        exec_suspend(g, value, g.is_async)
    }
}

exec_class :: proc(vm: ^Interp, g: ^Generator, f: ^Exec_Frame) {
    n := f.node
    if f.state == 0 {
        f.state = 1
        if n.callee != nil { exec_push(g, n.callee, f.env); return }
        g.result = nil
    }
    if f.state == 1 {
        f.values[0] = g.result
        f.keys = make([dynamic]string, len(n.body), len(n.body))
        f.state = 2
    } else if f.state == 3 {
        v := to_primitive(vm, g.result, false)
        if !vm.throwing do f.keys[f.index-1] = key_string(vm, v)
        f.state = 2
    }
    if vm.throwing { exec_pop(g, nil); return }
    for f.index < len(n.body) {
        m := n.body[f.index]; f.index += 1
        if m.kind != .Func && m.kind != .ClassField do continue
        if m.name != "" || m.left == nil { f.keys[f.index-1] = m.name; continue }
        f.state = 3; exec_push(g, m.left, f.env); return
    }
    value := eval_class(vm, n, f.env, f.keys[:], f.values[0], n.callee != nil)
    exec_pop(g, value)
}

exec_push_pattern :: proc(g: ^Generator, node: ^Node, value: Value, env: ^Env, declare, is_const: bool) {
    append(&g.frames, Exec_Frame{mode = .Pattern, node = node, env = env,
        values = {value, nil, nil, nil, nil, nil}, flag = declare, flag2 = is_const})
}

exec_pattern :: proc(vm: ^Interp, g: ^Generator, f: ^Exec_Frame) {
    pat, env := f.node, f.env
    if exec_abrupt(vm) {
        if f.protocol && !f.done do iterator_close_completion(vm, f.values[1])
        exec_pop(g, nil); return
    }
    if f.state == 0 {
        if !exec_needs_frame(vm, pat) {
            bind_pattern(vm, pat, f.values[0], env, f.flag, f.flag2)
            exec_pop(g, nil); return
        }
        if is_nullish(f.values[0]) || !pat.bval && is_primitive(f.values[0]) &&
           !is_string(f.values[0]) {
            throw_type_error(vm, "Cannot destructure value")
            exec_pop(g, nil); return
        }
        if !pat.bval {
            #partial switch v in f.values[0] {
            case ^Object, ^Collection:
                f.values[1], f.protocol = get_iterator(vm, v)
                if f.protocol do f.values[2] = iterator_next_fn(f.values[1])
            }
        }
        f.state = 1
    }
    if vm.throwing {
        if f.protocol && !f.done do iterator_close_completion(vm, f.values[1])
        exec_pop(g, nil); return
    }
    if f.index >= len(pat.body) {
        if f.protocol && !f.done do iterator_close_completion(vm, f.values[1])
        exec_pop(g, nil); return
    }
    el := pat.body[f.index]
    switch f.state {
    case 1:
        f.key = el.str
        if pat.bval && el.third != nil { f.state = 2; exec_push(g, el.third, env); return }
        f.state = 3
    case 2:
        f.key = key_string(vm, g.result)
        append(&f.keys, f.key)
        f.state = 3
    case 4: f.ref = g.reference; f.state = 5
    case 6: f.values[3] = g.result; f.state = 7
    case 8: f.index += 1; f.state = 1; return
    case:
    }
    if vm.throwing do return
    if f.state == 3 {
        if el.left != nil && el.left.kind != .Pattern {
            f.state = 4; exec_push_reference(g, el.left, env); return
        }
        f.state = 5
    }
    if f.state == 5 {
        if el.bval {
            if pat.bval {
                rest := new_object(vm)
                if src, ok := f.values[0].(^Object); ok {
                    keys: [dynamic]string
                    own_enum_keys(vm, src, &keys)
                    for k in keys {
                        used := pattern_has_key(pat, k)
                        for consumed in f.keys do if consumed == k do used = true
                        if !used do oput(rest, k, get_member(vm, src, k))
                    }
                    delete(keys)
                }
                f.values[3] = rest
            } else {
                rest := new_array(vm)
                if f.protocol {
                    next, _ := f.values[2].(^Function)
                    for !f.done {
                        v := pattern_iter_step(vm, f.values[1], next, &f.done)
                        if f.done do break
                        append(&rest.items, v)
                    }
                } else if src, ok := f.values[0].(^Array); ok {
                    for j := f.index; j < len(src.items); j += 1 do append(&rest.items, src.items[j])
                }
                f.values[3] = rest
            }
        } else if pat.bval { f.values[3] = get_member(vm, f.values[0], f.key) }
        else if f.protocol {
            next, _ := f.values[2].(^Function)
            f.values[3] = pattern_iter_step(vm, f.values[1], next, &f.done)
        } else { f.values[3] = get_index(vm, f.values[0], f64(f.index)) }
        if vm.throwing do return
        if f.values[3] == nil && el.right != nil {
            f.state = 6; exec_push(g, el.right, env); return
        }
        f.state = 7
    }
    if f.state == 7 {
        if el.left != nil && el.left.kind == .Pattern {
            f.state = 8
            exec_push_pattern(g, el.left, f.values[3], env, f.flag, f.flag2); return
        }
        if el.left != nil { put_target_ref(vm, f.ref, f.values[3], env, pat.strict) }
        else if el.name != "" {
            infer_binding_name(el.right, f.values[3], el.name)
            if f.flag {
                if f.flag2 do env_define_const(env, el.name, f.values[3])
                else do env_define(env, el.name, f.values[3])
            } else { env_assign(vm, env, el.name, f.values[3], pat.strict) }
        }
        f.index += 1; f.state = 1
    }
}
