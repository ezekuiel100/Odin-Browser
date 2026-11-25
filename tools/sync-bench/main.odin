package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:time"
import js "../../src/js"

samples: [2]uintptr
sample_count: int

sample_stack :: proc(vm: ^js.Interp, this: js.Value, args: []js.Value) -> js.Value {
    marker: int
    if sample_count < len(samples) do samples[sample_count] = uintptr(&marker)
    sample_count += 1
    return nil
}

// Run in fresh processes, with identical optimization and stack flags for A/B.
// A successful recursion run samples native SP at the first and deepest JS call.
main :: proc() {
    scenario := "recursion"
    count := 3000
    if len(os.args) > 1 do scenario = os.args[1]
    if len(os.args) > 2 { count, _ = strconv.parse_int(os.args[2]) }
    if count < 1 || count > 1_000_000 { fmt.eprintln("count must be 1..1000000"); os.exit(2) }
    if scenario != "recursion" && scenario != "calls" { fmt.eprintln("scenario must be recursion or calls"); os.exit(2) }
    vm := js.vm_create()
    defer js.vm_free(vm)
    vm.time_budget_ms = 0
    probe := js.new_function(vm)
    probe.native = sample_stack
    js.env_define(vm.global, "sampleStack", probe)
    js.env_define(vm.global, "benchmarkCount", f64(count))
    source := `
        var benchmarkResult=-1, benchmarkError='';
        function descend(n){
            if(n===benchmarkCount || n===0) sampleStack();
            return n ? 1+descend(n-1) : 0;
        }
        try{benchmarkResult=descend(benchmarkCount);}catch(e){benchmarkError=e.name;}
    `
    if scenario == "calls" {
        source = `
            var benchmarkResult=0, benchmarkError='';
            function add(a,b){return a+b;}
            for(var i=0;i<benchmarkCount;i++) benchmarkResult=add(benchmarkResult,1);
        `
    }
    started := time.tick_now()
    js.vm_run(vm, source)
    elapsed := time.duration_milliseconds(time.tick_since(started))
    result, _ := vm.global.vars["benchmarkResult"].(f64)
    error, _ := vm.global.vars["benchmarkError"].(string)
    growth: uintptr
    if sample_count == 2 {
        growth = max(samples[0], samples[1])-min(samples[0], samples[1])
    }
    fmt.print("{")
    fmt.printf(`"scenario":"%s","count":%d,"result":%.0f,"error":"%s","samples":%d,"nativeStackGrowthBytes":%d,"elapsedMs":%.3f,"callDepthAfter":%d`, scenario, count, result, error, sample_count, growth, elapsed, vm.call_depth)
    fmt.println("}")
    if result != f64(count) || error != "" || vm.call_depth != 0 || vm.frame != nil do os.exit(1)
}
