package css

import "core:strings"

// Registro LOCAL a um parse. O pipeline concatena as folhas antes de chamar
// parse, portanto declarações e reaberturas compartilham este mesmo registro.
// IDs transitórios (índice + 1) nunca escapam: finalize troca-os por ranks.
@(private)
Layer_Node :: struct { name: string, parent: int, rank: int }
@(private)
Layer_Registry :: struct { nodes: [dynamic]Layer_Node }

@(private)
layer_child :: proc(layers: ^Layer_Registry, parent: int, name: string) -> int {
    // Nome vazio = layer anônima: cada ocorrência cria uma identidade nova.
    if name != "" {
        for node, i in layers.nodes {
            if node.parent == parent && node.name == name do return i + 1
        }
    }
    append(&layers.nodes, Layer_Node{name = name, parent = parent})
    return len(layers.nodes)
}

// Escapes são consumidos ANTES de reconhecer separadores. Um ponto/vírgula
// escapado pertence ao identificador, nunca à hierarquia/lista. Strings
// decodificadas vivem no temp_allocator, como o texto-fonte deste parse.
// Encontrar { ou ; sem cortar escapes simples (ex.: @layer foo\;bar).
@(private)
layer_prelude_end :: proc(s: string, start: int) -> int {
    return token_boundary(s, start, "{;")
}

@(private)
layer_ident_start :: proc(c: u8) -> bool {
    return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || c == '_' || c >= 128 || c == '\\'
}

// Valida a grafia do token (dígitos iniciais só quando escapados), mas testa
// keywords e registra a identidade pelo valor decodificado do identificador.
@(private)
layer_ident :: proc(s: string, start: int) -> (name: string, end: int, ok: bool) {
    i := start
    if i >= len(s) do return "", i, false
    if s[i] == '-' {
        i += 1
        if i >= len(s) || !(layer_ident_start(s[i]) || s[i] == '-') do return "", i, false
    } else if !layer_ident_start(s[i]) {
        return "", i, false
    }
    sb := strings.builder_make(context.temp_allocator)
    i = start
    for i < len(s) {
        c := s[i]
        if c == '\\' {
            cp, next, valid := consume_escape(s, i)
            if !valid do return "", next, false
            strings.write_rune(&sb, cp)
            i = next
        } else if layer_ident_start(c) || c == '-' || (c >= '0' && c <= '9') {
            strings.write_byte(&sb, c)
            i += 1
        } else {
            break
        }
    }
    name = strings.to_string(sb)
    if strings.equal_fold(name, "initial") || strings.equal_fold(name, "inherit") ||
       strings.equal_fold(name, "unset") || strings.equal_fold(name, "revert") ||
       strings.equal_fold(name, "revert-layer") || strings.equal_fold(name, "default") {
        return "", i, false
    }
    return name, i, true
}

// Valide a lista INTEIRA antes de registrar; um erro não deixa layers parciais.
@(private)
layer_prelude :: proc(layers: ^Layer_Registry, parent: int, prelude: string, block: bool) -> int {
    paths := make([dynamic][]string, context.temp_allocator)
    path := make([dynamic]string, context.temp_allocator)
    i := 0
    for i < len(prelude) && is_space(prelude[i]) do i += 1
    if i == len(prelude) {
        if block do return layer_child(layers, parent, "")
        return -1
    }
    for {
        name, end, ok := layer_ident(prelude, i)
        if !ok do return -1
        append(&path, name)
        i = end
        for i < len(prelude) && is_space(prelude[i]) do i += 1
        if i < len(prelude) && prelude[i] == '.' {
            i += 1
            for i < len(prelude) && is_space(prelude[i]) do i += 1
            continue
        }
        append(&paths, path[:])
        path = make([dynamic]string, context.temp_allocator)
        if i == len(prelude) do break
        if block || prelude[i] != ',' do return -1
        i += 1
        for i < len(prelude) && is_space(prelude[i]) do i += 1
    }
    current := parent
    for parts in paths {
        current = parent
        for part in parts do current = layer_child(layers, current, part)
    }
    return block ? current : parent
}

// Pós-ordem: filhos primeiro, declarações diretas do pai depois. A ordem dos
// irmãos é a da PRIMEIRA declaração, não a posição da última reabertura.
@(private)
layer_rank_children :: proc(layers: ^Layer_Registry, parent: int, next: ^int) {
    for i := 0; i < len(layers.nodes); i += 1 {
        if layers.nodes[i].parent != parent do continue
        layer_rank_children(layers, i + 1, next)
        layers.nodes[i].rank = next^
        next^ += 1
    }
}

@(private)
layer_finalize :: proc(layers: ^Layer_Registry, rules: []Rule) {
    next := 0
    layer_rank_children(layers, LAYER_UNLAYERED, &next)
    for &rule in rules {
        if rule.layer_rank == LAYER_UNLAYERED || rule.layer_rank == LAYER_REGISTERED do continue
        rule.layer_rank = layers.nodes[rule.layer_rank - 1].rank
    }
}

// Resultado positivo: a vence; negativo: b vence; zero: desempatar pela
// especificidade/ordem. !important inverte TODA a árvore (inclusive sem-layer).
// @property sintética continua fallback, não ganha com a inversão.
layer_compare :: proc(a, b: Rule, important: bool) -> int {
    if a.layer_rank == b.layer_rank do return 0
    if a.layer_rank == LAYER_REGISTERED do return -1
    if b.layer_rank == LAYER_REGISTERED do return 1
    result := a.layer_rank > b.layer_rank ? 1 : -1
    return important ? -result : result
}
