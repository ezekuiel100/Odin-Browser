package js

import "core:testing"

// ── toFixed / toExponential / toPrecision e fuso local do Date (21/11/2026) ──
// Antes: o printf arredondava empate PARA O PAR ((2.5).toFixed(0) → "2"),
// toExponential não existia, e a Date era UTC pura (getTimezoneOffset() = 0).

// Os testes do pacote rodam com o fuso FIXO em UTC: os testes antigos de Date
// assumem local == UTC, e um teste não pode depender do fuso da máquina. Quem
// quer outro fuso usa `with_tz` (override por thread).
@(init)
tests_tz_utc :: proc "contextless" () {
    tz_override.active = true
    tz_override.info = TZ_UTC
}

@(private = "file")
expect_str :: proc(t: ^testing.T, src, want: string, loc := #caller_location) {
    v, ok := run(src).(string)
    testing.expectf(t, ok && v == want, "%s\n  esperado %q, veio %v", src, want, run(src), loc = loc)
}

// UTC-3 sem verão (o Brasil de hoje)
@(private = "file")
TZ_BRT :: Tz_Info{std_min = -180, dst_min = -180, std_name = "BRT", dst_name = "BRT"}

// EUA (Nova York): -5/-4, verão do 2º domingo de março 02:00 ao 1º domingo de novembro 02:00
@(private = "file")
TZ_NY :: Tz_Info{
    std_min = -300, dst_min = -240, has_dst = true,
    to_dst = {month = 3, week = 2, wday = 0, hour = 2},
    to_std = {month = 11, week = 1, wday = 0, hour = 2},
    std_name = "EST", dst_name = "EDT",
}

@(private = "file")
with_tz :: proc(info: Tz_Info) {
    tz_override_thread = Tz_Override{active = true, info = info, iana = "Test/Zone"}
}

@(private = "file")
end_tz :: proc() { tz_override_thread = {} }

// ── números ──

@(test)
test_number_to_string_radix_and_non_finite_values :: proc(t: ^testing.T) {
    expect_str(t, `[Infinity.toString(2), (-Infinity).toString(36),
        NaN.toString(16), (-0).toString(2), new Number(255).toString({valueOf() { return 16.9; }})].join()`,
        "Infinity,-Infinity,NaN,0,ff")
    expect_str(t, `
        function errorName(f) { try { f(); } catch (e) { return e.name; } }
        [errorName(() => Infinity.toString(1)), errorName(() => NaN.toString(Infinity)),
         errorName(() => Number.prototype.toString.call("2")), errorName(() => (2).toString(null))].join();
    `, "RangeError,RangeError,TypeError,RangeError")
}

@(test)
test_to_fixed_empate_para_cima :: proc(t: ^testing.T) {
    expect_str(t, `[(2.5).toFixed(0), (0.5).toFixed(0), (-2.5).toFixed(0), (1.25).toFixed(1)].join()`, "3,1,-3,1.3")
    // não é empate: o double de 1.005 é 1.00499999999999989…
    expect_str(t, `[(1.005).toFixed(2), (8.345).toFixed(2), (1.45).toFixed(1)].join()`, "1.00,8.35,1.4")
}

@(test)
test_to_fixed_bordas :: proc(t: ^testing.T) {
    expect_str(t, `[(1e21).toFixed(2), (1e20).toFixed(2), (0.05).toFixed(2), (9.99).toFixed(1), (-0).toFixed(2), (-1e-7).toFixed(2)].join()`,
               "1e+21,100000000000000000000.00,0.05,10.0,0.00,-0.00")
    expect_str(t, `(0.1).toFixed(20)`, "0.10000000000000000555")
    expect_str(t, `
        function se(f) { try { f(); return "ok"; } catch (e) { return e.name; } }
        [se(function(){ (1).toFixed(101) }), se(function(){ Number.prototype.toFixed.call("1") }), (1).toFixed(100).length].join()`,
        "RangeError,TypeError,102")
}

@(test)
test_to_exponential :: proc(t: ^testing.T) {
    expect_str(t, `[(123.456).toExponential(), (123.456).toExponential(2), (0).toExponential(), (0).toExponential(2)].join()`,
               "1.23456e+2,1.23e+2,0e+0,0.00e+0")
    expect_str(t, `[(1.25).toExponential(1), (9.99).toExponential(1), (-5e-324).toExponential(), Infinity.toExponential(1000)].join()`,
               "1.3e+0,1.0e+1,-5e-324,Infinity")
    expect_str(t, `var r; try { (1).toExponential(-1); r = "ok" } catch (e) { r = e.name } r`, "RangeError")
}

@(test)
test_to_precision :: proc(t: ^testing.T) {
    expect_str(t, `[(1).toPrecision(3), (123.456).toPrecision(4), (123.456).toPrecision(2), (0.000123).toPrecision(2)].join()`,
               "1.00,123.5,1.2e+2,0.00012")
    expect_str(t, `[(1e-7).toPrecision(1), (2.5).toPrecision(1), (99.99).toPrecision(3), (999.99).toPrecision(3), (0).toPrecision(3)].join()`,
               "1e-7,3,100,1.00e+3,0.00")
}

// ── fuso ──

@(test)
test_date_fuso_fixo :: proc(t: ^testing.T) {
    with_tz(TZ_BRT); defer end_tz()
    expect_str(t, `var d = new Date(Date.UTC(2026, 10, 21, 13)); [d.getTimezoneOffset(), d.getHours(), d.getUTCHours()].join()`, "180,10,13")
    expect_str(t, `new Date(Date.UTC(2026, 10, 21, 13)).toString()`, "Sat Nov 21 2026 10:00:00 GMT-0300 (BRT)")
    // componentes e ISO sem offset são hora LOCAL; ISO só-data é UTC
    expect_str(t, `new Date(2026, 0, 1).toISOString()`, "2026-01-01T03:00:00.000Z")
    expect_str(t, `[new Date("2026-01-01T00:00").toISOString(), new Date("2026-01-01").toISOString()].join()`,
               "2026-01-01T03:00:00.000Z,2026-01-01T00:00:00.000Z")
    expect_str(t, `new Date("Jan 1 2026 10:00").toISOString()`, "2026-01-01T13:00:00.000Z")
    // virada do dia: 01h UTC ainda é o dia anterior em UTC-3
    expect_str(t, `var d = new Date(Date.UTC(2026, 0, 1, 1)); d.getDate() + "/" + d.getUTCDate()`, "31/1")
    expect_str(t, `var d = new Date(Date.UTC(2026, 10, 21, 13)); String(Date.parse(d.toString()) === d.getTime())`, "true")
}

@(test)
test_date_setters_local_e_utc :: proc(t: ^testing.T) {
    with_tz(TZ_BRT); defer end_tz()
    expect_str(t, `var d = new Date(2026, 5, 15, 12); d.setHours(23); d.getHours() + " " + d.toISOString()`, "23 2026-06-16T02:00:00.000Z")
    expect_str(t, `var d = new Date(0); d.setUTCHours(5); d.toISOString()`, "1970-01-01T05:00:00.000Z")
    // setFullYear em Invalid Date: base +0 em hora LOCAL
    expect_str(t, `var d = new Date(NaN); d.setFullYear(2000); d.toISOString()`, "2000-01-01T03:00:00.000Z")
    // setDate só tem 1 parâmetro: o 2º não vira hora (antes virava)
    expect_str(t, `var d = new Date(2026, 0, 31); d.setDate(1, 5); d.getHours() + ""`, "0")
}

@(test)
test_date_horario_de_verao :: proc(t: ^testing.T) {
    with_tz(TZ_NY); defer end_tz()
    expect_str(t, `[new Date(2026, 0, 15).getTimezoneOffset(), new Date(2026, 6, 15).getTimezoneOffset()].join()`, "300,240")
    // 8/3/2026 02:00 → 03:00. 02:30 não existe: usa o deslocamento de ANTES (-5)
    expect_str(t, `var d = new Date(2026, 2, 8, 2, 30); d.toISOString() + " " + d.getHours() + ":" + d.getMinutes()`,
               "2026-03-08T07:30:00.000Z 3:30")
    // 1/11/2026 02:00 → 01:00. 01:30 acontece duas vezes: vale a de ANTES (-4)
    expect_str(t, `new Date(2026, 10, 1, 1, 30).toISOString()`, "2026-11-01T05:30:00.000Z")
    expect_str(t, `new Date(Date.UTC(2026, 6, 4, 16)).toString()`, "Sat Jul 04 2026 12:00:00 GMT-0400 (EDT)")
}

@(test)
test_date_getters_brand_e_nan :: proc(t: ^testing.T) {
    expect_str(t, `[new Date(NaN).getHours(), new Date(NaN).getTimezoneOffset()].join()`, "NaN,NaN")
    expect_str(t, `var r; try { Date.prototype.getHours.call({}); r = "ok" } catch (e) { r = e.name } r`, "TypeError")
    // em UTC o offset é +0, não −0
    expect_str(t, `Object.is(new Date(0).getTimezoneOffset(), 0) + ""`, "true")
}

@(test)
test_intl_fuso :: proc(t: ^testing.T) {
    with_tz(TZ_BRT); defer end_tz()
    expect_str(t, `Intl.DateTimeFormat().resolvedOptions().timeZone`, "Test/Zone")
    expect_str(t, `new Intl.DateTimeFormat("en-US", {timeZone: "UTC"}).resolvedOptions().timeZone`, "UTC")
    expect_str(t, `var d = new Date(Date.UTC(2026, 10, 21, 1)); d.toLocaleDateString("pt-BR") + "|" + d.toLocaleDateString("pt-BR", {timeZone: "UTC"})`,
               "20/11/2026|21/11/2026")
}

// ── atribuição com RHS que lança (achado pelo Test262 de toFixed em strict) ──
@(test)
test_assign_rhs_que_lanca_nao_escreve :: proc(t: ^testing.T) {
    expect_str(t, `var x = 1, o = {p: 1};
        function f() { throw 0 }
        try { x = f() } catch (e) {}
        try { o.p = f() } catch (e) {}
        try { x += f() } catch (e) {}
        try { o.q ??= f() } catch (e) {}
        x + "," + o.p + "," + ("q" in o)`, "1,1,false")
    // strict: a exceção do RHS vence o ReferenceError do nome não declarado
    expect_str(t, `"use strict"; var r; try { naoDeclarada = (function(){ throw "rhs" })() } catch (e) { r = typeof e === "string" ? e : e.name } r`, "rhs")
}
