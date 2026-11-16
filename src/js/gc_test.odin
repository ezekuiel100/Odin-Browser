package js

import "core:testing"

@(test)
gc_reclaims_cycles_and_preserves_closures :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `var keep=(function(){var a=[{answer:42}]; return function(){return a[0].answer;};})();`)
    vm_collect(vm)
    objects, arrays, funcs := len(vm.all_objects), len(vm.all_arrays), len(vm.all_funcs)
    vm_run(vm, `(function(){ var a={}, b=[]; a.self=a; a.b=b; b.push(a); var f=function(){return a;}; a.f=f; })();`)
    testing.expect(t, len(vm.all_objects) > objects)
    testing.expect(t, vm_collect(vm))
    testing.expect_value(t, len(vm.all_objects), objects)
    testing.expect_value(t, len(vm.all_arrays), arrays)
    testing.expect_value(t, len(vm.all_funcs), funcs)
    testing.expect_value(t, as_number(vm_run(vm, `keep()`)), f64(42))
}

@(test)
gc_weak_ephemerons_and_explicit_roots :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `var w=new WeakMap(), w2=new WeakMap(), s=new WeakSet();
        var key={}, second={}; w.set(key,second); w2.set(second,{answer:42}); s.add(second);
        second=null;
        (function(){var dead={}; w.set(dead,{back:dead}); s.add(dead);})();`)
    testing.expect(t, vm_collect(vm))
    w := vm.global.vars["w"].(^Collection)
    w2 := vm.global.vars["w2"].(^Collection)
    ws := vm.global.vars["s"].(^Collection)
    testing.expect_value(t, w.size, 1)
    testing.expect_value(t, w2.size, 1)
    testing.expect_value(t, ws.size, 1)
    testing.expect_value(t, as_number(vm_run(vm, `w2.get(w.get(key)).answer`)), f64(42))
    held := new_object(vm)
    held.props["answer"] = f64(7)
    testing.expect(t, vm_collect(vm, []Value{held}))
    testing.expect_value(t, as_number(held.props["answer"]), f64(7))
    vm_run(vm, `key=null`)
    testing.expect(t, vm_collect(vm))
    testing.expect_value(t, w.size, 0)
    testing.expect_value(t, w2.size, 0)
    testing.expect_value(t, ws.size, 0)
}

@(test)
gc_defers_with_suspended_native_stack :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `var g=(function*(){var x={answer:42}; yield 1; return x.answer;})(); g.next();`)
    testing.expect(t, !vm_collect(vm))
    testing.expect_value(t, as_number(vm_run(vm, `g.next().value`)), f64(42))
    testing.expect(t, vm_collect(vm))
}

@(test)
gc_runs_automatically_at_host_turn_end :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_collect(vm)
    baseline := len(vm.all_objects)
    for i in 0..<5000 { new_object(vm) }
    vm_end_host_turn(vm)
    testing.expect_value(t, len(vm.all_objects), baseline)
}
