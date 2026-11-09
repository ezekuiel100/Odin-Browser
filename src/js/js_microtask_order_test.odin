package js

import "core:testing"

// A primeira avaliação termina a tarefa e executa o checkpoint. A segunda
// observa as globais, sem confundir o valor de conclusão síncrono com o estado
// posterior aos jobs. Estes testes não exigem ordering completo de MO.
@(test)
test_microtask_shared_fifo :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var order = 'sync';
        var p = Promise.resolve();
        p.then(function() {
            order += ',a';
            queueMicrotask(function() { order += ',nested'; });
        }).then(function() { order += ',chain'; });
        queueMicrotask(function() { order += ',q'; });
        p.then(function() { order += ',b'; });
        order += ',end';
    `)
    ok, _ := vm_run(vm, `order === 'sync,end,a,q,b,nested,chain'`).(bool)
    testing.expect(t, ok, "Promise e queueMicrotask devem compartilhar FIFO no checkpoint")
}

@(test)
test_microtask_pending_settle_is_deferred :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var order = '';
        var resolve;
        var p = new Promise(function(r) { resolve = r; });
        p.then(function() { order += 'a'; });
        p.then(function() { order += 'b'; });
        resolve();
        order += 's';
    `)
    ok, _ := vm_run(vm, `order === 'sab'`).(bool)
    testing.expect(t, ok, "settle deve enfileirar sem executar reações na pilha síncrona")
}

@(test)
test_microtasks_between_timers :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var order = '';
        setTimeout(function() {
            order += 't1';
            Promise.resolve().then(function() { order += ',p'; });
            queueMicrotask(function() { order += ',q'; });
        }, 0);
        setTimeout(function() { order += ',t2'; }, 0);
    `)
    vm_pump_timers(vm, 1)
    ok, _ := vm_run(vm, `order === 't1,p,q,t2'`).(bool)
    testing.expect(t, ok, "cada timer deve terminar com checkpoint antes do próximo callback")
}

@(test)
test_queue_microtask_throw_does_not_poison_jobs :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var order = '';
        var badCallback = false;
        try { queueMicrotask(123); } catch (e) { badCallback = e.name === 'TypeError'; }
        queueMicrotask(function() { throw new Error('microtask failure'); });
        queueMicrotask(function() { order += 'q'; });
        Promise.resolve().then(function() { order += 'p'; });
    `)
    ok, _ := vm_run(vm, `badCallback && order === 'qp'`).(bool)
    testing.expect(t, ok, "TypeError síncrono e throw de job não devem bloquear a cauda")
    testing.expect_value(t, vm.uncaught_total, 1)
    testing.expect(t, !vm.throwing, "throw de queueMicrotask deve ser reportado e limpo")
}

@(test)
test_recursive_async_calls_keep_independent_promises :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    vm_run(vm, `
        var result = 0;
        async function recur(n) {
            if (n === 0) return 1;
            return (await recur(n - 1)) + 1;
        }
        recur(3).then(function(v) { result = v; });
    `)
    ok, _ := vm_run(vm, `result === 4`).(bool)
    testing.expect(t, ok, "recursão async deve criar uma corrotina própria em cada chamada")
}
