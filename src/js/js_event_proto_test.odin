package js

import "core:strings"
import "core:testing"
import dom "../dom"

// Evento SINTETIZADO herda de Event.prototype.
//
// O gap: `composedPath` existia em Event.prototype desde o M119, mas só
// `new Event()` linkava nele. Os outros DOIS caminhos que criam objeto de evento
// — o dispatch sintetizado (clique/input/load da UI, e `dispatchEvent` com uma
// STRING) e `document.createEvent` — devolviam objeto cru, e o teste do M119 não
// pegava porque só olhava o PROTÓTIPO, nunca uma instância desses caminhos.
// Sintoma em site real: `TypeError: e.composedPath is not a function` na 1ª
// página com listener delegado no document.
//
// ⚠️ Cada caso abaixo vem PAREADO com o controle `new Event()`, que sempre
// funcionou: assim um "conserto" que só quebre o caminho bom não passa.

@(private = "file")
ev_dom :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    body := dom.make_node(.Element); body.tag = strings.clone("body"); body.attrs = make(map[string]string)
    dom.append_child(root, body)
    return root
}

@(test)
evento_sintetizado_herda_do_prototype :: proc(t: ^testing.T) {
    root := ev_dom(); defer dom.free_tree(root)
    // dispatchEvent com STRING é exatamente o ramo `ev_in == nil` do
    // dispatch_event_obj — o mesmo por onde entra o clique vindo da UI.
    r := run_with_dom(`
        var visto = null;
        document.body.addEventListener('click', function(e){ visto = e; });
        document.body.dispatchEvent('click');
        visto !== null &&
        visto.type === 'click' &&
        typeof visto.composedPath === 'function' &&
        visto.composedPath().length === 0 &&
        typeof visto.stopImmediatePropagation === 'function'
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "evento sintetizado tem composedPath/stopImmediatePropagation")
}

@(test)
evento_sintetizado_mantem_preventdefault_real :: proc(t: ^testing.T) {
    root := ev_dom(); defer dom.free_tree(root)
    // ⚠️ o protótipo tem preventDefault/stopPropagation NO-OP. As props próprias
    // escritas pelo dispatch têm de continuar sombreando-as, senão o proto novo
    // teria trocado um comportamento que funcionava por um que não faz nada.
    r := run_with_dom(`
        var marcou = false;
        document.body.addEventListener('submit', function(e){
            e.preventDefault();
            marcou = e.defaultPrevented === true;
        });
        document.body.dispatchEvent('submit');
        marcou
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "preventDefault própria (real) sombreia o no-op do prototype")
}

@(test)
createevent_herda_do_prototype :: proc(t: ^testing.T) {
    root := ev_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var e = document.createEvent('Event');
        e.initEvent('x', true, true);
        e.type === 'x' &&
        typeof e.composedPath === 'function' &&
        typeof e.stopImmediatePropagation === 'function' &&
        typeof e.initEvent === 'function'
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "document.createEvent herda de Event.prototype e mantém initEvent")
}

@(test)
new_event_continua_herdando :: proc(t: ^testing.T) {
    root := ev_dom(); defer dom.free_tree(root)
    // CONTROLE: o caminho que já funcionava. Passa dos dois lados da sabotagem.
    r := run_with_dom(`
        var e = new Event('click');
        typeof e.composedPath === 'function' && (e instanceof Event)
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "controle: new Event() segue herdando de Event.prototype")
}
