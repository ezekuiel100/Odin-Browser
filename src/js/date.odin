package js

// Date de verdade (M59). O instante vive como epoch-ms em props["#t"] (chave
// "privada": não enumera em for-in/Object.keys nem vaza no JSON.stringify) e
// os métodos moram num prototype compartilhado (vm.date_proto) — cada
// `new Date()` é só um objeto pequeno apontando p/ ele.
//
// SIMPLIFICAÇÕES deliberadas: sem fuso horário — hora "local" == UTC
// (getTimezoneOffset() = 0; getHours == getUTCHours); setters além de setTime
// ficam p/ quando algum site precisar; toString devolve o ISO.

import "core:math"
import "core:strings"
import "core:time"
import "core:fmt"

// ── calendário civil (algoritmos de Howard Hinnant, days<->Y/M/D) ───────────

@(private = "file")
days_from_civil :: proc(y_in, m, d: int) -> int {
    y := y_in
    if m <= 2 do y -= 1
    era := (y >= 0 ? y : y - 399) / 400
    yoe := y - era * 400
    mp := (m + 9) % 12
    doy := (153 * mp + 2) / 5 + d - 1
    doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
    return era * 146097 + doe - 719468
}

@(private = "file")
civil_from_days :: proc(z_in: int) -> (y, m, d: int) {
    z := z_in + 719468
    era := (z >= 0 ? z : z - 146096) / 146097
    doe := z - era * 146097
    yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
    y = yoe + era * 400
    doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
    mp := (5 * doy + 2) / 153
    d = doy - (153 * mp + 2) / 5 + 1
    m = mp < 10 ? mp + 3 : mp - 9
    if m <= 2 do y += 1
    return
}

// Visíveis ao PACOTE (não file-private): o Intl (intl.odin) formata datas e
// precisa exatamente destes três — decompor o epoch-ms e ler o instante de um
// objeto Date. Duplicá-los lá seria ter dois calendários que podem divergir.
Date_Parts :: struct { year, month, day, wday, hour, min, sec, ms: int } // month 1-12

date_parts :: proc(t: f64) -> Date_Parts {
    total := int(math.floor(t))
    ms_of_day := ((total % 86_400_000) + 86_400_000) % 86_400_000
    days := (total - ms_of_day) / 86_400_000
    p: Date_Parts
    p.year, p.month, p.day = civil_from_days(days)
    p.wday = (((days + 4) % 7) + 7) % 7 // 1970-01-01 (dia 0) foi quinta (4)
    p.hour = ms_of_day / 3_600_000
    p.min  = (ms_of_day / 60_000) % 60
    p.sec  = (ms_of_day / 1000) % 60
    p.ms   = ms_of_day % 1000
    return p
}

@(private = "file")
ms_from_parts :: proc(y, mo, d, h, mi, s, ms: int) -> f64 {
    days := days_from_civil(y, mo, d)
    return f64(days) * 86_400_000 + f64(h) * 3_600_000 + f64(mi) * 60_000 + f64(s) * 1000 + f64(ms)
}

date_now_ms :: proc() -> f64 {
    // ms INTEIRO (divisão inteira de ns): a spec define time values como inteiros;
    // libs fazem `Number.isInteger(Date.now())` (ex.: uuidv7) e o fracionário de
    // sub-ms fazia isso dar false → RangeError.
    return f64(time.to_unix_nanoseconds(time.now()) / 1_000_000)
}

// ── objeto Date ──────────────────────────────────────────────────────────────

date_new :: proc(vm: ^Interp, t: f64) -> ^Object {
    o := new_object(vm)
    o.props["#t"] = t
    o.proto = vm.date_proto
    return o
}

// this → epoch-ms (NaN se this não é um Date)
date_t :: proc(this: Value) -> f64 {
    if o, ok := this.(^Object); ok {
        if t, tok := o.props["#t"].(f64); tok do return t
    }
    return math.nan_f64()
}

@(private = "file")
native_date_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    t: f64
    switch {
    case len(args) == 0:
        t = date_now_ms()
    case len(args) == 1:
        if s, ok := args[0].(string); ok {
            t = date_parse_str(s)
        } else if d, dok := args[0].(^Object); dok && d.proto == vm.date_proto {
            t = date_t(d) // new Date(outroDate) copia
        } else {
            t = as_number(args[0])
        }
    case:
        // new Date(ano, mês0, dia, h, min, s, ms) — mês fora de 0..11 transborda
        y := as_int(arg(args, 0))
        mo := as_int(arg(args, 1))
        total_months := y * 12 + mo
        y2 := total_months / 12
        mo2 := total_months % 12
        if mo2 < 0 { mo2 += 12; y2 -= 1 }
        d  := len(args) >= 3 ? as_int(args[2]) : 1
        h  := len(args) >= 4 ? as_int(args[3]) : 0
        mi := len(args) >= 5 ? as_int(args[4]) : 0
        s  := len(args) >= 6 ? as_int(args[5]) : 0
        ms := len(args) >= 7 ? as_int(args[6]) : 0
        t = ms_from_parts(y2, mo2 + 1, d, h, mi, s, ms)
    }
    return date_new(vm, t)
}

// ── Date.parse (subconjunto ISO 8601) ────────────────────────────────────────

// "YYYY-MM-DD" | "YYYY-MM-DDTHH:MM[:SS[.mmm]]" com sufixo opcional Z ou ±HH:MM.
// Qualquer outra coisa → NaN (navegadores aceitam mais formatos; anotado).
@(private = "file")
date_parse_str :: proc(s_in: string) -> f64 {
    s := strings.trim_space(s_in)
    i := 0
    read_n :: proc(s: string, i: ^int, n: int) -> (int, bool) {
        if i^ + n > len(s) do return 0, false
        v := 0
        for k in 0 ..< n {
            c := s[i^ + k]
            if c < '0' || c > '9' do return 0, false
            v = v * 10 + int(c - '0')
        }
        i^ += n
        return v, true
    }
    eat :: proc(s: string, i: ^int, c: u8) -> bool {
        if i^ < len(s) && s[i^] == c { i^ += 1; return true }
        return false
    }
    nan := math.nan_f64()

    y, yok := read_n(s, &i, 4)
    if !yok do return nan
    if !eat(s, &i, '-') do return nan
    mo, mok := read_n(s, &i, 2)
    if !mok || mo < 1 || mo > 12 do return nan
    if !eat(s, &i, '-') do return nan
    d, dok := read_n(s, &i, 2)
    if !dok || d < 1 || d > 31 do return nan

    h, mi, sec, ms := 0, 0, 0, 0
    off_min := 0
    if i < len(s) && (s[i] == 'T' || s[i] == ' ') {
        i += 1
        hv, hok := read_n(s, &i, 2)
        if !hok do return nan
        if !eat(s, &i, ':') do return nan
        mv, mvok := read_n(s, &i, 2)
        if !mvok do return nan
        h = hv; mi = mv
        if eat(s, &i, ':') {
            sv, sok := read_n(s, &i, 2)
            if !sok do return nan
            sec = sv
            if eat(s, &i, '.') {
                msv, msok := read_n(s, &i, 3)
                if !msok do return nan
                ms = msv
            }
        }
        // fuso: Z ou ±HH:MM (aplicado como deslocamento p/ UTC)
        if i < len(s) {
            switch s[i] {
            case 'Z':
                i += 1
            case '+', '-':
                sign := s[i] == '-' ? -1 : 1
                i += 1
                oh, ohok := read_n(s, &i, 2)
                if !ohok do return nan
                eat(s, &i, ':')
                om, omok := read_n(s, &i, 2)
                if !omok do return nan
                off_min = sign * (oh * 60 + om)
            }
        }
    }
    if i != len(s) do return nan // sobrou lixo
    return ms_from_parts(y, mo, d, h, mi, sec, ms) - f64(off_min) * 60_000
}

// ── métodos ──────────────────────────────────────────────────────────────────

@(private = "file") date_get_time :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    // brand-check (spec): getTime.call(não-Date) → TypeError, não NaN silencioso
    if o, ok := this.(^Object); ok {
        if t, tok := o.props["#t"].(f64); tok {
            if t == 0 do return f64(0) // TimeClip: -0 → +0 (new Date(-0).getTime() === 0)
            return t
        }
    }
    throw_type_error(vm, "Date.prototype.getTime called on non-Date object")
    return nil
}
@(private = "file") date_get_full_year :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return f64(date_parts(date_t(this)).year) }
@(private = "file") date_get_month :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return f64(date_parts(date_t(this)).month - 1) } // 0-based
@(private = "file") date_get_date :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return f64(date_parts(date_t(this)).day) }
@(private = "file") date_get_day :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return f64(date_parts(date_t(this)).wday) }
@(private = "file") date_get_hours :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return f64(date_parts(date_t(this)).hour) }
@(private = "file") date_get_minutes :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return f64(date_parts(date_t(this)).min) }
@(private = "file") date_get_seconds :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return f64(date_parts(date_t(this)).sec) }
@(private = "file") date_get_ms :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return f64(date_parts(date_t(this)).ms) }
@(private = "file") date_get_tz :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return f64(0) } // local == UTC

@(private = "file")
date_set_time :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    t := as_number(arg(a, 0))
    if o, ok := this.(^Object); ok do o.props["#t"] = t
    return t
}

// ── setters de componentes ────────────────────────────────────────────────────
// Todos: leem os campos atuais, sobrescrevem os informados (com transbordo — spec
// MakeDay/MakeTime), recompõem e devolvem o novo time value. Um argumento NaN
// (inclusive AUSENTE → undefined → NaN) torna a data Invalid (#t = NaN). Como
// local == UTC (tz 0), os setUTC* são os MESMOS procs. `int()` = ToInteger (trunca).

@(private = "file")
date_store :: proc(this: Value, t: f64) -> Value {
    if o, ok := this.(^Object); ok do o.props["#t"] = t
    return t
}

// Recompõe a partir de componentes: normaliza SÓ o mês (não-linear no calendário)
// carregando p/ o ano; dia/hora/min/seg/ms transbordam linearmente em ms_from_parts
// (day via days_from_civil). month0 é 0-based (como a API JS).
@(private = "file")
date_compose :: proc(year, month0, day, hour, min, sec, ms: int) -> f64 {
    tm := year * 12 + month0
    y := tm / 12
    m0 := tm % 12
    if m0 < 0 { m0 += 12; y -= 1 }
    return ms_from_parts(y, m0 + 1, day, hour, min, sec, ms)
}

// Motor comum dos setters. `start` mapeia arg[0] p/ o campo em
// [year, month0, day, hour, min, sec, ms]; args seguintes preenchem os campos
// à direita. `nan_base`: só setFullYear "revive" uma Invalid Date (base = epoch 0);
// os demais devolvem NaN se a data já é Invalid.
@(private = "file")
date_set_fields :: proc(vm: ^Interp, this: Value, a: []Value, start: int, nan_base: bool) -> Value {
    // brand-check: setter em não-Date (ex.: Date.prototype.setFullYear(2012)) →
    // TypeError. Distingue "Date c/ tempo NaN" (#t presente como f64) de "não-Date".
    o, isobj := this.(^Object)
    is_date := isobj
    if isobj { _, is_date = o.props["#t"].(f64) }
    if !is_date { throw_type_error(vm, "Date.prototype setter called on non-Date object"); return nil }
    t := date_t(this)
    if t != t {
        if !nan_base do return date_store(this, math.nan_f64())
        t = 0
    }
    p := date_parts(t)
    f := [7]int{ p.year, p.month - 1, p.day, p.hour, p.min, p.sec, p.ms }
    // ToNumber de CADA arg via valueOf/toString, na ordem (spec); valueOf que lança
    // propaga e NÃO modifica a data. Antes usava as_number (objeto → NaN sem valueOf).
    v0 := to_number(vm, arg(a, 0)) // arg[0] obrigatório: ausente → undefined → NaN
    if vm.throwing do return nil
    if v0 != v0 do return date_store(this, math.nan_f64())
    f[start] = int(v0)
    for k := 1; k < len(a) && start + k <= 6; k += 1 {
        v := to_number(vm, a[k])
        if vm.throwing do return nil
        if v != v do return date_store(this, math.nan_f64())
        f[start + k] = int(v)
    }
    return date_store(this, date_compose(f[0], f[1], f[2], f[3], f[4], f[5], f[6]))
}

@(private = "file") date_set_full_year :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return date_set_fields(vm, this, a, 0, true) }
@(private = "file") date_set_month :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return date_set_fields(vm, this, a, 1, false) }
@(private = "file") date_set_date :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return date_set_fields(vm, this, a, 2, false) }
@(private = "file") date_set_hours :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return date_set_fields(vm, this, a, 3, false) }
@(private = "file") date_set_minutes :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return date_set_fields(vm, this, a, 4, false) }
@(private = "file") date_set_seconds :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return date_set_fields(vm, this, a, 5, false) }
@(private = "file") date_set_ms :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return date_set_fields(vm, this, a, 6, false) }

// setYear (legado): 0..99 vira 1900+y; senão o ano cru. Como setFullYear(y).
@(private = "file")
date_set_year :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    yv := as_number(arg(a, 0))
    if yv != yv do return date_store(this, math.nan_f64())
    yi := int(yv)
    if yi >= 0 && yi <= 99 do yi += 1900
    t := date_t(this)
    p := date_parts(t == t ? t : 0)
    return date_store(this, date_compose(yi, p.month - 1, p.day, p.hour, p.min, p.sec, p.ms))
}

@(private = "file")
date_iso :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    t := date_t(this)
    if t != t do return own_str(vm, "Invalid Date")
    p := date_parts(t)
    s := fmt.tprintf("%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", p.year, p.month, p.day, p.hour, p.min, p.sec, p.ms)
    return own_str(vm, s)
}

// toLocaleDateString/TimeString — aproximação fixa dd/mm/aaaa e hh:mm:ss
// (sem locale de verdade; suficiente p/ exibição)
@(private = "file")
date_locale_date :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    t := date_t(this)
    if t != t do return own_str(vm, "Invalid Date")
    p := date_parts(t)
    return own_str(vm, fmt.tprintf("%02d/%02d/%04d", p.day, p.month, p.year))
}

@(private = "file")
date_locale_time :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    t := date_t(this)
    if t != t do return own_str(vm, "Invalid Date")
    p := date_parts(t)
    return own_str(vm, fmt.tprintf("%02d:%02d:%02d", p.hour, p.min, p.sec))
}

@(private = "file")
date_locale_full :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    t := date_t(this)
    if t != t do return own_str(vm, "Invalid Date")
    p := date_parts(t)
    return own_str(vm, fmt.tprintf("%02d/%02d/%04d %02d:%02d:%02d", p.day, p.month, p.year, p.hour, p.min, p.sec))
}

@(private = "file")
native_date_now :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return date_now_ms() }

@(private = "file")
native_date_parse :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    s, ok := arg(a, 0).(string)
    if !ok do return math.nan_f64()
    return date_parse_str(s)
}

install_date :: proc(vm: ^Interp) {
    proto := new_object(vm)
    vm.date_proto = proto
    proto.props["getTime"]            = mk_native(vm, date_get_time)
    proto.props["valueOf"]            = mk_native(vm, date_get_time)
    proto.props["getFullYear"]        = mk_native(vm, date_get_full_year)
    proto.props["getMonth"]           = mk_native(vm, date_get_month)
    proto.props["getDate"]            = mk_native(vm, date_get_date)
    proto.props["getDay"]             = mk_native(vm, date_get_day)
    proto.props["getHours"]           = mk_native(vm, date_get_hours)
    proto.props["getMinutes"]         = mk_native(vm, date_get_minutes)
    proto.props["getSeconds"]         = mk_native(vm, date_get_seconds)
    proto.props["getMilliseconds"]    = mk_native(vm, date_get_ms)
    // local == UTC: getUTC* são os mesmos procs
    proto.props["getUTCFullYear"]     = proto.props["getFullYear"]
    proto.props["getUTCMonth"]        = proto.props["getMonth"]
    proto.props["getUTCDate"]         = proto.props["getDate"]
    proto.props["getUTCDay"]          = proto.props["getDay"]
    proto.props["getUTCHours"]        = proto.props["getHours"]
    proto.props["getUTCMinutes"]      = proto.props["getMinutes"]
    proto.props["getUTCSeconds"]      = proto.props["getSeconds"]
    proto.props["getUTCMilliseconds"] = proto.props["getMilliseconds"]
    proto.props["getTimezoneOffset"]  = mk_native(vm, date_get_tz)
    proto.props["setTime"]            = mk_native(vm, date_set_time)
    proto.props["setFullYear"]        = mk_native(vm, date_set_full_year)
    proto.props["setMonth"]           = mk_native(vm, date_set_month)
    proto.props["setDate"]            = mk_native(vm, date_set_date)
    proto.props["setHours"]           = mk_native(vm, date_set_hours)
    proto.props["setMinutes"]         = mk_native(vm, date_set_minutes)
    proto.props["setSeconds"]         = mk_native(vm, date_set_seconds)
    proto.props["setMilliseconds"]    = mk_native(vm, date_set_ms)
    proto.props["setYear"]            = mk_native(vm, date_set_year) // legado
    // local == UTC: setUTC* são os mesmos procs
    proto.props["setUTCFullYear"]     = proto.props["setFullYear"]
    proto.props["setUTCMonth"]        = proto.props["setMonth"]
    proto.props["setUTCDate"]         = proto.props["setDate"]
    proto.props["setUTCHours"]        = proto.props["setHours"]
    proto.props["setUTCMinutes"]      = proto.props["setMinutes"]
    proto.props["setUTCSeconds"]      = proto.props["setSeconds"]
    proto.props["setUTCMilliseconds"] = proto.props["setMilliseconds"]
    proto.props["toISOString"]        = mk_native(vm, date_iso)
    proto.props["toJSON"]             = mk_native(vm, date_iso)
    proto.props["toString"]           = mk_native(vm, date_iso) // aproximação
    proto.props["toUTCString"]        = mk_native(vm, date_iso) // aproximação
    proto.props["toGMTString"]        = mk_native(vm, date_iso) // alias legado de toUTCString (dev.to/bing/espn)
    proto.props["toLocaleDateString"] = mk_native(vm, date_locale_date)
    proto.props["toLocaleTimeString"] = mk_native(vm, date_locale_time)
    proto.props["toLocaleString"]     = mk_native(vm, date_locale_full)

    ctor := mk_native(vm, native_date_ctor)
    ctor.name = "Date"
    ctor.props = make(map[string]Value)
    ctor.props["now"]   = mk_native(vm, native_date_now)
    ctor.props["parse"] = mk_native(vm, native_date_parse)
    ctor.props["UTC"]   = mk_native(vm, native_date_utc)
    // `Date.prototype` estava UNDEFINED — quebrava `Date.prototype.getTime`,
    // `date instanceof Date` (instanceof precisa de Date.prototype) e herança.
    ctor.props["prototype"] = proto
    proto.props["constructor"] = ctor
    mark_non_enumerable(proto, "constructor") // não-enumerável (spec)
    env_define(vm.global, "Date", ctor)
}

// Date.UTC(ano, mês0, ...) → epoch-ms (aqui igual ao construtor, pois local==UTC)
@(private = "file")
native_date_utc :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    if len(a) < 2 do return math.nan_f64()
    d := native_date_ctor(vm, nil, a)
    return date_t(d)
}
