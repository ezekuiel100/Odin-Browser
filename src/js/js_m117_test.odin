package js

import "core:testing"

// M117 — Streams API mínima (ReadableStream + reader/asyncIterator). Bundles
// evergreen (docker/medium/shopify no gap-report limpo) fazem `new ReadableStream`
// incondicional → "is not a constructor". As reações de read() são microtasks:
// o resultado é lido numa 2ª tarefa (`run_settled`), depois do checkpoint.

@(test)
m117_readable_stream_is_constructor :: proc(t: ^testing.T) {
    r := run(`typeof ReadableStream === 'function' && (new ReadableStream({}) instanceof Object)`)
    ok, _ := r.(bool)
    testing.expect(t, ok, "new ReadableStream não lança e é objeto")
}

@(test)
m117_reader_reads_enqueued :: proc(t: ^testing.T) {
    // start() enfileira 2 chunks + fecha; o reader lê os dois e depois done.
    r := run_settled(`
        var rs = new ReadableStream({
            start: function(c){ c.enqueue('a'); c.enqueue('b'); c.close(); }
        });
        var out = [];
        var rd = rs.getReader();
        var done = false;
        rd.read().then(function(r1){ out.push(r1.value);
          return rd.read(); }).then(function(r2){ out.push(r2.value);
          return rd.read(); }).then(function(r3){ done = r3.done; });
    `, "out.join(',') + '|' + done")
    s, _ := r.(string)
    testing.expect_value(t, s, "a,b|true")
}

@(test)
m117_async_iterator :: proc(t: ^testing.T) {
    // for-await sobre um ReadableStream.
    // ⚠️ DEGRADAÇÃO conhecida: o for-await ainda usa o await BLOQUEANTE
    // (promise_await_blocking), então `sum` já vale 6 na MESMA tarefa — pela spec
    // seria 0 ali. Lido na 2ª tarefa para não codificar esse desvio.
    r := run_settled(`
        var rs = new ReadableStream({
            start: function(c){ c.enqueue(1); c.enqueue(2); c.enqueue(3); c.close(); }
        });
        var sum = 0;
        (async function(){
            for await (var x of rs) { sum += x; }
        })();
    `, "sum")
    testing.expect_value(t, as_number(r), f64(6))
}

@(test)
m117_pull_source :: proc(t: ^testing.T) {
    // fonte que produz via pull() (síncrono): 1 chunk por pull, fecha no 3º.
    r := run_settled(`
        var n = 0;
        var rs = new ReadableStream({
            pull: function(c){ n++; if (n <= 2) c.enqueue(n); else c.close(); }
        });
        var rd = rs.getReader();
        var got = [];
        rd.read().then(function(a){ got.push(a.done ? 'D' : a.value);
          return rd.read(); }).then(function(b){ got.push(b.done ? 'D' : b.value);
          return rd.read(); }).then(function(cc){ got.push(cc.done ? 'D' : cc.value); });
    `, "got.join(',')")
    s, _ := r.(string)
    testing.expect_value(t, s, "1,2,D")
}

@(test)
m117_tee_and_cancel :: proc(t: ^testing.T) {
    // tee() devolve dois streams; cancel() não lança.
    r := run(`
        var rs = new ReadableStream({ start: function(c){ c.enqueue('x'); c.close(); } });
        var pair = rs.tee();
        var ok = Array.isArray(pair) && pair.length === 2;
        var rs2 = new ReadableStream({});
        var noThrow = true;
        try { rs2.cancel('bye'); } catch(e){ noThrow = false; }
        ok && noThrow
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "tee devolve par; cancel não lança")
}

@(test)
m117_transform_and_writable :: proc(t: ^testing.T) {
    // TransformStream/WritableStream existem e têm o shape esperado.
    r := run(`
        var ts = new TransformStream();
        var hasRW = (typeof ts.readable === 'object') && (typeof ts.writable === 'object');
        var ws = new WritableStream({});
        var w = ws.getWriter();
        var okW = (typeof w.write === 'function') && (typeof w.close === 'function');
        hasRW && okW
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "TransformStream.readable/writable + WritableStream.getWriter")
}

@(test)
m117_encoding_streams :: proc(t: ^testing.T) {
    // TextEncoderStream/TextDecoderStream existem e têm shape transform.
    r := run(`
        var es = new TextEncoderStream();
        var ds = new TextDecoderStream();
        (typeof TextEncoderStream === 'function') &&
        (typeof TextDecoderStream === 'function') &&
        (typeof es.readable === 'object') && (typeof es.writable === 'object') &&
        (es.encoding === 'utf-8') && (typeof ds.writable === 'object')
    `)
    ok, _ := r.(bool)
    testing.expect(t, ok, "TextEncoder/DecoderStream constroem e têm readable/writable/encoding")
}
