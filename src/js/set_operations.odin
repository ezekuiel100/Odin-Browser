package js

import "core:math"

Set_Operation :: enum { Union, Intersection, Difference, Symmetric_Difference, Subset, Superset, Disjoint }

set_operation_name :: proc(name: string) -> bool {
    return name == "union" || name == "intersection" || name == "difference" || name == "symmetricDifference" || name == "isSubsetOf" || name == "isSupersetOf" || name == "isDisjointFrom"
}

set_operation :: proc(vm: ^Interp, this: Value, args: []Value, op: Set_Operation) -> Value {
    c, ok := this.(^Collection)
    if !ok || c.kind != .Set { throw_type_error(vm, "Set operation requires a Set receiver"); return nil }
    other := arg(args, 0)
    if is_primitive(other) { throw_type_error(vm, "Set operation requires a set-like object"); return nil }
    size_value := get_member(vm, other, "size")
    if vm.throwing do return nil
    size := to_number(vm, size_value)
    if vm.throwing do return nil
    if size != size { throw_type_error(vm, "Invalid set-like size"); return nil }
    size = math.trunc(size)
    if size < 0 { vm.thrown = mk_error(vm, "RangeError", "Invalid set-like size"); vm.throwing = true; return nil }
    has_value := get_member(vm, other, "has")
    if vm.throwing do return nil
    has, has_ok := has_value.(^Function)
    if !has_ok { throw_type_error(vm, "Set-like has is not callable"); return nil }
    keys_value := get_member(vm, other, "keys")
    if vm.throwing do return nil
    keys, keys_ok := keys_value.(^Function)
    if !keys_ok { throw_type_error(vm, "Set-like keys is not callable"); return nil }

    if op == .Subset && f64(c.size) > size do return false
    if op == .Superset && f64(c.size) < size do return false
    out: ^Collection
    if op <= .Symmetric_Difference {
        out = new_collection(vm, .Set)
        if op == .Difference {
            for e in c.entries do if !e.dead do coll_put(out, e.key, e.key)
        }
    }
    // Pin tombstones while arbitrary has/keys callbacks can mutate the receiver.
    c.iterating += 1
    defer c.iterating -= 1
    use_has := op == .Subset || ((op == .Intersection || op == .Difference || op == .Disjoint) && f64(c.size) <= size)
    if use_has {
        source := c
        if op == .Difference do source = out // difference visits the snapshot
        source.iterating += 1
        defer source.iterating -= 1
        for i := 0; i < len(source.entries); i += 1 {
            if step_guard(vm) do return nil
            e := source.entries[i]
            if e.dead do continue
            found := truthy(call_function(vm, has, other, []Value{e.key}))
            if vm.throwing do return nil
            #partial switch op {
            case .Subset: if !found do return false
            case .Disjoint: if found do return false
            case .Intersection: if found do coll_put(out, e.key, e.key)
            case .Difference: if found do coll_delete(vm, out, []Value{e.key})
            case:
            }
        }
    } else {
        iter := call_function(vm, keys, other, nil)
        if vm.throwing do return nil
        if is_primitive(iter) { throw_type_error(vm, "Invalid set-like iterator"); return nil }
        next_value := get_member(vm, iter, "next")
        if vm.throwing do return nil
        next, next_ok := next_value.(^Function)
        if !next_ok { throw_type_error(vm, "Iterator next is not callable"); return nil }
        if op == .Union || op == .Symmetric_Difference {
            for e in c.entries do if !e.dead do coll_put(out, e.key, e.key)
        }
        for {
            if step_guard(vm) do return nil
            step := call_function(vm, next, iter, nil)
            if vm.throwing do return nil
            if is_primitive(step) { throw_type_error(vm, "Invalid iterator result"); return nil }
            done := get_member(vm, step, "done")
            if vm.throwing do return nil
            if truthy(done) do break
            key := get_member(vm, step, "value")
            if vm.throwing do return nil
            found := coll_find(c, key) >= 0
            #partial switch op {
            case .Union: coll_put(out, key, key)
            case .Intersection: if found do coll_put(out, key, key)
            case .Difference: coll_delete(vm, out, []Value{key})
            case .Symmetric_Difference:
                if found { coll_delete(vm, out, []Value{key}) } else { coll_put(out, key, key) }
            case .Superset, .Disjoint:
                if (op == .Superset && !found) || (op == .Disjoint && found) {
                    iterator_close(vm, iter)
                    if vm.throwing do return nil
                    return false
                }
            case:
            }
        }
    }
    if out != nil do return out
    return true
}

set_union :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return set_operation(vm, this, args, .Union) }
set_intersection :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return set_operation(vm, this, args, .Intersection) }
set_difference :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return set_operation(vm, this, args, .Difference) }
set_symmetric_difference :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return set_operation(vm, this, args, .Symmetric_Difference) }
set_is_subset :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return set_operation(vm, this, args, .Subset) }
set_is_superset :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return set_operation(vm, this, args, .Superset) }
set_is_disjoint :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return set_operation(vm, this, args, .Disjoint) }

install_set_operations :: proc(vm: ^Interp) {
    m := &vm.collection_methods
    m["union"] = mk_builtin_method(vm, set_union, "union", 1)
    m["intersection"] = mk_builtin_method(vm, set_intersection, "intersection", 1)
    m["difference"] = mk_builtin_method(vm, set_difference, "difference", 1)
    m["symmetricDifference"] = mk_builtin_method(vm, set_symmetric_difference, "symmetricDifference", 1)
    m["isSubsetOf"] = mk_builtin_method(vm, set_is_subset, "isSubsetOf", 1)
    m["isSupersetOf"] = mk_builtin_method(vm, set_is_superset, "isSupersetOf", 1)
    m["isDisjointFrom"] = mk_builtin_method(vm, set_is_disjoint, "isDisjointFrom", 1)
}
