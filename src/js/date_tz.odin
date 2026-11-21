package js

// Fuso horário LOCAL do Date (spec 21.4.1.25 LocalTZA / LocalTime / UTC).
//
// Até 21/11/2026 a Date era UTC pura (getTimezoneOffset() = 0, getHours ==
// getUTCHours): numa máquina em UTC-3 todo relógio de página aparecia 3 h
// adiantado e `new Date(2026, 0, 1)` caía às 21h do dia 31.
//
// A fonte é a regra do Windows POR ANO (GetTimeZoneInformationForYear): bias
// padrão, bias de verão e as duas datas de transição no formato "n-ésimo
// dia-da-semana do mês". Por ano porque as regras mudam (o Brasil teve horário
// de verão até 2019; uma data de 2018 tem que sair em -02). Cada ano consultado
// fica num cache por thread — getHours num laço não pode ir ao registro a cada
// chamada.
//
// Testes: `tz_override` (global, ligado no @(init) dos testes do pacote para UTC
// — os testes antigos assumem local == UTC) e `tz_override_thread` (por thread,
// p/ um teste simular um fuso) substituem o sistema.

import "core:math"

Tz_Rule :: struct {
    month, week, wday: int,  // week 1..5 (5 = última); wday 0 = domingo
    hour, min, sec, ms: int, // o Windows usa 23:59:59.999 ("fim do sábado")
    year: int,               // ≠ 0: data ABSOLUTA (week vira o dia do mês)
}

Tz_Info :: struct {
    std_min, dst_min: int,   // deslocamento local − UTC, em minutos
    has_dst:  bool,
    to_dst:   Tz_Rule,       // em hora local PADRÃO
    to_std:   Tz_Rule,       // em hora local DE VERÃO
    std_name: string,
    dst_name: string,
}

Tz_Override :: struct {
    active: bool,
    info:   Tz_Info,
    iana:   string,
}

tz_override: Tz_Override
@(thread_local) tz_override_thread: Tz_Override

TZ_UTC :: Tz_Info{std_name = "Coordinated Universal Time", dst_name = "Coordinated Universal Time"}

Tz_Year :: struct {
    year:      int,
    valid:     bool,
    info:      Tz_Info,
    names:     [128]u8,      // armazenamento de std_name/dst_name (UTF-8)
}

@(private = "file") @(thread_local) tz_cache: [8]Tz_Year
@(private = "file") @(thread_local) tz_cache_next: int

// Regras do fuso para um ano civil.
tz_info_for_year :: proc(year: int) -> Tz_Info {
    if tz_override_thread.active do return tz_override_thread.info
    if tz_override.active do return tz_override.info
    for &e in tz_cache do if e.valid && e.year == year do return e.info
    e := &tz_cache[tz_cache_next]
    tz_cache_next = (tz_cache_next + 1) % len(tz_cache)
    e^ = {}
    tz_load_year(year, e)
    e.year = year
    e.valid = true
    return e.info
}

// Nome IANA para o Intl (resolvedOptions().timeZone). "UTC" sob override sem nome
// ou se o sistema não responder.
tz_iana_name :: proc(buf: []u8) -> string {
    if tz_override_thread.active do return tz_override_thread.iana != "" ? tz_override_thread.iana : "UTC"
    if tz_override.active do return tz_override.iana != "" ? tz_override.iana : "UTC"
    s := tz_system_iana(buf)
    return s != "" ? s : "UTC"
}

// Instante UTC (ms) de uma regra de transição no ano `y`, dada em hora local com
// deslocamento `off_min`.
@(private = "file")
rule_utc_ms :: proc(r: Tz_Rule, y: int, off_min: int) -> f64 {
    day := r.week
    if r.year == 0 {
        // n-ésimo `wday` do mês; 5 = o último
        first_wd := (((days_from_civil(y, r.month, 1) + 4) % 7) + 7) % 7
        day = 1 + (r.wday - first_wd + 7) % 7 + (r.week - 1) * 7
        for day > days_in_month(y, r.month) do day -= 7
    }
    local := f64(days_from_civil(y, r.month, day)) * 86_400_000 +
             f64(r.hour) * 3_600_000 + f64(r.min) * 60_000 + f64(r.sec) * 1000 + f64(r.ms)
    return local - f64(off_min) * 60_000
}

@(private = "file")
year_of :: proc(t: f64) -> int {
    days := int(math.floor(t / 86_400_000))
    y, _, _ := civil_from_days(days)
    return y
}

// O deslocamento é de verão no instante UTC `t`?
@(private = "file")
in_dst :: proc(info: Tz_Info, t: f64, y: int) -> bool {
    if !info.has_dst do return false
    start := rule_utc_ms(info.to_dst, y, info.std_min)
    end   := rule_utc_ms(info.to_std, y, info.dst_min)
    if start < end do return t >= start && t < end
    return t >= start || t < end // hemisfério sul: o verão atravessa o ano-novo
}

// Regras e estado (verão ou não) no instante UTC `t`. O ano das regras é o ano
// LOCAL (um instante de 31/12 23h UTC já é 1º/1 em UTC+2).
@(private = "file")
tz_at :: proc(t: f64) -> (info: Tz_Info, dst: bool) {
    y := year_of(t)
    info = tz_info_for_year(y)
    if ly := year_of(t + f64(info.std_min) * 60_000); ly != y {
        y = ly
        info = tz_info_for_year(y)
    }
    return info, in_dst(info, t, y)
}

// LocalTZA(t, true): local − UTC em ms no instante UTC `t`.
local_offset_ms :: proc(t: f64) -> f64 {
    if t != t do return 0
    info, dst := tz_at(t)
    return f64(dst ? info.dst_min : info.std_min) * 60_000
}

// LocalTime(t)
local_time :: proc(t: f64) -> f64 {
    if t != t do return t
    return t + local_offset_ms(t)
}

// UTC(t_local) — LocalTZA(t, false). Hora local REPETIDA (fim do verão) ou
// PULADA (início) usa o deslocamento de ANTES da transição (spec): na repetida
// é o maior (o verão), na pulada o menor (o padrão).
utc_from_local :: proc(tl: f64) -> f64 {
    if tl != tl do return tl
    info := tz_info_for_year(year_of(tl))
    std := f64(info.std_min) * 60_000
    if !info.has_dst do return tl - std
    dst := f64(info.dst_min) * 60_000
    ok_std := local_offset_ms(tl - std) == std
    ok_dst := local_offset_ms(tl - dst) == dst
    switch {
    case ok_std && ok_dst: return tl - max(std, dst)
    case ok_std:           return tl - std
    case ok_dst:           return tl - dst
    }
    return tl - min(std, dst)
}

// Nome do fuso para o toString ("Hora oficial do Brasil"); vazio = omite.
tz_name_at :: proc(t: f64) -> string {
    info, dst := tz_at(t)
    return dst ? info.dst_name : info.std_name
}

// `options.timeZone` pede UTC? (toLocale*String e Intl.DateTimeFormat). Outros
// nomes IANA caem na hora local: sem a base de fusos não sabemos converter, e o
// fuso pedido costuma ser o da própria máquina.
tz_option_is_utc :: proc(vm: ^Interp, opts: Value) -> bool {
    if _, ok := opts.(^Object); !ok do return false
    v := get_member(vm, opts, "timeZone")
    if vm.throwing do return false
    s, ok := v.(string)
    if !ok do return false
    switch s {
    case "UTC", "utc", "Etc/UTC", "Etc/GMT", "GMT", "Etc/Universal", "Etc/Zulu", "UCT", "Etc/UCT", "Universal", "Zulu":
        return true
    }
    return false
}
