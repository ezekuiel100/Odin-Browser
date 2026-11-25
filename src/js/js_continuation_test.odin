package js

import "core:testing"

@(private = "file")
continuation_expect :: proc(t: ^testing.T, vm: ^Interp, expression: string) {
    value := vm_run(vm, expression)
    testing.expect(t, !vm.throwing, expression)
    testing.expect(t, value == Value(true), expression)
}

@(test)
test_continuation_gc_preserves_call_receiver_and_arguments :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var release, calls = 0, result = 0;
        var pending = new Promise(function(r){ release = r; });
        function make(){ return {base:40, get method(){
            calls++; return function(a,b){ return this.base + a.value + b; };
        }}; }
        (async function(){ result = make().method({value:1}, await pending); })();
    `)
    testing.expect(t, vm_collect(vm))
    vm_run(vm, `release(1)`)
    continuation_expect(t, vm, `result === 42 && calls === 1`)
}

@(test)
test_continuation_gc_preserves_compound_reference :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var release, reads=0, writes=0, result=0;
        var pending=new Promise(function(r){ release=r; });
        function make(){ return {get x(){reads++; return 40;}, set x(v){writes++; result=v;}}; }
        (async function(){ make().x += await pending; })();
    `)
    testing.expect(t, vm_collect(vm))
    vm_run(vm, `release(2)`)
    continuation_expect(t, vm, `result === 42 && reads === 1 && writes === 1`)
}

@(test)
test_continuation_property_key_is_resolved_before_await :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var release, conversions=0, result=0;
        var pending=new Promise(function(r){release=r;});
        var key={name:'x', toString:function(){conversions++;return this.name;}};
        var target={x:40,y:99};
        (async function(){target[key] += await pending; result=target.x;})();
        key.name='y';
    `)
    testing.expect(t, vm_collect(vm))
    vm_run(vm, `release(2)`)
    continuation_expect(t, vm, `result === 42 && target.y === 99 && conversions === 1`)
}

@(test)
test_continuation_gc_preserves_return_across_finally_yield :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        function* generate(){ try { yield 1; } finally { yield 2; } }
        var it=generate(); it.next(); var step=it.return({answer:42});
    `)
    continuation_expect(t, vm, `step.value === 2 && step.done === false`)
    testing.expect(t, vm_collect(vm))
    continuation_expect(t, vm, `(step=it.next()).value.answer === 42 && step.done === true`)
}

@(test)
test_continuation_gc_preserves_throw_and_nested_finally :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var log='';
        function* generate(){
            try { throw {answer:42}; }
            finally { try { yield 1; } finally { log+='closed'; } }
        }
        var it=generate(); it.next();
    `)
    testing.expect(t, vm_collect(vm))
    vm_run(vm, `var answer=0; try { it.next(); } catch(e){ answer=e.answer; }`)
    continuation_expect(t, vm, `answer === 42 && log === 'closed'`)
}

@(test)
test_continuation_gc_preserves_binary_operand_and_short_circuit :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var release, result=0, calls=0;
        var pending=new Promise(function(r){ release=r; });
        (async function(){
            result = {valueOf:function(){calls++; return 40;}} + await pending;
            false && await pending;
            true || await pending;
            7 ?? await pending;
        })();
    `)
    testing.expect(t, vm_collect(vm))
    vm_run(vm, `release(2)`)
    continuation_expect(t, vm, `result === 42 && calls === 1`)
}

@(test)
test_continuation_gc_preserves_pattern_source_and_target :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var release, result=0, calls=0;
        var pending=new Promise(function(r){ release=r; });
        function target(){ calls++; return {set x(v){result=v;}}; }
        (async function(){
            [target().x = await pending] = [undefined];
            var {a = await pending, ...rest} = {b:1};
            result += a + rest.b;
        })();
    `)
    testing.expect(t, vm_collect(vm))
    vm_run(vm, `release(20)`)
    continuation_expect(t, vm, `result === 41 && calls === 1`)
}

@(test)
test_continuation_gc_preserves_iterators_and_closure_bindings :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var callbacks=[], log='';
        function* generate(){
            outer: for(let i=0;i<3;i++) {
                callbacks.push(function(){return i;});
                for(var v of [{n:10},{n:20}]) {
                    yield v.n+i;
                    if(v.n===10) continue outer;
                }
            }
        }
        var it=generate(); log+=it.next().value+',';
    `)
    testing.expect(t, vm_collect(vm))
    vm_run(vm, `log+=it.next().value+',';`)
    testing.expect(t, vm_collect(vm))
    vm_run(vm, `log+=it.next().value; it.next();`)
    continuation_expect(t, vm, `log === '10,11,12' && callbacks[0]()===0 && callbacks[1]()===1 && callbacks[2]()===2`)
}

@(test)
test_continuation_gc_preserves_async_close_completion :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var release, result=0, log='';
        var pending=new Promise(function(r){release=r;});
        async function* generate(){try {yield 1;} finally {await pending; log+='closed,';}}
        (async function(){
            try {for await(var x of generate()){throw {answer:42};}}
            catch(e){result=e.answer;}
        })();
    `)
    testing.expect(t, vm_collect(vm))
    vm_run(vm, `release()`)
    continuation_expect(t, vm, `result === 42 && log === 'closed,'`)
}

@(test)
test_continuation_gc_preserves_async_generator_queued_jobs :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var release, log=''; var pending=new Promise(function(r){release=r;});
        async function* outer(){yield* (async function*(){yield pending; yield 2;})();}
        var it=outer();
        it.next().then(function(r){log+=r.value;});
        it.next().then(function(r){log+=r.value;});
        it.next().then(function(r){log+=r.done;});
    `)
    testing.expect(t, vm_collect(vm))
    vm_run(vm, `release(1)`)
    continuation_expect(t, vm, `log === '12true'`)
}

@(test)
test_continuation_collects_abandoned_executions_without_running_finally :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var closed=0;
        var it=(function*(){try {var local={self:null}; local.self=local; yield 1;} finally {closed++;}})();
        it.next(); it=null;
        (async function(){await new Promise(function(){}); closed++;})();
    `)
    testing.expect(t, vm_collect(vm))
    testing.expect_value(t, len(vm.all_generators), 0)
    continuation_expect(t, vm, `closed === 0`)
}

@(test)
test_continuation_thousands_pending_collect_and_resume :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var release, total=0, completed=0;
        var pending=new Promise(function(r){release=r;});
        async function work(i){var local={value:i}; await pending; total+=local.value; completed++;}
        for(var i=0;i<3000;i++) work(i);
    `)
    testing.expect(t, !vm.throwing)
    testing.expect_value(t, len(vm.all_generators), 3000)
    testing.expect(t, vm_collect(vm))
    live := gc_heap_count(vm)
    for _ in 0..<6000 { new_object(vm) }
    testing.expect(t, vm_collect(vm))
    testing.expect_value(t, gc_heap_count(vm), live)
    vm_run(vm, `release();`)
    continuation_expect(t, vm, `completed === 3000 && total === 4498500`)
    testing.expect(t, vm_collect(vm))
    testing.expect_value(t, len(vm.all_generators), 0)
}

@(thread_local) continuation_host_context: int

@(private = "file")
continuation_host_probe :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return f64(continuation_host_context)
}

@(test)
test_continuation_uses_current_host_thread_context :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    probe := new_function(vm)
    probe.native = continuation_host_probe
    env_define(vm.global, "hostProbe", probe)
    continuation_host_context = 73
    defer continuation_host_context = 0
    vm_run(vm, `var first=0, second=0; (async function(){first=hostProbe(); await 0; second=hostProbe();})();`)
    continuation_expect(t, vm, `first === 73 && second === 73`)
}

@(test)
test_continuation_literals_templates_classes_and_evaluation_order :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, "var result=false; (async function(){" +
        "var log=''; var key={toString:function(){log+='key,'; return 'value';}};" +
        "var o={[key]: await 40, extra:2};" +
        "var a=[...(await [1,2]),,await 3];" +
        "var tag={base:1, method:function(parts,x,y){return this.base+parts.length+x+y;}};" +
        "var tagged=tag.method`a${await 20}b${await 18}c`;" +
        "class C { [await 'answer'](){return 42;} }" +
        "result=log==='key,' && o.value+o.extra===42 && a.length===4 && !(2 in a) &&" +
        "tagged===42 && new C().answer()===42; })();")
    continuation_expect(t, vm, `result === true`)
}

@(test)
test_continuation_catch_pattern_can_suspend_and_collect :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        function* generate(){
            try {throw {};}
            catch({answer=yield 1}){return answer;}
        }
        var it=generate(); it.next();
    `)
    testing.expect(t, vm_collect(vm))
    continuation_expect(t, vm, `it.next(42).value === 42`)
}

@(test)
test_continuation_return_during_pattern_closes_without_assignment :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var assigned=0, closed=0;
        function* source(){try {yield undefined;} finally {closed++;}}
        function target(){return {set x(v){assigned++;}};}
        function* generate(){[target().x=yield 1]=source();}
        var it=generate(); it.next();
    `)
    testing.expect(t, vm_collect(vm))
    vm_run(vm, `var returned=it.return(42);`)
    continuation_expect(t, vm, `returned.value === 42 && returned.done === true`)
    continuation_expect(t, vm, `assigned === 0`)
    continuation_expect(t, vm, `closed === 1`)
}

@(test)
test_continuation_do_while_and_switch_suspending_cases :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        function* generate(){
            var sum=0;
            do {sum+=yield sum;} while(sum<3);
            switch(yield sum){case yield 4:sum+=10;break;default:sum+=100;}
            return sum;
        }
        var it=generate(), log=''; log+=it.next().value+',';
    `)
    testing.expect(t, vm_collect(vm))
    vm_run(vm, `log+=it.next(1).value+','; log+=it.next(2).value+',';`)
    testing.expect(t, vm_collect(vm))
    vm_run(vm, `log+=it.next(5).value+','; log+=it.next(5).value;`)
    continuation_expect(t, vm, `log === '0,1,3,4,13'`)
}

@(test)
test_continuation_completed_iterators_release_captured_locals :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var weak=new WeakMap();
        function create(){
            var key={answer:42}; weak.set(key,1);
            return (function*(){yield key;})();
        }
        var completed=create(), unstarted=create();
        completed.next(); completed.next(); unstarted.return();
    `)
    testing.expect(t, vm_collect(vm))
    weak := vm.global.vars["weak"].(^Collection)
    testing.expect_value(t, weak.size, 0)
    continuation_expect(t, vm, `completed.next().done && unstarted.next().done`)
}
