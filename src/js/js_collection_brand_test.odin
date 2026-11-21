package js

import "core:testing"

@(test)
collection_brand_rejects_cross_kind_receivers :: proc(t: ^testing.T) {
    testing.expect(t, run(`
        var ctors=[Map,Set,WeakMap,WeakSet], key={}, ok=true;
        var methods=[['set','get','has','delete','clear','forEach','keys','values','entries'],
                     ['add','has','delete','clear','forEach','keys','values','entries'],
                     ['set','get','has','delete'],['add','has','delete']];
        for(var i=0;i<ctors.length;i++){
            for(var j=0;j<ctors.length;j++){
                if(i===j)continue;
                var receiver=new ctors[j]();
                for(var name of methods[i]){
                    var threw=false;
                    try{ctors[i].prototype[name].call(receiver,key,1)}catch(e){threw=e instanceof TypeError}
                    if(!threw)ok=false;
                }
                if(receiver.has(key))ok=false;
            }
        }
        ok
    `) == Value(true))
}

@(test)
collection_brand_rejects_objects_without_internal_slots :: proc(t: ^testing.T) {
    testing.expect(t, run(`
        var ctors=[Map,Set,WeakMap,WeakSet], key={}, ok=true;
        var methods=[['set','get','has','delete','clear','forEach','keys','values','entries'],
                     ['add','has','delete','clear','forEach','keys','values','entries'],
                     ['set','get','has','delete'],['add','has','delete']];
        for(var i=0;i<ctors.length;i++){
            var C=ctors[i], real=new C();class D extends C{}
            var receivers=[undefined,null,1,true,'x',Symbol(),1n,{},[],/x/,function(){},
                           C.prototype,Object.create(C.prototype),Object.create(real),new Proxy(new D(),{})];
            for(var receiver of receivers){
                for(var name of methods[i]){
                    var threw=false;
                    try{C.prototype[name].call(receiver,key,1)}catch(e){threw=e instanceof TypeError}
                    if(!threw)ok=false;
                }
            }
        }
        ok
    `) == Value(true))
}

@(test)
collection_brand_accepts_matching_receivers_and_subclasses :: proc(t: ^testing.T) {
    for code in ([]string{
        `var k={},m=new Map();Map.prototype.set.call(m,k,7)===m && Map.prototype.get.call(m,k)===7 && Map.prototype.has.call(m,k) && Map.prototype.delete.call(m,k) && !m.has(k)`,
        `var k={},s=new Set();Set.prototype.add.call(s,k)===s && Set.prototype.has.call(s,k) && Set.prototype.delete.call(s,k) && !s.has(k)`,
        `var k={},m=new WeakMap();WeakMap.prototype.set.call(m,k,7)===m && WeakMap.prototype.get.call(m,k)===7 && WeakMap.prototype.has.call(m,k) && WeakMap.prototype.delete.call(m,k)`,
        `var k={},s=new WeakSet();WeakSet.prototype.add.call(s,k)===s && WeakSet.prototype.has.call(s,k) && WeakSet.prototype.delete.call(s,k)`,
        `class M extends Map{}var m=new M();m.set('a',1)===m && Map.prototype.set.call(m,'b',2)===m && m.size===2 && m.get('b')===2`,
        `class S extends Set{}var s=new S();s.add(1)===s && Set.prototype.add.call(s,2)===s && s.size===2`,
        `class W extends WeakMap{}var w=new W(),k={};w.set(k,1)===w && WeakMap.prototype.get.call(w,k)===1`,
        `class W extends WeakSet{}var w=new W(),k={};w.add(k)===w && WeakSet.prototype.has.call(w,k)`,
        `var ok=true;for(var C of [Map,WeakMap]){var m=new C();ok=ok && !m.has(1) && m.get(1)===undefined && !m.delete(1)}var s=new WeakSet();ok && !s.has(1) && !s.delete(1)`,
        `class M extends Map{}var m=new M([[1,2]]),ok=false;Map.prototype.forEach.call(m,function(v,k,c){ok=v===2 && k===1 && c===m});ok`,
        `class S extends Set{}var s=new S([3]),ok=false;s.forEach(function(v,k,c){ok=v===3 && k===3 && c===s});ok`,
        `var m=new Map([[1,2]]),s=new Set([3]);Map.prototype.clear.call(m);Set.prototype.clear.call(s);m.size===0 && s.size===0`,
        `var m=new Map([[1,2]]);Map.prototype.keys.call(m).next().value===1 && Map.prototype.values.call(m).next().value===2 && Map.prototype.entries.call(m).next().value.join()==='1,2'`,
        `var s=new Set([3]);Set.prototype.keys.call(s).next().value===3 && Set.prototype.values.call(s).next().value===3 && Set.prototype.entries.call(s).next().value.join()==='3,3'`,
    }) {
        testing.expect(t, run(code) == Value(true), code)
    }
}

@(test)
collection_brand_size_accessors :: proc(t: ^testing.T) {
    for code in ([]string{
        `var g=Object.getOwnPropertyDescriptor(Map.prototype,'size').get,m=new Map([[1,2]]);g.call(m)===1 && !Object.prototype.hasOwnProperty.call(m,'size')`,
        `var g=Object.getOwnPropertyDescriptor(Set.prototype,'size').get,s=new Set([1,2]);g.call(s)===2 && !Object.prototype.hasOwnProperty.call(s,'size')`,
        `var n=0;for(var C of [Map,Set]){class D extends C{}var g=Object.getOwnPropertyDescriptor(C.prototype,'size').get;for(var x of [undefined,null,{},C.prototype,new WeakMap(),new WeakSet(),new Proxy(new D(),{})]){try{g.call(x)}catch(e){if(e instanceof TypeError)n++}}}n===14`,
        `var n=0;try{Object.getOwnPropertyDescriptor(Map.prototype,'size').get.call(new Set())}catch(e){if(e instanceof TypeError)n++}try{Object.getOwnPropertyDescriptor(Set.prototype,'size').get.call(new Map())}catch(e){if(e instanceof TypeError)n++}n===2`,
        `class M extends Map{}class S extends Set{}var m=new M([[1,2]]),s=new S([3]);Object.getOwnPropertyDescriptor(Map.prototype,'size').get.call(m)===1 && Object.getOwnPropertyDescriptor(Set.prototype,'size').get.call(s)===1`,
    }) {
        testing.expect(t, run(code) == Value(true), code)
    }
}

@(test)
collection_brand_prototype_methods_and_aliases :: proc(t: ^testing.T) {
    for code in ([]string{
        `Map.prototype.get!==WeakMap.prototype.get && Map.prototype.set!==WeakMap.prototype.set && Map.prototype.has!==Set.prototype.has && WeakMap.prototype.has!==WeakSet.prototype.has && Set.prototype.add!==WeakSet.prototype.add`,
        `Set.prototype.keys===Set.prototype.values && Set.prototype[Symbol.iterator]===Set.prototype.values && Map.prototype[Symbol.iterator]===Map.prototype.entries`,
        `var ok=true;for(var C of [WeakMap,WeakSet]){var w=new C();for(var k of ['size','clear','forEach','keys','values','entries']){if(w[k]!==undefined || Object.getOwnPropertyDescriptor(C.prototype,k)!==undefined)ok=false}if(w[Symbol.iterator]!==undefined)ok=false}ok`,
        `var n=0;for(var C of [WeakMap,WeakSet]){try{new Set(new C())}catch(e){if(e instanceof TypeError)n++}}n===2`,
        `var n=0;for(var k of ['add']){if(Map.prototype[k]===undefined && WeakMap.prototype[k]===undefined)n++}Set.prototype.get===undefined && Set.prototype.set===undefined && WeakSet.prototype.get===undefined && WeakSet.prototype.set===undefined && n===1`,
        `Map.prototype.get=function(){return 99};new Map().get(1)===99`,
        `var m=new Map([[1,2]]),bound=Map.prototype.get.bind(m);bound(1)===2`,
        `var calls=0;try{Map.prototype.forEach.call(new Set(),function(){calls++})}catch(e){}calls===0`,
    }) {
        testing.expect(t, run(code) == Value(true), code)
    }
}
