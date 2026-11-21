package ui

import "core:fmt"
import "core:os"
import "core:time"
import im "../../vendor/imgui"

// Reproducible diagnostic run of the real UI loop, without taking mouse focus.
// Build with SCROLLPROBE and WHEELPROBE; WHEELPROBE_URL selects the page.
SCROLLPROBE :: #config(SCROLLPROBE, false)
when SCROLLPROBE {
    g_sp_start: time.Tick
    g_sp_ready: time.Tick
    g_sp_phase: string
    g_sp_tick: time.Tick
    g_sp_frame: int
    g_sp_next: f64
    g_sp_measuring: bool
    g_sp_skip_backdrop: bool
}

scroll_probe_stage :: proc(phase: string) {
    when SCROLLPROBE {
        now := time.tick_now()
        if g_sp_measuring && g_sp_phase != "" {
            fmt.eprintfln("[scrollphase],%d,%s,%.3f", g_sp_frame, g_sp_phase,
                time.duration_milliseconds(time.tick_diff(g_sp_tick, now)))
        }
        if phase == "events" do g_sp_frame += 1
        g_sp_phase = phase
        g_sp_tick = now
    }
}

scroll_probe_input :: proc(s: ^State) -> bool {
    when SCROLLPROBE {
        if g_sp_start._nsec == 0 {
            g_sp_start = time.tick_now()
            g_sp_skip_backdrop = os.get_env("SCROLLPROBE_SKIP_BACKDROP", context.temp_allocator) == "1"
        }
        if time.duration_seconds(time.tick_since(g_sp_start)) > 90 do return true
        if len(s.tabs) == 0 || s.tabs[s.active].layout == nil do return false
        if g_sp_ready._nsec == 0 {
            g_sp_ready = time.tick_now()
            fmt.eprintln("[scrollprobe] page-ready")
        }
        elapsed := time.duration_seconds(time.tick_since(g_sp_ready))
        g_sp_measuring = elapsed >= 3
        if elapsed >= 12 {
            when UIPROF {
                p := g_uiprof
                fmt.eprintfln("[scrolllayers] whole-run calls=%d hits=%d built=%d changed=%d texture_ms=%.3f record_ms=%.3f replay_ms=%.3f",
                    p.lay_n, p.lay_hit, p.lay_tex_built, p.lay_m_hash,
                    p.ms_lay_tex, p.ms_record, p.ms_replay)
            }
            return true
        }
        io := im.GetIO()
        io.MousePos = {600, 400}
        io.MouseWheel = 0
        if elapsed >= 3 && elapsed < 9 && elapsed >= g_sp_next {
            io.MouseWheel = -2
            g_sp_next = elapsed + 0.1
        }
    }
    return false
}
