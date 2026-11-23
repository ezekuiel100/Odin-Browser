package js

import "core:testing"

@(test)
typedarray_bigint_precision_and_content_types :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var a = new BigInt64Array([9007199254740993n, -1n, 18446744073709551617n]);
        var b = new BigUint64Array(a);
        var ok = a[0] === 9007199254740993n && a[2] === 1n &&
            b[1] === 18446744073709551615n && BigInt64Array.BYTES_PER_ELEMENT === 8;
        var bad = 0;
        [function(){new BigInt64Array([1]);}, function(){new Uint8Array(a);},
         function(){a.set(new Uint8Array(0));}, function(){a[0] = undefined;}].forEach(function(f){
            try { f(); } catch(e) { if(e instanceof TypeError) bad++; }
        });
        a[1] = {valueOf(){return '18446744073709551615';}};
        ok && bad === 4 && a[1] === -1n;
    `).(bool), true)
}

@(test)
typedarray_bigint_methods_preserve_values :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var a = BigInt64Array.of(3n, 9007199254740993n, -2n);
        var b = a.map(function(x){return x + 1n;}).filter(function(x){return x > 0n;});
        var c = a.toSorted(), d = a.with(0, '7');
        a.set(a.subarray(0, 2), 1);
        b.join() === '4,9007199254740994' && c.join() === '-2,3,9007199254740993' &&
            d[0] === 7n && a.join() === '3,3,9007199254740993' &&
            a.includes(3n) && !a.includes(3) && a.indexOf(9007199254740993n) === 2 &&
            a.reduce(function(x,y){return x+y;}, 0n) === 9007199254740999n &&
            a.toReversed()[0] === 9007199254740993n && Array.from(a)[1] === 3n;
    `).(bool), true)
}

@(test)
typedarray_float16_rounding_and_bits :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var a = new Float16Array([1.00048828125, 1.00146484375, 65520, -0, Math.pow(2,-24), Math.pow(2,-25), NaN]);
        var bits = new Uint16Array(a.buffer);
        a.BYTES_PER_ELEMENT === 2 && a[0] === 1 && a[1] === 1.001953125 &&
            a[2] === Infinity && Object.is(a[3], -0) && a[4] === Math.pow(2,-24) &&
            a[5] === 0 && Number.isNaN(a[6]) && bits[0] === 15360 && bits[3] === 32768;
    `).(bool), true)
}

@(test)
dataview_modern_elements_and_endianness :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var b = new ArrayBuffer(24), d = new DataView(b);
        d.setBigUint64(1, 18446744073709551615n);
        d.setBigInt64(9, -9007199254740993n, true);
        d.setFloat16(18, 1.00146484375);
        d.getBigInt64(1) === -1n && d.getBigUint64(1, true) === 18446744073709551615n &&
            d.getBigInt64(9, true) === -9007199254740993n && d.getFloat16(18) === 1.001953125 &&
            new Uint8Array(b)[18] === 60;
    `).(bool), true)
}

@(test)
arraybuffer_resize_views_and_zeroing :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var b = new ArrayBuffer(8, {maxByteLength:16}), a = new Uint16Array(b, 2),
            fixed = new Uint16Array(b, 2, 2), d = new DataView(b, 2);
        a.fill(42); b.resize(4);
        var ok = b.resizable && b.maxByteLength === 16 && b.byteLength === 4 &&
            a.length === 1 && fixed.length === 0 && fixed.byteOffset === 0 && d.byteLength === 2;
        b.resize(12);
        ok && a.length === 5 && fixed.length === 2 && fixed[0] === 42 && fixed[1] === 0 &&
            a[4] === 0 && d.byteLength === 10 && d.buffer === b;
    `).(bool), true)
}

@(test)
arraybuffer_transfer_detaches_and_preserves_options :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var b = new ArrayBuffer(4, {maxByteLength:16}), a = new Uint8Array(b), d = new DataView(b);
        a.set([1,2,3,4]); var c = b.transfer(6);
        var caught = false; try {d.getUint8(0);} catch(e){caught = e instanceof TypeError;}
        var ok = b.detached && b.byteLength === 0 && b.maxByteLength === 0 && a.length === 0 &&
            a[0] === undefined && caught && c.resizable && c.maxByteLength === 16 &&
            new Uint8Array(c).join() === '1,2,3,4,0,0';
        var f = c.transferToFixedLength(20);
        ok && c.detached && !f.resizable && f.byteLength === 20 && f.maxByteLength === 20;
    `).(bool), true)
}

@(test)
dataview_bounds_coercion_and_detachment :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var b = new ArrayBuffer(8), d = new DataView(b), errors = 0, log = '';
        [function(){new DataView(b,-1);}, function(){new DataView(b,9);},
         function(){new DataView(b,4,5);}, function(){d.getUint32(Infinity);}].forEach(function(f){
            try{f();}catch(e){if(e instanceof RangeError)errors++;}
        });
        try { d.setUint32({valueOf(){log += 'o'; return 0;}}, {valueOf(){log += 'v'; b.transfer(); return 1;}}); }
        catch(e){if(e instanceof TypeError)errors++;}
        errors === 5 && log === 'ov';
    `).(bool), true)
}

@(test)
typedarray_resize_during_callbacks_uses_initial_length :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var b = new ArrayBuffer(6, {maxByteLength:12}), a = new Uint16Array(b), seen = [];
        var r = a.reduce(function(prev,next,i){
            seen.push(next); if(i === 0)b.resize(2); return i;
        }, 0);
        seen.length === 3 && seen[0] === 0 && seen[1] === undefined && seen[2] === undefined && r === 2;
    `).(bool), true)
}

@(test)
typedarray_resizable_subclass_and_subarray_recovery :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        class View extends BigUint64Array {}
        var b = new ArrayBuffer(24,{maxByteLength:32}), a = new View(b,8), sub = a.subarray(1), fixed = new DataView(b,8,8);
        a[0] = 9007199254740993n; b.resize(4);
        var ok = a.length === 0 && sub.length === 0 && fixed.byteLength === 0 && fixed.byteOffset === 0;
        b.resize(32);
        ok && a.length === 3 && sub.length === 2 && sub.byteOffset === 16 && fixed.byteLength === 8 &&
            a[0] === 0n && a instanceof View;
    `).(bool), true)
}

@(test)
typedarray_resize_during_sort_and_copywithin :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var b = new ArrayBuffer(24,{maxByteLength:24}), a = new BigInt64Array(b);
        a.set([3n,2n,1n]);
        a.sort(function(x,y){b.resize(8);return x < y ? -1 : x > y ? 1 : 0;});
        var ok = a.length === 1 && a[0] === 1n;
        var c = new ArrayBuffer(4,{maxByteLength:4}), u = new Uint8Array(c);
        u.set([1,2,3,4]); u.copyWithin(0, 1, {valueOf(){c.resize(2); return 4;}});
        ok && u.join() === '2,2';
    `).(bool), true)
}

@(test)
typedarray_indexof_ignores_invalidated_elements :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var b = new ArrayBuffer(4), a = new Uint8Array(b);
        a.indexOf(undefined, {valueOf(){b.transfer(); return 0;}}) === -1;
    `).(bool), true)
}
