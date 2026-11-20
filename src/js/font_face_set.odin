package js

// `document.fonts` (CSS Font Loading, FontFaceSet).
//
// Entrou pelo github.com: a home faz `await document.fonts.ready` antes de
// cortar o título (SplitText) e montar a timeline do GSAP que REVELA o bloco
// principal (servido com `style="opacity:0"`). Sem `document.fonts`, o await
// lançava TypeError dentro de uma função async, a promise morria em silêncio e
// o meio da página ficava em branco para sempre.
//
// ⚠️ DEGRADAÇÃO HONESTA: as @font-face são baixadas e trocadas pela camada de
// UI (fontface_poll), que o motor JS não enxerga. Aqui o conjunto se declara
// "loaded" e `ready` já nasce resolvida: o código que espera as fontes segue
// em frente (o que importa: ele RODA), mas pode medir texto com a fonte de
// fallback; e `loadingdone` nunca dispara. Conjunto vazio: `size` 0, `check`
// true (nada pendente), `load` resolve com [].

install_font_face_set :: proc(vm: ^Interp, doc: ^Object) {
    fs := new_object(vm)
    fs.props["#class"] = "FontFaceSet"
    fs.props["status"] = own_str(vm, "loaded")
    fs.props["size"] = f64(0)
    fs.props["onloading"] = JS_Null{}
    fs.props["onloadingdone"] = JS_Null{}
    fs.props["onloadingerror"] = JS_Null{}
    metodos := [?]struct{ name: string, fn: Native_Fn }{
        {"check", ffs_check},
        {"load", ffs_load},
        {"has", ffs_false},
        {"delete", ffs_false},
        {"add", ffs_self},
        {"clear", ffs_undefined},
        {"forEach", ffs_undefined},
        {"addEventListener", ffs_undefined},
        {"removeEventListener", ffs_undefined},
        {"dispatchEvent", ffs_true},
    }
    for m in metodos {
        f := mk_native(vm, m.fn)
        f.bound = fs
        fs.props[m.name] = f
        mark_non_enumerable(fs, m.name)
    }
    ready := promise_new(vm)
    promise_resolve_with(vm, ready, fs) // spec: `ready` resolve com o próprio FontFaceSet
    fs.props["ready"] = ready
    doc.props["fonts"] = fs
}

@(private = "file")
ffs_check :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return true }

@(private = "file")
ffs_true :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return true }

@(private = "file")
ffs_false :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return false }

@(private = "file")
ffs_undefined :: proc(vm: ^Interp, this: Value, a: []Value) -> Value { return nil }

@(private = "file")
ffs_self :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    if o, ok := vm.native_bound.(^Object); ok do return o
    return this
}

// load(font) → Promise<FontFace[]>: nada a carregar do lado do JS.
@(private = "file")
ffs_load :: proc(vm: ^Interp, this: Value, a: []Value) -> Value {
    p := promise_new(vm)
    promise_resolve_with(vm, p, new_array(vm))
    return p
}
