package js

import "core:testing"

@(test)
typedarray_constructor_bounds_and_coercion :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var constructors = [Int8Array, Uint8Array, Uint8ClampedArray, Int16Array,
            Uint16Array, Int32Array, Uint32Array, Float32Array, Float64Array];
        constructors.every(function(TA) {
            var b = TA.BYTES_PER_ELEMENT, buf = new ArrayBuffer(b * 4);
            function range(f) { try { f(); return false; } catch(e) { return e instanceof RangeError; } }
            return range(function(){ new TA(-1); }) &&
                range(function(){ new TA(Infinity); }) &&
                range(function(){ new TA(buf, -1); }) &&
                range(function(){ new TA(buf, b * 5); }) &&
                range(function(){ new TA(buf, b, 4); }) &&
                (b === 1 || range(function(){ new TA(buf, 1); })) &&
                new TA(buf, {valueOf(){return b;}}, undefined).length === 3 &&
                new TA('2.9').length === 2 && new TA(true).length === 1 &&
                new TA(NaN).length === 0;
        });
    `).(bool), true)
}

@(test)
typedarray_set_observable_order_and_partial_writes :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var log = [], sentinel = {}, a = new Float64Array([1,2,3]);
        var src = {
            get length() { log.push('length'); return {valueOf(){log.push('len'); return 3;}}; },
            get 0() { log.push('zero'); return {valueOf(){log.push('num'); return 7;}}; },
            get 1() { log.push('one'); throw sentinel; },
            get 2() { log.push('two'); return 9; }
        };
        var caught = false;
        try { a.set(src, {valueOf(){log.push('off'); return 0;}}); }
        catch(e) { caught = e === sentinel; }
        caught && log.join(',') === 'off,length,len,zero,num,one' &&
            a[0] === 7 && a[1] === 2 && a[2] === 3;
    `).(bool), true)
}

@(test)
typedarray_set_overflow_is_atomic :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var a = new Uint8Array([1,2]), read = false, caught = false;
        try { a.set({length: 3, get 0(){read = true; return 9;}}); }
        catch(e) { caught = e instanceof RangeError; }
        var order = '';
        try { a.set({get length(){order += 'l'; return 0;}}, Infinity); }
        catch(e) { order += e instanceof RangeError ? 'r' : 'x'; }
        caught && !read && a.join(',') === '1,2' && order === 'lr';
    `).(bool), true)
}

@(test)
typedarray_set_primitives_and_overlap :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var a = new Uint8Array([1,2,3,4,5]);
        a.set('678', 1); a.set(true); a.set(Symbol());
        var primitive = a.join(',') === '1,6,7,8,5';
        a.set(a.subarray(0, 4), 1);
        var same = a.join(',') === '1,1,6,7,8';
        var buffer = new ArrayBuffer(8), bytes = new Uint8Array(buffer);
        bytes.set([1,2,3,4]);
        new Uint16Array(buffer).set(bytes.subarray(0, 4));
        primitive && same && new Uint16Array(buffer).join(',') === '1,2,3,4';
    `).(bool), true)
}

@(test)
typedarray_element_conversion_and_ties_to_even :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var a = new Uint8Array(1), count = 0;
        a[0] = {valueOf(){count++; return 257;}};
        var good = count === 1 && a[0] === 1;
        [Symbol(), 1n, {valueOf(){return Symbol();}}, {valueOf(){return 1n;}}].forEach(function(v) {
            var caught = false;
            try { a.set([v]); } catch(e) { caught = e instanceof TypeError; }
            good = good && caught && a[0] === 1;
        });
        good && new Uint8ClampedArray([0.5,1.5,2.5,3.5,254.5]).join(',') === '0,2,2,4,254';
    `).(bool), true)
}

@(test)
typedarray_constructor_iterable_getters_and_errors :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var log = '', i = 0;
        var src = { [Symbol.iterator]() { return {next() {
            var n = i++;
            return {get done(){log += 'd'; return n === 2;},
                get value(){log += 'v'; return {valueOf(){log += 'n'; return n+4;}};}};
        }}; }};
        var a = new Uint8Array(src);
        var good = a.join(',') === '4,5' && log === 'dvdvdnn';
        [{[Symbol.iterator]: 1}, {[Symbol.iterator](){return 1;}},
            {[Symbol.iterator](){return {next(){return 1;}};}}].forEach(function(v) {
            var caught = false;
            try { new Uint8Array(v); } catch(e) { caught = e instanceof TypeError; }
            good = good && caught;
        });
        good;
    `).(bool), true)
}

@(test)
typedarray_same_kind_copy_preserves_nan_bits :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var b = new ArrayBuffer(4), bytes = new Uint8Array(b);
        bytes.set([1,0,192,127]);
        var src = new Float32Array(b), dst = new Float32Array(1);
        dst.set(src);
        new Uint8Array(dst.buffer).join(',') === '1,0,192,127' &&
            new Uint8Array(new Float32Array(src).buffer).join(',') === '1,0,192,127';
    `).(bool), true)
}

@(test)
typedarray_detachment_during_conversion :: proc(t: ^testing.T) {
    res := run_js262([]string{`
        var b = new ArrayBuffer(4), a = new Uint8Array(b), caught = false;
        try { new Uint8Array(b, {valueOf(){$262.detachArrayBuffer(b); return 0;}}); }
        catch(e) { caught = e instanceof TypeError; }
        if (!caught || a.length !== 0 || a[0] !== undefined) throw Error('detach');
        caught = false;
        try { a.set([]); } catch(e) { caught = e instanceof TypeError; }
        if (!caught) throw Error('set detached');
        b = new ArrayBuffer(2); a = new Uint8Array(b);
        a.set([{valueOf(){$262.detachArrayBuffer(b); return 1;}}]);
        if (a[0] !== undefined) throw Error('write detached');
    `})
    testing.expect(t, !res.threw, res.err_msg)
}
