package js

import "core:testing"

@(test)
test_map_group_by_keys_and_iteration :: proc(t: ^testing.T) {
    for code in ([]string{
        `var a={},b={}; var m=Map.groupBy([a,b,a],function(x){return x}); m instanceof Map && m.size===2 && m.get(a).length===2 && m.get(b)[0]===b && [...m.keys()][0]===a`,
        `var m=Map.groupBy([NaN,NaN,-0,0],function(x){return x}); m.size===2 && m.get(NaN).length===2 && m.get(0).length===2 && 1/[...m.keys()][1]===Infinity`,
        `var log=''; var m=Map.groupBy(new Set([3,4,5]),function(v,i){'use strict'; log+=i; if(this!==undefined)throw 1; return v%2}); log==='012' && m.get(1).join()==='3,5'`,
        `Map.groupBy('a😀a',function(x){return x}).get('a').length===2`,
        `var closed=false, calls=0; var it={[Symbol.iterator]:function(){return this},next:function(){calls++;return {value:1,done:false}},return:function(){closed=true;throw 9}}; var caught=false;try{Map.groupBy(it,function(){throw 7})}catch(e){caught=e===7} caught && closed && calls===1`,
        `var n=0; for(var x of [null,undefined,{}, {length:1}]){try{Map.groupBy(x,function(){})}catch(e){if(e instanceof TypeError)n++}} n===4`,
        `var n=0; for(var f of [null,undefined,1,{}]){try{Map.groupBy([],f)}catch(e){if(e instanceof TypeError)n++}} n===4`,
        `Map.groupBy.length===2 && Map.groupBy.name==='groupBy' && !Object.getOwnPropertyDescriptor(Map,'groupBy').enumerable && !('groupBy' in Set)`,
    }) {
        testing.expect(t, run(code) == Value(true), code)
    }
}

@(test)
test_array_from_async_sources_and_errors :: proc(t: ^testing.T) {
    for code in ([]string{
        `Array.fromAsync([Promise.resolve(2),3],async function(v,i){return v*this.n+i},{n:4}).then(function(a){result=a.join()==='8,13'})`,
        `Array.fromAsync({0:Promise.resolve(2),length:2}).then(function(a){result=a.length===2 && a[0]===2 && a.hasOwnProperty(1) && a[1]===undefined})`,
        `Array.fromAsync('a😀').then(function(a){result=a.length===2 && a[1]==='😀'})`,
        `async function* gen(){yield 2;yield 3} Array.fromAsync(gen()).then(function(a){result=a.join()==='2,3'})`,
        `var p=Promise.resolve(3), n=0;var it={[Symbol.asyncIterator]:function(){return this},[Symbol.iterator]:function(){throw 1},next:function(){return Promise.resolve({done:n++>0,value:p})}}; Array.fromAsync(it).then(function(a){result=a[0]===p})`,
        `function C(n){this.n=n;this.argc=arguments.length} Array.fromAsync.call(C,{0:4,length:1}).then(function(a){result=a instanceof C && a.n===1 && a[0]===4 && a.length===1 && a.argc===1})`,
        `function C(){this.argc=arguments.length} Array.fromAsync.call(C,[4]).then(function(a){result=a instanceof C && a.length===1 && a.argc===0})`,
        `var p=Array.fromAsync(null);result=p instanceof Promise; p.catch(function(e){result=result && e instanceof TypeError})`,
        `Array.fromAsync([],null).catch(function(e){result=e instanceof TypeError})`,
        `Array.fromAsync({[Symbol.asyncIterator]:1}).catch(function(e){result=e instanceof TypeError})`,
        `Array.fromAsync([Promise.reject(7)]).catch(function(e){result=e===7})`,
        `var closed=false; var it={[Symbol.asyncIterator]:function(){return this},next:function(){return Promise.reject(7)},return:function(){closed=true;return {}}}; Array.fromAsync(it).catch(function(e){result=e===7 && !closed})`,
        `var closed=false;function* g(){try{yield 1}finally{closed=true}} function C(){return Object.freeze([])} Array.fromAsync.call(C,g()).catch(function(e){result=closed && e instanceof TypeError})`,
        `var src={0:1,1:2,length:2}; Array.fromAsync(src,function(v,i){if(i===0)src[1]=9;return v}).then(function(a){result=a.join()==='1,9'})`,
        `var closed=false;function* g(){try{yield 1}finally{closed=true}} Array.fromAsync(g(),function(){return Promise.reject(7)}).catch(function(e){result=closed && e===7})`,
        `Array.fromAsync.name==='fromAsync' && (result=Array.fromAsync.length===1 && !Object.getOwnPropertyDescriptor(Array,'fromAsync').enumerable)`,
    }) {
        vm := vm_create()
        vm_run(vm, "var result=false;")
        vm_run(vm, code)
        testing.expect(t, vm_run(vm, "result") == Value(true), code)
        vm_free(vm)
    }
}

@(test)
test_array_from_async_sequential_pending_and_close :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var release, log='', calls=0;
        var pending=new Promise(function(r){release=r});
        var source={[Symbol.asyncIterator]:function(){return this},next:function(){calls++;return Promise.resolve({value:calls,done:calls>2})}};
        Array.fromAsync(source,function(v){log+='m'+v;return v===1?pending:v}).then(function(a){log+=':'+a.join()});
        log+='sync';
    `)
    testing.expect_value(t, vm_run(vm, "log+':'+calls").(string), "syncm1:1")
    vm_run(vm, "release(8)")
    testing.expect_value(t, vm_run(vm, "log+':'+calls").(string), "syncm1m2:8,2:3")
    vm_run(vm, `
        var close, closed=false, caught=false;
        var it={[Symbol.asyncIterator]:function(){return this},next:function(){return {value:1,done:false}},return:function(){closed=true;return new Promise(function(r){close=r})}};
        Array.fromAsync(it,function(){throw 7}).catch(function(e){caught=e===7});
    `)
    testing.expect(t, vm_run(vm, "closed && !caught") == Value(true))
    vm_run(vm, "close({done:true})")
    testing.expect(t, vm_run(vm, "caught") == Value(true))
    vm_run(vm, `
        caught=false;
        var it2={[Symbol.iterator]:function(){return this},next:function(){return {value:1,done:false}},return:function(){return {done:true,value:new Promise(function(r){close=r})}}};
        Array.fromAsync(it2,function(){throw 8}).catch(function(e){caught=e===8});
    `)
    testing.expect(t, vm_run(vm, "!caught") == Value(true))
    vm_run(vm, "close(0)")
    testing.expect(t, vm_run(vm, "caught") == Value(true))
}
