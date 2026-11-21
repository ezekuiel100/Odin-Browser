package js

import "core:testing"

@(test)
collection_constructor_valid_sources :: proc(t: ^testing.T) {
    for code in ([]string{
        `var m=new Map([['a',1],['a',2],['b',3]]); m.size===2 && m.get('a')===2`,
        `new Set('a\u{1f600}a').size===2`,
        `var s=new Set(new Map([['a',1]])), p=s.values().next().value; Array.isArray(p) && p[0]==='a' && p[1]===1`,
        `new Map(new Set([['a',1]])).get('a')===1`,
        `var a=[1]; a[Symbol.iterator]=function*(){yield 9}; var s=new Set(a); s.has(9) && !s.has(1)`,
        `var m=new Map([[1,2]]); Map.prototype[Symbol.iterator]=function*(){yield [3,4]}; var n=new Map(m); n.get(3)===4 && !n.has(1)`,
        `var n=0;for(var C of [Map,Set]){var source=new C();delete C.prototype[Symbol.iterator];try{new Set(source)}catch(e){if(e instanceof TypeError)n++}}n===2`,
        `var pair=new Uint8Array([3,7]); new Map([pair]).get(3)===7`,
        `var m=new Map([{},function(){}]); m.size===1 && m.has(undefined)`,
        `var key={}, s=Symbol(); var m=new WeakMap([[key,1],[s,2]]); var w=new WeakSet([key,s]); m.get(key)===1 && m.get(s)===2 && w.has(key) && w.has(s)`,
    }) {
        testing.expect(t, run(code) == Value(true), code)
    }
}

@(test)
collection_constructor_intrinsic_iterator_survives_gc :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `var m=new Map([[1,2]]); Map=null;`)
    testing.expect(t, vm_collect(vm))
    testing.expect(t, vm_run(vm, `var s=new Set(m); var p=s.values().next().value; p[0]===1 && p[1]===2`) == Value(true))
}

@(test)
collection_constructor_rejects_invalid_inputs :: proc(t: ^testing.T) {
    for code in ([]string{
        `var n=0; for(var C of [Map,Set,WeakMap,WeakSet]){for(var x of [1,true,{},Symbol(),1n,{next:function(){return {done:true}}}]){try{new C(x)}catch(e){if(e instanceof TypeError)n++}}} n===24`,
        `var n=0; for(var C of [Map,WeakMap]){for(var x of [1,null,undefined,'ab',Symbol(),1n]){try{new C([x])}catch(e){if(e instanceof TypeError)n++}}} n===12`,
        `var n=0; for(var x of [1,null,undefined,true,'x',1n,Symbol.for('registered')]){try{new WeakMap([[x,1]])}catch(e){if(e instanceof TypeError)n++}try{new WeakSet([x])}catch(e){if(e instanceof TypeError)n++}} n===14`,
        `var n=0; for(var C of [Map,Set,WeakMap,WeakSet]){try{C()}catch(e){if(e instanceof TypeError)n++}try{C.call({})}catch(e){if(e instanceof TypeError)n++}} n===8`,
        `var n=0; for(var C of [Map,Set,WeakMap,WeakSet]){for(var x of [undefined,null]){var o=new C(x); if(o instanceof C)n++}} n===8`,
        `var n=0; for(var method of [undefined,null,1,{}]){var src={[Symbol.iterator]:method}; try{new Set(src)}catch(e){if(e instanceof TypeError)n++}} n===4`,
    }) {
        testing.expect(t, run(code) == Value(true), code)
    }
}

@(test)
collection_constructor_closes_on_entry_errors :: proc(t: ^testing.T) {
    for code in ([]string{
        `var log=''; function* g(){try{log+='a';yield 1;log+='b';yield ['x',2]}finally{log+='c'}} var caught=false;try{new Map(g())}catch(e){caught=e instanceof TypeError} caught && log==='ac'`,
        `var log='', pair={get 0(){log+='k';throw 7},get 1(){log+='v';return 2}}; function* g(){try{yield pair;log+='n'}finally{log+='c'}} var caught=false;try{new Map(g())}catch(e){caught=e===7} caught && log==='kc'`,
        `var log='', pair={get 0(){log+='k';return 1},get 1(){log+='v';throw 7}}; function* g(){try{yield pair;log+='n'}finally{log+='c'}} var caught=false;try{new Map(g())}catch(e){caught=e===7} caught && log==='kvc'`,
        `var log=''; var it={[Symbol.iterator]:function(){return this},next:function(){log+='n';return {value:1,done:false}},return:function(){log+='r';throw 9}}; var caught=false;try{new Map(it)}catch(e){caught=e instanceof TypeError} caught && log==='nr'`,
        `var closed=false;var it={[Symbol.iterator]:function(){return this},next:function(){return {value:1,done:false}},get return(){closed=true;throw 9}};var caught=false;try{new Map(it)}catch(e){caught=e instanceof TypeError} caught && closed`,
        `var closed=false;function* g(){try{yield 1;throw 9}finally{closed=true}} var caught=false;try{new WeakSet(g())}catch(e){caught=e instanceof TypeError} caught && closed`,
        `var log='';function* g(){try{yield [1,2];log+='n'}finally{log+='c'}} var caught=false;try{new WeakMap(g())}catch(e){caught=e instanceof TypeError} caught && log==='c'`,
    }) {
        testing.expect(t, run(code) == Value(true), code)
    }
}

@(test)
collection_constructor_protocol_access_order :: proc(t: ^testing.T) {
    for code in ([]string{
        `var log='', n=0; var it={get next(){log+='N';return function(){log+='n';return n++ ? {get done(){log+='D';return true},get value(){throw 9}} : {get done(){log+='d';return false},get value(){log+='v';return {get 0(){log+='k';return 1},get 1(){log+='w';return 2}}}}}},return:function(){log+='r'}}; var src={get [Symbol.iterator](){log+='I';return function(){log+='i';return it}}}; var m=new Map(src); m.get(1)===2 && log==='IiNndvkwnD'`,
        `var log='', a=[[1,2],[3,4]]; Object.defineProperty(a[0],'0',{get:function(){a[1]=[5,6];return 1}}); var m=new Map(a); m.get(5)===6 && !m.has(3)`,
        `var log='';var it={[Symbol.iterator]:function(){return this},get next(){throw 7},return:function(){log+='r'}};var caught=false;try{new Set(it)}catch(e){caught=e===7} caught && log===''`,
        `var n=0;for(var part of ['next','done','value']){var closed=false;var it={[Symbol.iterator]:function(){return this},next:function(){if(part==='next')throw 7;return {get done(){if(part==='done')throw 7;return false},get value(){throw 7}}},return:function(){closed=true;return {}}};try{new Map(it)}catch(e){if(e===7 && !closed)n++}} n===3`,
        `var n=0;for(var value of [null,1,'x',undefined]){try{new Set({[Symbol.iterator]:function(){return value}})}catch(e){if(e instanceof TypeError)n++}}n===4`,
        `var n=0;for(var value of [null,1,'x',undefined]){try{new Set({[Symbol.iterator]:function(){return {next:function(){return value}}}})}catch(e){if(e instanceof TypeError)n++}}n===4`,
        `var called=false;var it={[Symbol.iterator]:function(){return this},next:1,return:function(){called=true}};var caught=false;try{new Set(it)}catch(e){caught=e instanceof TypeError} caught && !called`,
    }) {
        testing.expect(t, run(code) == Value(true), code)
    }
}

@(test)
collection_constructor_uses_captured_adder :: proc(t: ^testing.T) {
    for code in ([]string{
        `var original=Map.prototype.set,log='';Map.prototype.set=function(k,v){log+=k;return original.call(this,k,v+1)};var m=new Map([['a',1],['b',2]]);m.get('a')===2 && m.get('b')===3 && log==='ab'`,
        `var original=Set.prototype.add,log='';Set.prototype.add=function(v){log+=v;Set.prototype.add=function(){throw 9};return original.call(this,v)};var s=new Set([1,2]);s.size===2 && log==='12'`,
        `var log='', original=Map.prototype.set, receiver;Object.defineProperty(Map.prototype,'set',{get:function(){log+='a';receiver=this;return original}});var src={get [Symbol.iterator](){log+='i';return function*(){yield [1,2]}}};var m=new Map(src);receiver===m && log==='ai' && m.get(1)===2`,
        `var accessed=false;Map.prototype.set=1;var src={get [Symbol.iterator](){accessed=true;throw 9}};var caught=false;try{new Map(src)}catch(e){caught=e instanceof TypeError}caught && !accessed`,
        `Object.defineProperty(Set.prototype,'add',{get:function(){throw 9}});new Set(null).size===0 && new Set().size===0`,
        `var log='';Set.prototype.add=function(){throw 7};function* g(){try{yield 1;log+='n'}finally{log+='c'}}var caught=false;try{new Set(g())}catch(e){caught=e===7}caught && log==='c'`,
        `class M extends Map {set(k,v){return super.set(k,v+1)}}var m=new M([['a',1]]);m instanceof M && m.get('a')===2 && m.size===1`,
        `class S extends Set {add(v){return super.add(v+1)}}var s=new S([1,2]);s instanceof S && s.has(2) && s.has(3) && s.size===2`,
        `class W extends WeakMap {constructor(xs){super(xs)}set(k,v){return super.set(k,v+1)}}var k={},m=new W([[k,1]]);m instanceof W && m.get(k)===2`,
        `var closed=false;class S extends Set {add(v){throw 7}}function* g(){try{yield 1}finally{closed=true}}var caught=false;try{new S(g())}catch(e){caught=e===7}caught && closed`,
    }) {
        testing.expect(t, run(code) == Value(true), code)
    }
}
