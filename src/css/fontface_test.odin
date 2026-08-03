package css

// M224 — parsing de `@font-face`. Antes a at-rule inteira caía no skip_at_rule.

import "core:testing"

@(private = "file")
one :: proc(css: string) -> (Font_Face, bool) {
    faces := parse_faces_only(css)
    if len(faces) == 0 { free_faces(&faces); return {}, false }
    return faces[0], true
}

@(test)
test_m224_face_basica :: proc(t: ^testing.T) {
    faces := parse_faces_only(`@font-face { font-family: "Inter"; src: url(inter.ttf) format("truetype") }`)
    defer free_faces(&faces)
    testing.expect(t, len(faces) == 1, "uma face")
    if len(faces) == 0 do return
    f := faces[0]
    testing.expectf(t, f.family == "inter", "família em MINÚSCULAS (casamento é case-insensitive); veio %q", f.family)
    testing.expect(t, f.weight == 400 && !f.italic, "defaults: 400, não-itálico")
    testing.expect(t, len(f.srcs) == 1, "uma src")
    testing.expectf(t, f.srcs[0].url == "inter.ttf", "url; veio %q", f.srcs[0].url)
    testing.expectf(t, f.srcs[0].hint == "truetype", "format(); veio %q", f.srcs[0].hint)
}

@(test)
test_m224_peso_e_estilo :: proc(t: ^testing.T) {
    f, _ := one(`@font-face{font-family:X;src:url(a.ttf);font-weight:700;font-style:italic}`)
    testing.expect(t, f.weight == 700 && f.italic, "700 + itálico")
    f2, _ := one(`@font-face{font-family:X;src:url(a.ttf);font-weight:bold}`)
    testing.expect(t, f2.weight == 700, "palavra-chave bold")
    // fonte VARIÁVEL declara faixa: guardamos o 1º (não temos eixos de variação)
    f3, _ := one(`@font-face{font-family:X;src:url(a.ttf);font-weight:100 900}`)
    testing.expectf(t, f3.weight == 100, "faixa `100 900` guarda o 1º; veio %d", f3.weight)
}

@(test)
test_m224_lista_de_src_com_formatos :: proc(t: ^testing.T) {
    // a forma canônica de site real: vários formatos, do mais novo p/ o mais velho
    f, ok := one(`@font-face{font-family:X;src:url(a.woff2) format("woff2"),
                                              url(a.woff)  format("woff"),
                                              url(a.ttf)   format("truetype")}`)
    testing.expect(t, ok && len(f.srcs) == 3, "três origens")
    if len(f.srcs) < 3 do return
    testing.expect(t, f.srcs[0].hint == "woff2" && f.srcs[2].hint == "truetype", "hints na ordem")
    testing.expect(t, f.srcs[2].url == "a.ttf", "url da 3ª")
}

@(test)
test_m224_local_e_aspas :: proc(t: ^testing.T) {
    // `local()` é descartado (não enumeramos fontes instaladas), mas não pode
    // fazer a face inteira cair quando há um url() junto.
    f, ok := one(`@font-face{font-family:'Minha Fonte';src:local("Minha Fonte"), url('a.ttf')}`)
    testing.expect(t, ok, "face com local()+url() vale")
    testing.expectf(t, f.family == "minha fonte", "aspas simples removidas; veio %q", f.family)
    testing.expect(t, len(f.srcs) == 1 && f.srcs[0].url == "a.ttf", "só o url() entra")
}

@(test)
test_m224_face_invalida_e_descartada :: proc(t: ^testing.T) {
    a := parse_faces_only(`@font-face{src:url(a.ttf)}`) // sem font-family
    defer free_faces(&a)
    testing.expect(t, len(a) == 0, "sem font-family ⇒ descarta")
    b := parse_faces_only(`@font-face{font-family:X}`) // sem src
    defer free_faces(&b)
    testing.expect(t, len(b) == 0, "sem src ⇒ descarta")
    c := parse_faces_only(`@font-face{font-family:X;src:local("Y")}`) // só local()
    defer free_faces(&c)
    testing.expect(t, len(c) == 0, "só local() ⇒ nada utilizável")
}

@(test)
test_m224_varias_faces_e_convivencia :: proc(t: ^testing.T) {
    css := `@font-face{font-family:A;src:url(a.ttf)}
            body { color: red }
            @font-face{font-family:A;src:url(ab.ttf);font-weight:700}
            @media (min-width:1px){ .x{color:blue} }`
    faces := parse_faces_only(css)
    defer free_faces(&faces)
    testing.expectf(t, len(faces) == 2, "duas faces da mesma família; veio %d", len(faces))
    // e o parse normal continua colhendo as REGRAS, sem se atrapalhar
    rules, _ := parse(css)
    defer free_rules(&rules)
    n := 0
    for r in rules do if _, ok := r.decls["color"]; ok do n += 1
    testing.expectf(t, n == 2, "as regras normais continuam; veio %d", n)
}

@(test)
test_m224_parse_normal_nao_vaza_face_como_regra :: proc(t: ^testing.T) {
    // O corpo do @font-face NÃO pode virar uma regra (era o risco de trocar o
    // skip_at_rule por um ramo próprio).
    rules, _ := parse(`@font-face{font-family:X;src:url(a.ttf)} div{color:red}`)
    defer free_rules(&rules)
    testing.expectf(t, len(rules) == 1, "só a regra do div; veio %d", len(rules))
    for r in rules {
        _, tem := r.decls["src"]
        testing.expect(t, !tem, "nenhuma regra pode carregar `src`")
    }
}
