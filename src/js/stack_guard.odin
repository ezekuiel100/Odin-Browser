package js

// Guarda de stack por PONTEIRO (não por contagem de chamadas). Mede os bytes de
// stack NATIVA realmente consumidos e, ao se aproximar do fundo da região
// reservada da thread, faz o interpretador LANÇAR RangeError em vez de estourar
// a stack e FECHAR o processo (0xC00000FD).
//
// POR QUE não bastava o teto de call_depth (CALL_DEPTH_LIMIT): o custo de stack
// nativa POR chamada JS varia MUITO — uma função trivial (`rec(n)`) gasta pouco,
// mas uma chamada do reconciler do React gasta MUITO (dezenas de KB: expressões
// aninhadas, muitos locais). Então um teto fixo de contagem ou dispara cedo
// demais (quebra recursão legítima) ou tarde demais (a stack já estourou). Medir
// o ponteiro real é agnóstico ao tamanho do frame. Ver call_function (interp.odin).

// Folga deixada acima do fundo: ao disparar, ainda restam STACK_SAFETY_MARGIN
// bytes p/ montar o RangeError (mk_error é raso) e desenrolar (frames só POPAM).
// DEVE ser MENOR que qualquer stack real — inclusive a de 1MB do binário de
// `odin test` (que não usa /STACK): uma margem >= à stack inteira dispararia em
// TODA chamada. 256KB é folga de sobra e cabe até em 1MB.
STACK_SAFETY_MARGIN :: uintptr(256 * 1024) // 256KB

when ODIN_OS == .Windows {
    foreign import kernel32 "system:Kernel32.lib"
    @(default_calling_convention = "stdcall")
    foreign kernel32 {
        // Limites da região RESERVADA da stack da thread atual (Win8+).
        GetCurrentThreadStackLimits :: proc(LowLimit: ^uintptr, HighLimit: ^uintptr) ---
    }
    stack_low_limit :: proc() -> uintptr {
        low, high: uintptr
        GetCurrentThreadStackLimits(&low, &high)
        return low
    }
} else {
    stack_low_limit :: proc() -> uintptr { return 0 } // outras plataformas: só call_depth
}

// Chamado no início de cada TAREFA síncrona (vm_run, pump de timers, dispatch de
// evento). A stack pode ser de threads DIFERENTES — o fetch inicial roda numa
// worker, cliques rodam na main — então re-lemos o limite da thread corrente.
refresh_stack_limit :: proc(vm: ^Interp) {
    vm.stack_low = stack_low_limit()
}

// True se `sp` (ponteiro de stack atual, medido no frame do chamador) está a
// menos de STACK_SAFETY_MARGIN do fundo reservado — ou seja, perto de estourar.
// A stack cresce para BAIXO: (sp - fundo) = bytes ainda disponíveis.
stack_near_limit :: proc(vm: ^Interp, sp: uintptr) -> bool {
    if vm.stack_low == 0 do return false          // guarda desligada
    if sp <= vm.stack_low do return true           // já no fundo (ou abaixo)
    return sp - vm.stack_low < STACK_SAFETY_MARGIN
}
