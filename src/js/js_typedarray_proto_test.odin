package js

// %TypedArray%.prototype: o protótipo comum dos nove TypedArrays, com os acessores
// buffer/byteLength/byteOffset/length/@@toStringTag. Não existia — e o
// propertyHelper.js do Test262 atual morria ao carregar lendo
// getOwnPropertyDescriptor(%TypedArray%.prototype, "byteLength").get.

import "core:testing"

@(test)
typedarray_prototipo_comum :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`var TA = Object.getPrototypeOf(Uint8Array.prototype); [TA === Object.getPrototypeOf(Float64Array.prototype), TA !== Object.prototype, Object.getPrototypeOf(TA) === Object.prototype].join()`).(string), "true,true,true")
    testing.expect_value(t, run(`var d = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(Uint8Array.prototype), "byteLength"); [typeof d.get, d.set, d.enumerable, d.configurable, d.get.name].join()`).(string), "function,,false,true,get byteLength")
}

@(test)
typedarray_acessores_do_prototipo :: proc(t: ^testing.T) {
    pre :: `var TA = Object.getPrototypeOf(Uint8Array.prototype), D = function (k) { return Object.getOwnPropertyDescriptor(TA, k).get }; `
    testing.expect_value(t, run(pre + `[D("byteLength").call(new Uint16Array(3)), D("byteLength").call(new Float64Array(new ArrayBuffer(32), 8, 2))].join()`).(string), "6,16")
    testing.expect_value(t, run(pre + `var a = new Int8Array(new ArrayBuffer(8), 2, 4); [D("length").call(a), D("byteOffset").call(a), D("buffer").call(a) === a.buffer].join()`).(string), "4,2,true")
    // receptor que não é view TypedArray: TypeError (inclusive ArrayBuffer e DataView)
    testing.expect_value(t, run(pre + `var r = []; for (var x of [{}, new ArrayBuffer(4), new DataView(new ArrayBuffer(4)), 1]) { try { D("byteLength").call(x); r.push("ok") } catch (e) { r.push(e.name) } } r.join()`).(string), "TypeError,TypeError,TypeError,TypeError")
    // @@toStringTag não lança: undefined fora de uma view
    testing.expect_value(t, run(`var tag = Object.getOwnPropertyDescriptor(Object.getPrototypeOf(Uint8Array.prototype), Symbol.toStringTag).get; [tag.call(new Uint8ClampedArray(1)), String(tag.call({})), Object.prototype.toString.call(new Float32Array(1))].join()`).(string), "Uint8ClampedArray,undefined,[object Float32Array]")
}

// As views não têm mais length/byteLength/byteOffset/buffer PRÓPRIOS (vêm do protótipo):
// Object.keys enumera os índices, não os metadados.
@(test)
typedarray_sem_metadados_proprios :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`var a = new Uint8Array([1,2,3]); [a.length, a.byteLength, a.byteOffset, a.BYTES_PER_ELEMENT, a.buffer instanceof ArrayBuffer].join()`).(string), "3,3,0,1,true")
    testing.expect_value(t, run(`var a = new Uint8Array([1,2,3]); ["length","byteLength","byteOffset","buffer"].map(k => a.hasOwnProperty(k)).join()`).(string), "false,false,false,false")
    testing.expect_value(t, run(`Object.keys(new Uint8Array([1,2,3])).join()`).(string), "0,1,2")
    testing.expect_value(t, run(`var a = new Uint16Array(new ArrayBuffer(16), 4, 3); var s = a.subarray(1); [s.length, s.byteOffset, s.buffer === a.buffer].join()`).(string), "2,6,true")
    testing.expect_value(t, run(`Array.prototype.map.call(new Uint8Array([1,2]), x => x + 1).join()`).(string), "2,3")
}

// `class X extends Uint8Array`: a instância recebe os campos de view do super() (antes
// só as props eram copiadas — os acessores do protótipo lançavam e os índices sumiam).
@(test)
typedarray_subclasse_e_view :: proc(t: ^testing.T) {
    src := `
        class My extends Uint8Array {}
        var buf = new ArrayBuffer(8), a = new My(buf, 2, 3);
        a[0] = 7;
        [a instanceof My, a instanceof Uint8Array, a.buffer === buf, a.byteLength, a.byteOffset, a.length, a[0],
         new Uint8Array(buf)[2], Object.keys(a).join("")].join()
    `
    testing.expect_value(t, run(src).(string), "true,true,true,3,2,3,7,7,012")
}
