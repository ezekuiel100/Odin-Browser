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
