package js

import "core:strings"
import "core:testing"
import dom "../dom"

// DOMMatrix / DOMMatrixReadOnly / DOMPoint.
//
// ⚠️ O risco desta feature NÃO é "não existe" — é dar NÚMERO PLAUSÍVEL E ERRADO.
// Convenção trocada (linha × coluna), grau × radiano e ordem de multiplicação
// produzem todas uma matriz de aparência normal. Por isso quase todo caso abaixo
// compara contra um resultado que só sai com a convenção CERTA, e vários usam
// `transformPoint` como oráculo independente: se a convenção interna estivesse
// espelhada, a matriz "bateria" consigo mesma mas moveria o ponto para o lugar
// errado.

@(private = "file")
dm_dom :: proc() -> ^dom.Node {
    root := dom.make_node(.Document)
    body := dom.make_node(.Element); body.tag = strings.clone("body"); body.attrs = make(map[string]string)
    dom.append_child(root, body)
    return root
}

@(test)
dommatrix_existe_e_comeca_identidade :: proc(t: ^testing.T) {
    root := dm_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var m = new DOMMatrix();
        m.a === 1 && m.b === 0 && m.c === 0 && m.d === 1 && m.e === 0 && m.f === 0 &&
        m.m11 === 1 && m.m22 === 1 && m.m33 === 1 && m.m44 === 1 &&
        m.is2D === true && m.isIdentity === true
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "new DOMMatrix() é a identidade, com aliases 2D e derivados")
}

@(test)
dommatrix_de_string_css :: proc(t: ^testing.T) {
    // O uso nº1 em site real: new DOMMatrix(getComputedStyle(el).transform).
    root := dm_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var m = new DOMMatrix('matrix(2, 0, 0, 3, 10, 20)');
        var n = new DOMMatrix('none');
        var vazio = new DOMMatrix('');
        m.a === 2 && m.d === 3 && m.e === 10 && m.f === 20 &&
        m.m11 === 2 && m.m22 === 3 && m.m41 === 10 && m.m42 === 20 &&
        n.isIdentity === true && vazio.isIdentity === true
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "matrix(...) e none/'' viram a matriz certa")
}

@(test)
dommatrix_matrix3d_e_is2d :: proc(t: ^testing.T) {
    root := dm_dom(); defer dom.free_tree(root)
    // ⚠️ a ordem de matrix3d é COLUNA-MAIOR: os 3 últimos antes do 16º são a
    // translação (m41,m42,m43). Um parser em linha-maior passaria no is2D e
    // erraria a translação — daí conferir m41/m42/m43 explicitamente.
    r := run_with_dom(`
        var m = new DOMMatrix('matrix3d(1,0,0,0, 0,1,0,0, 0,0,1,0, 5,6,7,1)');
        m.is2D === false && m.m41 === 5 && m.m42 === 6 && m.m43 === 7 &&
        new DOMMatrix('matrix(1,0,0,1,0,0)').is2D === true
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "matrix3d é coluna-maior e is2D distingue os dois")
}

@(test)
dommatrix_string_invalida_lanca :: proc(t: ^testing.T) {
    // Silêncio aqui seria o pior caso: identidade inventada e layout errado sem
    // sintoma. A spec manda SyntaxError.
    root := dm_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var e = '';
        try { new DOMMatrix('rotate(30deg)'); } catch (x) { e = x.name; }
        e
    `, root)
    s, _ := r.(string)
    testing.expectf(t, s == "SyntaxError", "string não-matrix lança SyntaxError; veio %q", s)
}

@(test)
dommatrix_translate_e_scale_com_oraculo_de_ponto :: proc(t: ^testing.T) {
    root := dm_dom(); defer dom.free_tree(root)
    // ORÁCULO INDEPENDENTE: escala 2× e depois translada (10,20) — no espaço
    // ESCALADO, porque translate() pós-multiplica. Logo o ponto (1,1) vai para
    // (2*(1+10), 2*(1+20)) = (22, 42). Convenção espelhada daria (12, 22).
    r := run_with_dom(`
        var m = new DOMMatrix().scale(2).translate(10, 20);
        var p = m.transformPoint({x: 1, y: 1});
        p.x + ',' + p.y + '|' + m.e + ',' + m.f
    `, root)
    s, _ := r.(string)
    testing.expectf(t, s == "22,42|20,40", "scale(2).translate(10,20) sobre (1,1); veio %q", s)
}

@(test)
dommatrix_scale_com_um_argumento_e_uniforme :: proc(t: ^testing.T) {
    // scale(2) tem de escalar Y também (a spec copia sx em sy). Escalar só X é
    // um erro visualmente sutil — o tipo que passa despercebido.
    root := dm_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var m = new DOMMatrix().scale(2);
        m.a === 2 && m.d === 2
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "scale(2) é uniforme em X e Y")
}

@(test)
dommatrix_rotate_usa_GRAUS :: proc(t: ^testing.T) {
    // ⚠️ graus, não radianos: rotate(90) leva (1,0) em (0,1). Com radianos daria
    // um número perfeitamente plausível e errado.
    root := dm_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var p = new DOMMatrix().rotate(90).transformPoint({x: 1, y: 0});
        Math.abs(p.x) < 1e-9 && Math.abs(p.y - 1) < 1e-9
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "rotate(90) roda 90 GRAUS")
}

@(test)
dommatrix_multiply_nao_muta_e_self_muta :: proc(t: ^testing.T) {
    root := dm_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var a = new DOMMatrix().translate(10, 0);
        var b = new DOMMatrix().translate(5, 0);
        var c = a.multiply(b);
        var antes = a.e;
        a.multiplySelf(b);
        c.e === 15 && antes === 10 && a.e === 15
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "multiply devolve nova; multiplySelf muta o receptor")
}

@(test)
dommatrix_inverse_desfaz :: proc(t: ^testing.T) {
    root := dm_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var m = new DOMMatrix().translate(10, 20).scale(2);
        var p = m.multiply(m.inverse()).transformPoint({x: 7, y: 9});
        Math.abs(p.x - 7) < 1e-9 && Math.abs(p.y - 9) < 1e-9 &&
        m.multiply(m.inverse()).isIdentity === true
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "M · M⁻¹ é a identidade e devolve o ponto intacto")
}

@(test)
dommatrix_inverse_singular_da_NaN :: proc(t: ^testing.T) {
    // Degradação HONESTA: matriz singular não tem inversa. Devolver identidade
    // seria um erro invisível.
    root := dm_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var m = new DOMMatrix().scale(0);
        isNaN(m.inverse().a)
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "inversa de matriz singular é NaN, não identidade silenciosa")
}

@(test)
dommatrix_readonly_nao_muta :: proc(t: ^testing.T) {
    root := dm_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var m = new DOMMatrixReadOnly('matrix(1,0,0,1,3,4)');
        m.e = 99;                                  // ignorado
        var semSelf = typeof m.translateSelf === 'undefined';
        m.e === 3 && semSelf && m.translate(1,1).e === 4
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "ReadOnly ignora escrita, não expõe *Self e ainda compõe")
}

@(test)
dommatrix_tostring_e_alias_legado :: proc(t: ^testing.T) {
    root := dm_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var m = new DOMMatrix('matrix(1,0,0,1,5,6)');
        var s = m.toString();
        (s.indexOf('matrix(') === 0) && (s.indexOf('5') > 0) &&
        (typeof WebKitCSSMatrix === 'function') &&
        (new WebKitCSSMatrix('matrix(2,0,0,2,0,0)').a === 2)
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "toString devolve matrix(...) e WebKitCSSMatrix é o alias")
}

@(test)
canvas_gettransform_devolve_dommatrix :: proc(t: ^testing.T) {
    // O produtor canônico de DOMMatrix no lado do DOM, e o ciclo completo
    // setTransform(getTransform()).
    root := dm_dom(); defer dom.free_tree(root)
    r := run_with_dom(`
        var cv = document.createElement('canvas');
        var ctx = cv.getContext('2d');
        ctx.setTransform(2, 0, 0, 3, 10, 20);
        var m = ctx.getTransform();
        var ok1 = m.a === 2 && m.d === 3 && m.e === 10 && m.f === 20;
        ctx.resetTransform();
        ctx.setTransform(m);                 // aceita a matriz de volta
        var m2 = ctx.getTransform();
        ok1 && m2.a === 2 && m2.f === 20
    `, root)
    ok, _ := r.(bool)
    testing.expect(t, ok, "ctx.getTransform() dá DOMMatrix e setTransform aceita ela de volta")
}
