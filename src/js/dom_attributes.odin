package js

// `el.attributes` (NamedNodeMap) e os nós Attr que ela devolve.
//
// POR QUE EXISTE: `attributes` estava DECLARADO como accessor em Element.prototype
// (install_dom_props) mas o hook do elemento nunca o servia — ou seja, undefined em
// silêncio. O jQuery 1.9.1 faz, no teste de suporte que roda ao carregar:
//     div.setAttribute("onsubmit", "t")
//     support.submitBubbles = "onsubmit" in window || div.attributes["onsubmit"].expando === false
// → "Cannot read properties of undefined (reading 'onsubmit')", o jQuery inteiro morre
// antes de definir `window.jQuery`, e TUDO o que vem depois cai em cascata ("Bootstrap's
// JavaScript requires jQuery", "jQuery is not defined", "$ is not defined"). Era o
// books.toscrape.com (django-oscar), e é o mesmo jQuery 1.9 de meia web legada.
//
// COMO FUNCIONA: mesma forma das coleções vivas de dom_collection.odin. A NamedNodeMap
// é UM objeto host por elemento (cacheado no wrapper, então `el.attributes ===
// el.attributes`) cujo hook lê `node.attrs` NA HORA — viva por construção, sem cópia.
// Ela é ZERADA por attrs_forget (chamado de forget_wrapper) quando o nó morre.
//
// Os Attr NÃO guardam o nó: guardam o WRAPPER do dono em `ownerElement` e leem o nó por
// `wrapper.host` a cada acesso. Como forget_wrapper zera esse host, um Attr guardado
// pela página depois que o elemento morreu vira inerte (value "") em vez de ler memória
// reciclada — sem precisar rastrear cada Attr criado.
//
// DEGRADAÇÕES CONHECIDAS (nomeadas em vez de escondidas):
//  1. Cada leitura cria um Attr NOVO: `el.attributes[0] === el.attributes[0]` é false
//     (no navegador é true). O `value` é vivo nos dois sentidos, então só a IDENTIDADE
//     difere.
//  2. name/value/… são props PRÓPRIAS (não-enumeráveis) do Attr, não accessors de
//     Attr.prototype.
//  3. Sem namespace: namespaceURI/prefix são sempre null e localName = name.
//  4. `for (k in el.attributes)` / Object.keys não enumeram os índices (mesma razão
//     da degradação 1 de dom_collection.odin).

import "core:strings"
import dom "../dom"

ATTRS_KEY :: "__namednodemap_attributes"

dom_named_node_map :: proc(vm: ^Interp, owner: ^Object, node: ^dom.Node) -> ^Object {
    if m, ok := owner.props[ATTRS_KEY].(^Object); ok do return m
    m := new_object(vm)
    m.host  = rawptr(node) // convenção dos wrappers: host é sempre um ^dom.Node
    m.get   = nnm_get
    m.geti  = nnm_geti
    m.proto = vm.dom_namednodemap_proto
    owner.props[ATTRS_KEY] = m
    mark_non_enumerable(owner, ATTRS_KEY) // fora de Object.keys(el)
    // o wrapper do dono vai junto: é dele que saem os Attr (ownerElement)
    m.props["__owner"] = owner
    mark_non_enumerable(m, "__owner")
    return m
}

// Par de coll_forget: o nó vai ser liberado, a NamedNodeMap guardada pela página vira
// inerte (length 0).
attrs_forget :: proc(vm: ^Interp, owner: ^Object) {
    if m, ok := owner.props[ATTRS_KEY].(^Object); ok do m.host = nil
}

@(private = "file")
nnm_owner :: proc(m: ^Object) -> ^Object {
    w, _ := m.props["__owner"].(^Object)
    return w
}

// Nome do i-ésimo atributo em ORDEM DE DOCUMENTO (a mesma de getAttributeNames).
@(private = "file")
nnm_name_at :: proc(node: ^dom.Node, i: int) -> (string, bool) {
    if node == nil || i < 0 || i >= len(node.attrs) do return "", false
    names := make([dynamic]string, context.temp_allocator)
    dom.attr_names(node, &names)
    if i >= len(names) do return "", false
    return names[i], true
}

// Nome qualificado como getNamedItem casa: exato, senão em minúsculas (elemento HTML
// num documento HTML — a spec rebaixa a caixa do argumento).
@(private = "file")
nnm_find :: proc(node: ^dom.Node, name: string) -> (string, bool) {
    if node == nil do return "", false
    if _, has := node.attrs[name]; has do return name, true
    low := strings.to_lower(name, context.temp_allocator)
    for k in node.attrs do if k == low do return k, true
    return "", false
}

nnm_geti :: proc(vm: ^Interp, o: ^Object, idx: int) -> (Value, bool) {
    node := cast(^dom.Node) o.host
    name, ok := nnm_name_at(node, idx)
    if !ok do return nil, true // fora do intervalo = undefined (não cai no proto)
    return mk_attr(vm, nnm_owner(o), name), true
}

nnm_get :: proc(vm: ^Interp, o: ^Object, name: string) -> (Value, bool) {
    node := cast(^dom.Node) o.host
    if name == "length" do return f64(node == nil ? 0 : len(node.attrs)), true
    if is_index_name(name) {
        i := 0
        for c in transmute([]u8)name do i = i * 10 + int(c - '0')
        return nnm_geti(vm, o, i)
    }
    if name == "__owner" || node == nil do return nil, false
    // Propriedade NOMEADA (`attributes["onsubmit"]`, `attributes.id`): NamedNodeMap não
    // tem [LegacyOverrideBuiltIns], então o que existe na cadeia de protótipo (item,
    // length, toString, constructor…) VENCE o atributo de mesmo nome.
    for p := o.proto; p != nil; p = p.proto {
        if _, has := p.props[name]; has do return nil, false
        if p.getters != nil { if _, has := p.getters[name]; has do return nil, false }
    }
    if k, found := nnm_find(node, name); found do return mk_attr(vm, nnm_owner(o), k), true
    return nil, false
}

// Índice de array canônico com cabe-em-int (mesma regra do canonical_index de
// dom_collection.odin: sem zero à esquerda, só dígitos).
@(private = "file")
is_index_name :: proc(name: string) -> bool {
    if len(name) == 0 || len(name) > 9 do return false
    if name[0] == '0' && len(name) > 1 do return false
    for i in 0 ..< len(name) do if name[i] < '0' || name[i] > '9' do return false
    return true
}

// ── Attr ────────────────────────────────────────────────────────────────────

mk_attr :: proc(vm: ^Interp, owner: ^Object, name: string) -> ^Object {
    a := new_object(vm)
    a.proto = vm.dom_attr_proto
    a.get = attr_get
    a.set = attr_set
    put :: proc(o: ^Object, k: string, v: Value) {
        oput(o, k, v)
        mark_non_enumerable(o, k)
    }
    n := own_str(vm, name)
    put(a, "name", n)
    put(a, "localName", n)
    put(a, "nodeName", n)
    put(a, "nodeType", f64(2)) // ATTRIBUTE_NODE
    put(a, "namespaceURI", JS_Null{})
    put(a, "prefix", JS_Null{})
    put(a, "specified", true)
    put(a, "ownerElement", owner != nil ? Value(owner) : Value(JS_Null{}))
    return a
}

@(private = "file")
attr_node :: proc(a: ^Object) -> (^dom.Node, string) {
    w, wok := a.props["ownerElement"].(^Object)
    name, _ := a.props["name"].(string)
    if !wok || w.host == nil do return nil, name
    return cast(^dom.Node) w.host, name
}

@(private = "file")
attr_get :: proc(vm: ^Interp, a: ^Object, prop: string) -> (Value, bool) {
    switch prop {
    case "value", "nodeValue", "textContent":
        node, name := attr_node(a)
        if node == nil {
            if v, has := a.props["__detached_value"]; has do return v, true
            return "", true
        }
        return own_str(vm, node.attrs[name]), true
    }
    return nil, false
}

@(private = "file")
attr_set :: proc(vm: ^Interp, a: ^Object, prop: string, val: Value) -> bool {
    switch prop {
    case "value", "nodeValue", "textContent":
        // pelo setAttribute do dono: mesmo funil (MutationObserver, restyle)
        node, name := attr_node(a)
        if node != nil {
            w, _ := a.props["ownerElement"].(^Object)
            call_owner_method(vm, w, "setAttribute", []Value{own_str(vm, name), val})
        }
        return true
    }
    return false
}

// ── métodos de NamedNodeMap.prototype ───────────────────────────────────────

@(private = "file")
nnm_this :: proc(this: Value) -> (^Object, ^dom.Node) {
    o, ok := this.(^Object)
    if !ok || o.get != nnm_get do return nil, nil
    return o, cast(^dom.Node) o.host
}

@(private = "file")
arg_text :: proc(args: []Value, i: int) -> string {
    sb := strings.builder_make(context.temp_allocator)
    to_text(&sb, arg(args, i))
    return strings.to_string(sb)
}

@(private = "file")
native_nnm_item :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, node := nnm_this(this)
    if o == nil do return JS_Null{}
    name, ok := nnm_name_at(node, as_int(arg(args, 0)))
    if !ok do return JS_Null{} // spec: item() fora do intervalo é null
    return mk_attr(vm, nnm_owner(o), name)
}

@(private = "file")
native_nnm_get_named_item :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, node := nnm_this(this)
    if o == nil do return JS_Null{}
    k, found := nnm_find(node, arg_text(args, 0))
    if !found do return JS_Null{}
    return mk_attr(vm, nnm_owner(o), k)
}

// removeNamedItem / setNamedItem passam pelos MESMOS métodos do elemento
// (removeAttribute/setAttribute) — é lá que estão MutationObserver e o restyle.
@(private = "file")
call_owner_method :: proc(vm: ^Interp, owner: ^Object, method: string, args: []Value) {
    if fn, ok := vm.dom_element_methods[method]; ok do call_function(vm, fn, owner, args)
}

@(private = "file")
native_nnm_remove_named_item :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, node := nnm_this(this)
    if o == nil do return JS_Null{}
    k, found := nnm_find(node, arg_text(args, 0))
    if !found {
        throw_type_error(vm, "Failed to execute 'removeNamedItem' on 'NamedNodeMap': No item with this name was found.")
        return nil
    }
    owner := nnm_owner(o)
    old := mk_attr(vm, nil, k)
    oput(old, "__detached_value", own_str(vm, node.attrs[k])) // Attr solto guarda o valor
    mark_non_enumerable(old, "__detached_value")
    call_owner_method(vm, owner, "removeAttribute", []Value{own_str(vm, k)})
    return old
}

@(private = "file")
native_nnm_set_named_item :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o, node := nnm_this(this)
    if o == nil do return JS_Null{}
    a, ok := arg(args, 0).(^Object)
    if !ok || a.proto != vm.dom_attr_proto {
        throw_type_error(vm, "Failed to execute 'setNamedItem' on 'NamedNodeMap': parameter 1 is not of type 'Attr'.")
        return nil
    }
    name, _ := a.props["name"].(string)
    val := get_member(vm, a, "value")
    call_owner_method(vm, nnm_owner(o), "setAttribute", []Value{own_str(vm, name), val})
    return JS_Null{}
}

install_attr_protos :: proc(vm: ^Interp, nnm, attr: ^Object) {
    vm.dom_namednodemap_proto = nnm
    vm.dom_attr_proto = attr
    put :: proc(o: ^Object, k: string, v: Value) {
        oput(o, k, v)
        mark_non_enumerable(o, k)
    }
    reg :: proc(vm: ^Interp, o: ^Object, name: string, fn: Native_Fn) {
        f := mk_native(vm, fn)
        f.name = name
        put(o, name, f)
    }
    reg(vm, nnm, "item", native_nnm_item)
    reg(vm, nnm, "getNamedItem", native_nnm_get_named_item)
    reg(vm, nnm, "getNamedItemNS", native_nnm_get_named_item)
    reg(vm, nnm, "removeNamedItem", native_nnm_remove_named_item)
    reg(vm, nnm, "setNamedItem", native_nnm_set_named_item)
    reg(vm, nnm, "setNamedItemNS", native_nnm_set_named_item)
    // NamedNodeMap tem getter indexado ⇒ WebIDL dá @@iterator = Array.prototype.values
    // (genérico por length+índice): `[...el.attributes]`, `Array.from`, for-of.
    if fn, ok := vm.array_methods["values"]; ok do put(nnm, vm.sym_iterator_key, fn)
}
