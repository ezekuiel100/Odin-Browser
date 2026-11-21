package js

import "core:testing"

@(test)
collection_iterator_observes_mutations :: proc(t: ^testing.T) {
    for code in ([]string{
        `var s=new Set([1]),it=s.values();s.add(2);it.next().value===1 && it.next().value===2 && it.next().done`,
        `var m=new Map([[1,2]]),it=m.keys();m.set(3,4);it.next().value===1 && it.next().value===3 && it.next().done`,
        `var s=new Set([1,2]),it=s.values();s.delete(1);it.next().value===2 && it.next().done`,
        `var s=new Set([1,2]),it=s.values();it.next();s.delete(2);it.next().done`,
        `var m=new Map([[1,2],[3,4]]),it=m.values();m.set(1,9);it.next().value===9 && it.next().value===4`,
        `var m=new Map([[1,2]]),it=m.entries();m.set(1,9);var p=it.next().value;p[0]===1 && p[1]===9`,
        `var s=new Set([1,2]),it=s.values();it.next();s.delete(1);s.add(1);it.next().value===2 && it.next().value===1 && it.next().done`,
        `var m=new Map([[1,2],[3,4]]),it=m.entries();it.next();m.delete(1);m.set(1,9);it.next().value[0]===3 && it.next().value[1]===9 && it.next().done`,
        `var s=new Set([1,2]),it=s.values();s.clear();s.add(3);it.next().value===3 && it.next().done`,
        `var s=new Set([1,2]),it=s.values();it.next();s.clear();s.add(3);it.next().value===3 && it.next().done`,
        `var m=new Map([[1,2]]),it=m.entries();m.clear();m.set(3,4);var p=it.next().value;p[0]===3 && p[1]===4 && it.next().done`,
        `var s=new Set([1,2]),a=s.values(),b=s.values();a.next();s.delete(2);s.add(3);b.next().value===1 && a.next().value===3 && b.next().value===3 && a.next().done && b.next().done`,
        `var s=new Set([1]),it=s.values();it.next();s.add(2);it.next().value===2 && it.next().done`,
        `var s=new Set([1]),it=s.values();it.next();it.next();s.add(2);it.next().done && it.next().value===undefined`,
        `var s=new Set(),it=s.values();s.add(1);it.next().value===1 && it.next().done`,
        `var s=new Set(),it=s.values();it.next();s.add(1);it.next().done`,
        `var s=new Set([1]),it=s.entries(),a=it.next().value;s.add(2);var b=it.next().value;a!==b && a.join()==='1,1' && b.join()==='2,2'`,
    }) {
        testing.expect(t, run(code) == Value(true), code)
    }
}

@(test)
collection_iterator_language_consumers_are_live :: proc(t: ^testing.T) {
    for code in ([]string{
        `var s=new Set([1,2]),seen='';for(var x of s){seen+=x;if(x===1){s.delete(2);s.add(3)}}seen==='13'`,
        `var m=new Map([[1,2],[3,4]]),seen='';for(var p of m){seen+=p.join();if(p[0]===1){m.set(3,9);m.set(5,6)}}seen==='1,23,95,6'`,
        `var s=new Set([1,2]),seen='';for(var x of s){seen+=x;if(x===1){s.clear();s.add(3)}}seen==='13'`,
        `var s=new Set([1]);function* g(){yield* s}var it=g();it.next();s.add(2);it.next().value===2 && it.next().done`,
        `var m=new Map([[1,2]]);function* g(){yield* m}var it=g();it.next();m.set(3,4);it.next().value.join()==='3,4' && it.next().done`,
        `var s=new Set([undefined,2]);var [a=(s.delete(2),s.add(3),1),b]=s;a===1 && b===3`,
        `var s=new Set([undefined,2]);var [a=(s.clear(),s.add(3),1),...rest]=s;a===1 && rest.join()==='3'`,
        `var s=new Set([1]);Set.prototype[Symbol.iterator]=function*(){yield 9};var seen='';for(var x of s)seen+=x;seen==='9'`,
        `var s=new Set([1]);Set.prototype[Symbol.iterator]=function*(){yield 9};var [x]=s;x===9`,
        `class S extends Set{}var s=new S([1,2]),seen='';for(var x of s){seen+=x;if(x===1){s.delete(2);s.add(3)}}seen==='13'`,
    }) {
        testing.expect(t, run(code) == Value(true), code)
    }
}

@(test)
collection_iterator_prototype_and_receiver :: proc(t: ^testing.T) {
    for code in ([]string{
        `var a=new Map().keys(),b=new Map().values(),c=new Set().values();Object.getPrototypeOf(a)===Object.getPrototypeOf(b) && Object.getPrototypeOf(a)!==Object.getPrototypeOf(c) && Object.getPrototypeOf(a)!==Object.getPrototypeOf([][Symbol.iterator]())`,
        `var a=new Map().keys(),b=new Set().values();a[Symbol.iterator]()===a && b[Symbol.iterator]()===b && Object.getPrototypeOf(Object.getPrototypeOf(a))===Object.getPrototypeOf(Object.getPrototypeOf(b))`,
        `Object.prototype.toString.call(new Map().keys())==='[object Map Iterator]' && Object.prototype.toString.call(new Set().values())==='[object Set Iterator]'`,
        `var n=0;for(var source of [new Map(),new Set()]){var it=source.values(),next=it.next;for(var x of [undefined,null,{},[],source,Object.create(it),new Proxy(it,{})]){try{next.call(x)}catch(e){if(e instanceof TypeError)n++}}}n===14`,
        `var a=new Map().keys(),b=new Set().values(),n=0;try{a.next.call(b)}catch(e){if(e instanceof TypeError)n++}try{b.next.call(a)}catch(e){if(e instanceof TypeError)n++}n===2`,
        `var it=new Map().keys();it._i=-5;it._kind=2;it._source=[9];it.next().done && Object.getOwnPropertyNames(new Set().values()).length===0`,
        `var it=new Set([1]).values();!Object.prototype.hasOwnProperty.call(it,'next') && it.next.name==='next' && it.next.length===0`,
    }) {
        testing.expect(t, run(code) == Value(true), code)
    }
}

@(test)
collection_iterator_for_await_is_live :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `var result=false;async function go(){var s=new Set([1,2]),seen='';for await(var v of s){seen+=v;if(v===1){s.delete(2);s.add(3)}}result=seen==='13'}go();`)
    testing.expect(t, vm_run(vm, "result") == Value(true))
}

@(test)
collection_iterator_compaction_after_exhaustion :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `var m=new Map();for(var i=0;i<100;i++)m.set(i,i);var a=m.keys(),b=m.values();a.next();b.next();for(var i=0;i<90;i++)m.delete(i);m.set(100,100);`)
    c := vm.global.vars["m"].(^Collection)
    testing.expect_value(t, c.iterating, 2)
    testing.expect_value(t, len(c.entries), 101)
    testing.expect(t, vm_run(vm, `var ka=[...a],vb=[...b];ka.length===11 && ka[0]===90 && ka[10]===100 && vb.join()===ka.join()`) == Value(true))
    testing.expect_value(t, c.iterating, 0)
    vm_run(vm, `m.set(101,101)`)
    testing.expect_value(t, len(c.entries), 12)
    testing.expect(t, vm_run(vm, `a.next().done && b.next().done && [...m.keys()].join()==='90,91,92,93,94,95,96,97,98,99,100,101'`) == Value(true))
}

@(test)
collection_iterator_gc_retains_and_releases_source :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_collect(vm)
    baseline := len(vm.all_collections)
    vm_run(vm, `var it=(function(){var m=new Map([[{}, {answer:42}]]);return m.entries()})();`)
    testing.expect(t, vm_collect(vm))
    testing.expect_value(t, len(vm.all_collections), baseline+1)
    testing.expect(t, vm_run(vm, `it.next().value[1].answer===42 && it.next().done`) == Value(true))
    testing.expect(t, vm_collect(vm))
    testing.expect_value(t, len(vm.all_collections), baseline)
    testing.expect(t, vm_run(vm, `it.next().done`) == Value(true))
}

@(test)
collection_iterator_gc_abandonment_unpins_compaction :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `var m=new Map();for(var i=0;i<100;i++)m.set(i,i);var it=m.keys();for(var i=0;i<90;i++)m.delete(i);it=null;`)
    c := vm.global.vars["m"].(^Collection)
    testing.expect_value(t, c.iterating, 1)
    testing.expect(t, vm_collect(vm))
    testing.expect_value(t, c.iterating, 0)
    vm_run(vm, `m.set(100,100)`)
    testing.expect_value(t, len(c.entries), 11)
    vm_run(vm, `m=null;(function(){var s=new Set([{}]);s.values()})();`)
    testing.expect(t, vm_collect(vm))
}

@(test)
collection_iterator_gc_retains_subclass_identity :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `var w=new WeakMap(),it;(function(){class M extends Map{}var m=new M([[1,2]]);w.set(m,3);it=m.values()})();`)
    w := vm.global.vars["w"].(^Collection)
    testing.expect(t, vm_collect(vm))
    testing.expect_value(t, w.size, 1)
    testing.expect(t, vm_run(vm, `it.next().value===2 && it.next().done`) == Value(true))
    testing.expect(t, vm_collect(vm))
    testing.expect_value(t, w.size, 0)
}
