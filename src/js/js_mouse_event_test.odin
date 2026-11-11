package js

// Eventos de MOUSE sintetizados pela UI (dispatch_mouse_event): o clique
// esquerdo e a sequência do botão do MEIO (mousedown/mouseup/auxclick).
// Rodar: odin test src/js

import "core:strings"
import "core:testing"
import dom "../dom"

// <div id="x"><span id="s">antigo</span></div> sob um Document. O alvo é o
// <span>; os listeners ficam no <div> ou no document p/ provar a SUBIDA.
@(private = "file")
mk_dom :: proc() -> (root, div, span: ^dom.Node) {
    root = dom.make_node(.Document)
    div = dom.make_node(.Element)
    div.tag = strings.clone("div")
    div.attrs = make(map[string]string)
    div.attrs[strings.clone("id")] = strings.clone("x")
    span = dom.make_node(.Element)
    span.tag = strings.clone("span")
    span.attrs = make(map[string]string)
    span.attrs[strings.clone("id")] = strings.clone("s")
    txt := dom.make_node(.Text)
    txt.text = strings.clone("antigo")
    dom.append_child(span, txt)
    dom.append_child(div, span)
    dom.append_child(root, div)
    return
}

@(private = "file")
txt_of :: proc(n: ^dom.Node) -> string {
    sb: strings.Builder
    strings.builder_init(&sb)
    defer strings.builder_destroy(&sb)
    dom.text_content(n, &sb)
    return strings.clone(strings.to_string(sb), context.temp_allocator)
}

// O filtro de handler de link mais comum da web é `if (e.button !== 0) return`.
// Com o evento sem `button` (undefined) ele recusava até o clique ESQUERDO.
@(test)
test_mouse_click_tem_button_zero :: proc(t: ^testing.T) {
    root, div, span := mk_dom()
    defer dom.free_tree(root)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        document.getElementById('x').addEventListener('click', function(e) {
            if (e.button !== 0) return;
            document.getElementById('x').textContent = 'esq b=' + e.button + ' bs=' + e.buttons;
        });
    `)
    fired, prevented := dispatch_mouse_event(vm, span, "click", 0, 0)
    testing.expect(t, fired, "o listener do pai roda (o evento SOBE do span)")
    testing.expect(t, !prevented, "ninguém chamou preventDefault")
    testing.expect_value(t, txt_of(div), "esq b=0 bs=0")
}

// Controle do teste acima: o mesmo handler, com o evento CRU de antes
// (dispatch_event, sem `button`), NÃO passa do filtro. Se este falhar, o
// teste de cima não está provando nada.
@(test)
test_mouse_click_cru_e_recusado_pelo_filtro :: proc(t: ^testing.T) {
    root, div, span := mk_dom()
    defer dom.free_tree(root)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        document.getElementById('x').addEventListener('click', function(e) {
            if (e.button !== 0) return;
            document.getElementById('x').textContent = 'passou';
        });
    `)
    dispatch_event(vm, span, "click")
    testing.expect_value(t, txt_of(div), "antigo")
}

// Sequência do meio: mousedown{1,4} → mouseup{1,0} → auxclick{1,0}, todos com
// target = o span e subindo até o document.
@(test)
test_mouse_meio_sequencia :: proc(t: ^testing.T) {
    root, div, span := mk_dom()
    defer dom.free_tree(root)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    vm_run(vm, `
        var log = [];
        function rec(e) { log.push(e.type + ':' + e.button + '/' + e.buttons + '@' + e.target.id); }
        document.addEventListener('mousedown', rec);
        document.addEventListener('mouseup', rec);
        document.addEventListener('auxclick', rec);
        document.addEventListener('click', rec); // o meio NÃO pode cair aqui
        document.addEventListener('auxclick', function() {
            document.getElementById('x').textContent = log.join(' ');
        });
    `)
    dispatch_mouse_event(vm, span, "mousedown", 1, 4)
    dispatch_mouse_event(vm, span, "mouseup", 1, 0)
    dispatch_mouse_event(vm, span, "auxclick", 1, 0)
    testing.expect_value(t, txt_of(div), "mousedown:1/4@s mouseup:1/0@s auxclick:1/0@s")
}

// `auxclick` cancelado é o que impede o navegador de abrir o link em aba nova:
// o dispatch tem de devolver `prevented` — e só quando alguém cancelou.
@(test)
test_mouse_auxclick_prevent_default :: proc(t: ^testing.T) {
    root, div, span := mk_dom()
    defer dom.free_tree(root)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    _ = div
    vm_run(vm, `
        document.getElementById('x').addEventListener('auxclick', function(e) {
            if (e.button === 1 && e.cancelable) e.preventDefault();
        });
    `)
    _, p_meio := dispatch_mouse_event(vm, span, "auxclick", 1, 0)
    testing.expect(t, p_meio, "auxclick do meio cancelado ⇒ prevented")
    // controle: o MESMO handler com button=2 não cancela
    _, p_dir := dispatch_mouse_event(vm, span, "auxclick", 2, 0)
    testing.expect(t, !p_dir, "auxclick do direito não foi cancelado")
}
