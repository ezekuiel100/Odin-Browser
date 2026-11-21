#+build !windows
package js

// Fora do Windows (o projeto só builda lá): local == UTC, como antes de 21/11/2026.

tz_load_year :: proc(year: int, e: ^Tz_Year) { e.info = TZ_UTC }
tz_system_iana :: proc(buf: []u8) -> string { return "" }
