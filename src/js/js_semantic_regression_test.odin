package js

import "core:testing"

@(test)
regression_bound_instanceof :: proc(t: ^testing.T) {
    cases := []string{
        `function F(){} new F() instanceof F.bind(null)`,
        `function F(){} var B=F.bind(null).bind({}); new B() instanceof B && new F() instanceof B`,
        `[] instanceof Array.bind(null)`,
        `function F(){} F[Symbol.hasInstance]=function(x){return x===7}; 7 instanceof F.bind(null)`,
        `function F(){} var B=F.bind(null); B[Symbol.hasInstance]=function(){return false}; !(new F() instanceof B)`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
regression_prototype_cycles :: proc(t: ^testing.T) {
    cases := []string{
        `var o={}; var p=Object.getPrototypeOf(o), ok=false; try{Object.setPrototypeOf(o,o)}catch(e){ok=e instanceof TypeError} ok && Object.getPrototypeOf(o)===p`,
        `var a={}, b=Object.create(a), c=Object.create(b), ok=false; try{Object.setPrototypeOf(a,c)}catch(e){ok=e instanceof TypeError} ok && Object.getPrototypeOf(a)===Object.prototype`,
        `function F(){} function G(){} Object.setPrototypeOf(G,F); var ok=false; try{Object.setPrototypeOf(F,G)}catch(e){ok=e instanceof TypeError} ok && Object.getPrototypeOf(F)===Function.prototype`,
        `var o={}, ok=false; try{o.__proto__=o}catch(e){ok=e instanceof TypeError} ok`,
        `var o=Object.preventExtensions({}), p=Object.getPrototypeOf(o), ok=false; Object.setPrototypeOf(o,p); try{Object.setPrototypeOf(o,{})}catch(e){ok=e instanceof TypeError} ok && Object.getPrototypeOf(o)===p`,
        `var o={}, p=Object.getPrototypeOf(o); o.__proto__=5; Object.getPrototypeOf(o)===p`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
regression_destructuring_default_names :: proc(t: ^testing.T) {
    cases := []string{
        `var {fn=function(){}}={}; fn.name==='fn'`,
        `var [fn=()=>1]=[]; fn.name==='fn'`,
        `var {x:fn=async function(){}}={}; fn.name==='fn'`,
        `var [{fn=function*(){}}]=[{}]; fn.name==='fn'`,
        `function f({fn=()=>1}={}){return fn.name} f()==='fn'`,
        `var fn; [fn=function(){}]=[]; fn.name==='fn'`,
        `var fn; ({x:fn=function(){}}={}); fn.name==='fn'`,
        `var [fn=function named(){}]=[]; fn.name==='named'`,
        `var original=(0,function(){}); var [fn=original]=[]; original.name==='' && fn===original`,
        `var o={}; [o.fn=function(){}]=[]; o.fn.name===''`,
        `var [fn=class {}]=[]; fn.name==='fn'`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
regression_for_await_does_not_pump_timers :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var log='';
        var p=new Promise(function(resolve){setTimeout(function(){log+='timer,';resolve(1)},5)});
        (async function(){for await(var v of [p]) log+=v; log+='done';})();
        log+='sync,';
    `)
    testing.expect_value(t, vm_run(vm,"log").(string), "sync,")
    vm_pump_timers(vm,5)
    testing.expect_value(t, vm_run(vm,"log").(string), "sync,timer,1done")
}

@(test)
regression_for_await_empty_suspends :: proc(t: ^testing.T) {
    testing.expect_value(t, run_settled(`var log=''; (async function(){for await(var x of []){} log+='done'})(); log+='sync,'`, "log").(string), "sync,done")
}

@(test)
regression_for_await_array_live :: proc(t: ^testing.T) {
    testing.expect_value(t, run_settled(`var a=[1], log=''; (async function(){for await(var x of a){ log+=x; if(x===1) a.push(2); }})();`, "log").(string), "12")
}

@(test)
regression_for_await_async_next_pending :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var release, log='', n=0;
        var pending=new Promise(function(r){release=r});
        var it={ [Symbol.asyncIterator](){return this}, next(){return n++===0?pending:Promise.resolve({done:true})} };
        (async function(){for await(var x of it) log+=x; log+='done'})();
        log+='sync,';
    `)
    testing.expect_value(t, vm_run(vm,"log").(string), "sync,")
    vm_run(vm,"release({value:7,done:false})")
    testing.expect_value(t, vm_run(vm,"log").(string), "sync,7done")
}

@(test)
regression_for_await_async_preserves_value :: proc(t: ^testing.T) {
    testing.expect_value(t, run_settled(`
        var pending=new Promise(function(){}), same=false, done=false, n=0;
        var it={ [Symbol.asyncIterator](){return this}, next(){return Promise.resolve(n++===0?{value:pending,done:false}:{done:true})} };
        (async function(){for await(var value of it) same=value===pending; done=true})();
    `,"same && done").(bool),true)
}
