package js

// M232 — IntersectionObserver REAL. Antes: observe/unobserve/disconnect no-op e
// callback que nunca disparava (o stub de valor neutro do Tier 1 da auditoria).
//
// A geometria entra por um hook (`g_element_rect`, o mesmo do
// getBoundingClientRect), e é isso que torna a MATEMÁTICA da interseção testável
// sem janela, sem layout e sem o pacote ui: instalamos um rect FALSO por nó e
// mexemos nele entre os passos, que é o análogo de rolar a página.
//
// ⚠️ os hooks são globais de PACOTE e o runner roda 16 testes em paralelo (a
// armadilha do M192/M216). Por isso os dois fakes são procs FIXAS — todas as
// threads escrevem o MESMO ponteiro, o que é inócuo — e o dado por-teste mora em
// `thread_local`. Nunca guarde o rect no global da proc.

import "core:strings"
import "core:testing"
import dom "../dom"

// Tabela FIXA (não map): o runner reporta vazamento de qualquer alocação viva no
// fim do teste, e um map thread_local sobrevive ao teste que o criou.
@(private = "file") Fake_Rect :: struct { n: ^dom.Node, r: [4]f32 }
@(private = "file", thread_local) g_fake_rects: [8]Fake_Rect
@(private = "file", thread_local) g_fake_n: int
@(private = "file", thread_local) g_fake_vw, g_fake_vh: f32

@(private = "file")
fake_rect :: proc(node: ^dom.Node) -> (x, y, w, h: f32, ok: bool) {
    for i in 0 ..< g_fake_n {
        if g_fake_rects[i].n == node {
            r := g_fake_rects[i].r
            return r[0], r[1], r[2], r[3], true
        }
    }
    return 0, 0, 0, 0, false // sem caixa (display:none), como o hook real
}

@(private = "file")
fake_dims :: proc() -> (w, h: f32) { return g_fake_vw, g_fake_vh }

// Caixas para o ResizeObserver: conteúdo, borda e o offset de padding.
@(private = "file") Fake_Box :: struct { n: ^dom.Node, cw, ch, bw, bh, px, py: f32 }
@(private = "file", thread_local) g_fake_boxes: [8]Fake_Box
@(private = "file", thread_local) g_fake_bn: int

@(private = "file")
fake_box :: proc(node: ^dom.Node) -> (cw, ch, bw, bh, px, py: f32, ok: bool) {
    for i in 0 ..< g_fake_bn {
        b := g_fake_boxes[i]
        if b.n == node do return b.cw, b.ch, b.bw, b.bh, b.px, b.py, true
    }
    return 0, 0, 0, 0, 0, 0, false // sem caixa (display:none), como o hook real
}

@(private = "file")
io_fake_box :: proc(n: ^dom.Node, cw, ch, bw, bh, px, py: f32) {
    for i in 0 ..< g_fake_bn {
        if g_fake_boxes[i].n == n {
            g_fake_boxes[i] = {n, cw, ch, bw, bh, px, py}
            return
        }
    }
    g_fake_boxes[g_fake_bn] = {n, cw, ch, bw, bh, px, py}
    g_fake_bn += 1
}

@(private = "file", thread_local) g_fake_sx, g_fake_sy: f32
@(private = "file")
fake_scroll :: proc() -> (x, y: f32) { return g_fake_sx, g_fake_sy }

// Instala os fakes e zera o estado desta thread. Chamar no INÍCIO de cada teste.
@(private = "file")
io_fake_setup :: proc(vw, vh: f32) {
    g_fake_n = 0
    g_fake_bn = 0
    g_fake_vw, g_fake_vh = vw, vh
    g_fake_sx, g_fake_sy = 0, 0
    g_element_rect  = fake_rect
    g_viewport_dims = fake_dims
    g_page_scroll   = fake_scroll
    g_element_box   = fake_box
}

@(private = "file")
io_fake_set :: proc(n: ^dom.Node, x, y, w, h: f32) {
    for i in 0 ..< g_fake_n {
        if g_fake_rects[i].n == n {
            g_fake_rects[i].r = {x, y, w, h}
            return
        }
    }
    g_fake_rects[g_fake_n] = {n, {x, y, w, h}}
    g_fake_n += 1
}

// <body><div id="a"></div><div id="b"></div></body> sob um Document.
@(private = "file")
build_io_dom :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    body := dom.make_node(.Element)
    body.tag = strings.clone("body")
    body.attrs = make(map[string]string)
    for id in ([?]string{"a", "b"}) {
        d := dom.make_node(.Element)
        d.tag = strings.clone("div")
        d.attrs = make(map[string]string)
        dom.set_attr(d, strings.clone("id"), strings.clone(id))
        dom.append_child(body, d)
    }
    dom.append_child(root, body)
    return root
}

@(private = "file")
io_node :: proc(root: ^dom.Node, id: string) -> ^dom.Node {
    body := root.children[0]
    for c in body.children {
        if v, ok := c.attrs["id"]; ok && v == id do return c
    }
    return nil
}

// (não é private: o js_m232_canvas_test.odin usa o mesmo helper)
str_of :: proc(v: Value) -> string {
    s, _ := v.(string)
    return strings.clone(s, context.temp_allocator)
}

// Script padrão: registra um observador que acumula "<isIntersecting>,<ratio>;".
@(private = "file")
IO_SCRIPT :: `
    var log = '', n = 0;
    var io = new IntersectionObserver(function(es, obs){
        n += es.length;
        for (var i = 0; i < es.length; i++) log += es[i].isIntersecting + ',' + es[i].intersectionRatio + ';';
    });
    io.observe(document.getElementById('a'));
`

// ── observação INICIAL (o que faz lazy-load funcionar) ──────────────────────

@(test)
test_io_entrega_inicial_mesmo_fora_da_tela :: proc(t: ^testing.T) {
    // A spec manda uma observação inicial logo após observe(), mesmo com o alvo
    // fora da viewport. Toda biblioteca de lazy-load depende disso: sem a 1ª
    // entry ela nunca decide "ainda não" e fica travada esperando.
    root := build_io_dom()
    defer dom.free_tree(root)
    io_fake_setup(1000, 800)
    io_fake_set(io_node(root, "a"), 0, 2000, 100, 100) // bem abaixo da dobra
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, IO_SCRIPT)
    testing.expect_value(t, io_step(vm), true) // houve entrega
    testing.expect_value(t, str_of(vm_run(vm, "log")), "false,0;")
}

@(test)
test_io_dispara_ao_entrar_na_viewport :: proc(t: ^testing.T) {
    root := build_io_dom()
    defer dom.free_tree(root)
    io_fake_setup(1000, 800)
    a := io_node(root, "a")
    io_fake_set(a, 0, 2000, 100, 100)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, IO_SCRIPT)
    io_step(vm)                      // inicial: fora
    io_fake_set(a, 0, 100, 100, 100) // "rolou": agora dentro, inteiro
    testing.expect_value(t, io_step(vm), true)
    testing.expect_value(t, str_of(vm_run(vm, "log")), "false,0;true,1;")
}

@(test)
test_io_sem_mudanca_nao_entrega_de_novo :: proc(t: ^testing.T) {
    // O passo roda TODO FRAME; se ele entregasse sempre, um observador viraria
    // um setInterval de 60 Hz no meio do site.
    root := build_io_dom()
    defer dom.free_tree(root)
    io_fake_setup(1000, 800)
    io_fake_set(io_node(root, "a"), 0, 100, 100, 100)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, IO_SCRIPT)
    testing.expect_value(t, io_step(vm), true)
    testing.expect_value(t, io_step(vm), false) // nada mudou
    testing.expect_value(t, io_step(vm), false)
    testing.expect_value(t, str_of(vm_run(vm, "n + '|' + log")), "1|true,1;")
}

// ── limiares ────────────────────────────────────────────────────────────────

@(test)
test_io_threshold_so_dispara_ao_cruzar :: proc(t: ^testing.T) {
    root := build_io_dom()
    defer dom.free_tree(root)
    io_fake_setup(1000, 800)
    a := io_node(root, "a")
    io_fake_set(a, 0, 750, 100, 100) // metade dentro (ratio 0.5)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var n = 0, ult = -1;
        var io = new IntersectionObserver(function(es){ n++; ult = es[es.length-1].intersectionRatio }, { threshold: 0.5 });
        io.observe(document.getElementById('a'));
    `)
    io_step(vm)                      // inicial: ratio 0.5 => índice 1
    io_fake_set(a, 0, 700, 100, 100) // ratio 1.0 => índice ainda 1: NÃO entrega
    testing.expect_value(t, io_step(vm), false)
    io_fake_set(a, 0, 790, 100, 100) // ratio 0.1 => índice 0: cruzou p/ baixo
    testing.expect_value(t, io_step(vm), true)
    io_fake_set(a, 0, 795, 100, 100) // ratio 0.05 => segue índice 0
    testing.expect_value(t, io_step(vm), false)
    // ⚠️ `ult` é 0.10, não 0.05: a última entry ENTREGUE foi a do cruzamento. Que o
    // valor mais recente da geometria NÃO apareça é exatamente o comportamento
    // sob teste (a 1ª versão deste teste esperava 0.05 — expectativa minha errada).
    testing.expect_value(t, str_of(vm_run(vm, "n + '|' + ult.toFixed(2)")), "2|0.10")
}

// ── rootMargin ──────────────────────────────────────────────────────────────

@(test)
test_io_root_margin_antecipa :: proc(t: ^testing.T) {
    // O idioma de pré-carregamento: "carregue quando faltarem 200px p/ aparecer".
    root := build_io_dom()
    defer dom.free_tree(root)
    io_fake_setup(1000, 800)
    io_fake_set(io_node(root, "a"), 0, 900, 100, 100) // 100px ABAIXO do viewport
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var vis = null;
        var io = new IntersectionObserver(function(es){ vis = es[0].isIntersecting }, { rootMargin: '200px' });
        io.observe(document.getElementById('a'));
    `)
    io_step(vm)
    testing.expect_value(t, str_of(vm_run(vm, "'' + vis")), "true")
}

@(test)
test_io_sem_root_margin_nao_antecipa :: proc(t: ^testing.T) {
    // Controle do teste acima: MESMA geometria, sem a margem, dá false. Sem este
    // par, o teste anterior passaria mesmo com o rootMargin sendo ignorado.
    root := build_io_dom()
    defer dom.free_tree(root)
    io_fake_setup(1000, 800)
    io_fake_set(io_node(root, "a"), 0, 900, 100, 100)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var vis = null;
        var io = new IntersectionObserver(function(es){ vis = es[0].isIntersecting });
        io.observe(document.getElementById('a'));
    `)
    io_step(vm)
    testing.expect_value(t, str_of(vm_run(vm, "'' + vis")), "false")
}

// ── raiz EXPLÍCITA (container rolável) ──────────────────────────────────────

@(test)
test_io_root_elemento_recorta :: proc(t: ^testing.T) {
    root := build_io_dom()
    defer dom.free_tree(root)
    io_fake_setup(1000, 800)
    a := io_node(root, "a")
    b := io_node(root, "b")
    io_fake_set(b, 0, 0, 500, 500)   // a raiz declarada
    io_fake_set(a, 0, 600, 100, 100) // dentro da VIEWPORT, fora da raiz
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var vis = null;
        var io = new IntersectionObserver(function(es){ vis = es[0].isIntersecting },
                                          { root: document.getElementById('b') });
        io.observe(document.getElementById('a'));
    `)
    io_step(vm)
    testing.expect_value(t, str_of(vm_run(vm, "'' + vis")), "false")
    io_fake_set(a, 0, 100, 100, 100) // agora dentro da raiz
    io_step(vm)
    testing.expect_value(t, str_of(vm_run(vm, "'' + vis")), "true")
}

// ── casos de borda da geometria ─────────────────────────────────────────────

@(test)
test_io_alvo_de_area_zero_conta_como_visivel :: proc(t: ^testing.T) {
    // O sentinela de "carregar mais": uma <div> de altura 0 no fim da lista. Com
    // divisão crua por área o ratio seria NaN e o alvo nunca dispararia.
    root := build_io_dom()
    defer dom.free_tree(root)
    io_fake_setup(1000, 800)
    io_fake_set(io_node(root, "a"), 0, 400, 300, 0)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, IO_SCRIPT)
    io_step(vm)
    testing.expect_value(t, str_of(vm_run(vm, "log")), "true,1;")
}

@(test)
test_io_alvo_sem_caixa_nao_intersecta :: proc(t: ^testing.T) {
    // display:none ⇒ o hook devolve ok=false. Tem de virar "não intersecta", NUNCA
    // um retângulo 0,0,0,0 que "toca" a origem da raiz e passa por visível.
    root := build_io_dom()
    defer dom.free_tree(root)
    io_fake_setup(1000, 800) // nenhum rect registrado p/ o alvo
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, IO_SCRIPT)
    io_step(vm)
    testing.expect_value(t, str_of(vm_run(vm, "log")), "false,0;")
}

// ── ciclo de vida ───────────────────────────────────────────────────────────

@(test)
test_io_unobserve_e_disconnect_silenciam :: proc(t: ^testing.T) {
    root := build_io_dom()
    defer dom.free_tree(root)
    io_fake_setup(1000, 800)
    a := io_node(root, "a")
    io_fake_set(a, 0, 2000, 100, 100)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, IO_SCRIPT)
    io_step(vm)
    vm_run(vm, "io.disconnect()")
    testing.expect_value(t, io_active(vm), false) // volta ao atalho de custo zero
    io_fake_set(a, 0, 100, 100, 100)
    testing.expect_value(t, io_step(vm), false)
    testing.expect_value(t, str_of(vm_run(vm, "log")), "false,0;")
}

@(test)
test_io_observar_o_mesmo_alvo_duas_vezes_e_noop :: proc(t: ^testing.T) {
    root := build_io_dom()
    defer dom.free_tree(root)
    io_fake_setup(1000, 800)
    io_fake_set(io_node(root, "a"), 0, 100, 100, 100)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, IO_SCRIPT)
    vm_run(vm, "io.observe(document.getElementById('a'))") // 2ª vez: ignorada
    io_step(vm)
    testing.expect_value(t, str_of(vm_run(vm, "n + '|' + log")), "1|true,1;")
}

// ── forma da entry ──────────────────────────────────────────────────────────

@(test)
test_io_entry_tem_os_campos_da_spec :: proc(t: ^testing.T) {
    root := build_io_dom()
    defer dom.free_tree(root)
    io_fake_setup(1000, 800)
    io_fake_set(io_node(root, "a"), 10, 700, 100, 200) // metade de baixo cortada
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var s = '';
        var io = new IntersectionObserver(function(es, obs){
            var e = es[0];
            s = e.target.id + '|' + e.boundingClientRect.top + '|' + e.boundingClientRect.height +
                '|' + e.intersectionRect.height + '|' + e.rootBounds.height +
                '|' + e.intersectionRatio + '|' + (obs === io) + '|' + (this === io);
        });
        io.observe(document.getElementById('a'));
    `)
    io_step(vm)
    // alvo 700..900 contra raiz 0..800 ⇒ interseção de 100 de altura, ratio 0.5
    testing.expect_value(t, str_of(vm_run(vm, "s")), "a|700|200|100|800|0.5|true|true")
}

@(test)
test_io_callback_que_lanca_nao_derruba_o_passo :: proc(t: ^testing.T) {
    // Um observador que lança não pode impedir o próximo (nem envenenar o vm).
    root := build_io_dom()
    defer dom.free_tree(root)
    io_fake_setup(1000, 800)
    io_fake_set(io_node(root, "a"), 0, 100, 100, 100)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var ok = 0;
        var mau = new IntersectionObserver(function(){ throw new Error('x') });
        var bom = new IntersectionObserver(function(){ ok = 1 });
        mau.observe(document.getElementById('a'));
        bom.observe(document.getElementById('a'));
    `)
    io_step(vm)
    testing.expect_value(t, str_of(vm_run(vm, "'' + ok")), "1")
}

// ── ResizeObserver ──────────────────────────────────────────────────────────

@(private = "file")
RO_SCRIPT :: `
    var n = 0, log = '';
    var ro = new ResizeObserver(function (es) {
        n += es.length;
        for (var i = 0; i < es.length; i++) log += es[i].contentRect.width + 'x' + es[i].contentRect.height + ';';
    });
    ro.observe(document.getElementById('a'));
`

@(test)
test_ro_entrega_o_tamanho_inicial :: proc(t: ^testing.T) {
    // O tamanho de referência inicial é (0,0) por spec: por isso um alvo COM
    // caixa recebe entry logo no 1o passo, que é o que a página espera de observe().
    root := build_io_dom()
    defer dom.free_tree(root)
    io_fake_setup(1000, 800)
    io_fake_box(io_node(root, "a"), 300, 100, 320, 120, 8, 8)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, RO_SCRIPT)
    testing.expect_value(t, vm_frame_step(vm), true)
    testing.expect_value(t, str_of(vm_run(vm, "n + '|' + log")), "1|300x100;")
}

@(test)
test_ro_alvo_sem_caixa_nao_entrega :: proc(t: ^testing.T) {
    // display:none ⇒ 0x0 ⇒ igual à referência inicial ⇒ NADA. É o "elemento não
    // renderizado é pulado" da spec, de graça.
    root := build_io_dom()
    defer dom.free_tree(root)
    io_fake_setup(1000, 800) // nenhuma caixa registrada
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, RO_SCRIPT)
    testing.expect_value(t, vm_frame_step(vm), false)
    testing.expect_value(t, str_of(vm_run(vm, "n + '|' + log")), "0|")
}

@(test)
test_ro_dispara_so_quando_o_tamanho_MUDA :: proc(t: ^testing.T) {
    // O passo roda todo frame; sem esta guarda o observador viraria um
    // setInterval de 60 Hz no meio do site.
    root := build_io_dom()
    defer dom.free_tree(root)
    io_fake_setup(1000, 800)
    a := io_node(root, "a")
    io_fake_box(a, 300, 100, 300, 100, 0, 0)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, RO_SCRIPT)
    testing.expect_value(t, vm_frame_step(vm), true)  // inicial
    testing.expect_value(t, vm_frame_step(vm), false) // nada mudou
    io_fake_box(a, 250, 100, 250, 100, 0, 0)          // "a janela encolheu"
    testing.expect_value(t, vm_frame_step(vm), true)
    testing.expect_value(t, str_of(vm_run(vm, "n + '|' + log")), "2|300x100;250x100;")
}

@(test)
test_ro_entry_tem_as_duas_caixas :: proc(t: ^testing.T) {
    root := build_io_dom()
    defer dom.free_tree(root)
    io_fake_setup(1000, 800)
    // conteúdo 300x100 dentro de uma caixa de borda 340x140 (padding 12, borda 8)
    io_fake_box(io_node(root, "a"), 300, 100, 340, 140, 12, 12)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var s = '';
        var ro = new ResizeObserver(function (es) {
            var e = es[0];
            s = e.target.id + '|' + e.contentRect.x + ',' + e.contentRect.y +
                '|' + e.contentBoxSize[0].inlineSize + 'x' + e.contentBoxSize[0].blockSize +
                '|' + e.borderBoxSize[0].inlineSize + 'x' + e.borderBoxSize[0].blockSize;
        });
        ro.observe(document.getElementById('a'));
    `)
    vm_frame_step(vm)
    testing.expect_value(t, str_of(vm_run(vm, "s")), "a|12,12|300x100|340x140")
}

@(test)
test_ro_unobserve_e_disconnect_silenciam :: proc(t: ^testing.T) {
    root := build_io_dom()
    defer dom.free_tree(root)
    io_fake_setup(1000, 800)
    a := io_node(root, "a")
    io_fake_box(a, 300, 100, 300, 100, 0, 0)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, RO_SCRIPT)
    vm_frame_step(vm)
    vm_run(vm, "ro.unobserve(document.getElementById('a'))")
    testing.expect_value(t, ro_active(vm), false) // sem alvo: sai da lista por frame
    io_fake_box(a, 111, 100, 111, 100, 0, 0)
    testing.expect_value(t, vm_frame_step(vm), false)
    testing.expect_value(t, str_of(vm_run(vm, "n + '|' + log")), "1|300x100;")
}

@(test)
test_ro_callback_pode_mutar_o_dom :: proc(t: ^testing.T) {
    // O uso REAL: mediu, agora troca a classe/o conteúdo. O passo tem de devolver
    // true para o hospedeiro re-estilizar antes de pintar.
    root := build_io_dom()
    defer dom.free_tree(root)
    io_fake_setup(1000, 800)
    io_fake_box(io_node(root, "a"), 300, 100, 300, 100, 0, 0)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var ro = new ResizeObserver(function (es) {
            es[0].target.setAttribute('class', es[0].contentRect.width > 200 ? 'largo' : 'estreito');
        });
        ro.observe(document.getElementById('a'));
    `)
    testing.expect_value(t, vm_frame_step(vm), true)
    testing.expect_value(t, io_node(root, "a").attrs["class"], "largo")
}

// ── window.matchMedia ───────────────────────────────────────────────────────
// A avaliação real mora no pacote css (mesmo motor do @media) e é testada no
// src/ui, que é quem tem os dois lados. Aqui o fake responde SIM/NÃO por um
// interruptor, para medir o que é deste arquivo: o objeto vivo e o evento.

@(private = "file", thread_local) g_fake_mq: bool
@(private = "file", thread_local) g_fake_mq_ultima: string
@(private = "file")
fake_media :: proc(q: string) -> bool {
    g_fake_mq_ultima = q
    return g_fake_mq
}

@(private = "file")
mq_setup :: proc(inicial: bool) {
    g_fake_mq = inicial
    g_fake_mq_ultima = ""
    g_media_match = fake_media
}

@(test)
test_mq_matches_e_a_query_chegam :: proc(t: ^testing.T) {
    root := build_io_dom()
    defer dom.free_tree(root)
    mq_setup(true)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    got := str_of(vm_run(vm, `
        var m = window.matchMedia('(min-width: 600px)');
        m.matches + '|' + m.media
    `))
    testing.expect_value(t, got, "true|(min-width: 600px)")
    testing.expect_value(t, g_fake_mq_ultima, "(min-width: 600px)") // a query CHEGOU ao motor
}

@(test)
test_mq_matches_e_VIVO :: proc(t: ^testing.T) {
    // A página guarda o MQL e consulta muito depois; se `matches` fosse gravado na
    // criação, a resposta ficaria velha assim que a janela mudasse de tamanho.
    root := build_io_dom()
    defer dom.free_tree(root)
    mq_setup(false)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, "var m = window.matchMedia('(max-width: 500px)')")
    testing.expect_value(t, str_of(vm_run(vm, "'' + m.matches")), "false")
    g_fake_mq = true // "a janela encolheu"
    testing.expect_value(t, str_of(vm_run(vm, "'' + m.matches")), "true")
}

@(test)
test_mq_change_dispara_na_VIRADA :: proc(t: ^testing.T) {
    root := build_io_dom()
    defer dom.free_tree(root)
    mq_setup(false)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var n = 0, ult = null;
        var m = window.matchMedia('(max-width: 500px)');
        m.addEventListener('change', function (e) { n++; ult = e.matches });
    `)
    // sem virada: NAO ha evento inicial (ao contrario do IntersectionObserver)
    testing.expect_value(t, vm_frame_step(vm), false)
    g_fake_mq = true
    testing.expect_value(t, vm_frame_step(vm), true)
    testing.expect_value(t, vm_frame_step(vm), false) // ja entregue: nao repete
    testing.expect_value(t, str_of(vm_run(vm, "n + '|' + ult")), "1|true")
}

@(test)
test_mq_addListener_legado_e_remove :: proc(t: ^testing.T) {
    // Safari < 14 (e todo polyfill que o detecta) usa addListener/removeListener.
    root := build_io_dom()
    defer dom.free_tree(root)
    mq_setup(false)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var n = 0;
        var m = window.matchMedia('(min-width: 900px)');
        var f = function () { n++ };
        m.addListener(f);
    `)
    g_fake_mq = true
    vm_frame_step(vm)
    vm_run(vm, "m.removeListener(f)")
    g_fake_mq = false
    vm_frame_step(vm) // ninguem mais ouvindo
    testing.expect_value(t, str_of(vm_run(vm, "'' + n")), "1")
}

@(test)
test_mq_onchange_tambem_dispara :: proc(t: ^testing.T) {
    // A forma legada por PROPRIEDADE: sem o set-hook ela seria um handler que
    // nunca roda, que e exatamente o defeito que este marco tira.
    root := build_io_dom()
    defer dom.free_tree(root)
    mq_setup(false)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var n = 0;
        var m = window.matchMedia('(min-width: 900px)');
        m.onchange = function (e) { n = n + (e.matches ? 1 : 10) };
    `)
    g_fake_mq = true
    testing.expect_value(t, vm_frame_step(vm), true)
    testing.expect_value(t, str_of(vm_run(vm, "'' + n")), "1")
}

@(test)
test_mq_sem_ouvinte_nao_custa_passo :: proc(t: ^testing.T) {
    // Quem so le `.matches` nao entra na lista por frame (o atalho de custo zero).
    root := build_io_dom()
    defer dom.free_tree(root)
    mq_setup(false)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, "var m = window.matchMedia('(min-width: 900px)'); m.matches")
    testing.expect_value(t, len(vm.media_lists), 0)
    g_fake_mq = true
    testing.expect_value(t, vm_frame_step(vm), false)
}

// ── window.innerWidth/innerHeight (mesma fonte de viewport) ─────────────────

@(test)
test_window_inner_reflete_o_viewport :: proc(t: ^testing.T) {
    // Eram props FIXAS em 800x600: um render 1280x2400 mentia para todo site que
    // pergunta o tamanho da janela para decidir mobile x desktop.
    root := build_io_dom()
    defer dom.free_tree(root)
    io_fake_setup(1280, 2400)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    testing.expect_value(t, str_of(vm_run(vm, "window.innerWidth + 'x' + window.innerHeight")), "1280x2400")
    // e como identificador solto (o global É a window)
    testing.expect_value(t, str_of(vm_run(vm, "innerWidth + 'x' + innerHeight")), "1280x2400")
}

@(test)
test_window_props_dinamicas_valem_para_o_identificador_NU :: proc(t: ^testing.T) {
    // O identificador livre resolvia lendo `window.props` DIRETO, pulando o hook:
    // `window.scrollY` dava o valor real e `scrollY` nu dava o 0 estatico. Vale
    // para a familia inteira das props servidas pelo hook.
    root := build_io_dom()
    defer dom.free_tree(root)
    io_fake_setup(1280, 2400)
    g_fake_sy = 250
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    testing.expect_value(t, str_of(vm_run(vm, "window.scrollY + '|' + scrollY + '|' + pageYOffset")), "250|250|250")
}

@(test)
test_window_inner_fallback_sem_viewport :: proc(t: ^testing.T) {
    // Sem hospedeiro (ou antes de a aba saber o tamanho) o valor tem de continuar
    // sendo o 800x600 de antes -- e NAO zero, que quebraria toda conta de divisao.
    root := build_io_dom()
    defer dom.free_tree(root)
    io_fake_setup(0, 0)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    testing.expect_value(t, str_of(vm_run(vm, "window.innerWidth + 'x' + window.innerHeight")), "800x600")
}

@(test)
test_io_callback_pode_mutar_o_dom :: proc(t: ^testing.T) {
    // É o uso REAL: entrou na tela ⇒ troca a classe / injeta o src. O io_step tem
    // de devolver true para o hospedeiro re-estilizar antes de pintar.
    root := build_io_dom()
    defer dom.free_tree(root)
    io_fake_setup(1000, 800)
    io_fake_set(io_node(root, "a"), 0, 100, 100, 100)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var io = new IntersectionObserver(function(es){
            if (es[0].isIntersecting) es[0].target.setAttribute('class', 'visivel');
        });
        io.observe(document.getElementById('a'));
    `)
    testing.expect_value(t, io_step(vm), true)
    a := io_node(root, "a")
    testing.expect_value(t, a.attrs["class"], "visivel")
}
