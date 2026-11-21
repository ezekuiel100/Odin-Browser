#+build windows
package js

// Camada do Windows do fuso local (ver date_tz.odin).

import win "core:sys/windows"

foreign import kernel32_tz "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign kernel32_tz {
    GetTimeZoneInformationForYear :: proc(wYear: u16, pdtzi: rawptr, ptzi: ^win.TIME_ZONE_INFORMATION) -> win.BOOL ---
}

@(private = "file")
rule_from_systime :: proc(st: win.SYSTEMTIME) -> Tz_Rule {
    return Tz_Rule{
        month = int(st.month), week = int(st.day), wday = int(st.day_of_week),
        hour = int(st.hour), min = int(st.minute), sec = int(st.second), ms = int(st.milliseconds), year = int(st.year),
    }
}

// UTF-16 (terminada em 0) → UTF-8 em `dst[at:]`; devolve a fatia escrita.
@(private = "file")
wname :: proc(src: []u16, dst: []u8, at: ^int) -> string {
    start := at^
    for c in src {
        if c == 0 do break
        r := rune(c)
        if r >= 0xD800 && r <= 0xDFFF do r = '?' // BMP basta para nome de fuso
        b: [3]u8
        n: int
        switch {
        case r < 0x80:  b[0] = u8(r); n = 1
        case r < 0x800: b[0] = u8(0xC0 | (r >> 6)); b[1] = u8(0x80 | (r & 0x3F)); n = 2
        case:           b[0] = u8(0xE0 | (r >> 12)); b[1] = u8(0x80 | ((r >> 6) & 0x3F)); b[2] = u8(0x80 | (r & 0x3F)); n = 3
        }
        if at^ + n > len(dst) do break
        copy(dst[at^:], b[:n])
        at^ += n
    }
    return string(dst[start:at^])
}

tz_load_year :: proc(year: int, e: ^Tz_Year) {
    tzi: win.TIME_ZONE_INFORMATION
    if !bool(GetTimeZoneInformationForYear(u16(clamp(year, 1601, 30827)), nil, &tzi)) {
        e.info = TZ_UTC
        return
    }
    e.info.std_min = -int(tzi.Bias + tzi.StandardBias)
    e.info.dst_min = -int(tzi.Bias + tzi.DaylightBias)
    e.info.has_dst = tzi.StandardDate.month != 0 && tzi.DaylightDate.month != 0 && e.info.std_min != e.info.dst_min
    e.info.to_dst = rule_from_systime(tzi.DaylightDate)
    e.info.to_std = rule_from_systime(tzi.StandardDate)
    at := 0
    e.info.std_name = wname(tzi.StandardName[:], e.names[:], &at)
    e.info.dst_name = wname(tzi.DaylightName[:], e.names[:], &at)
}

// Nome IANA do fuso da máquina ("America/Sao_Paulo"), pelo ICU do Windows.
tz_system_iana :: proc(buf: []u8) -> string {
    w: [128]u16
    status: win.UError
    n := win.ucal_getDefaultTimeZone(cstring16(raw_data(w[:])), i32(len(w)), &status)
    if status != .U_ZERO_ERROR || n <= 0 do return ""
    at := 0
    return wname(w[:n], buf, &at)
}
