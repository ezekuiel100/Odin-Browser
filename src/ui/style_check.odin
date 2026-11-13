package ui

// Oráculo de EQUIVALÊNCIA do cômputo de estilo (compile-gated:
// `-define:STYLECHECK=true`). A cada compute_styles, recomputa a árvore inteira
// pelo caminho de REFERÊNCIA — índice antigo (só id/classe/tag), sem filtro de
// ancestrais, sem memo de variáveis, cascata COMPLETA — e compara o Computed de
// cada nó campo a campo. Como o restyle incremental também passa por aqui, a
// mesma conferência prova que o mapa atualizado por subárvore é igual ao que a
// cascata completa produziria.
//
// Feito p/ rodar em SITE REAL (`--diagnose`): os testes de unidade não têm o CSS
// do github nem o DOM que o JS dele monta.

import "base:runtime"
import "core:fmt"
import "core:mem"
import dompkg "../dom"
import csspkg "../css"

STYLECHECK :: #config(STYLECHECK, false)
// Prova negativa do oráculo: cada define quebra UMA otimização de propósito.
SABOTAGE_ANC  :: #config(SABOTAGE_ANC, false)  // filtro exige ancestral também em `+`/`~`
SABOTAGE_MEMO :: #config(SABOTAGE_MEMO, false) // memo de vars ignora o mapa do pai
SABOTAGE_SIB  :: #config(SABOTAGE_SIB, false)  // mudança com `+`/`~` não alarga ao pai
SABOTAGE_DIRAUTO :: #config(SABOTAGE_DIRAUTO, false) // ignora ancestral dir=auto
SABOTAGE_PRUNE :: #config(SABOTAGE_PRUNE, false) // nó removido fica no mapa

// true enquanto o compute_styles de REFERÊNCIA roda: desliga as otimizações.
@(thread_local) g_style_legacy: bool

Style_Check :: struct {
    runs:       int,
    nodes:      int,
    mismatches: int,
    missing:    int,
    extra:      int,
}
g_style_check: Style_Check

// Caminho do 1º campo divergente ("" = iguais). Ponteiros são seguidos (o
// endereço não é valor CSS), slices/strings comparados por conteúdo, mapas por
// tamanho (o Computed não guarda mapa de valor).
deep_diff :: proc(a, b: rawptr, ti: ^runtime.Type_Info, path: string, depth := 0) -> string {
    if depth > 12 do return ""
    base := runtime.type_info_base(ti)
    #partial switch v in base.variant {
    case runtime.Type_Info_Struct:
        for i in 0 ..< v.field_count {
            off := v.offsets[i]
            p := deep_diff(rawptr(uintptr(a) + off), rawptr(uintptr(b) + off), v.types[i],
                v.names[i], depth + 1)
            if p != "" do return path == "" ? p : fmt.tprintf("%s.%s", path, p)
        }
        return ""
    case runtime.Type_Info_Pointer:
        pa := (^rawptr)(a)^
        pb := (^rawptr)(b)^
        if (pa == nil) != (pb == nil) do return path
        if pa == nil || v.elem == nil do return ""
        return deep_diff(pa, pb, v.elem, path, depth + 1)
    case runtime.Type_Info_String:
        if (^string)(a)^ != (^string)(b)^ do return path
        return ""
    case runtime.Type_Info_Slice:
        sa := (^runtime.Raw_Slice)(a)^
        sb := (^runtime.Raw_Slice)(b)^
        if sa.len != sb.len do return path
        for i in 0 ..< sa.len {
            off := uintptr(i * v.elem_size)
            if p := deep_diff(rawptr(uintptr(sa.data) + off), rawptr(uintptr(sb.data) + off), v.elem, path, depth + 1); p != "" {
                return fmt.tprintf("%s[%d]", p, i)
            }
        }
        return ""
    case runtime.Type_Info_Dynamic_Array:
        da := (^runtime.Raw_Dynamic_Array)(a)^
        db := (^runtime.Raw_Dynamic_Array)(b)^
        if da.len != db.len do return path
        for i in 0 ..< da.len {
            off := uintptr(i * v.elem_size)
            if p := deep_diff(rawptr(uintptr(da.data) + off), rawptr(uintptr(db.data) + off), v.elem, path, depth + 1); p != "" {
                return fmt.tprintf("%s[%d]", p, i)
            }
        }
        return ""
    case runtime.Type_Info_Array:
        for i in 0 ..< v.count {
            off := uintptr(i * v.elem_size)
            if p := deep_diff(rawptr(uintptr(a) + off), rawptr(uintptr(b) + off), v.elem, path, depth + 1); p != "" {
                return fmt.tprintf("%s[%d]", p, i)
            }
        }
        return ""
    case runtime.Type_Info_Map:
        if (^runtime.Raw_Map)(a).len != (^runtime.Raw_Map)(b).len do return path
        return ""
    case runtime.Type_Info_Union:
        // tag + payload: comparar bytes do payload só quando o tipo ativo é POD
        // seria preciso; o Computed não tem union com ponteiro — bytes bastam.
        if mem.compare_ptrs(a, b, base.size) != 0 do return path
        return ""
    case runtime.Type_Info_Float:
        // NaN != NaN, mas os dois caminhos que produzem NaN o fazem igual: bytes.
        if mem.compare_ptrs(a, b, base.size) != 0 do return path
        return ""
    }
    if mem.compare_ptrs(a, b, base.size) != 0 do return path
    return ""
}

// Campos que NÃO são valor computado e diferem por construção entre os dois
// caminhos (carimbos de invalidação são iguais, mas ficam aqui p/ documentar).
@(private="file")
style_check_ignored :: proc(path: string) -> bool {
    return false
}

style_check_compare :: proc(got, ref: map[^dompkg.Node]Computed) {
    g_style_check.runs += 1
    shown := 0
    for n, r in ref {
        g_style_check.nodes += 1
        g, ok := got[n]
        if !ok {
            g_style_check.missing += 1
            continue
        }
        gg, rr := g, r
        p := deep_diff(&gg, &rr, type_info_of(Computed), "")
        if p == "" || style_check_ignored(p) do continue
        g_style_check.mismatches += 1
        if shown < 8 {
            shown += 1
            cls := n.attrs["class"] if n.kind == .Element else ""
            if len(cls) > 60 do cls = cls[:60]
            fmt.eprintfln("[stylecheck] DIVERGE <%s class=%q> campo %s", n.tag, cls, p)
        }
    }
    // Entradas a mais = nós que saíram da árvore e ficaram no mapa incremental.
    extra := 0
    for n in got do if n not_in ref do extra += 1
    g_style_check.extra += extra
    fmt.eprintfln("[stylecheck] rodada %d: %d nós | %d divergentes | %d ausentes | %d a mais (acumulado: %d/%d, %d a mais)",
        g_style_check.runs, len(ref), g_style_check.mismatches, g_style_check.missing, extra,
        g_style_check.mismatches, g_style_check.nodes, g_style_check.extra)
}

// Roda a referência e compara. Chamado no FIM do compute_styles otimizado.
style_check_run :: proc(root: ^dompkg.Node, rules: ^[dynamic]csspkg.Rule, vw, vh: f32, kf: []csspkg.Keyframe_Set, got: map[^dompkg.Node]Computed) {
    when STYLECHECK {
        if g_style_legacy do return
        // g_root_font_size: a referência o regrava com o MESMO valor (o rem vem
        // da fonte da raiz, que é exatamente o que está sendo comparado).
        g_style_legacy = true
        ref, _ := compute_styles(root, rules, vw, vh, kf)
        g_style_legacy = false
        style_check_compare(got, ref)
        free_styles(ref)
        svg_css_bind(got) // free_styles soltou o vínculo; o painter lê o mapa real
    }
}
