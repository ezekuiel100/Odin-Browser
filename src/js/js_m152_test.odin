package js

// M152 — Performance Timeline + PerformanceObserver (performance.odin).
//
// Terceiro alvo nomeado pelo M150: `PerformanceObserver is not defined` em 3
// sites (wikipedia, vercel, wired).
//
// ⚠️ O TESTE MAIS IMPORTANTE DESTE ARQUIVO é o
// `m152_nao_inventamos_metrica_que_nao_medimos`. A razão pela qual os sites usam
// esta API é web-vitals (LCP, CLS, FID, paint, resource) e nós NÃO MEDIMOS nada
// disso. Seria trivial inventar entradas plausíveis e fazer o site "funcionar" —
// e seria o pior resultado possível, porque um painel de métricas passaria a
// receber dado FALSO sem ninguém perceber. O teste existe para que anunciar
// suporte a essas métricas seja uma decisão explícita, nunca um descuido.

import "core:testing"
import "core:strings"
import dom "../dom"

@(private = "file")
m152_dom :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    div := dom.make_node(.Element)
    div.tag = strings.clone("div")
    dom.append_child(root, div)
    return root
}

// Roda `src` numa VM com DOM e BOMBEIA os timers — a entrega ao observer é
// assíncrona (a spec entrega numa tarefa), então sem o pump o callback não roda.
@(private = "file")
run_dom_pumped :: proc(src: string) -> Value {
    root := m152_dom()
    defer dom.free_tree(root)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, src)
    for _ in 0 ..< 8 do vm_pump_timers(vm, vm.clock_ms + 16)
    return vm_run(vm, `__r`)
}

// mark/measure são SÍNCRONOS, mas `performance` e `PerformanceObserver` só
// existem com DOM (são do window). NÃO dá para usar o `run()` puro aqui — ele
// roda numa VM sem window, o global vira ReferenceError e a asserção sobre nil
// daria PANIC, que sob o harness trava as outras threads (foi o que travou a
// suíte inteira na 1ª versão deste arquivo).
@(private = "file")
run_dom :: proc(src: string) -> Value {
    root := m152_dom()
    defer dom.free_tree(root)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    return vm_run(vm, src)
}

// ── timeline: mark/measure deixaram de ser no-op ─────────────────────────────

@(test)
m152_mark_entra_na_timeline :: proc(t: ^testing.T) {
    // Eram STUBS: mark/measure engoliam tudo e getEntries* devolvia array vazio.
    src := `
        performance.mark('inicio');
        var e = performance.getEntriesByType('mark')[0];
        e.name + "|" + e.entryType + "|" + (e.duration === 0)
    `
    testing.expect_value(t, run_dom(src).(string), "inicio|mark|true")
}

@(test)
m152_measure_calcula_duracao_entre_marks :: proc(t: ^testing.T) {
    // O padrão canônico de instrumentação. `startTime` do measure é o da mark
    // inicial, não o instante da chamada.
    src := `
        performance.mark('a');
        performance.mark('b', {startTime: 250});
        performance.measure('trecho', 'a', 'b');
        var m = performance.getEntriesByName('trecho')[0];
        m.entryType + "|" + m.startTime + "|" + m.duration
    `
    testing.expect_value(t, run_dom(src).(string), "measure|0|250")
}

@(test)
m152_measure_com_opcoes :: proc(t: ^testing.T) {
    // 2ª forma (ES2019): measure(name, {start, end}) e {start, duration}.
    src := `
        performance.measure('x', {start: 10, end: 40});
        performance.measure('y', {start: 100, duration: 5});
        var x = performance.getEntriesByName('x')[0], y = performance.getEntriesByName('y')[0];
        x.duration + "|" + y.startTime + "|" + y.duration
    `
    testing.expect_value(t, run_dom(src).(string), "30|100|5")
}

@(test)
m152_mark_devolve_a_entrada :: proc(t: ^testing.T) {
    // A spec devolve a PerformanceMark criada; código real encadeia nisso.
    testing.expect_value(t, run_dom(`performance.mark('z').name`).(string), "z")
}

@(test)
m152_get_entries_e_filtros :: proc(t: ^testing.T) {
    src := `
        performance.mark('m1'); performance.mark('m2'); performance.measure('d', 'm1');
        performance.getEntries().length + "|" +
        performance.getEntriesByType('mark').length + "|" +
        performance.getEntriesByType('measure').length + "|" +
        performance.getEntriesByName('m1').length
    `
    testing.expect_value(t, run_dom(src).(string), "3|2|1|1")
}

@(test)
m152_clear_marks_e_measures :: proc(t: ^testing.T) {
    // sem argumento limpa TODAS do tipo; com nome, só aquela — e NÃO pode levar
    // junto as do outro tipo.
    src := `
        performance.mark('a'); performance.mark('b'); performance.measure('med','a');
        performance.clearMarks('a');
        var t1 = performance.getEntriesByType('mark').length;
        performance.clearMarks();
        var t2 = performance.getEntriesByType('mark').length;
        var t3 = performance.getEntriesByType('measure').length;
        performance.clearMeasures();
        t1 + "|" + t2 + "|" + t3 + "|" + performance.getEntries().length
    `
    testing.expect_value(t, run_dom(src).(string), "1|0|1|0")
}

// ── PerformanceObserver ──────────────────────────────────────────────────────

@(test)
m152_observer_recebe_marks :: proc(t: ^testing.T) {
    src := `
        var __r = "nao-chamou";
        var po = new PerformanceObserver(function(list) {
            var es = list.getEntries();
            __r = es.length + ":" + es[0].name + ":" + es[1].name;
        });
        po.observe({entryTypes: ['mark']});
        performance.mark('um');
        performance.mark('dois');
    `
    // duas marks seguidas viram UMA entrega com a lista inteira, como no browser
    testing.expect_value(t, run_dom_pumped(src).(string), "2:um:dois")
}

@(test)
m152_entrega_e_assincrona :: proc(t: ^testing.T) {
    // O callback NÃO pode rodar dentro do mark que o originou (a spec entrega
    // numa tarefa). Se rodasse em linha, `__r` já estaria preenchido aqui.
    src := `
        var __r = "ainda-nao";
        var po = new PerformanceObserver(function(){ __r = "chamou" });
        po.observe({type: 'mark'});
        performance.mark('agora');
        var sincrono = __r;
        __r = sincrono;
    `
    root := m152_dom()
    defer dom.free_tree(root)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, src)
    testing.expect_value(t, vm_run(vm, `__r`).(string), "ainda-nao")
    for _ in 0 ..< 4 do vm_pump_timers(vm, vm.clock_ms + 16)
    testing.expect_value(t, vm_run(vm, `__r`).(string), "chamou")
}

@(test)
m152_observer_buffered_pega_o_passado :: proc(t: ^testing.T) {
    // `buffered:true` entrega o que JÁ estava na timeline antes do observe —
    // é como o web-vitals não perde a métrica que ocorreu antes de ele carregar.
    src := `
        var __r = "nao-chamou";
        performance.mark('antiga');
        var po = new PerformanceObserver(function(list){ __r = list.getEntries()[0].name });
        po.observe({type: 'mark', buffered: true});
    `
    testing.expect_value(t, run_dom_pumped(src).(string), "antiga")
}

@(test)
m152_disconnect_para_de_entregar :: proc(t: ^testing.T) {
    src := `
        var __r = "vazio";
        var po = new PerformanceObserver(function(){ __r = "chamou" });
        po.observe({entryTypes:['mark']});
        po.disconnect();
        performance.mark('depois');
    `
    testing.expect_value(t, run_dom_pumped(src).(string), "vazio")
}

@(test)
m152_take_records_esvazia_a_fila :: proc(t: ^testing.T) {
    // takeRecords devolve o pendente e ZERA — quem o usa não quer o callback.
    src := `
        var __r = "?";
        var po = new PerformanceObserver(function(){});
        po.observe({entryTypes:['mark']});
        performance.mark('p');
        __r = po.takeRecords().length + "|" + po.takeRecords().length;
    `
    root := m152_dom()
    defer dom.free_tree(root)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, src)
    testing.expect_value(t, vm_run(vm, `__r`).(string), "1|0")
}

@(test)
m152_entry_list_tem_os_tres_metodos :: proc(t: ^testing.T) {
    // A lista NÃO é um array: a spec dá um PerformanceObserverEntryList, e
    // código real chama getEntriesByType/ByName nela.
    src := `
        var __r = "?";
        var po = new PerformanceObserver(function(list) {
            __r = list.getEntries().length + "|" + list.getEntriesByType('measure').length +
                  "|" + list.getEntriesByName('mm').length;
        });
        po.observe({entryTypes:['mark','measure']});
        performance.mark('k');
        performance.measure('mm', 'k');
    `
    testing.expect_value(t, run_dom_pumped(src).(string), "2|1|1")
}

@(test)
m152_callback_nao_funcao_lanca :: proc(t: ^testing.T) {
    src := `
        var r = "?";
        try { new PerformanceObserver(42) } catch (e) { r = e.name }
        r
    `
    testing.expect_value(t, run_dom(src).(string), "TypeError")
}

// ── A LINHA QUE NÃO ATRAVESSEI ───────────────────────────────────────────────

@(test)
m152_nao_inventamos_metrica_que_nao_medimos :: proc(t: ^testing.T) {
    // ⚠️ ESTE é o teste que importa. `supportedEntryTypes` é o feature-detect
    // canônico do web-vitals: a lib pergunta ANTES de observar. Listar aqui um
    // tipo que não medimos faria a lib observar e reportar número inventado —
    // pior que não suportar. Só entram `mark` e `measure`, que a PÁGINA produz.
    src := `
        var s = PerformanceObserver.supportedEntryTypes;
        var proibidos = ['largest-contentful-paint','layout-shift','paint','resource',
                         'first-input','longtask','navigation','element'];
        var mentiras = [];
        for (var i = 0; i < proibidos.length; i++) {
            if (s.indexOf(proibidos[i]) >= 0) mentiras.push(proibidos[i]);
        }
        s.join(',') + " // mentiras: " + mentiras.join(',')
    `
    testing.expect_value(t, run_dom(src).(string), "mark,measure // mentiras: ")
}

@(test)
m152_observar_tipo_nao_suportado_nao_lanca_e_nao_entrega :: proc(t: ^testing.T) {
    // A spec manda AVISAR e sair, sem lançar — e é o que um browser sem aquela
    // métrica faz. O site segue vivo; só nunca recebe a métrica que não temos.
    src := `
        var __r = "silencio-ok";
        var po = new PerformanceObserver(function(){ __r = "ENTREGOU-INVENTADO" });
        try { po.observe({type:'largest-contentful-paint', buffered:true}) }
        catch (e) { __r = "LANCOU:" + e.name }
        performance.mark('irrelevante');
    `
    testing.expect_value(t, run_dom_pumped(src).(string), "silencio-ok")
}

@(test)
m152_interfaces_existem_mas_nao_sao_construiveis :: proc(t: ^testing.T) {
    // Cascas p/ instanceof e feature-detect (mesmo motivo das órfãs do M150).
    // A spec marca todas como não-construíveis pela página: `new PerformanceEntry()`
    // é "Illegal constructor" no Chrome também.
    src := `
        var faltando = [], construiu = [];
        var nomes = ["PerformanceEntry","PerformanceMark","PerformanceMeasure",
                     "PerformanceObserverEntryList","PerformanceResourceTiming"];
        for (var i = 0; i < nomes.length; i++) {
            var g = window[nomes[i]];
            if (typeof g !== "function" || !g.prototype) { faltando.push(nomes[i]); continue }
            try { new g(); construiu.push(nomes[i]) } catch (e) {}
        }
        faltando.join(",") + "|" + construiu.join(",")
    `
    root := m152_dom()
    defer dom.free_tree(root)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    testing.expect_value(t, vm_run(vm, src).(string), "|")
}

@(test)
m152_typeof_deixou_de_ser_undefined :: proc(t: ^testing.T) {
    // A regressão que este marco fecha.
    testing.expect_value(t, run_dom(`typeof PerformanceObserver`).(string), "function")
    testing.expect_value(t, run_dom(`typeof PerformanceObserver.supportedEntryTypes`).(string), "object")
}
