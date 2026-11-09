package ui

import csspkg "../css"

// Prioridade de autor sem aritmética de pesos nem carry entre colunas.
// A ordem de fonte fica no Win, pois aliases têm política própria de empate.
Cascade_Priority :: struct {
    important: bool,
    inline: bool,
    layer: int,
    specificity: [3]int,
}

// Positivo: a vence; negativo: b vence; zero: desempatar por ordem de fonte.
cascade_priority_compare :: proc(a, b: Cascade_Priority) -> int {
    // @property sintetizada é sempre fallback, mesmo com importância diferente.
    if a.layer == csspkg.LAYER_REGISTERED && b.layer != csspkg.LAYER_REGISTERED do return -1
    if b.layer == csspkg.LAYER_REGISTERED && a.layer != csspkg.LAYER_REGISTERED do return 1
    if a.important != b.important do return a.important ? 1 : -1
    if a.inline != b.inline do return a.inline ? 1 : -1
    layers := csspkg.layer_compare(csspkg.Rule{layer_rank = a.layer}, csspkg.Rule{layer_rank = b.layer}, a.important)
    if layers != 0 do return layers
    return csspkg.specificity_compare(a.specificity, b.specificity)
}
