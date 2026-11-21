package js

import "core:testing"

@(test)
test_annex_b_block_functions :: proc(t: ^testing.T) {
    cases := []struct {src, want: string}{
        {`function g(){ { function f(){return 42} } return f() } g()`, "42"},
        {`var f = 'outer'; function g(){ var before = f; if(false){function f(){}} return String(before)+':'+String(f) } g()`, "undefined:undefined"},
        {`function g(){ var seen; { seen=typeof f; function f(){return 7} } return seen+':'+f() } g()`, "function:7"},
        {`function g(){ var f=1; { f=9; function f(){} } return String(f) } g()`, "9"},
        {`function g(){ var f=1; { function f(){} f=9 } return typeof f } g()`, "function"},
        {`function g(){ { return typeof f; function f(){} } } g()`, "function"},
        {`function g(){ var f=1; label:{ break label; function f(){} } return String(f) } g()`, "1"},
        {`function g(f){ { function f(){} } return String(f) } g(3)`, "3"},
        {`function g({f}){ { function f(){} } return String(f) } g({f:4})`, "4"},
        {`function g(){ {function f(){}} let f=5; return String(f) } g()`, "5"},
        {`function g(){ let f=6; {function f(){}} return String(f) } g()`, "6"},
        {`function g(){ { {function f(){}} let f=6; } return typeof f } g()`, "undefined"},
        {`function g(){ { function f(){} {function f(){return 2}} } return String(f()) } g()`, "2"},
        {`function g(){try{throw 1}catch(f){{function f(){return 8}}}return String(f())} g()`, "8"},
        {`function g(){ 'use strict'; {function f(){}} return typeof f } g()`, "undefined"},
        {`'use strict'; {function f(){}} typeof f`, "undefined"},
        {`function g(){ {function* f(){}} return typeof f } g()`, "undefined"},
        {`function g(){ {async function f(){}} return typeof f } g()`, "undefined"},
        {`function g(){ if(true) function f(){return 9} return String(f()) } g()`, "9"},
        {`function g(){ if(false) function f(){} return typeof f } g()`, "undefined"},
        {`function g(){ switch(1){case 1: function f(){return 3}} return String(f()) } g()`, "3"},
        {`function g(){ var seen; switch(1){case 1: seen=typeof f; break; default: function f(){}} return seen+':'+typeof f } g()`, "function:undefined"},
        {`function g(){switch(0){default:function f(){return 4}}return String(f())}g()`, "4"},
        {`function g(){ {function f(){return 1} function f(){return 2}} return String(f()) } g()`, "2"},
        {`{function annexGlobal(){return 11}} String(annexGlobal())`, "11"},
        {`function g(){ var read=()=>f(); {function f(){return 12}} return String(read()) } g()`, "12"},
        {`function g(){ {function f(){ 'use strict'; return 13 }} return String(f()) } g()`, "13"},
        {`function g(){ {function arguments(){}} return typeof arguments } g()`, "object"},
        {`{function arguments(){return 14}} String(arguments())`, "14"},
        {`function g(){ {label: function f(){return 15}} return String(f()) } g()`, "15"},
        {`function g(){ for(var i=0;i<2;i++){function f(){return i}} return String(f()) } g()`, "2"},
        {`function g(){ for(let f of [1]){function f(){}} return typeof f } g()`, "undefined"},
        {`function g(){ var a=[]; for(var i=0;i<2;i++){let x=i; function f(){return x} a.push(f)} return String(a[0]()+a[1]()) } g()`, "1"},
        {`var g=()=>{ {function f(){return 16}} return String(f()) }; g()`, "16"},
        {`function* g(){ {function f(){return 17}} yield f() } String(g().next().value)`, "17"},
        {`function g(){ eval('{function f(){return 18}}'); return String(f()) } g()`, "18"},
        {`function g(){ 'use strict'; eval('{function f(){}}'); return typeof f } g()`, "undefined"},
    }
    for c in cases {
        vm := vm_create()
        v := vm_exec(vm, c.src)
        testing.expect(t, !vm.throwing, c.src)
        testing.expect_value(t, key_string(vm, v), c.want)
        vm_free(vm)
    }
}

@(test)
test_annex_b_module_functions_stay_lexical :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_exec(vm, "var annexResult = '';")
    vm_run_module(vm, `{ function f(){} } annexResult = typeof f;`)
    testing.expect(t, !vm.throwing)
    testing.expect_value(t, key_string(vm, vm_exec(vm, "annexResult")), "undefined")
}
