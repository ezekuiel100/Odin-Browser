package ui

import "core:fmt"
import "core:os"
import "core:sync"
import "core:time"

// Diagnostic builds record directly from the app: no external process, PID
// attachment or recording window that can expire between user attempts.
LOADING_TRACE :: #config(LOADING_TRACE, true)

when LOADING_TRACE {
    g_loading_trace_lock: sync.Mutex
    g_loading_trace_lines: int
    g_loading_trace_phase: string
    g_loading_trace_tick: time.Tick
}

loading_trace_event :: proc(event: string) {
    when LOADING_TRACE {
        sync.mutex_lock(&g_loading_trace_lock)
        defer sync.mutex_unlock(&g_loading_trace_lock)
        if g_loading_trace_lines >= 4096 do return
        g_loading_trace_lines += 1
        line := fmt.aprintf("%d %s\n", time.tick_now()._nsec / 1_000_000, event)
        defer delete(line)
        f, err := os.open(#directory + "/../../_local/reports/loading-ui.log", os.O_WRONLY | os.O_CREATE | os.O_APPEND)
        if err != nil do return
        defer os.close(f)
        os.write(f, transmute([]byte)line)
    }
}

// UI-thread only; logging and the worker event writer serialize their output.
loading_trace_stage :: proc(phase: string) {
    when LOADING_TRACE {
        now := time.tick_now()
        if g_loading_trace_phase != "" {
            ms := time.duration_milliseconds(time.tick_diff(g_loading_trace_tick, now))
            if ms >= 100 {
                loading_trace_event(fmt.tprintf("slow-ui phase=%s ms=%.1f", g_loading_trace_phase, ms))
            }
        }
        g_loading_trace_phase = phase
        g_loading_trace_tick = now
    }
}
