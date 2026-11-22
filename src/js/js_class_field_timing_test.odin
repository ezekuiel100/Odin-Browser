package js

import "core:testing"

@(test)
class_fields_derived_order :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        const log = [];
        class A {
            a = log.push('a');
            constructor() { log.push('A:' + this.x); this.x = 1; }
        }
        class B extends A {
            x = (log.push('b'), 2);
            constructor() { log.push('before'); super(); log.push('B:' + this.x); }
        }
        class C extends B { c = log.push('c'); }
        const o = new C();
        log.join(',') + ':' + o.x
    `), "before,a,A:undefined,b,B:2,c:2")
}

@(test)
class_fields_computed_once :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        let keys = 0, values = 0;
        class C { [++keys] = ++values; }
        const before = keys;
        const a = new C(), b = new C();
        [before, keys, values, a[1], b[1]].join(',')
    `), "1,1,2,1,2")
}

@(test)
class_fields_key_order_static_and_methods :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        const log = [];
        function key(k) { log.push(k); return k; }
        class C {
            [key('a')] = log.push('init-a');
            static [key('b')] = (log.push('init-b'), C.m());
            [key('c')]() {}
            static [key('m')]() { return 7; }
            static { log.push('block'); }
            [key('d')];
        }
        new C();
        log.join(',') + ':' + C.b
    `), "a,b,c,m,d,init-b,block,init-a:7")
}

@(test)
class_fields_keys_per_class_evaluation :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        let n = 0;
        function make() { return class { [++n] = n; }; }
        const A = make(), B = make();
        const a = new A(), b = new B(), a2 = new A();
        [n, a[1], b[2], a2[1], a[2], b[1]].join(',')
    `), "2,2,2,2,,")
}

@(test)
class_fields_failed_super_skips_derived :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        const log = [];
        class A { a = log.push('a'); constructor() { throw 1; } }
        class B extends A { b = log.push('b'); constructor() { super(); } }
        try { new B(); } catch (e) { log.push('caught'); }
        log.join(',')
    `), "a,caught")
}

@(test)
class_fields_failed_key_aborts_definition :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        const log = [];
        function fail() { log.push('key'); throw 1; }
        try {
            class C {
                static x = log.push('static');
                [fail()] = log.push('field');
                [log.push('later')]() {}
            }
        } catch (e) { log.push('caught'); }
        log.join(',')
    `), "key,caught")
}

@(test)
class_fields_key_coercion_once_and_symbols :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        let calls = 0;
        const k = { toString() { calls++; return 'x'; } };
        const sym = Symbol('field');
        class C { [k] = 3; [sym] = 4; }
        const a = new C(), b = new C();
        [calls, a.x, b.x, a[sym], b[sym]].join(',')
    `), "1,3,3,4,4")
}

@(test)
class_fields_super_arrow_and_reflect :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        class A { x = 1; constructor() { this.x = 2; } }
        class B extends A { x = this.x + 1; constructor() { (() => super())(); } }
        [new B().x, Reflect.construct(B, []).x, new (B.bind(null))().x].join(',')
    `), "3,3,3")
}

@(test)
class_fields_no_super_no_derived_initializers :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        let n = 0;
        class A { a = ++n; }
        class B extends A { b = ++n; constructor() { return {}; } }
        class C extends null { c = ++n; constructor() { return {}; } }
        new B(); new C(); n
    `), f64(0))
}
