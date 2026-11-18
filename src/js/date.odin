package js

// Date de verdade (M59). O instante vive como epoch-ms em props["#t"] (chave
// "privada": não enumera em for-in/Object.keys nem vaza no JSON.stringify) e
// os métodos moram num prototype compartilhado (vm.date_proto) — cada
// `new Date()` é só um objeto pequeno apontando p/ ele.
//
// SIMPLIFICAÇÃO deliberada: sem fuso horário — hora "local" == UTC
// (getTimezoneOffset() = 0; getHours == getUTCHours; toString diz GMT+0000).

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
    o.props["#t"] = time_clip(t)
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
        if d, dok := args[0].(^Object); dok {
            if dt, isdate := d.props["#t"].(f64); isdate {
                t = dt // new Date(outroDate) copia o instante
                break
            }
        }
        // ToPrimitive: objeto com valueOf/toString vira número ou string de data
        v := args[0]
        if !is_primitive(v) {
            // hint "default": objeto comum usa a ordem de NÚMERO (valueOf antes)
            v = to_primitive(vm, v, true, "default")
            if vm.throwing do return nil
        }
        if s, ok := v.(string); ok {
            t = date_parse_str(s)
        } else {
            t = to_number(vm, v)
            if vm.throwing do return nil
        }
    case:
        // new Date(ano, mês0, dia, h, min, s, ms) — hora LOCAL (== UTC aqui)
        tv, ok := date_from_components(vm, args)
        if !ok do return nil
        t = tv
    }
    return date_new(vm, t)
}

// ── MakeTime / MakeDay / MakeDate (spec 21.4.1.27–29) ────────────────────────
// Em f64, na ordem de operações da spec: a precisão de ponto flutuante faz parte
// do resultado (Test262 UTC/fp-evaluation-order). Antes era tudo em `int` via
// as_int, e NaN em qualquer campo virava 0 em vez de propagar.

@(private = "file")
to_integer_f :: proc(x: f64) -> f64 {
    r := math.trunc(x)
    return r == 0 ? 0 : r // -0 → +0
}

@(private = "file")
is_finite_f :: proc(x: f64) -> bool { return x == x && abs(x) != math.inf_f64(1) }

@(private = "file")
make_time :: proc(h, m, s, ms: f64) -> f64 {
    if !is_finite_f(h) || !is_finite_f(m) || !is_finite_f(s) || !is_finite_f(ms) do return math.nan_f64()
    return ((to_integer_f(h) * 3_600_000 + to_integer_f(m) * 60_000) + to_integer_f(s) * 1000) + to_integer_f(ms)
}

@(private = "file")
make_day :: proc(year, month, date: f64) -> f64 {
    if !is_finite_f(year) || !is_finite_f(month) || !is_finite_f(date) do return math.nan_f64()
    y, m, dt := to_integer_f(year), to_integer_f(month), to_integer_f(date)
    ym := y + math.floor(m / 12)
    // além de ±1e6 anos o resultado sai da faixa do TimeClip de qualquer forma; a
    // guarda evita o overflow do `int` no calendário civil
    if !is_finite_f(ym) || abs(ym) > 1_000_000 do return math.nan_f64()
    mn := m - math.floor(m / 12) * 12 // m módulo 12, sempre em [0, 12)
    days := f64(days_from_civil(int(ym), int(mn) + 1, 1))
    return days + dt - 1
}

@(private = "file")
make_date :: proc(day, time: f64) -> f64 {
    if !is_finite_f(day) || !is_finite_f(time) do return math.nan_f64()
    tv := day * 86_400_000 + time
    if !is_finite_f(tv) do return math.nan_f64()
    return tv
}

// Os 7 componentes de `new Date(y, m, ...)` / `Date.UTC(y, ...)`: ToNumber de CADA
// argumento presente, na ordem (valueOf que lança propaga); ausentes assumem
// mês 0, dia 1 e hora 0. Ano inteiro em 0..99 → 1900+ano.
@(private = "file")
date_from_components :: proc(vm: ^Interp, args: []Value) -> (f64, bool) {
    f := [7]f64{0, 0, 1, 0, 0, 0, 0} // y, m, d, h, min, s, ms
    for i in 0 ..< min(len(args), 7) {
        f[i] = to_number(vm, args[i])
        if vm.throwing do return 0, false
    }
    y := f[0]
    if y == y {
        yi := to_integer_f(y)
        if yi >= 0 && yi <= 99 do y = 1900 + yi
    }
    return make_date(make_day(y, f[1], f[2]), make_time(f[3], f[4], f[5], f[6])), true
}

// TimeClip (spec 21.4.1.31): fora de ±8,64e15 ms (±100 milhões de dias) ou não-finito
// → NaN; senão trunca p/ inteiro e -0 vira +0.
time_clip :: proc(t: f64) -> f64 {
    if t != t || abs(t) > 8.64e15 do return math.nan_f64()
    r := math.trunc(t)
    return r == 0 ? 0 : r
}

// ── Date.parse ───────────────────────────────────────────────────────────────
// 1º o formato ISO da spec (21.4.1.32); se não casar, o parser LEGADO — a spec deixa
// "implementation-specific", mas o que os navegadores aceitam é de facto padrão e
// código real depende dele (`new Date("March 5, 2024")`, cabeçalho HTTP RFC 2822,
// e a ida e volta `Date.parse(d.toString())` que a spec EXIGE). Antes, tudo fora
// do ISO dava NaN/"Invalid Date". Hora sem fuso é LOCAL — aqui local == UTC.
@(private = "file")
date_parse_str :: proc(s_in: string) -> f64 {
    s := strings.trim_space(s_in)
    if t, ok := date_parse_iso(s); ok do return time_clip(t)
    return time_clip(date_parse_legacy(s))
}

@(private = "file")
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

@(private = "file")
eat :: proc(s: string, i: ^int, c: u8) -> bool {
    if i^ < len(s) && s[i^] == c { i^ += 1; return true }
    return false
}

// Date Time String Format: `YYYY[-MM[-DD]][THH:mm[:ss[.sss]][Z|±HH:mm]]`, com ano
// estendido `±YYYYYY` (`-000000` é inválido). Só-data é UTC. ok=false = não é ISO
// (o chamador tenta o legado); ok=true com NaN = é ISO mas fora de faixa.
@(private = "file")
date_parse_iso :: proc(s: string) -> (f64, bool) {
    nan := math.nan_f64()
    i := 0
    y: int
    if i < len(s) && (s[i] == '+' || s[i] == '-') {
        neg := s[i] == '-'
        i += 1
        v, ok := read_n(s, &i, 6)
        if !ok do return nan, false
        if neg && v == 0 do return nan, true // -000000: a spec proíbe
        y = neg ? -v : v
    } else {
        v, ok := read_n(s, &i, 4)
        if !ok do return nan, false
        y = v
    }
    mo, d := 1, 1
    if eat(s, &i, '-') {
        v, ok := read_n(s, &i, 2)
        if !ok do return nan, false
        mo = v
        if eat(s, &i, '-') {
            dv, dok := read_n(s, &i, 2)
            if !dok do return nan, false
            d = dv
        }
    }
    h, mi, sec, ms := 0, 0, 0, 0
    off_min := 0
    if i < len(s) && (s[i] == 'T' || s[i] == 't' || s[i] == ' ') {
        i += 1
        hv, hok := read_n(s, &i, 2)
        if !hok do return nan, false
        if !eat(s, &i, ':') do return nan, false
        mv, mvok := read_n(s, &i, 2)
        if !mvok do return nan, false
        h = hv; mi = mv
        if eat(s, &i, ':') {
            sv, sok := read_n(s, &i, 2)
            if !sok do return nan, false
            sec = sv
            if eat(s, &i, '.') || eat(s, &i, ',') {
                // spec: 3 dígitos; navegadores aceitam N e usam os 3 primeiros
                nd := 0
                for i < len(s) && s[i] >= '0' && s[i] <= '9' {
                    if nd < 3 do ms = ms * 10 + int(s[i] - '0')
                    nd += 1; i += 1
                }
                if nd == 0 do return nan, false
                for k := nd; k < 3; k += 1 do ms *= 10
            }
        }
        if i < len(s) {
            switch s[i] {
            case 'Z', 'z':
                i += 1
            case '+', '-':
                sign := s[i] == '-' ? -1 : 1
                i += 1
                oh, ohok := read_n(s, &i, 2)
                if !ohok do return nan, false
                eat(s, &i, ':')
                om, omok := read_n(s, &i, 2)
                if !omok do return nan, false
                if oh > 23 || om > 59 do return nan, true
                off_min = sign * (oh * 60 + om)
            }
        }
    } else if i < len(s) && (s[i] == 'Z' || s[i] == 'z') {
        i += 1 // "2020-01-01Z"
    }
    if i != len(s) do return nan, false // sobrou texto: talvez seja formato legado
    if mo < 1 || mo > 12 || d < 1 || d > days_in_month(y, mo) do return nan, true
    if mi > 59 || sec > 59 do return nan, true
    if h > 24 || (h == 24 && (mi != 0 || sec != 0 || ms != 0)) do return nan, true
    return ms_from_parts(y, mo, d, h, mi, sec, ms) - f64(off_min) * 60_000, true
}

@(private = "file")
days_in_month :: proc(y, m: int) -> int {
    switch m {
    case 2:
        leap := (y % 4 == 0 && y % 100 != 0) || y % 400 == 0
        return leap ? 29 : 28
    case 4, 6, 9, 11:
        return 30
    }
    return 31
}

@(private = "file")
MONTH_ABBR := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
@(private = "file")
WDAY_ABBR := [7]string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}

// Parser legado, no espírito do V8/SpiderMonkey: tokens soltos em qualquer ordem.
// Palavras: mês (pelas 3 primeiras letras), dia da semana (ignorado), AM/PM,
// GMT/UTC/UT/Z e zonas dos EUA; `(...)` é comentário ("(Coordinated Universal
// Time)"); `HH:MM[:SS[.mmm]]` é hora; `±HHMM`/`±HH:MM` depois de hora ou de GMT é
// fuso. Os números restantes são a data: com mês por NOME, dia e ano (o que tiver
// 3+ dígitos ou passar de 31 é o ano); sem nome, `Y/M/D` se o 1º tiver 3+ dígitos,
// senão `M/D/Y` (convenção dos EUA, a dos navegadores). Ano de 2 dígitos: <50 →
// 20xx, senão 19xx.
@(private = "file")
date_parse_legacy :: proc(s: string) -> f64 {
    nan := math.nan_f64()
    Num :: struct { v, nd: int }
    nums: [4]Num
    nn := 0
    month := -1
    h, mi, sec, ms := -1, 0, 0, 0
    ampm := 0 // 1 = AM, 2 = PM
    off_min := 0
    has_tz := false
    i := 0
    for i < len(s) {
        c := s[i]
        switch {
        case c == '(':
            depth := 0
            for i < len(s) {
                if s[i] == '(' do depth += 1
                if s[i] == ')' { depth -= 1; if depth == 0 { i += 1; break } }
                i += 1
            }
            if depth > 0 do return nan
        case (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z'):
            st := i
            for i < len(s) && ((s[i] >= 'a' && s[i] <= 'z') || (s[i] >= 'A' && s[i] <= 'Z') || s[i] == '.') do i += 1
            w := strings.to_lower(strings.trim_right(s[st:i], "."), context.temp_allocator)
            w, _ = strings.remove_all(w, ".", context.temp_allocator) // "a.m." → "am"
            switch w {
            case "am": ampm = 1
            case "pm": ampm = 2
            case "z", "gmt", "utc", "ut": has_tz = true
            case "est": has_tz = true; off_min = -5 * 60
            case "edt": has_tz = true; off_min = -4 * 60
            case "cst": has_tz = true; off_min = -6 * 60
            case "cdt": has_tz = true; off_min = -5 * 60
            case "mst": has_tz = true; off_min = -7 * 60
            case "mdt": has_tz = true; off_min = -6 * 60
            case "pst": has_tz = true; off_min = -8 * 60
            case "pdt": has_tz = true; off_min = -7 * 60
            case "t":   // separador ISO-ish ("2020/01/02T10:00")
            case:
                if len(w) < 3 do return nan
                found := false
                for name, k in MONTH_ABBR {
                    if strings.has_prefix(w, strings.to_lower(name, context.temp_allocator)) {
                        if month >= 0 do return nan // dois meses
                        month = k + 1; found = true; break
                    }
                }
                if !found {
                    for name in WDAY_ABBR {
                        if strings.has_prefix(w, strings.to_lower(name, context.temp_allocator)) { found = true; break }
                    }
                }
                if !found do return nan // palavra desconhecida
            }
        case c >= '0' && c <= '9':
            st := i
            v := 0
            for i < len(s) && s[i] >= '0' && s[i] <= '9' {
                if i - st < 9 do v = v * 10 + int(s[i] - '0')
                i += 1
            }
            nd := i - st
            if i < len(s) && s[i] == ':' { // hora
                if h >= 0 do return nan
                h = v
                i += 1
                mv, ok := read_n(s, &i, 2)
                if !ok do return nan
                mi = mv
                if eat(s, &i, ':') {
                    sv, sok := read_n(s, &i, 2)
                    if !sok do return nan
                    sec = sv
                    if eat(s, &i, '.') {
                        nd2 := 0
                        for i < len(s) && s[i] >= '0' && s[i] <= '9' {
                            if nd2 < 3 do ms = ms * 10 + int(s[i] - '0')
                            nd2 += 1; i += 1
                        }
                        for k := nd2; k < 3; k += 1 do ms *= 10
                    }
                }
                continue
            }
            if nn >= 3 do return nan
            nums[nn] = Num{v, nd}; nn += 1
        case (c == '+' || c == '-') && (h >= 0 || has_tz) && i + 1 < len(s) && s[i+1] >= '0' && s[i+1] <= '9':
            // fuso numérico: +HHMM, +HH:MM ou +H/+HH
            sign := c == '-' ? -1 : 1
            i += 1
            st := i
            v := 0
            for i < len(s) && s[i] >= '0' && s[i] <= '9' { v = v * 10 + int(s[i] - '0'); i += 1 }
            nd := i - st
            oh, om := 0, 0
            switch {
            case nd <= 2:
                oh = v
                if eat(s, &i, ':') {
                    m2, ok := read_n(s, &i, 2)
                    if !ok do return nan
                    om = m2
                }
            case nd == 4:
                oh = v / 100; om = v % 100
            case:
                return nan
            }
            if oh > 23 || om > 59 do return nan
            off_min = sign * (oh * 60 + om)
            has_tz = true
        case c == ' ' || c == ',' || c == '/' || c == '-' || c == '.' || c == '\t':
            i += 1
        case:
            return nan
        }
    }
    y, mo, d := 0, 0, 0
    year_nd := 0
    if month > 0 {
        if nn != 2 do return nan
        mo = month
        a, b := nums[0], nums[1]
        if a.nd >= 3 || a.v > 31 { y, year_nd, d = a.v, a.nd, b.v } else { d, y, year_nd = a.v, b.v, b.nd }
    } else {
        if nn != 3 do return nan
        a, b, cc := nums[0], nums[1], nums[2]
        if a.nd >= 3 { y, year_nd, mo, d = a.v, a.nd, b.v, cc.v } else { mo, d, y, year_nd = a.v, b.v, cc.v, cc.nd }
    }
    if year_nd <= 2 do y += y < 50 ? 2000 : 1900
    if mo < 1 || mo > 12 || d < 1 || d > days_in_month(y, mo) do return nan
    if h < 0 do h = 0
    switch ampm {
    case 1: if h > 12 do return nan; if h == 12 do h = 0
    case 2: if h > 12 do return nan; if h < 12 do h += 12
    }
    if h > 24 || mi > 59 || sec > 59 do return nan
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
    if _, ok := date_this(vm, this, "setTime"); !ok do return nil
    t := to_number(vm, arg(a, 0))
    if vm.throwing do return nil
    return date_store(this, t)
}

// ── setters de componentes ────────────────────────────────────────────────────
// Todos: leem os campos atuais, sobrescrevem os informados (com transbordo — spec
// MakeDay/MakeTime), recompõem e devolvem o novo time value. Um argumento NaN
// (inclusive AUSENTE → undefined → NaN) torna a data Invalid (#t = NaN). Como
// local == UTC (tz 0), os setUTC* são os MESMOS procs. `int()` = ToInteger (trunca).

@(private = "file")
date_store :: proc(this: Value, t: f64) -> Value {
    t := time_clip(t)
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

// thisTimeValue (spec): o instante de um Date; não-Date → TypeError.
@(private = "file")
date_this :: proc(vm: ^Interp, this: Value, method: string) -> (f64, bool) {
    if o, ok := this.(^Object); ok {
        if t, tok := o.props["#t"].(f64); tok do return t, true
    }
    throw_type_error(vm, fmt.tprintf("Date.prototype.%s called on non-Date object", method))
    return 0, false
}

// ano: 4 dígitos com sinal "-" se negativo (spec DateString/UTCString)
@(private = "file")
date_year_str :: proc(y: int) -> string {
    return y < 0 ? fmt.tprintf("-%04d", -y) : fmt.tprintf("%04d", y)
}

// "Thu Jan 01 1970"
@(private = "file")
date_date_part :: proc(p: Date_Parts) -> string {
    return fmt.tprintf("%s %s %02d %s", WDAY_ABBR[p.wday], MONTH_ABBR[p.month - 1], p.day, date_year_str(p.year))
}

// "00:00:00 GMT+0000 (Coordinated Universal Time)" — local == UTC, fuso fixo
@(private = "file")
date_time_part :: proc(p: Date_Parts) -> string {
    return fmt.tprintf("%02d:%02d:%02d GMT+0000 (Coordinated Universal Time)", p.hour, p.min, p.sec)
}

// toString: o formato de navegador (spec 21.4.4.41). Antes devolvia o ISO, e
// código que faz `String(d).split(' ')` ou exibe a data saía errado.
@(private = "file")
date_to_string :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    t, ok := date_this(vm, this, "toString")
    if !ok do return nil
    if t != t do return own_str(vm, "Invalid Date")
    p := date_parts(t)
    return own_str(vm, fmt.tprintf("%s %s", date_date_part(p), date_time_part(p)))
}

@(private = "file")
date_to_date_string :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    t, ok := date_this(vm, this, "toDateString")
    if !ok do return nil
    if t != t do return own_str(vm, "Invalid Date")
    return own_str(vm, date_date_part(date_parts(t)))
}

@(private = "file")
date_to_time_string :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    t, ok := date_this(vm, this, "toTimeString")
    if !ok do return nil
    if t != t do return own_str(vm, "Invalid Date")
    return own_str(vm, date_time_part(date_parts(t)))
}

// "Thu, 01 Jan 1970 00:00:00 GMT" (RFC 7231 / spec 21.4.4.43)
@(private = "file")
date_to_utc_string :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    t, ok := date_this(vm, this, "toUTCString")
    if !ok do return nil
    if t != t do return own_str(vm, "Invalid Date")
    p := date_parts(t)
    return own_str(vm, fmt.tprintf("%s, %02d %s %s %02d:%02d:%02d GMT", WDAY_ABBR[p.wday], p.day,
        MONTH_ABBR[p.month - 1], date_year_str(p.year), p.hour, p.min, p.sec))
}

// toISOString: data inválida LANÇA RangeError (spec); ano fora de 0..9999 usa a
// forma estendida ±YYYYYY.
@(private = "file")
date_iso :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    t, ok := date_this(vm, this, "toISOString")
    if !ok do return nil
    if t != t {
        vm.thrown = mk_error(vm, "RangeError", "Invalid time value"); vm.throwing = true
        return nil
    }
    p := date_parts(t)
    ys: string
    switch {
    case p.year < 0:     ys = fmt.tprintf("-%06d", -p.year)
    case p.year > 9999:  ys = fmt.tprintf("+%06d", p.year)
    case:                ys = fmt.tprintf("%04d", p.year)
    }
    s := fmt.tprintf("%s-%02d-%02dT%02d:%02d:%02d.%03dZ", ys, p.month, p.day, p.hour, p.min, p.sec, p.ms)
    return own_str(vm, s)
}

// toJSON (spec 21.4.4.37): genérico — ToPrimitive(this, number); não-finito → null;
// senão invoca this.toISOString(). Antes era o próprio toISOString, então
// `JSON.stringify({d: new Date(NaN)})` saía `{"d":"Invalid Date"}` em vez de null.
@(private = "file")
date_to_json :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    if is_nullish(this) { throw_type_error(vm, "Date.prototype.toJSON called on null or undefined"); return nil }
    tv := to_primitive(vm, this, true, "number")
    if vm.throwing do return nil
    if n, isnum := tv.(f64); isnum && (n != n || abs(n) == math.inf_f64(1)) do return JS_Null{}
    m := get_member(vm, this, "toISOString")
    if vm.throwing do return nil // getter que lança: a exceção é a do getter
    fn, ok := m.(^Function)
    if !ok { throw_type_error(vm, "toISOString is not a function"); return nil }
    return call_function(vm, fn, this, nil)
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
    // ToString do argumento (spec): Date.parse(objetoComToString) também vale
    v := arg(a, 0)
    if !is_primitive(v) {
        v = to_primitive(vm, v, false, "string")
        if vm.throwing do return nil
    }
    if _, sym := v.(^Symbol); sym { throw_type_error(vm, "Cannot convert a Symbol value to a string"); return nil }
    return date_parse_str(key_string(vm, v))
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
    proto.props["toJSON"]             = mk_native(vm, date_to_json)
    proto.props["toString"]           = mk_native(vm, date_to_string)
    proto.props["toDateString"]       = mk_native(vm, date_to_date_string)
    proto.props["toTimeString"]       = mk_native(vm, date_to_time_string)
    proto.props["toUTCString"]        = mk_native(vm, date_to_utc_string)
    // alias legado: a spec manda ser o MESMO objeto-função que toUTCString (dev.to/bing/espn)
    proto.props["toGMTString"]        = proto.props["toUTCString"]
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

// Date.UTC(ano[, mês0, ...]) → epoch-ms. Desde o ES2017 basta o ano (antes exigia 2
// args e `Date.UTC(1970)` dava NaN). Sem argumento nenhum: NaN.
@(private = "file")
native_date_utc :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    if len(a) == 0 do return math.nan_f64()
    tv, ok := date_from_components(vm, a)
    if !ok do return nil
    return time_clip(tv)
}
