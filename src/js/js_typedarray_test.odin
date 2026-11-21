package js

// M69 (2026-07-10): TypedArrays, ArrayBuffer, DataView + crypto.getRandomValues/
// randomUUID + Array.from(iterável) + Date.now() inteiro. Descobertos atacando o
// ultra-photo: `Uint8Array` faltando (uuidv7 `new ms([...])`), depois uma cadeia
// (performance.now, crypto, Date.now não-inteiro fazia uuidv7 lançar RangeError).

import "core:testing"

// ── construção + acesso indexado com semântica de tipo ───────────────────────

@(test)
test_uint8array_wrap :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        Array.from(new Uint8Array([0, 127, 255, 256, -1])).join(',')
    `).(string), "0,127,255,0,255")
}

@(test)
test_uint8_clamped :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        Array.from(new Uint8ClampedArray([-5, 128, 300])).join(',')
    `).(string), "0,128,255")
}

@(test)
test_int16_signed_wrap :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        Array.from(new Int16Array([32767, 32768, -32769])).join(',')
    `).(string), "32767,-32768,32767")
}

@(test)
test_float32 :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var f = new Float32Array([1.5, -2.25]); f[0] + ',' + f[1]
    `).(string), "1.5,-2.25")
}

@(test)
test_index_assign_wraps :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var u = new Uint8Array(1); u[0] = 300; u[0]
    `).(f64), f64(44))
}

// ── ArrayBuffer + views compartilhadas (little-endian) ───────────────────────

@(test)
test_shared_buffer_little_endian :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var buf = new ArrayBuffer(4);
        var u8 = new Uint8Array(buf), u32 = new Uint32Array(buf);
        u8[0] = 1; u8[1] = 0; u8[2] = 0; u8[3] = 0;
        (u32[0] === 1) && (u8.buffer === buf) && (buf.byteLength === 4)
    `).(bool), true)
}

@(test)
test_byteoffset_view :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var v = new Uint8Array(new ArrayBuffer(8), 4, 2);
        v.byteOffset + '|' + v.length + '|' + v.byteLength
    `).(string), "4|2|2")
}

// ── set / subarray (compartilha) / slice (copia) / fill ──────────────────────

@(test)
test_set_subarray_slice :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var t = new Uint8Array(5);
        t.set([10,20,30], 1);
        var sub = t.subarray(1, 4);  sub[0] = 99;   // compartilha
        var sl  = t.slice(1, 3);     sl[0] = 7;      // copia
        Array.from(t).join(',') + '|' + Array.from(sub).join(',')
    `).(string), "0,99,20,30,0|99,20,30")
}

@(test)
test_fill :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        Array.from(new Uint8Array(5).fill(7, 1, 3)).join(',')
    `).(string), "0,7,7,0,0")
}

// ── métodos iterativos + for-of + instanceof ─────────────────────────────────

@(test)
test_ta_map_reduce_join :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var m = new Uint8Array([1,2,3]).map(function(x){ return x*2; });
        Array.from(m).join(',') + '|' +
        new Uint8Array([1,2,3,4]).reduce(function(a,b){return a+b;}, 0) + '|' +
        new Uint8Array([5,6,7]).indexOf(6)
    `).(string), "2,4,6|10|1")
}

@(test)
test_ta_for_of :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var acc = [];
        for (var x of new Uint8Array([9,8,7])) acc.push(x);
        acc.join(',')
    `).(string), "9,8,7")
}

@(test)
test_ta_instanceof_and_bpe :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var u = new Uint8Array(1);
        (u instanceof Uint8Array) && !(u instanceof Int8Array) && (Uint32Array.BYTES_PER_ELEMENT === 4)
    `).(bool), true)
}

@(test)
test_ta_from_of :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        Array.from(Uint8Array.from([1,2,3], function(x){return x+10;})).join(',') + '|' +
        Array.from(Uint8Array.of(4,5,6)).join(',')
    `).(string), "11,12,13|4,5,6")
}

// ── DataView (endianness) ────────────────────────────────────────────────────

@(test)
test_dataview_endianness :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var dv = new DataView(new ArrayBuffer(8));
        dv.setUint16(0, 0x1234);              // big-endian default
        var be = (dv.getUint8(0) === 0x12) && (dv.getUint16(0) === 0x1234);
        dv.setUint32(0, 0xDEADBEEF, true);    // little-endian
        var le = dv.getUint32(0, true) === 0xDEADBEEF;
        dv.setFloat64(0, 3.5);
        be && le && (dv.getFloat64(0) === 3.5)
    `).(bool), true)
}

// ── crypto + Date.now inteiro (uuidv7) ───────────────────────────────────────

@(test)
test_crypto_get_random_values :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var a = new Uint8Array(16);
        var same = a; var ret = crypto.getRandomValues(a);
        (ret === same) && a.every(function(x){ return x >= 0 && x <= 255 && Number.isInteger(x); })
    `).(bool), true)
}

@(test)
test_crypto_random_uuid_shape :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var u = crypto.randomUUID();
        (u.length === 36) && (u[14] === '4') && (u.split('-').length === 5)
    `).(bool), true)
}

@(test)
test_date_now_is_integer :: proc(t: ^testing.T) {
    // uuidv7 faz Number.isInteger(Date.now()); o fracionário de sub-ms quebrava
    testing.expect_value(t, run(`Number.isInteger(Date.now())`).(bool), true)
}

// ── set() com offset negativo: RangeError, não escrita OOB ───────────────────
// Test262 built-ins/TypedArray/prototype/set achou o bug: `.set(src, -2)` só
// checava o teto (off+i < len), então o índice de byte virava negativo e o
// wr_u32 escrevia fora do buffer (crash / corrupção). Agora lança RangeError.
@(test)
test_ta_set_negative_offset_throws :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var a = new Int32Array(4);
        var threw = false, name = '';
        try { a.set([1,2], -2); } catch (e) { threw = true; name = e.name; }
        threw && name === 'RangeError'
    `).(bool), true)
}

// offset válido continua funcionando (não quebramos o caminho feliz)
@(test)
test_ta_set_valid_offset :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var a = new Int32Array(4);
        a.set([7,8], 1);
        a.join(',')
    `).(string), "0,7,8,0")
}

// ── Array.from de iterável genérico ──────────────────────────────────────────

@(test)
test_array_from_iterable :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        function* g(){ yield 1; yield 2; yield 3; }
        Array.from(g()).join(',') + '|' + Array.from(new Set([4,4,5])).join(',')
    `).(string), "1,2,3|4,5")
}

@(test)
test_ta_at_relative_indices :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var a = new Int16Array([10,20,30]);
        a.at() === 10 && a.at(-1) === 30 && a.at(-1.9) === 30 &&
        a.at(NaN) === 10 && a.at({valueOf:function(){return 1;}}) === 20 &&
        a.at(-4) === undefined && a.at(3) === undefined &&
        a.at(Infinity) === undefined && a.at(-Infinity) === undefined &&
        new Uint8Array().at(0) === undefined
    `).(bool), true)
}

@(test)
test_ta_find_methods_direction_and_this :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var a = new Uint8Array([2,7,4,7]), seen = [], ctx = {limit:4};
        var result = a.findLast(function(v,i,source) {
            seen.push(i); return this === ctx && source === a && v < this.limit;
        }, ctx);
        result === 2 && seen.join() === '3,2,1,0' &&
        a.findLastIndex(function(v){return v === 7;}) === 3 &&
        a.findIndex(function(v){return v === 7;}) === 1 &&
        a.find(function(v){return v > 3;}) === 7 &&
        a.findLast(function(){return false;}) === undefined &&
        a.findLastIndex(function(){return false;}) === -1 &&
        new Uint8Array().findIndex(function(){return true;}) === -1
    `).(bool), true)
}

@(test)
test_ta_search_equality_and_from_index :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var a = new Float64Array([1,2,1,NaN]);
        a.indexOf(1,1) === 2 && a.indexOf(1,-2) === 2 &&
        a.indexOf(1,Infinity) === -1 && a.indexOf(1,-Infinity) === 0 &&
        a.lastIndexOf(1) === 2 && a.lastIndexOf(1,undefined) === 0 &&
        a.lastIndexOf(1,-3) === 0 && a.lastIndexOf(1,-5) === -1 &&
        a.lastIndexOf(1,Infinity) === 2 && a.lastIndexOf(1,-Infinity) === -1 &&
        a.indexOf('1') === -1 && !a.includes('1') &&
        a.includes(NaN) && a.indexOf(NaN) === -1 && a.lastIndexOf(NaN) === -1 &&
        !a.includes(1,3) && !new Uint8Array().includes(0)
    `).(bool), true)
}

@(test)
test_ta_copy_within_overlap_and_view :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var a = new Uint16Array([99,1,2,3,4,88]), v = a.subarray(1,5);
        var same = v.copyWithin(1,0,3) === v;
        var first = a.join();
        v.copyWithin(0,2);
        var second = a.join();
        v.copyWithin(-1,-4,-3);
        same && first === '99,1,1,2,3,88' && second === '99,2,3,2,3,88' &&
        a.join() === '99,2,3,2,2,88' && v.copyWithin(Infinity,0) === v &&
        v.copyWithin(0,0,-Infinity) === v
    `).(bool), true)
}

@(test)
test_ta_copy_methods_preserve_kind_and_source :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var kinds = [Int8Array,Uint8Array,Uint8ClampedArray,Int16Array,Uint16Array,
                     Int32Array,Uint32Array,Float32Array,Float64Array];
        kinds.every(function(C) {
            var a = new C([3,1,2]), r = a.toReversed(), s = a.toSorted(), w = a.with(-1,9);
            return r instanceof C && s instanceof C && w instanceof C &&
                r.buffer !== a.buffer && s.buffer !== a.buffer && w.buffer !== a.buffer &&
                r.join() === '2,1,3' && s.join() === '1,2,3' && w.join() === '3,1,9' &&
                a.join() === '3,1,2';
        }) && new Uint8Array([1]).with(0,257)[0] === 1 &&
        new Uint8Array().toSorted().length === 0 && new Uint8Array().toReversed().length === 0
    `).(bool), true)
}

@(test)
test_ta_to_sorted_numeric_and_comparator :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var a = new Float64Array([NaN,10,2,0,-0,-3,NaN]), s = a.toSorted();
        var stable = new Uint8Array([4,1,3,2]).toSorted(function(){return NaN;});
        s[0] === -3 && 1/s[1] === -Infinity && 1/s[2] === Infinity &&
        s[3] === 2 && s[4] === 10 && Number.isNaN(s[5]) && Number.isNaN(s[6]) &&
        a.toSorted(function(a,b){return b-a;}).length === 7 &&
        new Uint8Array([2,10,1]).toSorted(function(a,b){return b-a;}).join() === '10,2,1' &&
        stable.join() === '4,1,3,2' && Number.isNaN(a[0])
    `).(bool), true)
}

@(test)
test_ta_reduce_right_order_and_initial :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var a = new Uint8Array([1,2,3]), seen = [];
        var r = a.reduceRight(function(acc,v,i,source) {
            seen.push(i); return source === a ? acc-v : 999;
        });
        r === 0 && seen.join() === '1,0' &&
        a.reduceRight(function(acc,v){return acc+v;},10) === 16 &&
        new Uint8Array().reduceRight(function(){return 99;},undefined) === undefined
    `).(bool), true)
}

@(test)
test_ta_new_method_errors :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var a = new Uint8Array([1,2]), errors = [];
        function check(f) { try { f(); } catch(e) { errors.push(e.name); } }
        check(function(){a.with(2,0);});
        check(function(){a.with(-3,0);});
        check(function(){a.with(Infinity,0);});
        check(function(){new Uint8Array().with(0,0);});
        check(function(){a.toSorted(null);});
        check(function(){new Uint8Array().findLast(null);});
        check(function(){a.findIndex(1);});
        check(function(){a.reduceRight(null);});
        check(function(){new Uint8Array().reduceRight(function(){});});
        check(function(){Uint8Array.prototype.at.call({},0);});
        errors.join() === 'RangeError,RangeError,RangeError,RangeError,TypeError,TypeError,TypeError,TypeError,TypeError,TypeError'
    `).(bool), true)
}

@(test)
test_ta_callback_exceptions_stop_iteration :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var a = new Uint8Array([1,2,3]), count = 0, caught = 0, marker = {};
        function fail() { count++; throw marker; }
        try { a.findLast(fail); } catch(e) { if(e === marker) caught++; }
        try { a.findIndex(fail); } catch(e) { if(e === marker) caught++; }
        try { a.reduceRight(fail); } catch(e) { if(e === marker) caught++; }
        try { a.toSorted(fail); } catch(e) { if(e === marker) caught++; }
        count === 4 && caught === 4 && a.join() === '1,2,3'
    `).(bool), true)
}

@(test)
test_ta_locale_string_dispatch :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var original = Number.prototype.toLocaleString;
        Number.prototype.toLocaleString = function(locale) { return locale + ':' + this; };
        var result = new Uint8Array([1,2]).toLocaleString('pt');
        Number.prototype.toLocaleString = original;
        result === 'pt:1,pt:2' && new Uint8Array().toLocaleString() === ''
    `).(bool), true)
}

@(test)
test_ta_copy_within_preserves_nan_bytes :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var buffer = new ArrayBuffer(12), bits = new Uint32Array(buffer);
        bits.set([0x7fc12345,0x80000000,0]);
        new Float32Array(buffer).copyWithin(1,0,2);
        bits[0] === 0x7fc12345 && bits[1] === 0x7fc12345 && bits[2] === 0x80000000
    `).(bool), true)
}

@(test)
test_ta_with_coercion_order :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var a = new Uint8Array([1,2]), seen = [], marker = {};
        var index = {valueOf:function(){seen.push('index'); return 8;}};
        var value = {valueOf:function(){seen.push('value'); throw marker;}};
        var caught = false;
        try { a.with(index,value); } catch(e) { caught = e === marker; }
        caught && seen.join() === 'index,value' && a.join() === '1,2'
    `).(bool), true)
}
