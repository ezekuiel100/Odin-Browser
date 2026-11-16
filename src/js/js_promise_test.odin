package js

import "core:testing"

@(test)
test_promise_executor_validation :: proc(t: ^testing.T) {
    ok, _ := run_settled(`
        var count = 0;
        function invalid(value) {
            try { new Promise(value); } catch (e) {
                if (e instanceof TypeError) count++;
            }
        }
        try { new Promise(); } catch (e) { if (e instanceof TypeError) count++; }
        invalid(undefined); invalid(null); invalid(false); invalid(1);
        invalid('executor'); invalid({}); invalid({then: function() {}});
        var result;
        new Promise(function(resolve) { resolve(7); }).then(function(v) { result = v; });
    `, `count === 8 && result === 7`).(bool)
    testing.expect(t, ok, "invalid executors must throw synchronously")
}

@(test)
test_promise_finally_waits_and_preserves_result :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var release;
        var cleanup = new Promise(function(resolve) { release = resolve; });
        var out = '';
        var calls = 0;
        function finish() { calls++; if (arguments.length !== 0) throw 'arguments'; return cleanup; }
        Promise.resolve('value').finally(finish).then(function(v) { out += v; });
        Promise.reject('reason').finally(finish).catch(function(e) { out += ',' + e; });
    `)
    waiting, _ := vm_run(vm, `calls === 2 && out === ''`).(bool)
    testing.expect(t, waiting, "finally must wait for pending cleanup on both paths")
    vm_run(vm, `release('ignored');`)
    done, _ := vm_run(vm, `out === 'value,reason'`).(bool)
    testing.expect(t, done, "cleanup fulfillment must preserve original value and reason")
}

@(test)
test_promise_finally_cleanup_failures_and_passthrough :: proc(t: ^testing.T) {
    ok, _ := run_settled(`
        var out = [];
        Promise.resolve(1).finally(function() { return Promise.reject('a'); }).catch(function(e) { out.push(e); });
        Promise.reject(2).finally(function() { return Promise.reject('b'); }).catch(function(e) { out.push(e); });
        Promise.resolve(3).finally(function() { throw 'c'; }).catch(function(e) { out.push(e); });
        Promise.reject(4).finally(function() { throw 'd'; }).catch(function(e) { out.push(e); });
        Promise.resolve(5).finally(42).then(function(v) { out.push(v); });
        Promise.reject(6).finally(null).catch(function(e) { out.push(e); });
        Promise.resolve(7).finally(function() { return {then: function(resolve) { resolve(99); }}; }).then(function(v) { out.push(v); });
        Promise.reject(8).finally(function() { return 99; }).catch(function(e) { out.push(e); });
    `, `out.length === 8 && out.indexOf('a') >= 0 && out.indexOf('b') >= 0 && out.indexOf('c') >= 0 && out.indexOf('d') >= 0 && out.indexOf(5) >= 0 && out.indexOf(6) >= 0 && out.indexOf(7) >= 0 && out.indexOf(8) >= 0`).(bool)
    testing.expect(t, ok, "cleanup failures override results; other cleanup preserves them")
}
