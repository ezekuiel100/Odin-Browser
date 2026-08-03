package js

// Date setters completos (date.odin): setFullYear/Month/Date/Hours/Minutes/
// Seconds/Milliseconds (+ setUTC* aliases + setYear legado), com transbordo
// (MakeDay/MakeTime) e propagação de NaN. Date é builtin → `run` puro basta.

import "core:testing"

// ── básico + valor de retorno (novo time value) ──────────────────────────────

@(test)
test_date_set_full_year :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var d = new Date(2020, 0, 15);
        d.setFullYear(1999);
        d.getFullYear()
    `).(f64), 1999)
}

@(test)
test_date_setter_returns_time :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var d = new Date(2020, 0, 1);
        d.setFullYear(2021) === d.getTime()
    `).(bool), true)
}

@(test)
test_date_set_full_year_with_month_day :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var d = new Date(2020, 0, 1);
        d.setFullYear(2010, 5, 20); // junho (0-based), dia 20
        d.getFullYear() + "-" + d.getMonth() + "-" + d.getDate()
    `).(string), "2010-5-20")
}

// ── transbordo de mês/dia ────────────────────────────────────────────────────

@(test)
test_date_set_month_overflow :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var d = new Date(2020, 0, 15);
        d.setMonth(12); // 12 (0-based) → janeiro do ano seguinte
        d.getFullYear() + "-" + d.getMonth()
    `).(string), "2021-0")
}

@(test)
test_date_set_date_overflow :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var d = new Date(2020, 0, 31); // janeiro tem 31 dias
        d.setDate(32);                 // → 1 de fevereiro
        d.getMonth() + "-" + d.getDate()
    `).(string), "1-1")
}

@(test)
test_date_set_date_zero_rolls_back :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var d = new Date(2020, 2, 15); // março; 2020 é bissexto
        d.setDate(0);                  // → 29 de fevereiro
        d.getMonth() + "-" + d.getDate()
    `).(string), "1-29")
}

// ── tempo (hours/minutes/seconds/ms) ─────────────────────────────────────────

@(test)
test_date_set_hours_multi :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var d = new Date(2020, 0, 1);
        d.setHours(13, 45, 30, 500);
        d.getHours() + ":" + d.getMinutes() + ":" + d.getSeconds() + "." + d.getMilliseconds()
    `).(string), "13:45:30.500")
}

@(test)
test_date_set_minutes_seconds_ms :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var d = new Date(2020, 0, 1, 10, 0, 0, 0);
        d.setMinutes(5); d.setSeconds(9); d.setMilliseconds(123);
        d.getMinutes() + "," + d.getSeconds() + "," + d.getMilliseconds()
    `).(string), "5,9,123")
}

@(test)
test_date_set_hours_overflow_day :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var d = new Date(2020, 0, 1, 0, 0, 0);
        d.setHours(25); // +1 dia, 1h
        d.getDate() + "-" + d.getHours()
    `).(string), "2-1")
}

// ── setUTC* aliases (local == UTC) ───────────────────────────────────────────

@(test)
test_date_set_utc_full_year :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var d = new Date(2020, 0, 1);
        d.setUTCFullYear(2030);
        d.getUTCFullYear()
    `).(f64), 2030)
}

// ── Invalid Date ─────────────────────────────────────────────────────────────

@(test)
test_date_set_full_year_revives_invalid :: proc(t: ^testing.T) {
    // setFullYear é o único que "revive" uma data Invalid (base = epoch 0)
    testing.expect_value(t, run(`
        var d = new Date(NaN);
        d.setFullYear(2022);
        d.getFullYear() + "-" + d.getMonth() + "-" + d.getDate()
    `).(string), "2022-0-1")
}

@(test)
test_date_set_month_keeps_invalid :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var d = new Date(NaN);
        d.setMonth(5);
        isNaN(d.getTime())
    `).(bool), true)
}

@(test)
test_date_set_hours_no_args_invalid :: proc(t: ^testing.T) {
    // setHours() sem args → hora = ToNumber(undefined) = NaN → Invalid Date
    testing.expect_value(t, run(`
        var d = new Date(2020, 0, 1);
        d.setHours();
        isNaN(d.getTime())
    `).(bool), true)
}

// ── setYear legado ───────────────────────────────────────────────────────────

@(test)
test_date_set_year_legacy :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var d = new Date(2020, 0, 1);
        d.setYear(99);   var a = d.getFullYear(); // 1999
        d.setYear(2015); var b = d.getFullYear(); // 2015
        a + "," + b
    `).(string), "1999,2015")
}

// ── ISO após vários setters ──────────────────────────────────────────────────

@(test)
test_date_setters_iso_roundtrip :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var d = new Date(2020, 0, 1);
        d.setMonth(5); d.setDate(15); d.setHours(8, 0, 0, 0);
        d.toISOString()
    `).(string), "2020-06-15T08:00:00.000Z")
}
