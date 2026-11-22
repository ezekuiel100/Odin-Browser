package js

import "core:testing"

@(test)
json_stringify_regex_properties :: proc(t: ^testing.T) {
    cases := []string{
        `var r=/a/g; r.lastIndex=3; JSON.stringify(r)==='{}'`,
        `var r=/a/; r.x=1; JSON.stringify(r)==='{"x":1}'`,
        `var r=/a/; r.b=2; r[2]='two'; r.a=1; r[1]='one'; JSON.stringify(r)==='{"1":"one","2":"two","b":2,"a":1}'`,
        `var r=/a/; Object.defineProperty(r,'hidden',{value:7}); r.x=1; JSON.stringify(r)==='{"x":1}'`,
        `var r=/a/, receiver, calls=0; Object.defineProperty(r,'x',{get:function(){calls++;receiver=this;return 7},enumerable:true}); JSON.stringify(r)==='{"x":7}' && calls===1 && receiver===r`,
        `var r=/a/; Object.defineProperty(r,'x',{set:function(v){},enumerable:true}); JSON.stringify(r)==='{}'`,
        `var r=/a/; r.x=1; Object.defineProperty(r,'x',{get:function(){return 7}}); JSON.stringify(r)==='{"x":7}'`,
        `var r=/a/; r.x=1; Object.defineProperty(r,'x',{enumerable:false}); JSON.stringify(r)==='{}'`,
        `var r=/a/; r.x=undefined; r.f=function(){}; r.s=Symbol(); r[Symbol('key')]=7; r.y=2; JSON.stringify(r)==='{"y":2}'`,
        `var r=/a/; r.x=1; JSON.stringify(r,['lastIndex','source','x'])==='{"lastIndex":0,"source":"a","x":1}'`,
        `var r=/a/; r.x=1; JSON.stringify(r,null,1)==='{\n "x": 1\n}'`,
        `RegExp.prototype.inherited=7; JSON.stringify(/a/)==='{}' && JSON.stringify(/a/,['inherited'])==='{"inherited":7}'`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
json_stringify_collection_properties :: proc(t: ^testing.T) {
    cases := []string{
        `JSON.stringify(new Map([['x',1]]))==='{}' && JSON.stringify(new Set([1,2]))==='{}'`,
        `[Map,Set,WeakMap,WeakSet].every(function(C){var o=new C();o.x=1;return JSON.stringify(o)==='{"x":1}'})`,
        `var m=new Map([['entry',2]]); m.x=1; m['y']=3; JSON.stringify(m)==='{"x":1,"y":3}' && m.get('entry')===2 && m.size===1`,
        `[Map,Set,WeakMap,WeakSet].every(function(C){var o=new C();Object.defineProperty(o,'x',{value:7,enumerable:true});Object.defineProperty(o,'hidden',{value:8});return JSON.stringify(o)==='{"x":7}'})`,
        `var s=new Set(), receiver; Object.defineProperty(s,'x',{get:function(){receiver=this;return 7},enumerable:true}); JSON.stringify(s)==='{"x":7}' && receiver===s`,
        `var m=new Map(); m.b=2; m[2]='two'; m.a=1; m[1]='one'; JSON.stringify(m)==='{"1":"one","2":"two","b":2,"a":1}'`,
        `var m=new Map(); m[Symbol('x')]=7; m.x=undefined; m.f=function(){}; m.y=2; JSON.stringify(m)==='{"y":2}'`,
        `var m=new Map([['entry',2]]); m.x=1; JSON.stringify(m,['size','x'])==='{"size":1,"x":1}'`,
        `Map.prototype.inherited=7; JSON.stringify(new Map())==='{}' && JSON.stringify(new Map(),['inherited'])==='{"inherited":7}'`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
json_special_object_hooks_and_cycles :: proc(t: ^testing.T) {
    cases := []string{
        `var r=/a/, holder, keys=''; r.x=1; JSON.stringify(r,function(k,v){keys+=k+'|';if(k==='x')holder=this;return v})==='{"x":1}' && holder===r && keys==='|x|'`,
        `var m=new Map(), holder; m.x=1; JSON.stringify(m,function(k,v){if(k==='x')holder=this;return v})==='{"x":1}' && holder===m`,
        `var r=/a/; r.toJSON=function(k){return k+'!'}; JSON.stringify({r:r})==='{"r":"r!"}'`,
        `var m=new Map(); m.toJSON=function(k){return k+'!'}; JSON.stringify({m:m})==='{"m":"m!"}'`,
        `var receiver; Object.defineProperty(RegExp.prototype,'toJSON',{get:function(){receiver=this;return function(){return 7}}}); var r=/a/; JSON.stringify(r)==='7' && receiver===r`,
        `var r=/a/, sentinel={}, caught=false; Object.defineProperty(r,'x',{get:function(){throw sentinel},enumerable:true}); try{JSON.stringify(r)}catch(e){caught=e===sentinel} caught`,
        `var m=new Map(), sentinel={}, caught=false; Object.defineProperty(m,'x',{get:function(){throw sentinel},enumerable:true}); try{JSON.stringify(m)}catch(e){caught=e===sentinel} caught`,
        `var r=/a/; r.self=r; var caught=false; try{JSON.stringify(r)}catch(e){caught=e instanceof TypeError} caught`,
        `[Map,Set,WeakMap,WeakSet].every(function(C){var o=new C();o.self=o;try{JSON.stringify(o)}catch(e){return e instanceof TypeError}return false})`,
        `var r=/a/, m=new Map(); r.m=m; m.r=r; var caught=false; try{JSON.stringify(r)}catch(e){caught=e instanceof TypeError} caught`,
        `var r=/a/, m=new Map(); r.x=1; m.y=2; JSON.stringify([r,r,m,m])==='[{"x":1},{"x":1},{"y":2},{"y":2}]'`,
        `var r=/a/; r.a=1;r.b=2; Object.defineProperty(r,'a',{get:function(){delete r.b;r.c=3;return 1}}); JSON.stringify(r)==='{"a":1}'`,
        `var m=new Map(); m.a=1;m.b=2; Object.defineProperty(m,'a',{get:function(){delete m.b;m.c=3;return 1}}); JSON.stringify(m)==='{"a":1}'`,
        `var r=/a/; r.x=1; JSON.stringify(new Proxy(r,{}))==='{"x":1}'`,
        `var m=new Map(), receiver, p=new Proxy(m,{}); Object.defineProperty(m,'x',{get:function(){receiver=this;return 7},enumerable:true}); JSON.stringify(p)==='{"x":7}' && receiver===p`,
        `var m=new Map(), s=Symbol('s'); m[s]=7; m.x=1; JSON.stringify(new Proxy(m,{}))==='{"x":1}'`,
        `var r=/a/, p=new Proxy(r,{}); r.p=p; var caught=false; try{JSON.stringify(p)}catch(e){caught=e instanceof TypeError} caught`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
special_object_property_metadata :: proc(t: ^testing.T) {
    cases := []string{
        `var r=/a/; r.x=1; r.y=2; delete r.x; r.x=3; Object.keys(r).join()==='y,x' && JSON.stringify(r)==='{"y":2,"x":3}'`,
        `var m=new Map(); m.x=1; m.y=2; delete m.x; m.x=3; Object.keys(m).join()==='y,x' && JSON.stringify(m)==='{"y":2,"x":3}'`,
        `var r=/a/; Object.defineProperty(r,'x',{value:7,enumerable:true}); r.x=8; var d=Object.getOwnPropertyDescriptor(r,'x'); d.value===7 && d.enumerable && !d.writable && !d.configurable && !delete r.x`,
        `var m=new Map(); Object.defineProperty(m,'x',{value:7,enumerable:true}); m.x=8; var d=Object.getOwnPropertyDescriptor(m,'x'); d.value===7 && d.enumerable && !d.writable && !d.configurable && !delete m.x`,
        `var r=/a/; r.x=1; Object.hasOwn(r,'x') && r.propertyIsEnumerable('x') && !r.propertyIsEnumerable('lastIndex')`,
        `var m=new Map(); m.x=1; Object.hasOwn(m,'x') && m.propertyIsEnumerable('x') && !m.propertyIsEnumerable('size')`,
        `var r=/a/; Object.defineProperty(r,'x',{get:function(){return 7},enumerable:true,configurable:true}); delete r.x; JSON.stringify(r)==='{}' && !Object.hasOwn(r,'x')`,
        `var r=/a/; r.x=1; r[2]=2; Object.getOwnPropertyNames(r).join()==='2,lastIndex,x' && ('lastIndex' in r) && ('x' in r)`,
        `var m=new Map(); m.x=1; ('x' in m) && Reflect.deleteProperty(m,'x') && !('x' in m)`,
        `var r=/a/; Object.defineProperties(r,{lastIndex:{value:3},x:{value:7,enumerable:true}}); r.lastIndex===3 && JSON.stringify(r)==='{"x":7}'`,
        `var m=new Map(); Object.defineProperties(m,{x:{value:7,enumerable:true},y:{value:8}}); JSON.stringify(m)==='{"x":7}'`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
gc_preserves_special_object_properties :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_exec(vm, `var r=/a/, m=new Map(), w=new WeakMap(); r.x={answer:7}; m.x={answer:8}; w.x={answer:9}; Object.defineProperty(r,'y',{get:(function(){var a={answer:10};return function(){return a.answer}})(),enumerable:true});`)
    testing.expect(t, !vm.throwing)
    testing.expect(t, vm_collect(vm))
    testing.expect_value(t, vm_exec(vm, `r.x.answer===7 && m.x.answer===8 && w.x.answer===9 && JSON.stringify(r)==='{"x":{"answer":7},"y":10}'`).(bool), true)
    objects := len(vm.all_objects)
    vm_exec(vm, `(function(){var r=/b/, m=new Map();r.self=r;m.self=m;r.m=m;m.r=r})();`)
    testing.expect(t, vm_collect(vm))
    testing.expect_value(t, len(vm.all_objects), objects)
}
