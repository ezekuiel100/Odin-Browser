package js

import "core:testing"

@(private = "file")
sync_expect :: proc(t: ^testing.T, vm: ^Interp, source: string) {
    result := vm_run(vm, source)
    testing.expect(t, result == Value(true), source)
    testing.expect_value(t, vm.call_depth, 0)
    testing.expect(t, vm.frame == nil)
    testing.expect(t, !vm.returning && !vm.throwing)
}

@(test)
test_sync_deep_non_tail_recursion :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm.time_budget_ms = 0
    sync_expect(t, vm, `
        function sum(n){ return n === 0 ? 0 : n + sum(n-1); }
        sum(3000) === 4501500;
    `)
}

@(test)
test_sync_deep_mutual_methods_and_receivers :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm.time_budget_ms = 0
    sync_expect(t, vm, `
        var a={offset:1, run:function(n){return n ? this.offset+b.run(n-1) : 0;}};
        var b={offset:2, run:function(n){return n ? this.offset+a.run(n-1) : 0;}};
        a.run(3000) === 4500;
    `)
}

@(test)
test_sync_deep_call_apply_and_bound_functions :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm.time_budget_ms = 0
    sync_expect(t, vm, `
        var receiver={base:42};
        function viaCall(n){return n ? viaCall.call(this,n-1)+1 : this.base;}
        function viaApply(n){return n ? viaApply.apply(this,[n-1])+1 : this.base;}
        function viaBind(n){return n ? bound(n-1)+1 : this.base;}
        var bound=viaBind.bind(receiver);
        viaCall.call(receiver,1500)===1542 && viaApply.apply(receiver,[1500])===1542 && bound(1500)===1542;
    `)
}

@(test)
test_sync_deep_parameter_defaults_and_patterns :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm.time_budget_ms = 0
    sync_expect(t, vm, `
        function defaults(n, value=n ? defaults(n-1) : 0){return value+1;}
        function patterns(n, [value=n ? patterns(n-1) : 0]=[]){return value+1;}
        defaults(1500)===1501 && patterns(1500)===1501;
    `)
}

@(test)
test_sync_deep_throw_and_finally_unwind :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm.time_budget_ms = 0
    sync_expect(t, vm, `
        var count=0, caught;
        function descend(n){
            try { if(n) return descend(n-1); throw {answer:42}; }
            finally { count++; }
        }
        try { descend(3000); } catch(e){ caught=e.answer; }
        count===3001 && caught===42;
    `)
    sync_expect(t, vm, `(function(){return 42;})()===42`)
}

@(test)
test_sync_deep_finally_overrides_return :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm.time_budget_ms = 0
    sync_expect(t, vm, `
        var count=0;
        function descend(n){
            try { return n ? descend(n-1) : 1; }
            finally { count++; if(n===1000) return 42; }
        }
        descend(2000)===42 && count===2001;
    `)
}

@(test)
test_sync_constructor_recursion_and_new_target :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm.time_budget_ms = 0
    sync_expect(t, vm, `
        var count=0, correct=true;
        function Link(n){
            count++; correct=correct && new.target===Link;
            this.next=n ? new Link(n-1) : null;
            return 3;
        }
        var root=new Link(1500);
        count===1501 && correct && root instanceof Link && root.next instanceof Link;
    `)
}

@(test)
test_sync_argument_order_and_nested_native_reentry :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    sync_expect(t, vm, `
        var log='';
        function mark(x){log+=x;return x;}
        var object={base:40,get method(){log+='g';return function(a,b){log+='c';return this.base+a+b;};}};
        function run(){return object.method(mark(1),[1].map(function(x){mark(2);return x;})[0]);}
        run()===42 && log==='g12c';
    `)
}

@(test)
test_sync_retained_closures_and_arguments :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    sync_expect(t, vm, `
        var saved=[];
        function descend(n){
            saved.push(function(){return n;});
            if(n) descend(n-1);
            return arguments;
        }
        var args=descend(200);
        args[0]===200 && saved[0]()===200 && saved[200]()===0;
    `)
    testing.expect(t, vm_collect(vm))
    sync_expect(t, vm, `args[0]===200 && saved[0]()===200 && saved[200]()===0`)
}

@(test)
test_sync_recursion_limit_and_state_recovery :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm.call_depth_limit = 400
    sync_expect(t, vm, `
        var count=0, name;
        function descend(){try{return descend();}finally{count++;}}
        try{descend();}catch(e){name=e.name;}
        name==='RangeError' && count===400;
    `)
    sync_expect(t, vm, `(function(){return 42;})()===42`)
}

@(test)
test_sync_calls_inside_async_and_generator :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm.time_budget_ms = 0
    sync_expect(t, vm, `
        var release, result=0;
        var pending=new Promise(function(r){release=r;});
        function sum(n){return n ? 1+sum(n-1) : 0;}
        async function work(){result=sum(1000)+(await pending)+sum(1000);}
        function* generate(){yield sum(1000);return sum(1000);}
        var iterator=generate();
        work(); iterator.next().value===1000;
    `)
    testing.expect(t, vm_collect(vm))
    sync_expect(t, vm, `release(42);iterator.next().value===1000`)
    sync_expect(t, vm, `result===2042`)
}
