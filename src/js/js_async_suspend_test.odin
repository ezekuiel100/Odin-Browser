package js

import "core:testing"

@(test)
test_async_for_await_resolved_after_call :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var release, log = '';
        var pending = new Promise(function(r){ release = r; });
        async function consume(){
            for await (var value of [pending]) log += value;
            log += '!';
        }
        consume(); log += 'sync,'; release('ok');
    `)
    testing.expect_value(t, vm_run(vm, "log").(string), "sync,ok!")
}

@(test)
test_async_generator_queued_requests_and_rejection :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var release, log = '';
        var pending = new Promise(function(r){ release = r; });
        async function* generate(){
            try { yield await pending; yield 2; }
            catch(e) { yield e; }
            finally { log += 'closed,'; }
        }
        var it = generate();
        it.next().then(function(r){ log += r.value + ','; });
        it.throw('caught').then(function(r){ log += r.value + ','; });
        it.return(9).then(function(r){ log += r.value + ':' + r.done; });
        log += 'sync,'; release(1);
    `)
    testing.expect_value(t, vm_run(vm, "log").(string), "sync,1,caught,closed,9:true")
}

@(test)
test_async_generator_pending_does_not_pump_timers :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var log = '';
        var pending = new Promise(function(r){ setTimeout(function(){ r('value'); }, 5); });
        async function* generate(){ yield pending; }
        generate().next().then(function(r){ log += r.value; });
        log += 'sync,';
    `)
    testing.expect_value(t, vm_run(vm, "log").(string), "sync,")
    vm_pump_timers(vm, 5)
    testing.expect_value(t, vm_run(vm, "log").(string), "sync,value")
}

@(test)
test_async_for_await_waits_for_iterator_close :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var close, log = '';
        var pending = new Promise(function(r){ close = r; });
        async function* generate(){
            try { yield 1; } finally { await pending; log += 'closed,'; }
        }
        (async function(){
            for await (var v of generate()) { log += v + ','; break; }
            log += 'after';
        })();
    `)
    testing.expect_value(t, vm_run(vm, "log").(string), "1,")
    vm_run(vm, "close()")
    testing.expect_value(t, vm_run(vm, "log").(string), "1,closed,after")
}

@(test)
test_async_generator_await_rejection_catch_finally :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var reject, log = '';
        var pending = new Promise(function(_, r){ reject = r; });
        async function* generate(){
            try { await pending; } catch(e) { yield e; }
            finally { log += 'finally,'; }
        }
        var it = generate();
        it.next().then(function(r){ log += r.value + ','; });
        it.next().then(function(r){ log += r.done; });
        log += 'sync,'; reject('error');
    `)
    testing.expect_value(t, vm_run(vm, "log").(string), "sync,error,finally,true")
}

@(test)
test_async_generator_return_awaits_promise :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var release, result = 'pending';
        var pending = new Promise(function(r){ release = r; });
        async function* generate(){ return pending; }
        generate().next().then(function(r){ result = r.value + ':' + r.done; });
    `)
    testing.expect_value(t, vm_run(vm, "result").(string), "pending")
    vm_run(vm, "release(42)")
    testing.expect_value(t, vm_run(vm, "result").(string), "42:true")
}

@(test)
test_async_generator_pending_disposal :: proc(t: ^testing.T) {
    vm := vm_create()
    vm_run(vm, `
        async function* generate(){ await new Promise(function(){}); yield 1; }
        var it = generate(); it.next(); it.next();
        async function consume(){ for await (var v of [new Promise(function(){})]) {} }
        consume();
    `)
    testing.expect(t, !vm.throwing)
    vm_free(vm)
}

@(test)
test_async_generator_yield_star_suspends :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var release, log = '';
        var pending = new Promise(function(r){ release = r; });
        async function* inner(){ yield pending; yield 2; }
        async function* outer(){ yield* inner(); }
        (async function(){ for await (var v of outer()) log += v; })();
        log += 'sync,'; release(1);
    `)
    testing.expect_value(t, vm_run(vm, "log").(string), "sync,12")
}

@(test)
test_async_await_pending_microtask_fifo :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var release, log = '';
        var pending = new Promise(function(r){ release = r; });
        (async function(){ await pending; log += 'await,'; })();
        pending.then(function(){ log += 'then,'; });
        release();
        queueMicrotask(function(){ log += 'microtask'; });
        log += 'sync,';
    `)
    testing.expect_value(t, vm_run(vm, "log").(string), "sync,await,then,microtask")
}

@(test)
test_async_await_primitive_microtask_fifo :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var log = '';
        (async function(){ await 1; log += 'await,'; await 2; log += 'again'; })();
        queueMicrotask(function(){ log += 'microtask,'; });
        log += 'sync,';
    `)
    testing.expect_value(t, vm_run(vm, "log").(string), "sync,await,microtask,again")
}

@(test)
test_async_for_await_preserves_throw_after_close :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var release, log = '';
        var pending = new Promise(function(r){ release = r; });
        async function* generate(){
            try { yield 1; } finally { await pending; log += 'closed,'; }
        }
        (async function(){
            try { for await (var v of generate()) { throw 'body'; } }
            catch(e) { log += e; }
        })();
    `)
    testing.expect_value(t, vm_run(vm, "log").(string), "")
    vm_run(vm, "release()")
    testing.expect_value(t, vm_run(vm, "log").(string), "closed,body")
}

@(test)
test_async_await_thenable_job_order :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var log = '';
        var thenable = {
            get then(){
                log += 'get,';
                return function(resolve){ log += 'then,'; resolve(7); };
            }
        };
        (async function(){ var value = await thenable; log += value; })();
        queueMicrotask(function(){ log += 'microtask,'; });
        log += 'sync,';
    `)
    testing.expect_value(t, vm_run(vm, "log").(string), "get,sync,then,microtask,7")
}

@(test)
test_async_await_thenable_getter_rejection :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var log = '';
        (async function(){
            try { await { get then(){ throw 'getter'; } }; }
            catch(e) { log += e; }
        })();
        log += 'sync,';
    `)
    testing.expect_value(t, vm_run(vm, "log").(string), "sync,getter")
}
