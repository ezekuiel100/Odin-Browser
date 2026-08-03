package js

// Testes de el.style e el.dataset (#4 do roadmap SPA). React aplica estilos
// dinâmicos via `node.style[prop] = val` (setValueForStyles) e lê/grava
// data-attributes via el.dataset. Rodar: odin test src/js

import "core:strings"
import "core:testing"
import dom "../dom"

// Monta:  <div id="x" style="color: red"></div>  sob um Document.
@(private = "file")
build_styled :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    div := dom.make_node(.Element)
    div.tag = strings.clone("div")
    div.attrs = make(map[string]string)
    div.attrs[strings.clone("id")]    = strings.clone("x")
    div.attrs[strings.clone("style")] = strings.clone("color: red")
    dom.append_child(root, div)
    return root
}

@(private = "file")
expect_true :: proc(t: ^testing.T, src: string, root: ^dom.Node, msg: string) {
    r := run_with_dom(src, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, msg)
}

// Lê o valor final do atributo style do div (para conferir a serialização).
@(private = "file")
style_attr :: proc(root: ^dom.Node) -> string {
    div := dom.find_first(root, "div")
    return div.attrs["style"]
}

// style.<prop> lê o inline inicial.
@(test)
test_style_get_initial :: proc(t: ^testing.T) {
    root := build_styled()
    defer dom.free_tree(root)
    expect_true(t,
        `document.getElementById('x').style.color === 'red'`,
        root, "style.color deve ler o inline inicial")
}

// prop CSS ausente devolve "" (não undefined).
@(test)
test_style_missing_is_empty :: proc(t: ^testing.T) {
    root := build_styled()
    defer dom.free_tree(root)
    expect_true(t,
        `document.getElementById('x').style.fontSize === ''`,
        root, "prop de estilo ausente deve ser string vazia")
}

// Setar camelCase escreve kebab-case no atributo, preservando o existente.
@(test)
test_style_set_camel_to_kebab :: proc(t: ^testing.T) {
    root := build_styled()
    defer dom.free_tree(root)
    run_with_dom(
        `var s = document.getElementById('x').style;
         s.backgroundColor = 'blue';
         s.fontSize = '14px';`,
        root)
    got := style_attr(root)
    testing.expect(t, strings.contains(got, "background-color: blue"), "deve gravar background-color kebab")
    testing.expect(t, strings.contains(got, "font-size: 14px"), "deve gravar font-size kebab")
    testing.expect(t, strings.contains(got, "color: red"), "deve preservar o color existente")
}

// Reatribuir uma prop existente atualiza (não duplica).
@(test)
test_style_update_existing :: proc(t: ^testing.T) {
    root := build_styled()
    defer dom.free_tree(root)
    expect_true(t,
        `var s = document.getElementById('x').style;
         s.color = 'green';
         s.color === 'green'`,
        root, "atualizar style.color deve refletir o novo valor")
    got := style_attr(root)
    testing.expect(t, !strings.contains(got, "red"), "o valor antigo (red) não deve permanecer")
}

// Setar "" remove a propriedade.
@(test)
test_style_empty_removes :: proc(t: ^testing.T) {
    root := build_styled()
    defer dom.free_tree(root)
    expect_true(t,
        `var s = document.getElementById('x').style;
         s.color = '';
         s.color === ''`,
        root, "definir style.color='' deve remover a propriedade")
}

// cssText lê e grava a string inteira.
@(test)
test_style_css_text :: proc(t: ^testing.T) {
    root := build_styled()
    defer dom.free_tree(root)
    expect_true(t,
        `var s = document.getElementById('x').style;
         s.cssText = 'margin: 4px; padding: 8px';
         s.margin === '4px' && s.padding === '8px'`,
        root, "cssText deve substituir tudo e ser lido de volta por prop")
}

// setProperty / getPropertyValue / removeProperty (props já em kebab, inclui --custom).
@(test)
test_style_set_property_methods :: proc(t: ^testing.T) {
    root := build_styled()
    defer dom.free_tree(root)
    expect_true(t,
        `var s = document.getElementById('x').style;
         s.setProperty('font-weight', 'bold');
         s.setProperty('--brand', '#09f');
         var a = s.getPropertyValue('font-weight');   // 'bold'
         var b = s.getPropertyValue('--brand');        // '#09f'
         s.removeProperty('font-weight');
         a === 'bold' && b === '#09f' && s.getPropertyValue('font-weight') === ''`,
        root, "setProperty/getPropertyValue/removeProperty devem funcionar (inclui --custom)")
}

// dataset lê e grava data-attributes com conversão camelCase <-> kebab.
@(test)
test_dataset_get_set :: proc(t: ^testing.T) {
    root := build_styled()
    defer dom.free_tree(root)
    run_with_dom(
        `var el = document.getElementById('x');
         el.dataset.userId = '42';
         el.dataset.tabIndex = '3';`,
        root)
    div := dom.find_first(root, "div")
    testing.expect_value(t, div.attrs["data-user-id"], "42")
    testing.expect_value(t, div.attrs["data-tab-index"], "3")
}

// dataset lê um data-attribute pré-existente; ausente é undefined.
@(test)
test_dataset_read_and_missing :: proc(t: ^testing.T) {
    root := build_styled()
    div := dom.find_first(root, "div")
    div.attrs[strings.clone("data-role")] = strings.clone("admin")
    defer dom.free_tree(root)
    expect_true(t,
        `var el = document.getElementById('x');
         el.dataset.role === 'admin' && el.dataset.inexistente === undefined`,
        root, "dataset deve ler data-attr existente e dar undefined p/ ausente")
}

// Integração: mesmo padrão do React (style[prop]=val por um objeto de estilos).
@(test)
test_style_react_pattern :: proc(t: ^testing.T) {
    root := build_styled()
    defer dom.free_tree(root)
    expect_true(t,
        `var el = document.getElementById('x');
         var estilos = { color: 'navy', marginTop: '10px', display: 'flex' };
         for (var k in estilos) { el.style[k] = estilos[k]; }  // setValueForStyles
         el.style.color === 'navy' && el.style.marginTop === '10px' && el.style.display === 'flex'`,
        root, "aplicar um objeto de estilos via style[k]=v (padrão React)")
}
