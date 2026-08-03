package js

import "core:strings"
import "core:testing"
import dom "../dom"

// HTMLMediaElement: play/pause/load + estado coerente.
//
// ⚠️ O caso mais importante é `play_rejeita_e_paused_continua_true`: é lá que
// mora a decisão de desenho. Um `play()` que RESOLVE passaria em qualquer teste
// de "existe e não lança" e mentiria para a página — que esconderia o pôster e
// esperaria para sempre um `ended` que não vem.

@(private = "file")
media_dom :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    body := dom.make_node(.Element); body.tag = strings.clone("body"); body.attrs = make(map[string]string)
    v := dom.make_node(.Element); v.tag = strings.clone("video"); v.attrs = make(map[string]string)
    v.attrs[strings.clone("id")] = strings.clone("v")
    a := dom.make_node(.Element); a.tag = strings.clone("audio"); a.attrs = make(map[string]string)
    a.attrs[strings.clone("id")] = strings.clone("a")
    d := dom.make_node(.Element); d.tag = strings.clone("div"); d.attrs = make(map[string]string)
    d.attrs[strings.clone("id")] = strings.clone("d")
    dom.append_child(root, body)
    dom.append_child(body, v)
    dom.append_child(body, a)
    dom.append_child(body, d)
    return root
}

@(test)
media_tem_play_pause_load :: proc(t: ^testing.T) {
    root := media_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var v = document.getElementById('v'), a = document.getElementById('a');
        typeof v.pause === 'function' && typeof v.play === 'function' &&
        typeof v.load === 'function' && typeof v.canPlayType === 'function' &&
        typeof a.pause === 'function' && typeof a.play === 'function'
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "<video> e <audio> têm play/pause/load/canPlayType")
}

@(test)
media_pause_nao_lanca :: proc(t: ^testing.T) {
    // O erro original era literalmente `e.pause is not a function`.
    root := media_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var e = 'sem erro';
        try { document.getElementById('v').pause(); } catch (x) { e = 'lancou: ' + x; }
        e
    `, root)
    s, _ := r.(string)
    testing.expectf(t, s == "sem erro", "pause() não lança; veio %q", s)
}

@(test)
media_play_rejeita_e_paused_continua_true :: proc(t: ^testing.T) {
    // ⚠️ O CASO CENTRAL. play() devolve uma promise REJEITADA com NotAllowedError
    // e o estado continua verdadeiro (`paused === true`), que é exatamente o que
    // um navegador real reporta quando a reprodução não pode começar.
    root := media_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var v = document.getElementById('v');
        var p = v.play();
        var ehPromise = p && typeof p.then === 'function';
        var nome = '';
        p.catch(function(err){ nome = err.name; });
        // a rejeição é entregue numa microtarefa; o valor é lido depois dela
        [ehPromise, v.paused, nome]
    `, root)
    // Só o formato é verificável AQUI; o nome chega na microtarefa (ver abaixo).
    arr, _ := r.(^Array)
    testing.expect(t, arr != nil && len(arr.items) == 3, "play() devolveu o trio esperado")
    if arr == nil do return
    eh, _ := arr.items[0].(bool)
    pausado, _ := arr.items[1].(bool)
    testing.expect(t, eh, "play() devolve uma Promise")
    testing.expect(t, pausado, "paused continua true depois de play() rejeitado")
}

@(test)
media_play_entrega_NotAllowedError_na_microtarefa :: proc(t: ^testing.T) {
    // ⚠️ Lição do repo: check de entrega ASSÍNCRONA conferido na linha seguinte
    // acusa BAD até contra o Chrome. O nome do erro só existe depois que a
    // microtarefa roda — por isso este caso é separado do de cima e lê no fim.
    root := media_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var visto = 'nada';
        document.getElementById('v').play().catch(function(err){ visto = err.name; });
        Promise.resolve().then(function(){}).then(function(){});
        visto
    `, root)
    s, _ := r.(string)
    testing.expectf(t, s == "NotAllowedError",
        "a rejeição é NotAllowedError (o que o site usa p/ mostrar o pôster); veio %q", s)
}

@(test)
media_estado_e_real_de_ida_e_volta :: proc(t: ^testing.T) {
    // currentTime/volume/muted são estado DE VERDADE: escreve e lê de volta.
    // Um stub que devolvesse sempre 0 passaria num teste de "existe".
    root := media_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var v = document.getElementById('v');
        v.currentTime = 12.5;
        v.volume = 0.25;
        v.muted = true;
        v.playbackRate = 2;
        v.currentTime === 12.5 && v.volume === 0.25 && v.muted === true &&
        v.playbackRate === 2 && v.paused === true && v.ended === false
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "currentTime/volume/muted/playbackRate guardam o que foi escrito")
}

@(test)
media_o_que_nao_sabemos_diz_que_nao_sabe :: proc(t: ^testing.T) {
    // Degradação HONESTA: sem decodificador, duration é NaN e readyState é
    // HAVE_NOTHING. Devolver 0 para duration seria "vídeo de 0s", que é MENTIRA
    // diferente de "não sei" — e sites dividem por duration.
    root := media_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var v = document.getElementById('v');
        isNaN(v.duration) && v.readyState === 0 && v.networkState === 0 &&
        v.canPlayType('video/mp4') === ''
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "duration NaN, readyState 0 e canPlayType '' — o valor de 'não sei'")
}

@(test)
media_setters_disparam_evento :: proc(t: ^testing.T) {
    root := media_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var v = document.getElementById('v');
        var ev = [];
        v.addEventListener('timeupdate', function(){ ev.push('t'); });
        v.addEventListener('volumechange', function(){ ev.push('v'); });
        v.currentTime = 3;
        v.volume = 0.5;
        ev.join('')
    `, root)
    s, _ := r.(string)
    testing.expectf(t, s == "tv", "seek dispara timeupdate e volume dispara volumechange; veio %q", s)
}

@(test)
media_metodos_nao_vazam_para_elemento_comum :: proc(t: ^testing.T) {
    // ⚠️ `dom_element_methods` é um mapa PLANO — sem a guarda por tag, todo
    // <div> ganharia .paused/.duration. Este caso trava a guarda.
    root := media_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var d = document.getElementById('d');
        typeof d.paused === 'undefined' && typeof d.duration === 'undefined' &&
        typeof d.currentTime === 'undefined'
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "<div> NÃO ganha propriedades de mídia")
}

@(test)
media_cadeia_de_prototipo_da_spec :: proc(t: ^testing.T) {
    // HTMLVideoElement → HTMLMediaElement → HTMLElement. Antes Video/Audio eram
    // IRMÃOS de HTMLMediaElement e o instanceof mentia.
    root := media_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var v = document.getElementById('v'), a = document.getElementById('a');
        (v instanceof HTMLVideoElement) && (v instanceof HTMLMediaElement) &&
        (v instanceof HTMLElement) && (a instanceof HTMLMediaElement) &&
        !(document.getElementById('d') instanceof HTMLMediaElement)
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "video/audio são instanceof HTMLMediaElement; div não é")
}

@(test)
media_load_reseta_o_estado :: proc(t: ^testing.T) {
    root := media_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var v = document.getElementById('v');
        v.currentTime = 30;
        v.load();
        v.currentTime === 0 && v.paused === true
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "load() volta currentTime a 0 e mantém pausado")
}
