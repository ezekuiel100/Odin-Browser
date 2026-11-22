package js

import "core:testing"
import "core:time"

@(test)
test_promise_private_state_is_not_a_property :: proc(t: ^testing.T) {
    ok, _ := run_settled(`
        var p = Promise.resolve(7), value = 0;
        var hidden = !('_state' in p) && !('_value' in p) && !('_reactions' in p);
        var empty = Reflect.ownKeys(p).length === 0;
        p._state = 2; p._value = 99; p._reactions = [];
        p.then(function(v) { value = v; });
    `, `hidden && empty && value === 7 && p._value === 99`).(bool)
    testing.expect(t, ok, "internal slots must be invisible and independent of ordinary user properties")
}

@(test)
test_promise_private_state_survives_freeze_and_property_traps :: proc(t: ^testing.T) {
    ok, _ := run_settled(`
        var cap = Promise.withResolvers(), value = 0, traps = 0;
        Object.defineProperty(cap.promise, '_state', {get: function() { traps++; throw 'wrong'; }});
        Object.defineProperty(cap.promise, '_value', {set: function() { traps++; throw 'wrong'; }});
        Object.freeze(cap.promise);
        cap.promise.then(function(v) { value = v; });
        cap.resolve(42);
    `, `value === 42 && traps === 0`).(bool)
    testing.expect(t, ok, "frozen promises and user accessors must not affect native resolution")
}

@(test)
test_promise_private_brand_cannot_be_forged_or_inherited :: proc(t: ^testing.T) {
    ok, _ := run_settled(`
        var p = Promise.resolve(1), caught = 0;
        var fake = {_state: 1, _value: 99, _reactions: []};
        [fake, Object.create(p), new Proxy(p, {})].forEach(function(value) {
            try { Promise.prototype.then.call(value, function() {}); }
            catch(e) { if (e instanceof TypeError) caught++; }
        });
        var resolved = false;
        Promise.resolve(fake).then(function(value) { resolved = value === fake; });
    `, `caught === 3 && resolved`).(bool)
    testing.expect(t, ok, "only an actual promise carries the brand required by Promise.prototype.then")
}

@(test)
test_promise_private_slots_are_traced_by_gc :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var fulfilled = Promise.resolve({answer: 42});
        var rejected = Promise.reject({reason: 7});
        var cap = Promise.withResolvers();
        var pending = (function() {
            var held = {answer: 11};
            return cap.promise.then(function(v) { return held.answer + v; });
        })();
        var out = '';
    `)
    testing.expect(t, vm_collect(vm))
    vm_run(vm, `
        fulfilled.then(function(v) { out += v.answer + ','; });
        rejected.catch(function(e) { out += e.reason + ','; });
        pending.then(function(v) { out += v; });
        cap.resolve(1);
    `)
    testing.expect_value(t, vm_run(vm, `out`), Value("42,7,12"))
}

@(test)
test_promise_private_cycles_are_collected :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_collect(vm)
    baseline := gc_heap_count(vm)
    vm_run(vm, `
        (function() {
            var value = {};
            var p = Promise.resolve(value);
            value.promise = p;
            var cap = Promise.withResolvers();
            cap.promise.then(function() { return cap.promise; });
        })();
    `)
    testing.expect(t, vm_collect(vm))
    testing.expect_value(t, gc_heap_count(vm), baseline)
}

@(test)
test_microtask_large_fifo_preserves_nested_jobs_and_errors :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm.time_budget_ms = 0
    vm_run(vm, `
        var expected = 0, correct = true, nested = 0;
        function enqueue(i) {
            queueMicrotask(function() {
                if (expected !== i) correct = false;
                expected++;
                if (i === 2048) throw new Error('expected');
                queueMicrotask(function() {
                    if (expected !== 6000) correct = false;
                    nested++;
                });
            });
        }
        for (var i = 0; i < 6000; i++) enqueue(i);
    `)
    testing.expect_value(t, vm_run(vm, `correct && expected === 6000 && nested === 5999`), Value(true))
    testing.expect_value(t, vm.uncaught_total, 1)
    testing.expect_value(t, len(vm.reaction_queue), 0)
}

@(test)
test_microtask_deferred_tail_keeps_order_and_gc_roots :: proc(t: ^testing.T) {
    vm := host_turn_test_vm()
    defer vm_free(vm)
    vm_exec(vm, `
        var order = '';
        queueMicrotask(function() {
            order += 'a'; block();
            queueMicrotask(function() { order += 'd'; });
        });
        Promise.resolve({letter: 'b'}).then(function(v) { order += v.letter; });
        queueMicrotask(function() { order += 'c'; });
    `)
    vm_begin_host_turn(vm, 5)
    promise_checkpoint(vm)
    vm_end_host_turn(vm)
    testing.expect_value(t, vm.global.vars["order"], Value("a"))
    testing.expect_value(t, len(vm.reaction_queue), 3)
    testing.expect(t, vm_collect(vm))
    promise_checkpoint(vm)
    testing.expect_value(t, vm.global.vars["order"], Value("abcd"))
    testing.expect_value(t, len(vm.reaction_queue), 0)
}

@(test)
test_microtask_watchdog_discards_tail_and_allows_next_checkpoint :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_exec(vm, `
        var count = 0;
        function spin() { count++; queueMicrotask(spin); }
        queueMicrotask(spin);
    `)
    vm.time_budget_ms = 1
    vm.task_start = time.tick_add(time.tick_now(), -10 * time.Millisecond)
    promise_checkpoint(vm)
    testing.expect(t, as_number(vm.global.vars["count"]) > 0)
    testing.expect_value(t, len(vm.reaction_queue), 0)
    vm.time_budget_ms = 0
    vm_run(vm, `var recovered = false; queueMicrotask(function() { recovered = true; });`)
    testing.expect_value(t, vm_run(vm, `recovered`), Value(true))
}
