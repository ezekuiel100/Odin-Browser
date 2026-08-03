package js

import "core:testing"

// M108 — Blob + requestIdleCallback/cancelIdleCallback FALTAVAM (globais concretos
// que sites usam: Blob p/ downloads/workers/objectURL; rIC p/ adiar init não-crítico).

// ── Blob ──────────────────────────────────────────────────────────────────────

@(test)
m108_blob_ctor_e_size :: proc(t: ^testing.T) {
    r := run(`(typeof Blob) + "," + new Blob(['abc']).size + "," + new Blob(['a','bc','def']).size`)
    s, _ := r.(string)
    testing.expectf(t, s == "function,3,6", "Blob ctor/size: got %q", s)
}

@(test)
m108_blob_type :: proc(t: ^testing.T) {
    r := run(`new Blob(['x'], {type:'text/plain'}).type + "|" + new Blob(['x']).type`)
    s, _ := r.(string)
    testing.expectf(t, s == "text/plain|", "Blob type: got %q", s)
}

@(test)
m108_blob_de_uint8array :: proc(t: ^testing.T) {
    // parte BufferSource: conta os bytes da view
    r := run(`new Blob([new Uint8Array([104,105]), 'x']).size`)
    testing.expectf(t, as_number(r) == 3, "Blob de Uint8Array+string: got %v", r)
}

@(test)
m108_blob_slice :: proc(t: ^testing.T) {
    r := run(`var b = new Blob(['abcdef']).slice(1,4); b.size + "," + (b instanceof Blob ? "blob" : "no")`)
    s, _ := r.(string)
    testing.expectf(t, s == "3,blob", "Blob.slice: got %q", s)
}

@(test)
m108_blob_text :: proc(t: ^testing.T) {
    // text() → Promise<string>; promise resolvida roda o then na hora nesta engine
    r := run(`var out=''; new Blob(['olá']).text().then(function(s){ out = s; }); out`)
    s, _ := r.(string)
    testing.expectf(t, s == "olá", "Blob.text(): got %q", s)
}

@(test)
m108_blob_arraybuffer :: proc(t: ^testing.T) {
    r := run(`var n=-1; new Blob(['hello']).arrayBuffer().then(function(ab){ n = ab.byteLength; }); n`)
    testing.expectf(t, as_number(r) == 5, "Blob.arrayBuffer().byteLength: got %v", r)
}

// ── requestIdleCallback ───────────────────────────────────────────────────────

@(test)
m108_ric_dispara_com_deadline :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var ran = false, rem = -1, timedOut = null;
        requestIdleCallback(function(dl){
            ran = true;
            rem = dl.timeRemaining();
            timedOut = dl.didTimeout;
        });
    `)
    testing.expect(t, !truthy(vm_run(vm, "ran")), "rIC não roda antes do pump")
    vm_pump_timers(vm, 20)
    testing.expect(t, truthy(vm_run(vm, "ran")), "rIC deve disparar no pump")
    testing.expect(t, as_number(vm_run(vm, "rem")) > 0, "deadline.timeRemaining() > 0")
    testing.expect(t, !truthy(vm_run(vm, "timedOut")), "didTimeout === false")
}

@(test)
m108_cancel_idle_callback :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `var ran = false; var id = requestIdleCallback(function(){ ran = true; }); cancelIdleCallback(id);`)
    vm_pump_timers(vm, 20)
    testing.expect(t, !truthy(vm_run(vm, "ran")), "cancelIdleCallback deve impedir o disparo")
}
