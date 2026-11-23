package js

import "core:testing"

@(test)
test_promise_resolution_first_call_locks_pending_adoption :: proc(t: ^testing.T) {
    ok, _ := run_settled(`
        var release;
        var inner = new Promise(function(r) { release = r; });
        var out = '';
        new Promise(function(resolve, reject) {
            resolve(inner);
            reject('wrong');
            resolve('also wrong');
            throw 'executor error';
        }).then(function(v) { out = v; }, function(e) { out = e; });
        release('right');
    `, `out === 'right'`).(bool)
    testing.expect(t, ok, "resolving with a pending promise must lock out later calls and executor throws")
}

@(test)
test_promise_resolution_thenable_first_call_and_throw :: proc(t: ^testing.T) {
    ok, _ := run_settled(`
        var release;
        var inner = new Promise(function(r) { release = r; });
        var out = '';
        Promise.resolve({then: function(resolve, reject) {
            resolve(inner);
            reject('wrong');
            resolve('also wrong');
            throw 'then error';
        }}).then(function(v) { out = v; }, function(e) { out = e; });
        release('right');
    `, `out === 'right'`).(bool)
    testing.expect(t, ok, "thenable resolving functions must share a first-call guard")
}

@(test)
test_promise_resolution_with_resolvers_first_call :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var release;
        var inner = new Promise(function(r) { release = r; });
        var cap = Promise.withResolvers();
        var out = '';
        cap.promise.then(function(v) { out = v; }, function(e) { out = e; });
        cap.resolve(inner);
        cap.reject('wrong');
        cap.resolve('also wrong');
    `)
    testing.expect_value(t, vm_run(vm, `out`), Value(""))
    vm_run(vm, `release('right');`)
    testing.expect_value(t, vm_run(vm, `out`), Value("right"))
}

@(test)
test_promise_resolution_then_getter_and_job_order :: proc(t: ^testing.T) {
    ok, _ := run_settled(`
        var out = '';
        Promise.resolve({get then() {
            out += 'g';
            return function(resolve) { out += 't'; resolve(1); };
        }}).then(function() { out += 'h'; });
        queueMicrotask(function() { out += 'q'; });
        out += 's';
    `, `out === 'gstqh'`).(bool)
    testing.expect(t, ok, "read then synchronously, invoke it in a job, and enqueue handlers after sibling jobs")
}

@(test)
test_promise_resolution_then_getter_rejects :: proc(t: ^testing.T) {
    ok, _ := run_settled(`
        var out = '', gets = 0;
        try {
            Promise.resolve({get then() { gets++; throw 'boom'; }})
                .catch(function(e) { out += e; });
            out += 'sync,';
        } catch(e) { out += 'wrong'; }
    `, `out === 'sync,boom' && gets === 1`).(bool)
    testing.expect(t, ok, "then getter errors must reject rather than escape Promise.resolve")
}

@(test)
test_promise_resolution_callable_and_array_thenables :: proc(t: ^testing.T) {
    ok, _ := run_settled(`
        var out = '';
        function f() {}
        f.then = function(resolve) { resolve('f'); };
        var a = [];
        a.then = function(resolve) { resolve('a'); };
        Promise.resolve(f).then(function(v) { out += v; });
        Promise.resolve(a).then(function(v) { out += v; });
    `, `out === 'fa'`).(bool)
    testing.expect(t, ok, "all object representations can be thenables")
}

@(test)
test_promise_resolution_adoption_observes_then_override :: proc(t: ^testing.T) {
    ok, _ := run_settled(`
        var p = Promise.resolve('original'), out = '';
        p.then = function(resolve) { out += 't'; resolve('override'); };
        new Promise(function(resolve) { resolve(p); }).then(function(v) { out += v; });
        out += 's';
    `, `out === 'stoverride'`).(bool)
    testing.expect(t, ok, "adoption must read and schedule a native promise's overridden then")
}

@(test)
test_promise_resolution_ignores_later_getters_and_rejects_cycles :: proc(t: ^testing.T) {
    ok, _ := run_settled(`
        var gets = 0, result = 0, cycle = false;
        new Promise(function(resolve) {
            resolve(7);
            resolve({get then() { gets++; throw 'wrong'; }});
        }).then(function(v) { result = v; });
        var cap = Promise.withResolvers();
        cap.promise.catch(function(e) { cycle = e instanceof TypeError; });
        cap.resolve(cap.promise);
    `, `gets === 0 && result === 7 && cycle`).(bool)
    testing.expect(t, ok, "ignore subsequent resolution side effects and reject self-resolution")
}

@(test)
test_promise_combinator_thenables_and_mixed_race :: proc(t: ^testing.T) {
    ok, _ := run_settled(`
        var all = 0, race = '', any = '', settled = '';
        Promise.all([{then: function(r) { r(7); }}]).then(function(a) { all = a[0]; });
        Promise.race([Promise.resolve('first'), 'second']).then(function(v) { race = v; });
        Promise.any([Promise.resolve('first'), 'second']).then(function(v) { any = v; });
        Promise.allSettled([{then: function(r, j) { j('reason'); }}]).then(function(a) {
            settled = a[0].status + ':' + a[0].reason;
        });
    `, `all === 7 && race === 'first' && any === 'first' && settled === 'rejected:reason'`).(bool)
    testing.expect(t, ok, "combinators must normalize every input through promise resolution")
}

@(test)
test_promise_combinator_iterators_and_noniterables :: proc(t: ^testing.T) {
    ok, _ := run_settled(`
        var size = -1, errors = 0, text = '';
        var a = [1];
        a[Symbol.iterator] = function() { return {next: function() { return {done: true}; }}; };
        Promise.all(a).then(function(v) { size = v.length; });
        Promise.all('ab').then(function(v) { text = v.join(''); });
        [Promise.all, Promise.race, Promise.any, Promise.allSettled].forEach(function(f) {
            f.call(Promise, 123).catch(function(e) { if (e instanceof TypeError) errors++; });
        });
    `, `size === 0 && text === 'ab' && errors === 4`).(bool)
    testing.expect(t, ok, "honor array iterator overrides, string iteration, and reject noniterables")
}

@(test)
test_promise_combinator_iterator_errors_are_rejections :: proc(t: ^testing.T) {
    ok, _ := run_settled(`
        var errors = '', sync = false;
        function check(value) {
            try { Promise.all(value).catch(function(e) { errors += e.message + ','; }); }
            catch(e) { sync = true; }
        }
        check({get [Symbol.iterator]() { throw new Error('method'); }});
        check({[Symbol.iterator]: function() { return {get next() { throw new Error('next'); }}; }});
        check({[Symbol.iterator]: function() { var n = 0; return {next: function() {
            if (n++) return {done: true};
            return {get done() { throw new Error('done'); }};
        }}; }});
        check({[Symbol.iterator]: function() { var n = 0; return {next: function() {
            if (n++) return {done: true};
            return {done: false, get value() { throw new Error('value'); }};
        }}; }});
    `, `!sync && errors === 'method,next,done,value,'`).(bool)
    testing.expect(t, ok, "iterator access errors must reject the aggregate promise")
}

@(test)
test_promise_combinator_resolves_during_iteration :: proc(t: ^testing.T) {
    ok, _ := run_settled(`
        var out = '', i = 0, values = '';
        var source = {[Symbol.iterator]: function() { return {next: function() {
            i++;
            out += i;
            if (i > 2) return {done: true};
            return {done: false, value: {get then() {
                out += 'g';
                return function(resolve) { resolve(i); };
            }}};
        }}; }};
        Promise.all(source).then(function(a) { values = a.join(','); });
    `, `out === '1g2g3' && values === '3,3'`).(bool)
    testing.expect(t, ok, "normalize each input before requesting the next iterator result")
}

@(test)
test_promise_combinators_close_after_then_getter_throws :: proc(t: ^testing.T) {
    ok, _ := run_settled(`
        var error = {}, closes = 0, rejected = 0, calls = 0;
        var item = Promise.resolve(1);
        Object.defineProperty(item, "then", {get() { throw error; }});
        for (var method of [Promise.all, Promise.allSettled, Promise.race, Promise.any]) {
            var source = {[Symbol.iterator]() {
                var advanced = false;
                return {
                    next() {
                        calls++;
                        var done = advanced;
                        advanced = true;
                        return {done: done, value: item};
                    },
                    return() { closes++; throw "close error"; }
                };
            }};
            method.call(Promise, source).catch(function(reason) { if (reason === error) rejected++; });
        }
    `, `closes === 4 && rejected === 4 && calls === 4`).(bool)
    testing.expect(t, ok, "close on a then getter error and preserve the original reason")
}

@(test)
test_promise_combinator_custom_resolve_and_subclass :: proc(t: ^testing.T) {
    ok, _ := run_settled(`
        var trace = "", result, error = {}, rejected;
        class Custom extends Promise {
            static resolve(value) {
                if (this !== Custom) throw "wrong receiver";
                trace += value;
                if (value === "bad") throw error;
                return { then(onFulfill, onReject) {
                    onReject("first");
                    onFulfill("second");
                    onReject("third");
                } };
            }
        }
        var aggregate = Custom.allSettled([1, 2]);
        aggregate.then(function(values) { result = JSON.stringify(values); });
        var source = {[Symbol.iterator]() { return {
            next() { return {done: trace.endsWith("bad"), value: "bad"}; },
            return() { trace += "!"; return {}; }
        }; }};
        Custom.any(source).catch(function(reason) { rejected = reason; });
    `, `aggregate instanceof Custom && rejected === error && trace === "12bad!" &&
         result === '[{"status":"rejected","reason":"first"},{"status":"rejected","reason":"first"}]'`).(bool)
    testing.expect(t, ok, "honor the receiver's resolve and settle each allSettled element once")
}

@(test)
test_promise_resolve_preserves_identity_and_reads_constructor :: proc(t: ^testing.T) {
    ok, _ := run_settled(`
        var p = Promise.resolve(1);
        var same = Promise.resolve(p) === p;
        var gets = 0, caught = false;
        Object.defineProperty(p, 'constructor', {get: function() { gets++; throw 'ctor'; }});
        try { Promise.resolve(p); } catch(e) { caught = e === 'ctor'; }
    `, `same && gets === 1 && caught`).(bool)
    testing.expect(t, ok, "Promise.resolve must preserve identity only after checking constructor")
}
