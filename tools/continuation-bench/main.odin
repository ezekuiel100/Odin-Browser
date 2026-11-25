#+build windows
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"
import win "core:sys/windows"
import js "../../src/js"

// Same executable source can be built against the before and after engines.
// Report OS threads/committed memory in addition to VM allocation counts: a
// native thread's stack is not visible in the Odin heap allocator.
Process_Memory :: struct {
    cb, faults: u32,
    peak_working, working, peak_paged, paged, peak_nonpaged, nonpaged,
    pagefile, peak_pagefile, private_bytes: uintptr,
}

foreign import kernel32 "system:Kernel32.lib"
@(default_calling_convention = "system")
foreign kernel32 {
    K32GetProcessMemoryInfo :: proc(process: win.HANDLE, info: ^Process_Memory, cb: u32) -> win.BOOL ---
}

snapshot :: proc() -> (threads: u32, memory: Process_Memory) {
    memory.cb = u32(size_of(memory))
    K32GetProcessMemoryInfo(win.GetCurrentProcess(), &memory, memory.cb)
    snap := win.CreateToolhelp32Snapshot(win.TH32CS_SNAPPROCESS, 0)
    defer win.CloseHandle(snap)
    entry: win.PROCESSENTRY32W
    entry.dwSize = u32(size_of(entry))
    if win.Process32FirstW(snap, &entry) {
        for {
            if entry.th32ProcessID == win.GetCurrentProcessId() { threads = entry.cntThreads; break }
            if !win.Process32NextW(snap, &entry) do break
        }
    }
    return
}

main :: proc() {
    count := 1000
    if len(os.args) > 1 { count, _ = strconv.parse_int(os.args[1]) }
    if count < 1 || count > 10000 { fmt.eprintln("count must be 1..10000"); os.exit(2) }
    vm := js.vm_create()
    vm.time_budget_ms = 0
    js.env_define(vm.global, "benchmarkCount", f64(count))
    threads_before, memory_before := snapshot()
    source := `
        var release, total=0, completed=0;
        var pending=new Promise(function(r){release=r;});
        async function work(i){var local={value:i}; await pending; total+=local.value; completed++;}
        for(var i=0;i<benchmarkCount;i++) work(i);
    `
    started := time.tick_now()
    js.vm_run(vm, source)
    start_ms := time.duration_milliseconds(time.tick_since(started))
    threads_pending, memory_pending := snapshot()
    before_trash := js.gc_heap_count(vm)
    for _ in 0..<6000 { js.new_object(vm) }
    collected := js.vm_collect(vm)
    after_collect := js.gc_heap_count(vm)
    started = time.tick_now()
    js.vm_run(vm, "release()")
    resume_ms := time.duration_milliseconds(time.tick_since(started))
    completed, _ := vm.global.vars["completed"].(f64)
    total, _ := vm.global.vars["total"].(f64)
    threads_done, _ := snapshot()
    js.vm_collect(vm)
    generators_after := len(vm.all_generators)
    started = time.tick_now()
    js.vm_free(vm)
    dispose_ms := time.duration_milliseconds(time.tick_since(started))
    fmt.print("{")
    fmt.printf(`"count":%d,"threadsBefore":%d,"threadsPending":%d,"threadsDone":%d,"privateBytesBefore":%d,"privateBytesPending":%d,"workingSetBefore":%d,"workingSetPending":%d,"gcWhilePending":%t,"heapBeforeTrash":%d,"heapAfterCollection":%d,"generatorsAfterCollection":%d,"completed":%.0f,"total":%.0f,"startMs":%.3f,"resumeMs":%.3f,"disposeMs":%.3f`,
        count, threads_before, threads_pending, threads_done,
        memory_before.private_bytes, memory_pending.private_bytes, memory_before.working, memory_pending.working,
        collected, before_trash, after_collect, generators_after, completed, total, start_ms, resume_ms, dispose_ms)
    fmt.println("}")
    if int(completed) != count || total != f64(count*(count-1)/2) do os.exit(1)
}
