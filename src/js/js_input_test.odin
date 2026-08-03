package js

// Testes de inputs controlados + eventos (#3 do roadmap SPA): el.value get/set,
// atributos refletidos, handlers on* genéricos (oninput/onchange/onsubmit...),
// dispatchEvent e o objeto de evento com target.value — o ciclo que o React usa
// para inputs controlados. Rodar: odin test src/js
//
// NOTA: a EDIÇÃO interativa real (digitar num <input> desenhado e disparar 'input'
// a partir do teclado) é trabalho da camada de UI, ainda não implementado; aqui
// exercitamos a semântica JS observável, disparando eventos programaticamente.

import "core:strings"
import "core:testing"
import dom "../dom"

// Monta:  <form><input id="campo" value="inicial" type="text"></form>  sob Document.
@(private = "file")
build_form :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)

    form := dom.make_node(.Element)
    form.tag = strings.clone("form")

    inp := dom.make_node(.Element)
    inp.tag = strings.clone("input")
    inp.attrs = make(map[string]string)
    inp.attrs[strings.clone("id")]    = strings.clone("campo")
    inp.attrs[strings.clone("value")] = strings.clone("inicial")
    inp.attrs[strings.clone("type")]  = strings.clone("text")

    dom.append_child(form, inp)
    dom.append_child(root, form)
    return root
}

@(private = "file")
expect_true :: proc(t: ^testing.T, src: string, root: ^dom.Node, msg: string) {
    r := run_with_dom(src, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, msg)
}

// .value lê o atributo inicial e reflete o que foi escrito.
@(test)
test_input_value_get_set :: proc(t: ^testing.T) {
    root := build_form()
    defer dom.free_tree(root)
    expect_true(t,
        `var el = document.getElementById('campo');
         var antes = el.value;               // 'inicial'
         el.value = 'digitado';
         antes === 'inicial' && el.value === 'digitado'`,
        root, ".value deve ler o inicial e refletir a escrita")
}

// atributos refletidos comuns que o React lê.
@(test)
test_input_reflected_attrs :: proc(t: ^testing.T) {
    root := build_form()
    defer dom.free_tree(root)
    expect_true(t,
        `var el = document.getElementById('campo');
         el.name = 'usuario';
         el.placeholder = 'Digite...';
         el.id === 'campo' && el.type === 'text' &&
         el.name === 'usuario' && el.placeholder === 'Digite...'`,
        root, "id/type/name/placeholder devem refletir atributos")
}

// .checked é booleano (checkbox).
@(test)
test_input_checked_bool :: proc(t: ^testing.T) {
    root := build_form()
    defer dom.free_tree(root)
    expect_true(t,
        `var el = document.getElementById('campo');
         var a = el.checked;      // false (ausente)
         el.checked = true;
         var b = el.checked;      // true
         el.checked = false;
         a === false && b === true && el.checked === false`,
        root, ".checked deve ser booleano e alternável")
}

// oninput dispara e o handler lê event.target.value (o padrão React controlado).
@(test)
test_input_oninput_target_value :: proc(t: ^testing.T) {
    root := build_form()
    defer dom.free_tree(root)
    expect_true(t,
        `var el = document.getElementById('campo');
         var visto = '';
         el.oninput = function(e) { visto = e.target.value; };
         el.value = 'abc';                 // "usuário digitou"
         el.dispatchEvent(new Event('input'));
         visto === 'abc'`,
        root, "oninput deve rodar e ler e.target.value")
}

// onchange também funciona (mesmo canal genérico on*).
@(test)
test_input_onchange :: proc(t: ^testing.T) {
    root := build_form()
    defer dom.free_tree(root)
    expect_true(t,
        `var el = document.getElementById('campo');
         var n = 0;
         el.onchange = function() { n++; };
         el.dispatchEvent('change');       // string também é aceita
         el.dispatchEvent('change');
         n === 2`,
        root, "onchange deve disparar via dispatchEvent")
}

// Reatribuir o handler-propriedade SUBSTITUI (não acumula) — componente re-render.
@(test)
test_input_prop_handler_replaces :: proc(t: ^testing.T) {
    root := build_form()
    defer dom.free_tree(root)
    expect_true(t,
        `var el = document.getElementById('campo');
         var velho = 0, novo = 0;
         el.oninput = function() { velho++; };
         el.oninput = function() { novo++; };   // substitui o anterior
         el.dispatchEvent('input');
         velho === 0 && novo === 1`,
        root, "reatribuir on* deve substituir o handler anterior")
}

// addEventListener e o handler-propriedade COEXISTEM (ambos disparam).
@(test)
test_input_addlistener_and_prop_coexist :: proc(t: ^testing.T) {
    root := build_form()
    defer dom.free_tree(root)
    expect_true(t,
        `var el = document.getElementById('campo');
         var viaProp = 0, viaAdd = 0;
         el.oninput = function() { viaProp++; };
         el.addEventListener('input', function() { viaAdd++; });
         el.dispatchEvent('input');
         viaProp === 1 && viaAdd === 1`,
        root, "on* e addEventListener devem coexistir")
}

// onsubmit num form + preventDefault (padrão de formulário React).
@(test)
test_form_onsubmit_prevent :: proc(t: ^testing.T) {
    root := build_form()
    defer dom.free_tree(root)
    expect_true(t,
        `var form = document.querySelector ? null : null;  // querySelector sem hook aqui
         var f = document.getElementById('campo').parentNode;  // o <form>
         var enviou = false, prevenido = false;
         f.onsubmit = function(e) { enviou = true; e.preventDefault(); prevenido = e.defaultPrevented; };
         f.dispatchEvent('submit');
         enviou === true && prevenido === true`,
        root, "onsubmit deve rodar e preventDefault marcar defaultPrevented")
}

// Evento borbulha do input até o form (bubbling), lendo target vs currentTarget.
@(test)
test_event_bubbles_to_parent :: proc(t: ^testing.T) {
    root := build_form()
    defer dom.free_tree(root)
    expect_true(t,
        `var el = document.getElementById('campo');
         var f = el.parentNode;
         var alvoOK = false, atualOK = false;
         f.addEventListener('input', function(e) {
            alvoOK  = (e.target === el);   // alvo = input
            atualOK = (e.currentTarget === f); // currentTarget = form (onde escuta)
         });
         el.dispatchEvent('input');
         alvoOK && atualOK`,
        root, "evento deve borbulhar do input ao form com target/currentTarget certos")
}

// Definir onclick como null remove o handler.
@(test)
test_prop_handler_null_removes :: proc(t: ^testing.T) {
    root := build_form()
    defer dom.free_tree(root)
    expect_true(t,
        `var el = document.getElementById('campo');
         var n = 0;
         el.onclick = function() { n++; };
         el.onclick = null;     // remove
         el.dispatchEvent('click');
         n === 0`,
        root, "on* = null deve remover o handler")
}
