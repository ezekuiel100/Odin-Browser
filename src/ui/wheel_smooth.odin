package ui

import "core:math"
import "core:os"

// ── Roda do mouse SUAVE (rolagem da página) ─────────────────────────────────
// Antes: cada clique da roda era `SetScrollY(GetScrollY() - roda*60)` — um salto
// seco de 60 px no MESMO frame. Mesmo a 60 fps isso se lê como degrau.
// Agora a roda move um ALVO e a posição persegue o alvo com decaimento
// exponencial na constante de tempo WHEEL_TAU:
//   • cliques seguidos ACUMULAM no alvo (girar rápido vai longe), e girar para
//     o outro lado no meio da animação inverte a partir do alvo, não da posição;
//   • o passo é função do TEMPO (`dt`), não do nº de frames: a 5 fps a animação
//     termina no mesmo tempo de parede que a 60 fps (só com menos quadros) —
//     o `d * 0.2` por frame da âncora suave depende do fps, este não;
//   • o valor entregue é INTEIRO: texto em posição sub-pixel sai borrado (mesma
//     razão do `acc` do autoscroll.odin);
//   • QUALQUER outro escritor do scroll vence. Se o scroll que o ImGui reporta
//     não é o último que a animação escreveu, alguém mexeu (arrastou a barra,
//     âncora `#id`, navegação, o conteúdo encolheu e o ImGui clampou) e a
//     animação larga o controle em vez de puxar a página de volta.
//
// Containers internos usam o mesmo passo, com seu deslocamento de 40 px.

// Sonda (`-define:WHEELPROBE=true`): uma linha por frame em que a roda chegou ou a
// animação vertical está ativa — tempo de parede, dt, roda, scroll lido e escrito.
// É o que prova a animação no APP (o headless não passa pelo draw_content).
WHEELPROBE :: #config(WHEELPROBE, false)

// Só na sonda: URL a abrir ao iniciar (`WHEELPROBE_URL`). Mensagem postada não
// ativa a barra de endereço com a janela em foco (o backend lê o cursor REAL),
// e dirigir o mouse de verdade tomaria a máquina de quem está usando.
wheel_probe_startup_url :: proc() -> string {
    when WHEELPROBE { return os.get_env("WHEELPROBE_URL", context.temp_allocator) }
    return ""
}

WHEEL_STEP_PX :: f32(60)   // px por clique da roda (o valor do salto antigo)
WHEEL_TAU     :: f32(0.05) // constante de tempo (s): ~95% do caminho em 3τ = 150 ms
WHEEL_DT_MAX  :: f32(1)    // dt absurdo (janela arrastada, breakpoint) não vira NaN/overshoot

Wheel_Axis :: struct {
    on:       bool,
    pos:      f32, // posição animada, fracionária (só a saída é arredondada)
    target:   f32, // aonde a roda mandou ir, já clampado em [0, max]
    last_set: f32, // o último valor ENTREGUE — detecta escritor externo
}

// Um passo de um eixo. `cur` = scroll que o ImGui reporta neste frame; `max_v` =
// limite do eixo; `delta` = deslocamento pedido pela roda NESTE frame, em px
// (+ = para baixo/direita); `dt` = segundos desde o frame anterior.
// Devolve `set=true` e o valor a escrever quando a animação está ativa.
wheel_axis_step :: proc(a: ^Wheel_Axis, cur, max_v, delta, dt: f32) -> (value: f32, set: bool) {
    // alguém mexeu no scroll desde o nosso último SetScroll: larga o controle.
    // Tolerância de 1 px para o ImGui arredondar/clampar à moda dele.
    if a.on && abs(cur - a.last_set) > 1 do a.on = false

    hi := max(max_v, 0)
    if delta != 0 {
        if !a.on {
            a.on = true
            a.pos = cur
            a.target = cur
        }
        a.target += delta
    }
    if !a.on do return

    a.target = clamp(a.target, 0, hi) // o limite pode ter encolhido no caminho
    t := clamp(dt, 0, WHEEL_DT_MAX)
    k := 1 - math.exp(-t / WHEEL_TAU)
    a.pos += (a.target - a.pos) * k
    if abs(a.target - a.pos) < 0.5 {
        a.pos = a.target
        a.on = false // último passo: entrega o alvo e para
    }
    value = math.round(a.pos)
    a.last_set = value
    return value, true
}

wheel_axis_stop :: proc(a: ^Wheel_Axis) {
    a.on = false
}

// Decide o encadeamento pelo alvo, inclusive enquanto a posição ainda anima.
// Assim uma roda no limite passa ao ancestral sem cancelar a animação local.
wheel_container_step :: proc(a: ^Wheel_Axis, cur, max_v, delta, dt: f32, contain: bool) -> (value: f32, consumed: bool) {
    target := a.on && abs(cur - a.last_set) <= 1 ? a.target : cur
    consumed = delta != 0 && (contain || clamp(target + delta, 0, max(max_v, 0)) != target)
    value = cur
    if v, ok := wheel_axis_step(a, cur, max_v, consumed ? delta : 0, dt); ok do value = v
    return
}
