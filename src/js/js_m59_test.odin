package js

// M59 (grupo 1 das sondas): Date completo, Number.prototype + estáticos,
// Array moderno (flat/flatMap/fill/at/findLast/copyWithin/of/iteradores) e
// Promise.prototype.finally. Rodar: odin test src/js

import "core:testing"

// ── Date ──────────────────────────────────────────────────────────────────────

@(test)
test_date_epoch_zero :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`new Date(0).toISOString()`).(string), "1970-01-01T00:00:00.000Z")
}

@(test)
test_date_from_parts :: proc(t: ^testing.T) {
    // mês é 0-based: 6 = julho. 2026-07-10 foi uma sexta (getDay 5).
    testing.expect_value(t, run(`
        var d = new Date(2026, 6, 10, 12, 30, 45, 250);
        d.getFullYear() + '-' + d.getMonth() + '-' + d.getDate() + ' ' +
        d.getDay() + ' ' + d.getHours() + ':' + d.getMinutes() + ':' +
        d.getSeconds() + '.' + d.getMilliseconds()
    `).(string), "2026-6-10 5 12:30:45.250")
}

@(test)
test_date_iso_roundtrip :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var d = new Date('2026-07-10T08:05:03.021Z');
        d.toISOString()
    `).(string), "2026-07-10T08:05:03.021Z")
}

@(test)
test_date_parse :: proc(t: ^testing.T) {
    // 2026-01-01 00:00Z em ms + data inválida = NaN
    testing.expect_value(t, run(`
        Date.parse('1970-01-02') === 86400000 &&
        isNaN(Date.parse('não é data'))
    `).(bool), true)
}

@(test)
test_date_parse_offset :: proc(t: ^testing.T) {
    // -03:00 → 3h a mais em UTC
    testing.expect_value(t, run(`
        Date.parse('1970-01-01T00:00:00-03:00') === 3 * 3600 * 1000
    `).(bool), true)
}

@(test)
test_date_now_and_gettime :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var d = new Date();
        var ok1 = d.getTime() > 1700000000000; // depois de 2023
        var ok2 = Math.abs(Date.now() - d.getTime()) < 5000;
        var ok3 = d.getFullYear() >= 2026;
        ok1 && ok2 && ok3
    `).(bool), true)
}

@(test)
test_date_copy_settime_month_overflow :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var d = new Date(0);
        d.setTime(86400000);
        var d2 = new Date(d);
        var ovf = new Date(2025, 12, 1); // mês 12 transborda p/ jan/2026
        d2.getTime() + ':' + ovf.getFullYear() + ':' + ovf.getMonth()
    `).(string), "86400000:2026:0")
}

@(test)
test_date_hidden_from_json :: proc(t: ^testing.T) {
    // o "#t" interno não vaza (chave privada); getUTC* = get* (local==UTC)
    testing.expect_value(t, run(`
        var d = new Date(0);
        JSON.stringify({d: 1}) + ':' + Object.keys(d).length + ':' +
        (d.getUTCHours() === d.getHours())
    `).(string), `{"d":1}:0:true`)
}

// ── Number ────────────────────────────────────────────────────────────────────

@(test)
test_number_to_fixed :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`(3.14159).toFixed(2)`).(string), "3.14")
    testing.expect_value(t, run(`(1.005).toFixed(0)`).(string), "1")
    testing.expect_value(t, run(`(-2.5).toFixed(1)`).(string), "-2.5")
    testing.expect_value(t, run(`(42).toFixed(2)`).(string), "42.00")
}

@(test)
test_number_to_string_radix :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`(255).toString(16)`).(string), "ff")
    testing.expect_value(t, run(`(5).toString(2)`).(string), "101")
    testing.expect_value(t, run(`(-255).toString(16)`).(string), "-ff")
    testing.expect_value(t, run(`(35).toString(36)`).(string), "z")
    testing.expect_value(t, run(`(3.5).toString(2)`).(string), "11.1")
    testing.expect_value(t, run(`(42).toString()`).(string), "42")
}

@(test)
test_number_statics :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        Number.isInteger(5) && !Number.isInteger(5.5) && !Number.isInteger('5') &&
        Number.isFinite(1) && !Number.isFinite(Infinity) && !Number.isFinite('1') &&
        Number.isNaN(NaN) && !Number.isNaN('x') &&
        Number.MAX_SAFE_INTEGER === 9007199254740991 &&
        Number.parseInt('42px') === 42 &&
        Number.EPSILON > 0
    `).(bool), true)
}

// ── Array moderno ─────────────────────────────────────────────────────────────

@(test)
test_array_flat :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`[1,[2,[3,[4]]]].flat().length`).(f64), f64(3))       // depth 1
    testing.expect_value(t, run(`[1,[2,[3,[4]]]].flat(Infinity).join('')`).(string), "1234")
}

@(test)
test_array_flat_map :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`[1,2,3].flatMap(function(x){ return [x, x*10]; }).join(',')`).(string), "1,10,2,20,3,30")
}

@(test)
test_array_fill :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`[1,2,3,4].fill(0, 1, 3).join('')`).(string), "1004")
    testing.expect_value(t, run(`Array(3).fill('x').join('')`).(string), "xxx")
}

@(test)
test_array_at_findlast :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var a = [1,2,3,4];
        a.at(-1) + ':' + a.at(0) + ':' +
        a.findLast(function(x){ return x % 2 === 1; }) + ':' +
        a.findLastIndex(function(x){ return x % 2 === 1; })
    `).(string), "4:1:3:2")
}

@(test)
test_array_copy_within :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`[1,2,3,4,5].copyWithin(0, 3).join('')`).(string), "45345")
}

@(test)
test_array_of_and_iterators :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var ks = [], es = [];
        for (var k of ['a','b'].keys()) ks.push(k);
        for (var e of ['a','b'].entries()) es.push(e[0] + e[1]);
        var vs = [...['x','y'].values()];
        Array.of(7,8).join('') + ':' + ks.join('') + ':' + es.join(',') + ':' + vs.join('')
    `).(string), "78:01:0a,1b:xy")
}

// ── Promise.finally ───────────────────────────────────────────────────────────

@(test)
test_promise_finally_on_resolve :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var log = [];
        Promise.resolve(42)
            .finally(function(){ log.push('fin'); })
            .then(function(v){ log.push('v' + v); });
        log.join(',')
    `).(string), "fin,v42")
}

@(test)
test_promise_finally_on_reject :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var log = [];
        Promise.reject('erro')
            .finally(function(){ log.push('fin'); })
            .catch(function(e){ log.push('c' + e); });
        log.join(',')
    `).(string), "fin,cerro")
}

@(test)
test_promise_finally_callback_throw :: proc(t: ^testing.T) {
    // exceção no cb do finally rejeita a derivada (substitui o valor)
    testing.expect_value(t, run(`
        var got = '';
        Promise.resolve(1)
            .finally(function(){ throw 'boom'; })
            .catch(function(e){ got = e; });
        got
    `).(string), "boom")
}
