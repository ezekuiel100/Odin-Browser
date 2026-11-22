package js

import "core:testing"
import "core:strings"

// Observe a completed top-level coroutine after the checkpoint. Timers advance
// only by the explicit amount requested by the test; no polling or real sleep.
run_top_completion :: proc(src: string, dt: f64 = 0) -> Value {
    vm := vm_create()
    defer vm_free(vm)
    result := vm_run(vm, src)
    if dt > 0 do vm_pump_timers(vm, dt)
    check_parse_recoveries(vm, src)
    if p, ok := result.(^Object); ok {
        if p.promise != nil && p.promise.state == PROMISE_FULFILLED {
            return p.promise.value
        }
    }
    return result
}

@(private = "file")
top_resolve :: proc(vm: ^Interp, specifier, referrer: string) -> string {
    return strings.clone(specifier)
}

@(private = "file")
top_fetch :: proc(vm: ^Interp, url: string) -> (string, bool) {
    if src, ok := vm.module_stubs[url]; ok do return strings.clone(src), true
    return "", false
}

@(private = "file")
top_vm :: proc() -> ^Interp {
    vm := vm_create()
    vm.module_resolve = top_resolve
    vm.module_fetch = top_fetch
    vm.module_stubs = make(map[string]string)
    return vm
}

@(test)
test_top_await_resumes_after_later_script :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    completion := vm_run(vm, `var release, order = 'before,';
        var pending = new Promise(function(r){ release = r; });
        var value = await pending; order += value; value + 1;`).(^Object)
    testing.expect_value(t, completion.promise.state, PROMISE_PENDING)
    testing.expect_value(t, vm_run(vm, "order").(string), "before,")
    vm_run(vm, "order += 'script,'; release(41)")
    testing.expect_value(t, vm_run(vm, "order").(string), "before,script,41")
    testing.expect_value(t, as_number(completion.promise.value), f64(42))
    testing.expect_value(t, as_number(vm_run(vm, "value")), f64(41))
}

@(test)
test_top_await_does_not_pump_timer :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    completion := vm_run(vm, `var finished = false;
        await new Promise(function(r){ setTimeout(r, 25); }); finished = true;`).(^Object)
    testing.expect(t, !truthy(vm_run(vm, "finished")))
    testing.expect_value(t, vm.clock_ms, f64(0))
    vm_pump_timers(vm, 25)
    testing.expect(t, truthy(vm_run(vm, "finished")))
    testing.expect_value(t, completion.promise.state, PROMISE_FULFILLED)
}

@(test)
test_top_await_fifo_and_catch :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `var order = ''; await 0; order += 'await,';
        try { await Promise.reject('caught'); } catch(e){ order += e; }
        finally { order += ',finally'; }`)
    testing.expect_value(t, vm_run(vm, "order").(string), "await,caught,finally")
}

@(test)
test_top_module_dependency_and_dynamic_import_wait :: proc(t: ^testing.T) {
    vm := top_vm()
    defer vm_free(vm)
    vm_run(vm, "var release, order = ''; var pending = new Promise(function(r){ release = r; });")
    vm.module_stubs["dep"] = `order += 'dep,'; export var value = await pending; order += 'ready,';`
    vm.module_stubs["parent"] = `import {value} from 'dep'; order += 'parent,'; export var result = value + 1;`
    vm_run(vm, `var result = 0; import('parent').then(function(ns){ result = ns.result; order += 'imported'; });`)
    testing.expect_value(t, vm_run(vm, "order").(string), "dep,")
    testing.expect_value(t, vm.modules["parent"].state, Module_State.Loading)
    testing.expect_value(t, vm.modules["dep"].state, Module_State.Loading)
    vm_run(vm, "release(41)")
    testing.expect_value(t, as_number(vm_run(vm, "result")), f64(42))
    testing.expect_value(t, vm_run(vm, "order").(string), "dep,ready,parent,imported")
    testing.expect_value(t, vm.modules["parent"].state, Module_State.Done)
}

@(test)
test_top_module_failure_rejects_importers :: proc(t: ^testing.T) {
    vm := top_vm()
    defer vm_free(vm)
    vm_run(vm, "var reject, ran = false, error = ''; var pending = new Promise(function(_,r){ reject = r; });")
    vm.module_stubs["dep"] = `await pending; export var value = 1;`
    vm.module_stubs["parent"] = `import {value} from 'dep'; ran = true;`
    vm_run(vm, `import('parent').catch(function(e){ error = e; });`)
    vm_run(vm, "reject('failure')")
    testing.expect(t, !truthy(vm_run(vm, "ran")))
    testing.expect_value(t, vm_run(vm, "error").(string), "failure")
    testing.expect_value(t, vm.modules["parent"].state, Module_State.Failed)
    vm_run(vm, `error = ''; import('parent').catch(function(e){ error = e; });`)
    testing.expect_value(t, vm_run(vm, "error").(string), "failure")
}

@(test)
test_top_modules_restore_context_after_suspension :: proc(t: ^testing.T) {
    vm := top_vm()
    defer vm_free(vm)
    vm_run(vm, "var release; var pending = new Promise(function(r){ release = r; });")
    vm_run_module(vm, `export var first = await pending; export var url = import.meta.url;`, "first")
    vm_run_module(vm, `export var second = 2;`, "second")
    testing.expect(t, vm.current_module == nil)
    vm_run(vm, "release(7)")
    testing.expect_value(t, as_number(get_member(vm, vm.modules["first"].ns, "first")), f64(7))
    testing.expect_value(t, get_member(vm, vm.modules["first"].ns, "url").(string), "first")
    testing.expect(t, get_member(vm, vm.modules["second"].ns, "first") == nil)
    testing.expect(t, vm.current_module == nil)
}

@(test)
test_top_await_pending_disposal :: proc(t: ^testing.T) {
    vm := top_vm()
    vm.module_stubs["pending"] = `await new Promise(function(){}); export var value = 1;`
    vm_run(vm, `import('pending'); await new Promise(function(){});`)
    testing.expect(t, vm.current_module == nil)
    vm_free(vm)
}

@(test)
test_top_module_starts_sibling_dependencies :: proc(t: ^testing.T) {
    vm := top_vm()
    defer vm_free(vm)
    vm_run(vm, "var release, order = ''; var pending = new Promise(function(r){ release = r; });")
    vm.module_stubs["first"] = `order += 'first,'; export var value = await pending;`
    vm.module_stubs["second"] = `order += 'second,'; release(42);`
    vm.module_stubs["root"] = `import {value} from 'first'; import 'second'; order += value;`
    vm_run(vm, "import('root')")
    testing.expect_value(t, vm_run(vm, "order").(string), "first,second,42")
    testing.expect_value(t, vm.modules["root"].state, Module_State.Done)
}

@(test)
test_top_module_static_cycle_with_await :: proc(t: ^testing.T) {
    vm := top_vm()
    defer vm_free(vm)
    vm_run(vm, "var release, result = 0; var pending = new Promise(function(r){ release = r; });")
    vm.module_stubs["a"] = `import * as b from 'b'; export var value = b.value + 1;`
    vm.module_stubs["b"] = `import * as a from 'a'; export var value = await pending;`
    vm_run(vm, "import('a').then(function(ns){ result = ns.value; });")
    testing.expect_value(t, as_number(vm_run(vm, "result")), f64(0))
    vm_run(vm, "release(41)")
    testing.expect_value(t, as_number(vm_run(vm, "result")), f64(42))
}

@(test)
test_top_module_reexport_waits_and_shares_evaluation :: proc(t: ^testing.T) {
    vm := top_vm()
    defer vm_free(vm)
    vm_run(vm, "var release, calls = 0, left = 0, right = 0; var pending = new Promise(function(r){ release = r; });")
    vm.module_stubs["dep"] = `calls++; export var value = await pending;`
    vm.module_stubs["reexport"] = `export {value} from 'dep';`
    vm_run(vm, `import('reexport').then(function(ns){ left = ns.value; });
        import('dep').then(function(ns){ right = ns.value; });`)
    testing.expect_value(t, as_number(vm_run(vm, "calls")), f64(1))
    vm_run(vm, "release(42)")
    testing.expect_value(t, as_number(vm_run(vm, "left + right")), f64(84))
    testing.expect_value(t, as_number(vm_run(vm, "calls")), f64(1))
}

@(test)
test_top_await_never_times_out_or_drains_recursively :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    completion := vm_run(vm, `var release, order = '';
        var pending = new Promise(function(r){ release = r; });
        await pending; order += 'await,';`).(^Object)
    vm_pump_timers(vm, 30000)
    testing.expect_value(t, completion.promise.state, PROMISE_PENDING)
    vm_run(vm, `Promise.resolve().then(function(){
        order += 'handler,'; release(); order += 'end,';
        queueMicrotask(function(){ order += 'microtask'; });
    });`)
    testing.expect_value(t, vm_run(vm, "order").(string), "handler,end,await,microtask")
    testing.expect_value(t, completion.promise.state, PROMISE_FULFILLED)
}
