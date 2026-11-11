package ui

import "core:testing"
import "core:reflect"
import "core:mem"

// O portão anti-esquecimento: campo novo no Computed sem linha no registro
// (style_registry.odin) ficaria FORA do reset — ou seja, herdaria em silêncio.
// Este teste falha dizendo o NOME de cada campo esquecido.
@(test)
test_registro_cobre_todo_campo :: proc(t: ^testing.T) {
    faltando := make([dynamic]string, context.temp_allocator)
    for name in reflect.struct_field_names(Computed) {
        if _, ok := registry_group_of(name); !ok do append(&faltando, name)
    }
    testing.expectf(t, len(faltando) == 0,
        "campos do Computed sem metadado no registro (decida Inherit/Reset/Own e Layout/Paint): %v", faltando[:])
}

// O inverso: nome no registro que não existe no Computed (campo renomeado ou
// removido) seria ignorado em silêncio pelo @(init).
@(test)
test_registro_sem_nome_fantasma :: proc(t: ^testing.T) {
    for g in COMPUTED_FIELDS {
        for f in g.fields {
            sf := reflect.struct_field_by_name(Computed, f)
            testing.expectf(t, sf.type != nil, "registro cita %q (grupo %q), que não existe no Computed", f, g.prop)
        }
    }
}

// Semântica do reset, campo a campo e por REFLEXÃO (não depende de quais campos
// existem hoje): um "pai" com todo byte envenenado passa pelo reset; o herdado
// tem de sair intacto e o não-herdado igual ao inicial. Pega erro na fusão das
// faixas de bytes (uma faixa que engole um campo herdado vizinho).
@(test)
test_registro_reset_por_campo :: proc(t: ^testing.T) {
    pai: Computed
    mem.set(&pai, 0x5A, size_of(Computed)) // ponteiros-lixo: nunca desreferenciados
    filho := pai
    computed_reset_noninherited(&filho)
    ini := registry_initial_template()
    pf, pp, pi := cast([^]byte)&filho, cast([^]byte)&pai, cast([^]byte)&ini

    names := reflect.struct_field_names(Computed)
    types := reflect.struct_field_types(Computed)
    offs  := reflect.struct_field_offsets(Computed)
    for name, i in names {
        g, ok := registry_group_of(name)
        if !ok do continue // o teste de cobertura já reprova
        o, sz := int(offs[i]), types[i].size
        if g.flow == .Inherit {
            testing.expectf(t, mem.compare_byte_ptrs(&pf[o], &pp[o], sz) == 0, "%q herda, mas o reset o tocou", name)
        } else {
            testing.expectf(t, mem.compare_byte_ptrs(&pf[o], &pi[o], sz) == 0, "%q não herda, mas não voltou ao inicial", name)
        }
    }
}

// O reset usa um molde do inicial tirado no @(init) com g_zoom = 1. Só vale se
// nenhum campo NÃO-herdado depender do zoom (hoje só font_size depende, e herda).
@(test)
test_registro_reset_independe_do_zoom :: proc(t: ^testing.T) {
    salvo := g_zoom
    defer g_zoom = salvo
    g_zoom = 2.5
    agora := computed_initial()
    molde := registry_initial_template()
    pa, pm := cast([^]byte)&agora, cast([^]byte)&molde
    names := reflect.struct_field_names(Computed)
    types := reflect.struct_field_types(Computed)
    offs  := reflect.struct_field_offsets(Computed)
    for name, i in names {
        g, ok := registry_group_of(name)
        if !ok || g.flow == .Inherit do continue
        o := int(offs[i])
        testing.expectf(t, mem.compare_byte_ptrs(&pa[o], &pm[o], types[i].size) == 0,
            "%q não herda e o inicial dele depende do zoom: o molde do @(init) ficaria velho", name)
    }
}

// O inicial de vários enums é o 1º MEMBRO (zero do tipo); reordenar o enum
// mudaria o inicial em silêncio.
@(test)
test_registro_iniciais_de_enum :: proc(t: ^testing.T) {
    ini := computed_initial()
    testing.expect(t, ini.box_sizing  == .Content)
    testing.expect(t, ini.position    == .Static)
    testing.expect(t, ini.flex_dir    == .Row)
    testing.expect(t, ini.justify     == .Start)
    testing.expect(t, ini.align_items == .Stretch && ini.align_self == .Stretch)
    testing.expect(t, ini.justify_items == .Stretch && ini.justify_self == .Stretch)
    testing.expect(t, ini.align_content == .Start)
    testing.expect(t, ini.bg_size == .Auto && ini.bg_clip == .Border && ini.bg_origin == .Padding)
    testing.expect(t, ini.obj_fit == .Fill && ini.valign == .Baseline)
    testing.expect(t, ini.float == .None && ini.clear == .None && ini.resize == .None)
    testing.expect(t, ini.blend_mode == .Normal && ini.unicode_bidi == .Normal)
}

// Pipeline de verdade: valor NÃO-herdado do pai não chega ao filho; herdado
// chega. Controle pareado: a mesma regra no filho faz o valor aparecer nele.
@(test)
test_registro_pipeline_pai_filho :: proc(t: ^testing.T) {
    css := ".g{margin:7px;opacity:.5;flex-shrink:0;transform:rotate(30deg);color:#123456;letter-spacing:3px}"
    c := test_compute_child(css)
    testing.expectf(t, c.margin[0] == 0 && !c.has_margin, "margin não herda; veio %v", c.margin)
    testing.expectf(t, c.opacity == 1, "opacity não herda; veio %v", c.opacity)
    testing.expectf(t, c.flex_shrink == 1, "flex-shrink não herda (inicial 1); veio %v", c.flex_shrink)
    testing.expectf(t, !c.has_transform && c.transform_rot == 0 && c.xform == nil, "transform não herda")
    testing.expectf(t, c.color == 0x123456, "color herda; veio %x", c.color)
    testing.expectf(t, c.letter_spacing == 3, "letter-spacing herda; veio %v", c.letter_spacing)
    ctl := test_compute_child(".i{margin:7px;opacity:.5}")
    testing.expectf(t, ctl.margin[0] == 7 && ctl.opacity == 0.5, "controle: no próprio filho vale; veio %v %v", ctl.margin[0], ctl.opacity)
}

// Efeito .Paint: o restyle reescreve na Box sem layout. Copiar tem de cobrir
// exatamente os campos marcados (e nada de layout junto).
@(test)
test_registro_paint_espelha_na_box :: proc(t: ^testing.T) {
    a := computed_initial()
    b := a
    b.opacity = 0.25; b.cursor = .Pointer; b.bg = 0xff0000; b.has_bg = true
    testing.expect(t, computed_paint_changed(a, b), "mudança de pintura não detectada")
    box: Box
    box_apply_paint(&box, b)
    testing.expectf(t, box.opacity == 0.25 && box.cursor == .Pointer && box.bg == 0xff0000 && box.has_bg,
        "Box não recebeu a pintura: %v %v %x %v", box.opacity, box.cursor, box.bg, box.has_bg)

    // controle: campo de LAYOUT não conta como pintura e não é copiado
    c := a
    c.margin[0] = 9
    testing.expect(t, !computed_paint_changed(a, c), "margin foi tratada como pintura")
    neut := c
    computed_copy_paint(&neut, a)
    testing.expect(t, neut.margin[0] == 9, "copiar pintura levou junto um campo de layout")
}

// O grupo nomeado volta ao inicial e o resto fica (é o que o :hover usa).
@(test)
test_registro_reset_de_grupo :: proc(t: ^testing.T) {
    c := test_apply("transform: rotate(45deg) scale(2); transform-origin: 0 0; margin: 3px")
    testing.expect(t, c.has_transform, "pré-condição: transform aplicado")
    x := c.xform
    defer if x != nil { delete(x.ops); free(x) }
    computed_reset_group(&c, "transform")
    testing.expect(t, !c.has_transform && c.transform_rot == 0 && c.transform_sx == 1 && c.xform == nil, "grupo transform não voltou ao inicial")
    testing.expectf(t, c.transform_ox == 0 && c.margin[0] == 3, "reset de grupo vazou p/ fora do grupo: origin %v margin %v", c.transform_ox, c.margin[0])
}
