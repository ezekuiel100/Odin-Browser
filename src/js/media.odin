package js

// HTMLMediaElement: play() / pause() / load() e o ESTADO que os torna coerentes.
//
// Era `TypeError: e.pause is not a function` — `HTMLMediaElement` existia só como
// casca de `instanceof`, sem um único método.
//
// ── A decisão que importa: play() REJEITA ────────────────────────────────────
// Não há decodificador de mídia neste navegador. Havia duas saídas:
//
//   (a) resolver a promise e fingir que tocou. O site esconde o pôster, mostra
//       uma área preta e fica esperando `timeupdate`/`ended` que NUNCA vêm —
//       carrossel que avança no fim do vídeo trava para sempre. É o "stub de
//       valor neutro" que erra em SILÊNCIO.
//   (b) rejeitar com `NotAllowedError`, que é EXATAMENTE o que um navegador de
//       verdade faz quando a reprodução não pode começar (autoplay bloqueado).
//       O site cai no caminho que ele já tem testado: mantém o pôster e mostra o
//       botão de play.
//
// Escolhemos (b), e não por conformidade: (b) RENDERIZA MELHOR. O pôster é a
// imagem certa a mostrar quando não se toca vídeo. `paused` continua `true`
// depois de um play() rejeitado — que é o estado verdadeiro, e o mesmo que o
// navegador real reporta nesse caso.
//
// ⚠️ Consequência aceita: site que chama `video.play()` sem `.catch()` gera uma
// rejeição não tratada. Navegador real tem o mesmo comportamento (é um footgun
// conhecido da API), e o alternativa seria mentir sobre o estado.
//
// `canPlayType()` devolve "" (= não sei tocar), que é a resposta honesta e a que
// a spec reserva para "não suportado". Todo detector sério testa esse retorno.
//
// O resto do estado (currentTime, volume, muted, playbackRate, loop) é REAL:
// escreve e lê de volta, porque é isso que o código de UI espera. O que não
// existe é o TEMPO ANDANDO — `currentTime` só muda se alguém escrever nele.

import "core:math"
import dom "../dom"

Media_State :: struct {
    paused:        bool,
    ended:         bool,
    current_time:  f64,
    volume:        f64,
    muted:         bool,
    playback_rate: f64,
    loop_:         bool,
}

is_media_node :: proc(n: ^dom.Node) -> bool {
    return n != nil && n.kind == .Element && (n.tag == "video" || n.tag == "audio")
}

@(private = "file")
media_state_of :: proc(vm: ^Interp, node: ^dom.Node) -> ^Media_State {
    if !is_media_node(node) do return nil
    if vm.media == nil do vm.media = make(map[rawptr]^Media_State)
    if m, ok := vm.media[rawptr(node)]; ok do return m
    m := new(Media_State)
    m.paused = true // nada toca até um play() BEM-SUCEDIDO — e nenhum é
    m.volume = 1
    m.playback_rate = 1
    if node.attrs != nil { // `muted`/`loop` são atributos de conteúdo: refletem
        _, m.muted = node.attrs["muted"]
        _, m.loop_ = node.attrs["loop"]
    }
    vm.media[rawptr(node)] = m
    return m
}

media_free :: proc(vm: ^Interp) {
    if vm.media == nil do return
    for _, m in vm.media do free(m)
    delete(vm.media)
    vm.media = nil
}

// ── métodos ─────────────────────────────────────────────────────────────────

native_media_play :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    p := promise_new(vm)
    if !is_media_node(node) {
        promise_settle(vm, p, PROMISE_REJECTED,
            mk_error(vm, "NotSupportedError", "play() chamado em elemento que não é <video>/<audio>"))
        return p
    }
    // ⚠️ ver o cabeçalho: rejeitar é a resposta VERDADEIRA e a que renderiza melhor.
    promise_settle(vm, p, PROMISE_REJECTED,
        mk_error(vm, "NotAllowedError", "não há decodificador de mídia: a reprodução não começou"))
    return p
}

native_media_pause :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    m := media_state_of(vm, node)
    if m == nil do return nil
    // Só dispara o evento na TRANSIÇÃO (spec). Pausar o que já está pausado é
    // no-op silencioso — disparar sempre faria handler de UI piscar à toa.
    if !m.paused {
        m.paused = true
        dispatch_event(vm, node, "pause")
    }
    return nil
}

native_media_load :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    node := node_of(this)
    m := media_state_of(vm, node)
    if m == nil do return nil
    m.paused, m.ended, m.current_time = true, false, 0
    return nil
}

// "" = não sei tocar. As outras respostas da spec são "probably"/"maybe", e
// qualquer uma delas aqui seria uma promessa que não podemos cumprir.
native_media_can_play_type :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return own_str(vm, "")
}

// ── propriedades (chamadas pelo get/set hook de elemento) ────────────────────

// Devolve (valor, true) quando `name` é uma propriedade de mídia DESTE nó.
media_get :: proc(vm: ^Interp, node: ^dom.Node, name: string) -> (Value, bool) {
    if !is_media_node(node) do return nil, false
    m := media_state_of(vm, node)
    if m == nil do return nil, false
    switch name {
    case "paused":       return m.paused, true
    case "ended":        return m.ended, true
    case "currentTime":  return m.current_time, true
    case "volume":       return m.volume, true
    case "muted":        return m.muted, true
    case "defaultMuted": return m.muted, true
    case "playbackRate", "defaultPlaybackRate": return m.playback_rate, true
    case "loop":         return m.loop_, true
    // ── o que NÃO sabemos, dito com o valor que a spec reserva p/ "não sei" ──
    case "duration":     return math.nan_f64(), true // NaN = duração desconhecida
    case "readyState":   return f64(0), true      // HAVE_NOTHING
    case "networkState": return f64(0), true      // NETWORK_EMPTY
    case "seeking":      return false, true
    case "videoWidth", "videoHeight": return f64(0), true
    case "currentSrc":
        if node.attrs != nil do if s, ok := node.attrs["src"]; ok do return own_str(vm, s), true
        return own_str(vm, ""), true
    }
    return nil, false
}

// true quando consumiu a escrita.
media_set :: proc(vm: ^Interp, node: ^dom.Node, name: string, val: Value) -> bool {
    if !is_media_node(node) do return false
    m := media_state_of(vm, node)
    if m == nil do return false
    switch name {
    case "currentTime":
        m.current_time = to_number(vm, val)
        m.ended = false
        dispatch_event(vm, node, "timeupdate") // seek observável, como no real
        return true
    case "volume":
        m.volume = to_number(vm, val)
        dispatch_event(vm, node, "volumechange")
        return true
    case "muted":
        m.muted = truthy(val)
        dispatch_event(vm, node, "volumechange")
        return true
    case "playbackRate", "defaultPlaybackRate":
        m.playback_rate = to_number(vm, val)
        return true
    case "loop":
        m.loop_ = truthy(val)
        return true
    }
    return false
}
