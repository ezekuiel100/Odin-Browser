package ui

// ── Registro de METADADOS do Computed ───────────────────────────────────────
//
// Fonte ÚNICA para três perguntas que antes tinham respostas espalhadas (e que
// divergiam entre si):
//
//   1. qual é o valor INICIAL de cada campo  → `computed_initial`, abaixo;
//   2. o campo HERDA do pai ou volta ao inicial a cada elemento → `flow`;
//   3. mudar o campo exige refazer o LAYOUT ou basta repintar a Box → `effect`.
//
// Antes, (2) era um bloco de ~180 atribuições à mão no compute_node, MAIS os
// ajustes do `child_inherit`, MAIS o `transform_reset`, MAIS um `root_inherit`
// montado à mão no compute_styles; e (3) era uma whitelist de 5 campos copiada
// em três procs do style_invalidation. Esquecer um campo novo em qualquer um
// desses lugares não dava erro nenhum: o valor do pai VAZAVA em silêncio p/ a
// subárvore (foi o caso do `bg_extra` — os 4 radiais do hero do getbootstrap
// pintados em todo descendente).
//
// Agora o reset é DERIVADO desta tabela (faixas de bytes calculadas por
// reflexão no @(init)), e o teste `test_registro_cobre_todo_campo` reprova
// qualquer campo do Computed que não esteja listado aqui — campo novo sem
// metadado deixa de ser esquecimento silencioso e vira teste vermelho que
// diz o NOME do campo.
//
// ⚠️ `flow` descreve o comportamento DESTE motor, que nem sempre é o da spec.
// Os casos em que herdamos algo que a spec diz não herdar estão marcados com
// `// spec: não herda` — são deliberados (propagação de text-decoration) ou
// pendências; mudar qualquer um muda pixel e tem de ser medido à parte.

import "base:runtime"
import "core:mem"
import "core:reflect"
import "core:slice"
import "core:strings"

Field_Flow :: enum u8 {
    Inherit, // o filho começa com o valor do PAI
    Reset,   // o filho começa no valor INICIAL (propriedade que não herda)
    Own,     // dado por-nó que não é propriedade CSS (fingerprint, flag "definido
             // aqui", ponteiro alocado): também volta ao inicial, e nunca é
             // tocado pelas palavras-chave CSS-wide
}

Field_Effect :: enum u8 {
    Layout, // mudar exige build_layout (default conservador)
    Paint,  // a Box ESPELHA o campo (mesmo nome e tipo) e o restyle o reescreve
            // no lugar, sem layout — ver refresh_box_paint. O @(init) verifica.
}

Field_Group :: struct {
    prop:   string, // propriedade (ou família) CSS dona dos campos; rótulo p/ busca
    flow:   Field_Flow,
    effect: Field_Effect,
    fields: []string,
}

// Ordem = ordem do Computed (facilita conferir). Um campo em DUAS linhas é erro
// (o @(init) recusa); um campo em NENHUMA também (o teste recusa).
COMPUTED_FIELDS := [?]Field_Group{
    {"(restyle)",            .Own,     .Layout, {"style_fp", "style_kids_ver", "style_layout_fp"}},

    // ── texto e fonte ──
    {"color",                .Inherit, .Layout, {"color"}},
    {"caret-color",          .Inherit, .Layout, {"caret_color", "has_caret"}},
    {"background-color",     .Reset,   .Paint,  {"bg", "has_bg"}},
    {"(:hover)",             .Own,     .Layout, {"hover"}},
    {"animation",            .Reset,   .Layout, {"anim_more", "anim"}},
    {"font-weight",          .Inherit, .Layout, {"weight"}},
    {"font-style",           .Inherit, .Layout, {"italic"}},
    {"display",              .Reset,   .Layout, {"display_none"}},
    {"font-size",            .Inherit, .Layout, {"font_size"}},
    // has_font_size herda DE PROPÓSITO: o layout escolhe entre o tamanho herdado
    // e o default da TAG (h1…) conforme "algum ancestral definiu font-size".
    // Grupo PRÓPRIO: `font-size: initial` muda o tamanho, não esta escolha —
    // no grupo do font-size, o h1 cairia de volta nos 2em da tag.
    {"(font-size definido)", .Inherit, .Layout, {"has_font_size"}},
    {"line-height",          .Inherit, .Layout, {"line_height"}},
    {"font-family",          .Inherit, .Layout, {"font_family", "font_fam_id"}},
    {"(definido aqui)",      .Own,     .Layout, {"has_color", "has_font_family"}},
    {"text-transform",       .Inherit, .Layout, {"text_transform"}},
    {"letter-spacing",       .Inherit, .Layout, {"letter_spacing"}},
    {"font-kerning",         .Inherit, .Layout, {"font_kerning"}},
    {"word-spacing",         .Inherit, .Layout, {"word_spacing"}},
    {"text-wrap",            .Inherit, .Layout, {"text_balance"}},
    {"text-indent",          .Inherit, .Layout, {"text_indent", "indent_each_line", "indent_hanging", "text_indent_pct"}},
    {"white-space",          .Inherit, .Layout, {"white_space"}},
    {"overflow-wrap",        .Inherit, .Layout, {"break_word", "wrap_anywhere"}},
    {"word-break",           .Inherit, .Layout, {"break_all"}},
    {"text-overflow",        .Reset,   .Layout, {"ellipsis"}},
    {"-webkit-line-clamp",   .Reset,   .Layout, {"line_clamp"}},
    {"list-style-type",      .Inherit, .Layout, {"list_style"}},
    {"visibility",           .Inherit, .Layout, {"invisible"}},
    {"text-align",           .Inherit, .Layout, {"text_align"}},
    {"text-align-last",      .Inherit, .Layout, {"text_align_last", "has_text_align_last"}},
    // spec: não herda — mas a decoração PROPAGA p/ o conteúdo inline dos
    // descendentes, e este motor modela a propagação como herança.
    {"text-decoration-line", .Inherit, .Layout, {"underline", "overline", "strike"}},
    {"(text-decoration definido aqui)", .Own, .Layout, {"deco_set"}},
    {"quotes",               .Inherit, .Layout, {"quotes_raw"}},
    {"(lang)",               .Inherit, .Layout, {"lang"}},
    {"unicode-bidi",         .Reset,   .Layout, {"unicode_bidi"}},
    {"writing-mode",         .Inherit, .Layout, {"writing_mode"}},
    {"text-orientation",     .Inherit, .Layout, {"text_orientation"}},
    {"direction",            .Inherit, .Layout, {"direction"}},
    // spec: não herdam — idem text-decoration-line (propagação).
    {"text-decoration-color",     .Inherit, .Layout, {"deco_color"}},
    {"text-decoration-style",     .Inherit, .Layout, {"deco_style"}},
    {"text-decoration-thickness", .Inherit, .Layout, {"deco_thick"}},
    {"text-underline-offset",     .Inherit, .Layout, {"underline_offset"}},
    {"text-underline-position",   .Inherit, .Layout, {"underline_under"}},
    {"text-decoration-skip-ink",  .Inherit, .Layout, {"skip_ink_none"}},

    // ── box model ──
    {"margin",               .Reset,   .Layout, {"margin", "has_margin", "margin_pct", "margin_frac", "margin_off",
                                                 "margin_x_auto", "margin_left_auto", "margin_right_auto",
                                                 "margin_top_auto", "margin_bottom_auto"}},
    {"padding",              .Reset,   .Layout, {"padding", "padding_pct", "padding_frac", "padding_off"}},
    {"border",               .Reset,   .Layout, {"border_w", "border_c", "border_style_none", "has_border"}},
    {"border-image",         .Reset,   .Layout, {"bimg"}},
    {"border-collapse",      .Inherit, .Layout, {"border_collapse"}},
    {"table-layout",         .Reset,   .Layout, {"table_fixed"}},
    {"empty-cells",          .Inherit, .Layout, {"empty_cells_hide"}},
    {"caption-side",         .Inherit, .Layout, {"caption_side_bottom"}},
    {"outline",              .Reset,   .Layout, {"outline_w", "outline_c", "outline_off"}},
    {"width",                .Reset,   .Layout, {"width", "width_pct", "has_width", "width_pct_off", "width_bd",
                                                 "width_mc", "width_minc", "width_fit"}},
    {"max-width",            .Reset,   .Layout, {"maxw", "maxw_pct", "has_maxw", "maxw_pct_off", "maxw_bd"}},
    {"min-width",            .Reset,   .Layout, {"minw", "minw_pct", "has_minw", "minw_pct_off", "minw_bd"}},
    {"height",               .Reset,   .Layout, {"height", "has_height", "height_pct", "has_height_pct",
                                                 "height_pct_off", "height_bd", "height_mc"}},
    {"min-height",           .Reset,   .Layout, {"minh", "has_minh", "minh_pct", "has_minh_pct", "minh_pct_off",
                                                 "minh_bd", "minh_mc"}},
    {"max-height",           .Reset,   .Layout, {"maxh", "has_maxh", "maxh_pct", "has_maxh_pct", "maxh_pct_off", "maxh_bd"}},
    {"aspect-ratio",         .Reset,   .Layout, {"aspect"}},
    {"box-sizing",           .Reset,   .Layout, {"box_sizing"}},
    {"border-radius",        .Reset,   .Layout, {"border_radius", "border_radius_pct"}},

    // ── posicionamento e display ──
    {"position",             .Reset,   .Layout, {"position"}},
    {"inset",                .Reset,   .Layout, {"inset", "inset_off", "inset_pct", "inset_has"}},
    {"display",              .Reset,   .Layout, {"display_inline_block", "display_block", "display_inline",
                                                 "display_inline_level", "display_flex", "display_grid",
                                                 "display_table", "display_table_row", "display_table_cell",
                                                 "display_table_rowgrp", "display_contents"}},

    // ── flex / alinhamento ──
    {"flex-direction",       .Reset,   .Layout, {"flex_dir", "flex_reverse"}},
    {"flex-wrap",            .Reset,   .Layout, {"flex_wrap", "flex_wrap_reverse"}},
    {"justify-content",      .Reset,   .Layout, {"justify"}},
    {"align-items",          .Reset,   .Layout, {"align_items"}},
    {"align-content",        .Reset,   .Layout, {"align_content", "ac_stretch"}},
    {"justify-items",        .Reset,   .Layout, {"justify_items"}},
    {"align-self",           .Reset,   .Layout, {"align_self", "has_align_self"}},
    {"justify-self",         .Reset,   .Layout, {"justify_self", "has_justify_self"}},
    {"column-gap",           .Reset,   .Layout, {"gap", "gap_pct", "gap_frac", "gap_off"}},
    {"row-gap",              .Reset,   .Layout, {"row_gap", "row_gap_pct", "row_gap_frac", "row_gap_off"}},
    {"flex-grow",            .Reset,   .Layout, {"flex_grow"}},
    {"flex-shrink",          .Reset,   .Layout, {"flex_shrink"}},
    {"flex-basis",           .Reset,   .Layout, {"flex_basis", "flex_basis_pct", "has_flex_basis", "flex_basis_auto",
                                                 "flex_basis_pct_off", "flex_basis_bd"}},
    {"order",                .Reset,   .Layout, {"order"}},

    // ── multi-coluna / fragmentação ──
    {"columns",              .Reset,   .Layout, {"col_count", "col_width", "col_gap"}},
    {"break-before",         .Reset,   .Layout, {"break_before_avoid"}},
    {"break-after",          .Reset,   .Layout, {"break_after_avoid"}},

    // ── grid ──
    {"grid-template-columns", .Reset,  .Layout, {"grid_auto_fill", "grid_track_n", "grid_tracks",
                                                 "grid_col_lines", "grid_col_line_n"}},
    {"grid-template-rows",   .Reset,   .Layout, {"grid_row_track_n", "grid_row_tracks",
                                                 "grid_row_lines", "grid_row_line_n"}},
    {"grid-auto-rows",       .Reset,   .Layout, {"grid_auto_row_n", "grid_auto_rows"}},
    {"grid-auto-columns",    .Reset,   .Layout, {"grid_auto_col_n", "grid_auto_cols"}},
    {"grid-auto-flow",       .Reset,   .Layout, {"grid_flow_col", "grid_flow_dense"}},
    {"grid-template-areas",  .Reset,   .Layout, {"grid_areas", "grid_area_n"}},
    {"grid-area",            .Reset,   .Layout, {"grid_area_name"}},
    {"grid-column",          .Reset,   .Layout, {"grid_col_start", "grid_col_span", "grid_col_start_name",
                                                 "grid_col_end_name", "grid_col_end_line"}},
    {"grid-row",             .Reset,   .Layout, {"grid_row_start", "grid_row_span", "grid_row_start_name",
                                                 "grid_row_end_name", "grid_row_end_line"}},

    // ── contenção ──
    {"content-visibility",   .Reset,   .Layout, {"content_hidden"}},
    {"contain-intrinsic-size", .Reset, .Layout, {"cis_w", "cis_h", "has_cis_w", "has_cis_h"}},
    {"container",            .Reset,   .Layout, {"container_inline", "container_name"}},

    // ── fundo ──
    {"background-image",     .Reset,   .Layout, {"grad", "grad_clip_text", "bg_img", "bg_extra"}},
    {"background-size",      .Reset,   .Layout, {"bg_size"}},
    // escrito pelo compute_styles DEPOIS da cascata (raiz ou body pinta o canvas)
    {"(fundo do canvas)",    .Own,     .Paint,  {"bg_canvas"}},
    {"background-clip",      .Reset,   .Layout, {"bg_clip"}},
    {"background-origin",    .Reset,   .Layout, {"bg_origin"}},
    {"background-attachment", .Reset,  .Layout, {"bg_fixed"}},
    {"background-position",  .Reset,   .Layout, {"bg_pos_x", "bg_pos_y"}},
    {"background-repeat",    .Reset,   .Layout, {"bg_repeat"}},
    {"object-fit",           .Reset,   .Layout, {"obj_fit"}},
    {"object-position",      .Reset,   .Layout, {"obj_pos_x", "obj_pos_y"}},

    // ── interação ──
    {"cursor",               .Inherit, .Paint,  {"cursor"}},
    {"accent-color",         .Inherit, .Layout, {"accent_color", "has_accent"}},
    {"pointer-events",       .Inherit, .Layout, {"pe_none"}},
    {"user-select",          .Inherit, .Layout, {"user_select_none"}}, // spec: não herda (efeito equivalente)
    {"appearance",           .Reset,   .Layout, {"appearance_none"}},
    {"scroll-behavior",      .Reset,   .Layout, {"scroll_smooth"}},
    {"scroll-margin",        .Reset,   .Layout, {"scroll_margin_top"}},
    {"scroll-padding",       .Reset,   .Layout, {"scroll_padding_top"}},
    {"overscroll-behavior",  .Reset,   .Layout, {"overscroll_contain"}},
    {"tab-size",             .Inherit, .Layout, {"tab_size"}},
    {"vertical-align",       .Reset,   .Layout, {"valign"}},
    {"transition",           .Reset,   .Layout, {"trans"}},

    // ── overflow / float ──
    {"overflow",             .Reset,   .Layout, {"overflow_hidden", "ovf_clip_x", "ovf_clip_y", "overflow_scroll",
                                                 "ovf_scroll_x", "ovf_scroll_y", "scroll_container"}},
    {"resize",               .Reset,   .Layout, {"resize"}},
    {"float",                .Reset,   .Layout, {"float"}},
    {"clear",                .Reset,   .Layout, {"clear"}},

    // ── empilhamento e efeitos visuais ──
    {"z-index",              .Reset,   .Layout, {"z_index", "z_index_set"}},
    {"will-change",          .Reset,   .Layout, {"stacking_hint", "cb_abs", "cb_fixed"}},
    {"opacity",              .Reset,   .Paint,  {"opacity"}},
    {"isolation",            .Reset,   .Layout, {"isolate"}},
    {"clip-path",            .Reset,   .Layout, {"clip_path"}},
    // mask_grad = <gradient>; mask_image = url() de SVG (o bloco à mão antigo o
    // zerava com `= {}`, que é o inicial: zero do tipo)
    {"mask-image",           .Reset,   .Layout, {"mask_grad", "mask_image"}},
    {"mix-blend-mode",       .Reset,   .Layout, {"blend_mode"}},
    {"filter",               .Reset,   .Layout, {"filters", "n_filters"}},
    {"backdrop-filter",      .Reset,   .Layout, {"backdrop_filters", "n_backdrop"}},

    // ── transform ── (o grupo "transform" é o que `transform_reset` zera: as
    // quatro props transform/translate/rotate/scale caem nestes campos)
    {"transform",            .Reset,   .Layout, {"transform_tx", "transform_ty", "transform_tx_pct", "transform_ty_pct",
                                                 "xform", "xf_percent", "transform_rot", "transform_sx", "transform_sy",
                                                 "xf_a", "xf_b", "xf_c", "xf_d", "has_xform_matrix", "has_transform",
                                                 "xf_back"}},
    {"perspective",          .Reset,   .Layout, {"perspective"}},
    {"perspective-origin",   .Reset,   .Layout, {"perspective_ox", "perspective_oy", "perspective_opx", "perspective_opy"}},
    {"transform-origin",     .Reset,   .Layout, {"transform_ox", "transform_oy", "transform_opx", "transform_opy", "transform_opz"}},
    {"backface-visibility",  .Reset,   .Layout, {"backface_hidden"}},
    {"transform-style",      .Reset,   .Layout, {"preserve_3d"}},
    // "meu PAI tem preserve-3d": o compute_node lê do pai logo após o reset
    {"(pai preserve-3d)",    .Own,     .Layout, {"in_p3d"}},
    {"offset-path",          .Reset,   .Layout, {"has_offset_path", "offset_path"}},
    {"offset-distance",      .Reset,   .Layout, {"offset_distance", "offset_distance_pct"}},
    {"offset-rotate",        .Reset,   .Layout, {"offset_rotate_auto", "offset_rotate_angle"}},
    {"contain",              .Reset,   .Layout, {"contained"}},

    // ── sombras ──
    {"box-shadow",           .Reset,   .Layout, {"shadows", "shadow_n"}},
    {"text-shadow",          .Inherit, .Layout, {"text_shadows", "text_shadow_n"}},

    // ── conteúdo gerado / contadores ──
    {"content",              .Reset,   .Layout, {"content", "has_content", "content_raw", "content_has_counter"}},
    {"counter-reset",        .Reset,   .Layout, {"counter_reset_raw"}},
    {"counter-increment",    .Reset,   .Layout, {"counter_increment_raw"}},
    {"counter-set",          .Reset,   .Layout, {"counter_set_raw"}},
    // ponteiros ALOCADOS por nó (dono = free_styles): herdar = alias = double free
    {"(pseudo-elementos)",   .Own,     .Layout, {"before", "after", "first_letter", "placeholder"}},
    {"(fill/stroke de regra)", .Own,   .Layout, {"svg_css"}},
}

// Valores INICIAIS de todas as propriedades (o "zero" da spec). Os campos que
// não aparecem aqui têm inicial = zero do tipo. É a ÚNICA fonte de inicial: o
// reset por elemento, a raiz da árvore e `all: initial` partem daqui.
computed_initial :: proc() -> Computed {
    return Computed{text_align = .Start, color = DEFAULT_TEXT, font_size = 16 * g_zoom, line_height = 1.3, opacity = 1.0,
                    obj_pos_x = 0.5, obj_pos_y = 0.5, transform_sx = 1, transform_sy = 1,
                    transform_ox = 0.5, transform_oy = 0.5, xf_a = 1, xf_d = 1, deco_color = DECO_UNSET,
                    perspective_ox = 0.5, perspective_oy = 0.5, offset_rotate_auto = true,
                    // Estes DIVERGIAM do bloco de reset das não-herdadas que o
                    // compute_node tinha à mão: aqui ficavam no zero-value do
                    // tipo, e o zero-value NÃO é o valor inicial da spec. Agora o
                    // reset É esta função, então a divergência não tem mais onde morar.
                    flex_shrink = 1,          // css-flexbox §7.2: inicial 1
                    col_gap     = -1,         // sentinela "normal" (1em)
                    ac_stretch  = true,       // align-content: normal → stretch
                    bg_origin   = .Padding,   // background-origin: padding-box
                    bg_repeat   = true,       // background-repeat: repeat
                    grid_col_span = 1, grid_row_span = 1}
    // ⚠️ os enums (box-sizing .Content, position .Static, align-* .Stretch,
    // background-clip .Border…) dependem de o valor inicial ser o 1º MEMBRO do
    // enum. Reordenar um enum muda o inicial em silêncio — o teste
    // `test_registro_iniciais_de_enum` fixa os que importam.
}

// ── Tabelas derivadas (montadas UMA vez no @(init), só leitura depois) ──────

@(private="file")
Byte_Range :: struct { off, size: int }

@(private="file")
Paint_Mirror :: struct { src, dst, size: int } // offset no Computed, offset na Box

@(private="file") g_reg_reset:   [dynamic]Byte_Range   // Reset+Own, faixas contíguas fundidas
@(private="file") g_reg_paint:   [dynamic]Paint_Mirror // campos .Paint e onde moram na Box
@(private="file") g_reg_initial: Computed              // computed_initial() com g_zoom = 1
@(private="file") g_reg_field_group: map[string]int    // campo → índice em COMPUTED_FIELDS

@(init)
build_style_registry :: proc "contextless" () {
    context = runtime.default_context()
    g_reg_initial = computed_initial()
    names := reflect.struct_field_names(Computed)
    types := reflect.struct_field_types(Computed)
    offs  := reflect.struct_field_offsets(Computed)

    g_reg_field_group = make(map[string]int)
    for g, gi in COMPUTED_FIELDS {
        for f in g.fields {
            // registro inconsistente = bug de programação: falhar ALTO no boot
            // em vez de produzir um reset que esquece (ou duplica) campo
            if f in g_reg_field_group do panic("style_registry: campo listado duas vezes")
            g_reg_field_group[f] = gi
        }
    }

    // Faixas de bytes a restaurar do inicial: percorre os campos por OFFSET e
    // funde vizinhos não-herdados (o enchimento entre eles é copiado junto —
    // inofensivo). Um campo do Computed que não está no registro fica FORA do
    // reset (= herda); o teste de cobertura é quem impede isso de acontecer.
    idx := make([]int, len(names), context.temp_allocator)
    for i in 0 ..< len(names) do idx[i] = i
    slice.sort_by(idx, proc(a, b: int) -> bool {
        o := reflect.struct_field_offsets(Computed)
        return o[a] < o[b]
    })
    for i in idx {
        gi, ok := g_reg_field_group[names[i]]
        if !ok || COMPUTED_FIELDS[gi].flow == .Inherit do continue
        off, size := int(offs[i]), types[i].size
        if n := len(g_reg_reset); n > 0 {
            last := &g_reg_reset[n - 1]
            if !reg_inherit_between(last.off + last.size, off, names, offs) {
                last.size = off + size - last.off
                continue
            }
        }
        append(&g_reg_reset, Byte_Range{off, size})
    }

    // Espelhos de pintura: todo campo .Paint TEM de existir na Box com o MESMO
    // tipo — é o que permite ao restyle reescrevê-lo sem layout.
    for g in COMPUTED_FIELDS {
        if g.effect != .Paint do continue
        for f in g.fields {
            cf := reflect.struct_field_by_name(Computed, f)
            bf := reflect.struct_field_by_name(Box, f)
            if cf.type == nil || bf.type == nil || cf.type.id != bf.type.id {
                panic("style_registry: campo .Paint sem espelho de mesmo tipo na Box")
            }
            append(&g_reg_paint, Paint_Mirror{int(cf.offset), int(bf.offset), cf.type.size})
        }
    }
}

// Há algum campo HERDADO começando em [lo, hi)? (impede a fusão das faixas)
@(private="file")
reg_inherit_between :: proc(lo, hi: int, names: []string, offs: []uintptr) -> bool {
    for name, i in names {
        o := int(offs[i])
        if o < lo || o >= hi do continue
        gi, ok := g_reg_field_group[name]
        if !ok || COMPUTED_FIELDS[gi].flow == .Inherit do return true
    }
    return false
}

// O que um elemento recebe do pai ANTES das próprias declarações: cópia do pai
// com todo campo não-herdado de volta ao inicial. Substitui o bloco manual.
// ⚠️ O inicial usado é o do @(init) (g_zoom = 1). Só `font_size` depende do
// zoom em computed_initial, e ele HERDA — logo não está em nenhuma faixa.
// O teste `test_registro_reset_independe_do_zoom` guarda essa premissa.
computed_reset_noninherited :: proc(comp: ^Computed) {
    dst := cast([^]byte)comp
    src := cast([^]byte)&g_reg_initial
    for r in g_reg_reset do mem.copy(&dst[r.off], &src[r.off], r.size)
}

// Volta os campos de UM grupo do registro ao inicial (ex.: "transform" —
// o :hover reaplica o grupo inteiro em vez de compor com a base).
computed_reset_group :: proc(comp: ^Computed, prop: string) {
    ini := computed_initial()
    dst := cast([^]byte)comp
    src := cast([^]byte)&ini
    found := false
    for g in COMPUTED_FIELDS {
        if g.prop != prop do continue
        found = true
        for f in g.fields {
            sf := reflect.struct_field_by_name(Computed, f)
            mem.copy(&dst[sf.offset], &src[sf.offset], sf.type.size)
        }
    }
    assert(found, "computed_reset_group: grupo inexistente no registro")
}

// Algum campo de efeito .Paint difere?
computed_paint_changed :: proc(a, b: Computed) -> bool {
    a, b := a, b
    pa, pb := cast([^]byte)&a, cast([^]byte)&b
    for m in g_reg_paint do if mem.compare_byte_ptrs(&pa[m.src], &pb[m.src], m.size) != 0 do return true
    return false
}

// Copia de `from` para `to` os campos de efeito .Paint (usado p/ neutralizá-los
// antes de comparar o resto: o que sobrar de diferença exige layout).
computed_copy_paint :: proc(to: ^Computed, from: Computed) {
    from := from
    d, s := cast([^]byte)to, cast([^]byte)&from
    for m in g_reg_paint do mem.copy(&d[m.src], &s[m.src], m.size)
}

// Reescreve na Box os espelhos dos campos .Paint.
box_apply_paint :: proc(b: ^Box, c: Computed) {
    c := c
    d, s := cast([^]byte)b, cast([^]byte)&c
    for m in g_reg_paint do mem.copy(&d[m.dst], &s[m.src], m.size)
}

// ── Palavras-chave CSS-wide (Values §7.3): inherit / initial / unset ────────
//
// Resolvidas DEPOIS do apply_decls, porque só o compute_node tem o Computed do
// pai — e porque o `comp` já passou pelos defaults de UA (h1 em negrito,
// padding do <button>), então "não fazer nada" NÃO é o mesmo que herdar nem que
// voltar ao inicial. Antes eram ~30 casos escritos à mão (box-sizing, display,
// background-color, background-clip, font-weight, z-index e uma lista de
// `initial`); agora vale para TODA propriedade cujo nome é um grupo do registro.
//
// Fora (de propósito): longhand cujo grupo é mais largo que ela
// (`margin-top: inherit` não pode levar as 4 margens — não é nome de grupo, e
// fica sem efeito como antes); grupo com ponteiro DONO (transform, animation,
// background-image: copiar o ponteiro do pai é alias → double free); `revert`
// (= o valor do UA, que o `comp` já tem).

@(private="file") g_reg_group_ranges: [dynamic][dynamic]Byte_Range // por grupo
@(private="file") g_reg_prop_groups:  map[string][dynamic]int      // nome → grupos planos

// Grafias alternativas que caem no mesmo grupo.
@(private="file")
wide_kw_prop :: proc(p: string) -> string {
    switch p {
    case "word-wrap":               return "overflow-wrap"
    case "-webkit-background-clip": return "background-clip"
    }
    return p
}

// O tipo guarda ponteiro/slice/map (memória com DONO)? `string` não conta: é
// fatia não-owned, e herdar fatia de string é o que a herança comum já faz.
@(private="file")
type_owns_memory :: proc(ti: ^runtime.Type_Info) -> bool {
    base := runtime.type_info_base(ti)
    #partial switch v in base.variant {
    case runtime.Type_Info_Pointer, runtime.Type_Info_Multi_Pointer, runtime.Type_Info_Slice,
         runtime.Type_Info_Dynamic_Array, runtime.Type_Info_Map, runtime.Type_Info_Procedure:
        return true
    case runtime.Type_Info_Array:            return type_owns_memory(v.elem)
    case runtime.Type_Info_Enumerated_Array: return type_owns_memory(v.elem)
    case runtime.Type_Info_Struct:
        for i in 0 ..< v.field_count do if type_owns_memory(v.types[i]) do return true
    case runtime.Type_Info_Union:
        for t in v.variants do if type_owns_memory(t) do return true
    }
    return false
}

@(init)
build_style_registry_keywords :: proc "contextless" () {
    context = runtime.default_context()
    g_reg_prop_groups = make(map[string][dynamic]int)
    for g, gi in COMPUTED_FIELDS {
        rs := make([dynamic]Byte_Range)
        plain := g.flow != .Own
        for f in g.fields {
            sf := reflect.struct_field_by_name(Computed, f)
            if sf.type == nil do continue // o teste de nome-fantasma reprova
            append(&rs, Byte_Range{int(sf.offset), sf.type.size})
            if type_owns_memory(sf.type) do plain = false
        }
        append(&g_reg_group_ranges, rs)
        if !plain do continue
        if g.prop not_in g_reg_prop_groups do g_reg_prop_groups[g.prop] = make([dynamic]int)
        append(&g_reg_prop_groups[g.prop], gi)
    }
}

Wide_Keyword :: enum u8 { None, Inherit, Initial, Unset }

wide_keyword_of :: proc(v: string) -> Wide_Keyword {
    t := strings.trim_space(v)
    if strings.equal_fold(t, "inherit") do return .Inherit
    if strings.equal_fold(t, "initial") do return .Initial
    if strings.equal_fold(t, "unset")   do return .Unset
    return .None
}

// Aplica inherit/initial/unset de `decls` sobre `comp`. `parent` é o Computed
// REAL do pai (para a raiz, o inicial).
computed_apply_wide_keywords :: proc(comp: ^Computed, parent: ^Computed, decls: map[string]string) {
    ini: Computed
    have_ini := false
    dst := cast([^]byte)comp
    for prop, val in decls {
        kw := wide_keyword_of(val)
        if kw == .None do continue
        groups, ok := g_reg_prop_groups[wide_kw_prop(prop)]
        if !ok do continue
        for gi in groups {
            from_parent := kw == .Inherit || (kw == .Unset && COMPUTED_FIELDS[gi].flow == .Inherit)
            if !from_parent && !have_ini { ini = computed_initial(); have_ini = true } // font_size segue o zoom ATUAL
            src := from_parent ? cast([^]byte)parent : cast([^]byte)&ini
            for r in g_reg_group_ranges[gi] do mem.copy(&dst[r.off], &src[r.off], r.size)
        }
    }
}

// Constrói o Computed de um pseudo-elemento: herda do elemento de ORIGEM tudo
// que herda e começa no inicial o resto. Os três construtores (::before/::after,
// ::first-letter, ::placeholder) listavam à mão ~25 campos herdados cada; o que
// não estava na lista saía com o ZERO do tipo, que não é o inicial
// (flex-shrink 0, background-repeat no-repeat, grid span 0).
computed_for_pseudo :: proc(origin: Computed) -> Computed {
    pc := origin
    computed_reset_noninherited(&pc)
    return pc
}

// ── ganchos p/ testes ──
registry_group_of :: proc(field: string) -> (Field_Group, bool) {
    gi, ok := g_reg_field_group[field]
    if !ok do return {}, false
    return COMPUTED_FIELDS[gi], true
}
registry_initial_template :: proc() -> Computed { return g_reg_initial }
