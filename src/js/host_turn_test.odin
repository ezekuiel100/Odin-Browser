package js

import "core:testing"
import "core:time"

host_turn_block :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    time.sleep(20 * time.Millisecond)
    return nil
}

host_turn_test_vm :: proc() -> ^Interp {
    vm := vm_create()
    f := new_function(vm)
    f.native = host_turn_block
    vm.global.vars["block"] = f
    return vm
}

@(test)
host_turn_defers_timers_without_losing_order_or_cancellation :: proc(t: ^testing.T) {
    vm := host_turn_test_vm()
    defer vm_free(vm)
    vm_run(vm, `var result='';
        setTimeout(function(){result+='a'; clearTimeout(cancelled); block();}, 0);
        var cancelled=setTimeout(function(){result+='x';}, 0);
        setTimeout(function(){result+='b';}, 0);
        setTimeout(function(){result+='c';}, 0);`)
    vm_begin_host_turn(vm, 5)
    testing.expect(t, vm_pump_timers(vm, 1))
    testing.expect(t, vm_host_turn_expired(vm))
    vm_end_host_turn(vm)
    testing.expect_value(t, vm.global.vars["result"], Value("a"))
    testing.expect_value(t, len(vm.timers), 2)
    vm_pump_timers(vm, 0)
    testing.expect_value(t, vm_run(vm, "result"), Value("abc"))
    testing.expect_value(t, len(vm.timers), 0)
}

@(test)
host_turn_preserves_due_interval :: proc(t: ^testing.T) {
    vm := host_turn_test_vm()
    defer vm_free(vm)
    vm_run(vm, `var count=0;
        setTimeout(block, 0);
        var interval=setInterval(function(){count++;}, 1);`)
    vm_begin_host_turn(vm, 5)
    vm_pump_timers(vm, 1)
    vm_end_host_turn(vm)
    vm_pump_timers(vm, 0)
    testing.expect_value(t, as_number(vm_run(vm, "count")), 1.0)
    vm_pump_timers(vm, 0)
    testing.expect_value(t, as_number(vm_run(vm, "count")), 1.0)
    vm_pump_timers(vm, 1)
    testing.expect_value(t, as_number(vm_run(vm, "count")), 2.0)
}

@(test)
host_turn_resumes_microtasks_on_next_pump :: proc(t: ^testing.T) {
    vm := host_turn_test_vm()
    defer vm_free(vm)
    vm_run(vm, `var result='';
        setTimeout(function(){
            queueMicrotask(function(){result+='a'; block();});
            queueMicrotask(function(){result+='b';});
            queueMicrotask(function(){result+='c';});
        }, 0);`)
    vm_begin_host_turn(vm, 5)
    vm_pump_timers(vm, 1)
    vm_end_host_turn(vm)
    testing.expect_value(t, vm.global.vars["result"], Value("a"))
    vm_pump_timers(vm, 0)
    testing.expect_value(t, vm_run(vm, "result"), Value("abc"))
}

@(test)
host_turn_long_callback_retains_per_task_watchdog :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `setTimeout(function(){while(true){}}, 0);`)
    vm.time_budget_ms = 20 // frame scheduling must retain the per-task watchdog
    started := time.tick_now()
    vm_begin_host_turn(vm, 20)
    vm_pump_timers(vm, 0)
    testing.expect(t, vm_host_turn_expired(vm))
    vm_end_host_turn(vm)
    testing.expect(t, time.duration_milliseconds(time.tick_since(started)) < 1000)
    testing.expect(t, len(vm.uncaught_log) > 0)
    testing.expect_value(t, as_number(vm_run(vm, "1+2")), 3.0)
}

@(test)
host_turn_finishes_started_callback_before_deferring_next :: proc(t: ^testing.T) {
    vm := host_turn_test_vm()
    defer vm_free(vm)
    vm_run(vm, `var result=''; var caught='';
        setTimeout(function(){
            try {
                result+='start'; block();
                for(var i=0;i<4096;i++) {}
                result+='finish';
            } catch(e) { caught=e.name; result='Error'; }
        },0);
        setTimeout(function(){result+='next';},0);`)
    vm_begin_host_turn(vm, 5)
    vm_pump_timers(vm, 0)
    vm_end_host_turn(vm)
    testing.expect_value(t, vm.global.vars["result"], Value("startfinish"))
    testing.expect_value(t, vm.global.vars["caught"], Value(""))
    testing.expect_value(t, vm.uncaught_total, 0)
    testing.expect_value(t, len(vm.timers), 1)
    vm_pump_timers(vm, 0)
    testing.expect_value(t, vm.global.vars["result"], Value("startfinishnext"))
}

@(test)
host_turn_keeps_large_timer_batch_and_allows_later_cancellation :: proc(t: ^testing.T) {
    vm := host_turn_test_vm()
    defer vm_free(vm)
    vm_run(vm, `var count=0; var ids=[];
        setTimeout(block, 0);
        for(var i=0;i<500;i++) ids.push(setTimeout(function(){count++;},0));`)
    vm_begin_host_turn(vm, 5)
    vm_pump_timers(vm, 1)
    vm_end_host_turn(vm)
    testing.expect_value(t, len(vm.timers), 500)
    vm_run(vm, "clearTimeout(ids[0]);clearTimeout(ids[499]);")
    vm_pump_timers(vm, 0)
    testing.expect_value(t, as_number(vm.global.vars["count"]), 498.0)
    testing.expect_value(t, len(vm.timers), 0)
}
