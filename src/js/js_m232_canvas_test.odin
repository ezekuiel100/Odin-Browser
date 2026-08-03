package js

// M232 — canvas.getContext('2d'). O contrato testado aqui é a LISTA DE COMANDOS:
// o pacote ui só a converte para tela, então tudo que decide o desenho (matriz,
// cores, achatamento de curvas, truncar no clearRect) é medível sem janela.
//
// ⚠️ os hooks são globais de PACOTE e o runner é paralelo: os dois fakes são
// procs PURAS e fixas (todas as threads escrevem o mesmo ponteiro, e o resultado
// não depende de estado), então não há corrida — o oposto do fake de rect do
// js_m232_test.odin, que precisou de thread_local por guardar dados.

import "core:math"
import "core:strings"
import "core:testing"
import dom "../dom"

@(private = "file")
fake_color :: proc(s: string) -> (u32, bool) {
    switch s {
    case "red":     return 0xFF0000, true
    case "lime":    return 0x00FF00, true
    case "blue":    return 0x0000FF, true
    case "#123456": return 0x123456, true
    }
    return 0, false // desconhecida: a spec manda IGNORAR a atribuição
}

@(private = "file")
fake_measure :: proc(text: string, px: f32) -> f32 { return f32(len(text)) * px } // 1 px por char, previsível

// <body><canvas id="c" width="200" height="100"></canvas></body>
@(private = "file")
build_canvas_dom :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    body := dom.make_node(.Element)
    body.tag = strings.clone("body")
    body.attrs = make(map[string]string)
    cv := dom.make_node(.Element)
    cv.tag = strings.clone("canvas")
    cv.attrs = make(map[string]string)
    dom.set_attr(cv, strings.clone("id"), strings.clone("c"))
    dom.set_attr(cv, strings.clone("width"), strings.clone("200"))
    dom.set_attr(cv, strings.clone("height"), strings.clone("100"))
    dom.append_child(body, cv)
    dom.append_child(root, body)
    return root
}

@(private = "file")
canvas_setup :: proc() {
    g_parse_color  = fake_color
    g_measure_text = fake_measure
}

@(private = "file")
canvas_node :: proc(root: ^dom.Node) -> ^dom.Node { return root.children[0].children[0] }

// Desenho corrente do canvas de teste.
@(private = "file")
draw_of :: proc(vm: ^Interp, root: ^dom.Node) -> Canvas_Draw {
    d, _ := canvas_draw_of(vm, rawptr(canvas_node(root)))
    return d
}

// ── o básico ────────────────────────────────────────────────────────────────

@(test)
test_canvas_getcontext_2d_e_unico :: proc(t: ^testing.T) {
    // Antes NÃO existia getContext: todo código de gráfico morria com TypeError
    // na 1ª linha. E a spec exige que duas chamadas devolvam o MESMO objeto —
    // bibliotecas guardam o contexto e comparam identidade.
    root := build_canvas_dom()
    defer dom.free_tree(root)
    canvas_setup()
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    got := str_of(vm_run(vm, `
        var c = document.getElementById('c');
        var a = c.getContext('2d'), b = c.getContext('2d');
        (a === b) + '|' + (typeof a.fillRect) + '|' + (a.canvas === c) + '|' + (c.getContext('webgl') === null)
    `))
    testing.expect_value(t, got, "true|function|true|true")
}

@(test)
test_canvas_fill_rect_grava_o_retangulo :: proc(t: ^testing.T) {
    root := build_canvas_dom()
    defer dom.free_tree(root)
    canvas_setup()
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var x = document.getElementById('c').getContext('2d');
        x.fillStyle = 'red';
        x.fillRect(10, 20, 30, 40);
    `)
    d := draw_of(vm, root)
    testing.expect_value(t, len(d.cmds), 1)
    testing.expect_value(t, d.cmds[0].op, Canvas_Op.Fill_Path)
    testing.expect_value(t, d.cmds[0].color & 0xFFFFFF, u32(0xFF0000))
    p := d.pts[d.cmds[0].n0:d.cmds[0].n1]
    testing.expect_value(t, len(p), 5) // 4 cantos + fecho
    testing.expect_value(t, p[0], [2]f32{10, 20})
    testing.expect_value(t, p[2], [2]f32{40, 60})
    testing.expect_value(t, d.w, f32(200)) // tamanho do BITMAP (atributos)
    testing.expect_value(t, d.h, f32(100))
}

@(test)
test_canvas_cor_desconhecida_e_IGNORADA :: proc(t: ^testing.T) {
    // Spec: valor inválido em fillStyle mantém o anterior. Zerar (preto) seria
    // desenhar a coisa errada em silêncio.
    root := build_canvas_dom()
    defer dom.free_tree(root)
    canvas_setup()
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var x = document.getElementById('c').getContext('2d');
        x.fillStyle = 'lime';
        x.fillStyle = 'nao-e-cor';
        x.fillRect(0, 0, 1, 1);
    `)
    d := draw_of(vm, root)
    testing.expect_value(t, d.cmds[0].color & 0xFFFFFF, u32(0x00FF00))
}

// ── matriz ──────────────────────────────────────────────────────────────────

@(test)
test_canvas_translate_e_scale_entram_nos_pontos :: proc(t: ^testing.T) {
    // Os pontos saem daqui JÁ transformados: é isso que deixa o pacote ui sem
    // saber o que é uma matriz.
    root := build_canvas_dom()
    defer dom.free_tree(root)
    canvas_setup()
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var x = document.getElementById('c').getContext('2d');
        x.translate(100, 50);
        x.scale(2, 3);
        x.fillRect(1, 1, 10, 10);
    `)
    d := draw_of(vm, root)
    p := d.pts[d.cmds[0].n0:d.cmds[0].n1]
    testing.expect_value(t, p[0], [2]f32{102, 53})  // 100+1*2, 50+1*3
    testing.expect_value(t, p[2], [2]f32{122, 83})  // 100+11*2, 50+11*3
}

@(test)
test_canvas_save_restore_devolve_estado_E_matriz :: proc(t: ^testing.T) {
    root := build_canvas_dom()
    defer dom.free_tree(root)
    canvas_setup()
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var x = document.getElementById('c').getContext('2d');
        x.fillStyle = 'red';
        x.save();
        x.fillStyle = 'blue';
        x.translate(50, 50);
        x.restore();
        x.fillRect(0, 0, 5, 5);
    `)
    d := draw_of(vm, root)
    testing.expect_value(t, d.cmds[0].color & 0xFFFFFF, u32(0xFF0000)) // voltou p/ red
    testing.expect_value(t, d.pts[d.cmds[0].n0], [2]f32{0, 0})         // e p/ a matriz identidade
}

@(test)
test_canvas_rotate :: proc(t: ^testing.T) {
    root := build_canvas_dom()
    defer dom.free_tree(root)
    canvas_setup()
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var x = document.getElementById('c').getContext('2d');
        x.rotate(Math.PI / 2);
        x.fillRect(10, 0, 1, 1);
    `)
    d := draw_of(vm, root)
    p := d.pts[d.cmds[0].n0]
    // (10,0) girado 90° vira (0,10)
    testing.expect(t, abs(p.x) < 0.001 && abs(p.y - 10) < 0.001, "esperava ~(0,10)")
}

// ── caminhos ────────────────────────────────────────────────────────────────

@(test)
test_canvas_path_stroke_com_espessura :: proc(t: ^testing.T) {
    root := build_canvas_dom()
    defer dom.free_tree(root)
    canvas_setup()
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var x = document.getElementById('c').getContext('2d');
        x.strokeStyle = 'blue';
        x.lineWidth = 4;
        x.beginPath();
        x.moveTo(0, 0);
        x.lineTo(10, 10);
        x.lineTo(20, 0);
        x.stroke();
    `)
    d := draw_of(vm, root)
    testing.expect_value(t, len(d.cmds), 1)
    testing.expect_value(t, d.cmds[0].op, Canvas_Op.Stroke_Path)
    testing.expect_value(t, d.cmds[0].lw, f32(4))
    testing.expect_value(t, d.cmds[0].n1 - d.cmds[0].n0, 3)
}

@(test)
test_canvas_subcaminhos_viram_comandos_SEPARADOS :: proc(t: ^testing.T) {
    // Dois moveTo = duas formas. Preenchê-las como um polígono só ligaria
    // formas que não se tocam — é o erro clássico de quem achata subcaminhos.
    root := build_canvas_dom()
    defer dom.free_tree(root)
    canvas_setup()
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var x = document.getElementById('c').getContext('2d');
        x.beginPath();
        x.moveTo(0,0); x.lineTo(5,0); x.lineTo(5,5);
        x.moveTo(50,50); x.lineTo(60,50); x.lineTo(60,60);
        x.fill();
    `)
    d := draw_of(vm, root)
    testing.expect_value(t, len(d.cmds), 2)
    testing.expect_value(t, d.pts[d.cmds[1].n0], [2]f32{50, 50})
}

@(test)
test_canvas_arco_fecha_o_circulo :: proc(t: ^testing.T) {
    // Um arco de 0 a 2π tem de dar a volta INTEIRA: o número de segmentos é
    // proporcional ao ângulo justamente por isso (16 fixos dariam um polígono).
    root := build_canvas_dom()
    defer dom.free_tree(root)
    canvas_setup()
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var x = document.getElementById('c').getContext('2d');
        x.beginPath();
        x.arc(50, 50, 20, 0, Math.PI * 2);
        x.fill();
    `)
    d := draw_of(vm, root)
    testing.expect_value(t, len(d.cmds), 1)
    p := d.pts[d.cmds[0].n0:d.cmds[0].n1]
    testing.expect(t, len(p) > 30, "esperava muitos segmentos no círculo cheio")
    minx, maxx, miny, maxy := f32(1e9), f32(-1e9), f32(1e9), f32(-1e9)
    for q in p {
        r := math.sqrt((q.x - 50) * (q.x - 50) + (q.y - 50) * (q.y - 50))
        testing.expect(t, abs(r - 20) < 0.01, "todo ponto do arco fica no raio")
        minx = min(minx, q.x); maxx = max(maxx, q.x)
        miny = min(miny, q.y); maxy = max(maxy, q.y)
    }
    testing.expect(t, minx < 31 && maxx > 69 && miny < 31 && maxy > 69, "o círculo cobre os 4 lados")
}

@(test)
test_canvas_bezier_achata :: proc(t: ^testing.T) {
    root := build_canvas_dom()
    defer dom.free_tree(root)
    canvas_setup()
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var x = document.getElementById('c').getContext('2d');
        x.beginPath();
        x.moveTo(0, 0);
        x.bezierCurveTo(0, 100, 100, 100, 100, 0);
        x.stroke();
    `)
    d := draw_of(vm, root)
    p := d.pts[d.cmds[0].n0:d.cmds[0].n1]
    testing.expect(t, len(p) >= 17, "curva achatada em vários segmentos")
    testing.expect_value(t, p[len(p) - 1], [2]f32{100, 0}) // termina no ponto final
    meio := p[len(p) / 2]
    testing.expect(t, meio.y > 40 && meio.y < 80, "o meio da curva sai da reta")
}

// ── clearRect e o ciclo de vida ─────────────────────────────────────────────

@(test)
test_canvas_clear_total_TRUNCA_a_lista :: proc(t: ^testing.T) {
    // É o "limpa e redesenha" de todo canvas animado — e o que impede a lista
    // de comandos de crescer sem fim.
    root := build_canvas_dom()
    defer dom.free_tree(root)
    canvas_setup()
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var x = document.getElementById('c').getContext('2d');
        x.fillRect(0, 0, 10, 10);
        x.fillRect(20, 20, 10, 10);
        x.clearRect(0, 0, 200, 100);
        x.fillRect(5, 5, 1, 1);
    `)
    d := draw_of(vm, root)
    testing.expect_value(t, len(d.cmds), 1)
    testing.expect_value(t, d.pts[d.cmds[0].n0], [2]f32{5, 5})
}

@(test)
test_canvas_clear_PARCIAL_nao_apaga :: proc(t: ^testing.T) {
    // Degradação NOMEADA: numa lista de comandos não há pixel para apagar.
    // O teste existe para a degradação ser um FATO medido, não uma surpresa.
    root := build_canvas_dom()
    defer dom.free_tree(root)
    canvas_setup()
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var x = document.getElementById('c').getContext('2d');
        x.fillRect(0, 0, 10, 10);
        x.clearRect(0, 0, 5, 5);
    `)
    d := draw_of(vm, root)
    testing.expect_value(t, len(d.cmds), 1)
}

@(test)
test_canvas_width_reseta_a_superficie :: proc(t: ^testing.T) {
    // `canvas.width = N` é o idioma de "limpar tudo", e a spec manda resetar
    // mesmo quando o valor NÃO muda.
    root := build_canvas_dom()
    defer dom.free_tree(root)
    canvas_setup()
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var c = document.getElementById('c');
        var x = c.getContext('2d');
        x.fillRect(0, 0, 10, 10);
        c.width = 300;
    `)
    d, ok := canvas_draw_of(vm, rawptr(canvas_node(root)))
    testing.expect_value(t, ok, false) // sem comandos = nada a desenhar
    testing.expect_value(t, len(d.cmds), 0)
    // e o atributo foi refletido (é dele que o layout tira o tamanho)
    testing.expect_value(t, canvas_node(root).attrs["width"], "300")
}

// ── texto ───────────────────────────────────────────────────────────────────

@(test)
test_canvas_fill_text_e_alinhamento :: proc(t: ^testing.T) {
    root := build_canvas_dom()
    defer dom.free_tree(root)
    canvas_setup()
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var x = document.getElementById('c').getContext('2d');
        x.font = '20px Arial';
        x.fillStyle = 'blue';
        x.fillText('abcd', 100, 50);          // esquerda (default)
        x.textAlign = 'center';
        x.fillText('abcd', 100, 50);          // centralizado
    `)
    d := draw_of(vm, root)
    testing.expect_value(t, len(d.cmds), 2)
    testing.expect_value(t, d.cmds[0].text, "abcd")
    testing.expect_value(t, d.cmds[0].font_px, f32(20))
    testing.expect_value(t, d.cmds[0].x, f32(100))
    // fake_measure = 1px por char por px de fonte ⇒ 4*20 = 80 de largura
    testing.expect_value(t, d.cmds[1].x, f32(100 - 40))
}

@(test)
test_canvas_measure_text_usa_a_fonte_do_hospedeiro :: proc(t: ^testing.T) {
    root := build_canvas_dom()
    defer dom.free_tree(root)
    canvas_setup()
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    got := str_of(vm_run(vm, `
        var x = document.getElementById('c').getContext('2d');
        x.font = '10px Arial';
        '' + x.measureText('abc').width
    `))
    testing.expect_value(t, got, "30") // 3 chars * 10px pelo fake
}

@(test)
test_canvas_global_alpha_entra_na_cor :: proc(t: ^testing.T) {
    root := build_canvas_dom()
    defer dom.free_tree(root)
    canvas_setup()
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var x = document.getElementById('c').getContext('2d');
        x.fillStyle = 'red';
        x.globalAlpha = 0.5;
        x.fillRect(0, 0, 1, 1);
    `)
    d := draw_of(vm, root)
    // convenção da engine: byte alto = alfa 0..255 (127 ≈ 0.5)
    testing.expect_value(t, (d.cmds[0].color >> 24) & 0xFF, u32(127))
}
