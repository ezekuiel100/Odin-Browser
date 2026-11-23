package js

// FORMULÁRIOS e NAVEGAÇÃO PEDIDA PELA PÁGINA.
//
// O que faltava: até aqui o motor não sabia enviar um formulário. Não havia
// `document.forms`, nem `form.elements`, nem `submit()`/`requestSubmit()`, e o
// evento `submit` só rodava handlers, sem efeito nenhum. Também não havia navegação
// iniciada por JS: `location.assign/replace` eram no-op e `location.href = x` caía
// numa prop solta. O caso que motivou isto foi o reddit: ele serve um desafio de JS
// (`js_challenge`) que calcula um `solution`, grava num <form hidden method=GET> e
// chama `requestSubmit()`. Sem o envio, a aba ficava PARA SEMPRE no logo do desafio.
//
// O modelo é um canal VM → host: a página só PEDE a navegação gravando
// `vm.nav_request` (URL absoluta). Quem navega é o host (ui), que consome o pedido
// fora do JS, por `vm_take_nav_request`. O JS que estiver rodando continua até o fim,
// como no navegador, onde a navegação também é assíncrona. Se houver mais de um
// pedido, vale o último.
//
// DEGRADAÇÕES (ditas aqui, não escondidas):
//  1. Só o método GET envia. POST (e `enctype=multipart`) precisaria de corpo na
//     requisição de navegação, que o fetch da aba ainda não carrega. O envio POST
//     é RECUSADO com um aviso no console, em vez de virar um GET que o servidor não
//     espera.
//  2. `target` é ignorado: o envio vai sempre para a MESMA aba.
//  3. Sem validação de constraints: `checkValidity()` é sempre true.
//  4. `document.forms` e `form.elements` são INSTANTÂNEOS (um ^Array novo por
//     leitura, com item/namedItem e propriedades nomeadas), não coleções vivas.
//     O uso real é ler e indexar na hora.
//  5. `location.reload()` segue no-op DE PROPÓSITO. Sites chamam reload como
//     recuperação de erro ("chunk falhou, recarrega"), e este motor ainda tem erros
//     de JS que o Chrome não tem: obedecer viraria um laço de recarga infinito.
//  6. Mudança só de fragmento (`location.hash = "x"`, `href = "#y"`) não recarrega,
//     mas também não atualiza `location.hash` nem dispara `hashchange`.

import "core:strings"
import dom "../dom"
import net "../net"

// ── canal de navegação ──────────────────────────────────────────────────────

// O host consome o pedido pendente (e o zera). A string pertence ao vm e vive até
// o vm_destroy, então quem guardar além disso precisa clonar.
vm_take_nav_request :: proc(vm: ^Interp) -> (url: string, replace: bool, ok: bool) {
    if vm == nil || vm.nav_request == "" do return "", false, false
    url, replace = vm.nav_request, vm.nav_replace
    vm.nav_request, vm.nav_replace = "", false
    return url, replace, true
}

// URL sem o fragmento (`#...`).
@(private = "file")
strip_fragment :: proc(u: string) -> string {
    if h := strings.index_byte(u, '#'); h >= 0 do return u[:h]
    return u
}

// URL sem query nem fragmento.
@(private = "file")
strip_query :: proc(u: string) -> string {
    s := strip_fragment(u)
    if q := strings.index_byte(s, '?'); q >= 0 do return s[:q]
    return s
}

// Resolve `raw` contra a página e registra o pedido. Devolve false quando não há
// navegação de documento (javascript:, mailto:, ou só fragmento).
js_request_navigation :: proc(vm: ^Interp, raw: string, replace := false) -> bool {
    href := strings.trim_space(raw)
    base := vm.base_url
    resolved: string
    switch {
    case strings.has_prefix(href, "#"):
        return false // só fragmento: mesmo documento (degradação 6)
    case strings.has_prefix(href, "?"):
        // o net.resolve_url simplificado juntaria "?q" ao DIRETÓRIO, mas o certo é
        // trocar só a query do caminho atual
        resolved = strings.concatenate({strip_query(base), href}, context.temp_allocator)
    case href == "":
        resolved = strip_fragment(base) // `location.href = ""` recarrega o documento
    case:
        resolved = net.resolve_url(base, href, context.temp_allocator)
    }
    if resolved == "" do return false // javascript:/mailto:/tel:
    // Mesmo documento com fragmento diferente: não recarrega (degradação 6).
    if strings.contains(resolved, "#") && strip_fragment(resolved) == strip_fragment(base) do return false
    vm.nav_request = own_str_raw(vm, resolved)
    vm.nav_replace = replace
    return true
}

// ToString de um valor que vai virar URL (`location.href = new URL(...)` usa o
// toString do objeto).
js_value_to_string :: proc(vm: ^Interp, v: Value) -> string {
    if s, ok := v.(string); ok do return s
    if v == nil do return ""
    val := v
    if o, ook := v.(^Object); ook {
        if fn, fok := get_member(vm, o, "toString").(^Function); fok {
            r := call_function(vm, fn, o, nil)
            if vm.throwing do return ""
            if s, sok := r.(string); sok do return s
            val = r
        }
    }
    sb := strings.builder_make(context.temp_allocator)
    to_text(&sb, val)
    return strings.to_string(sb)
}

// ── location ────────────────────────────────────────────────────────────────

location_assign :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    js_request_navigation(vm, js_value_to_string(vm, arg(args, 0)))
    return nil
}

location_replace :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    js_request_navigation(vm, js_value_to_string(vm, arg(args, 0)), replace = true)
    return nil
}

// No-op DE PROPÓSITO: ver a degradação 5 no cabeçalho.
location_reload :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return nil }

// `location.href = x` e as partes que, escritas, navegam (search/pathname/hash).
// O resto fica como prop comum (é o que acontecia antes).
location_set :: proc(vm: ^Interp, o: ^Object, name: string, val: Value) -> bool {
    switch name {
    case "href":
        js_request_navigation(vm, js_value_to_string(vm, val))
        return true
    case "search", "pathname", "hash":
        v := js_value_to_string(vm, val)
        scheme, host, path, search, hash := split_url(vm.base_url)
        switch name {
        case "search":
            if v != "" && v[0] != '?' do v = strings.concatenate({"?", v}, context.temp_allocator)
            search = v
        case "pathname":
            if v == "" || v[0] != '/' do v = strings.concatenate({"/", v}, context.temp_allocator)
            path = v
        case "hash":
            return true // só fragmento (degradação 6)
        }
        _ = hash
        js_request_navigation(vm, strings.concatenate({scheme, "://", host, path, search}, context.temp_allocator))
        return true
    }
    o.props[name] = val
    return true
}

// ── form owner / controles ──────────────────────────────────────────────────

// Elementos "listed" (spec): os que aparecem em form.elements. <input type=image>
// é a exceção histórica (spec): é listed, mas form.elements não o inclui.
@(private = "file")
is_listed_control :: proc(n: ^dom.Node) -> bool {
    if n == nil || n.kind != .Element do return false
    switch n.tag {
    case "button", "fieldset", "object", "output", "select", "textarea": return true
    case "input":
        t, _ := n.attrs["type"]
        return !strings.equal_fold(t, "image")
    }
    return false
}

@(private = "file")
doc_root_of :: proc(n: ^dom.Node) -> ^dom.Node {
    r := n
    for r.parent != nil do r = r.parent
    return r
}

@(private = "file")
find_by_id :: proc(n: ^dom.Node, id: string) -> ^dom.Node {
    if n.kind == .Element {
        if v, ok := n.attrs["id"]; ok && v == id do return n
    }
    for c in n.children {
        if dom.is_pseudo_child(c) do continue
        if r := find_by_id(c, id); r != nil do return r
    }
    return nil
}

// Form owner de um controle: o atributo `form="id"` vence (o controle pode estar
// FORA do <form>); senão, o <form> ancestral mais próximo.
form_owner :: proc(n: ^dom.Node) -> ^dom.Node {
    if n == nil do return nil
    if id, ok := n.attrs["form"]; ok {
        f := find_by_id(doc_root_of(n), id)
        if f != nil && f.tag == "form" do return f
        return nil
    }
    for a := n.parent; a != nil; a = a.parent {
        if a.kind == .Element && a.tag == "form" do return a
    }
    return nil
}

// Controles cujo owner é `form`, em ordem de árvore. Varre o DOCUMENTO inteiro
// por causa do `form="id"`.
@(private = "file")
collect_form_controls :: proc(n, form: ^dom.Node, out: ^[dynamic]^dom.Node, listed_only: bool) {
    if n.kind == .Element {
        ok := is_listed_control(n) if listed_only else (n.tag == "input" || n.tag == "button" ||
              n.tag == "select" || n.tag == "textarea" || n.tag == "object")
        if ok && form_owner(n) == form do append(out, n)
    }
    for c in n.children {
        if dom.is_pseudo_child(c) do continue
        collect_form_controls(c, form, out, listed_only)
    }
}

// Coleção instantânea com cara de HTMLCollection: itens indexados, `item`,
// `namedItem` e as propriedades nomeadas (id e name), como `form.elements.solution`.
@(private = "file")
named_snapshot :: proc(vm: ^Interp, nodes: []^dom.Node) -> ^Array {
    arr := new_array(vm)
    for n in nodes do append(&arr.items, wrap_element(vm, n))
    // `item`/`namedItem` PRÓPRIOS: os do HTMLCollection.prototype leem o Coll_State,
    // que um ^Array não tem. Nomeadas: id antes de name, o 1º de cada vence.
    array_put(arr, "item", mk_native(vm, snapshot_item))
    array_put(arr, "namedItem", mk_native(vm, snapshot_named_item))
    for key in ([2]string{"id", "name"}) {
        for n, i in nodes {
            v, ok := n.attrs[key]
            if !ok || v == "" || v == "length" || v == "item" || v == "namedItem" do continue
            owned := own_str_raw(vm, v)
            if _, dup := arr.props[owned]; dup do continue
            array_put(arr, owned, arr.items[i])
        }
    }
    return arr
}

@(private = "file")
snapshot_item :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a, ok := this.(^Array)
    if !ok do return JS_Null{}
    i := as_int(arg(args, 0))
    if i < 0 || i >= len(a.items) do return JS_Null{}
    return a.items[i]
}

@(private = "file")
snapshot_named_item :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    a, ok := this.(^Array)
    if !ok do return JS_Null{}
    key := js_value_to_string(vm, arg(args, 0))
    for attr in ([2]string{"id", "name"}) {
        for it in a.items {
            n := node_of(it)
            if n == nil do continue
            if v, has := n.attrs[attr]; has && v == key do return it
        }
    }
    return JS_Null{}
}

@(private = "file")
collect_forms :: proc(n: ^dom.Node, out: ^[dynamic]^dom.Node) {
    if n.kind == .Element && n.tag == "form" do append(out, n)
    for c in n.children {
        if dom.is_pseudo_child(c) do continue
        collect_forms(c, out)
    }
}

// document.forms
doc_forms :: proc(vm: ^Interp, root: ^dom.Node) -> Value {
    forms := make([dynamic]^dom.Node, context.temp_allocator)
    collect_forms(root, &forms)
    return named_snapshot(vm, forms[:])
}

// form.elements / form.action / form.method / form.enctype / control.form
form_prop_get :: proc(vm: ^Interp, node: ^dom.Node, name: string) -> (Value, bool) {
    switch name {
    case "form":
        if node.tag == "form" do return nil, false
        if !is_listed_control(node) && node.tag != "input" do return nil, false
        if f := form_owner(node); f != nil do return wrap_element(vm, f), true
        return JS_Null{}, true
    }
    if node.tag != "form" do return nil, false
    switch name {
    case "elements":
        ctrls := make([dynamic]^dom.Node, context.temp_allocator)
        collect_form_controls(doc_root_of(node), node, &ctrls, true)
        return named_snapshot(vm, ctrls[:]), true
    case "action":
        // spec: a URL RESOLVIDA; sem atributo (ou vazio) é a URL do documento
        a, _ := node.attrs["action"]
        if strings.trim_space(a) == "" do return own_str(vm, vm.base_url), true
        if r := net.resolve_url(vm.base_url, a, context.temp_allocator); r != "" do return own_str(vm, r), true
        return own_str(vm, a), true
    case "method":
        return own_str(vm, form_method(node, nil)), true
    case "enctype", "encoding":
        e, _ := node.attrs["enctype"]
        e = strings.to_lower(strings.trim_space(e), context.temp_allocator)
        if e != "multipart/form-data" && e != "text/plain" do e = "application/x-www-form-urlencoded"
        return own_str(vm, e), true
    }
    return nil, false
}

// Método efetivo (minúsculo): `formmethod` do botão que enviou vence o do <form>.
// Valor inválido = "get" (spec: estado default do atributo enumerado).
@(private = "file")
form_method :: proc(form, submitter: ^dom.Node) -> string {
    m := ""
    if submitter != nil { if v, ok := submitter.attrs["formmethod"]; ok do m = v }
    if m == "" { if v, ok := form.attrs["method"]; ok do m = v }
    m = strings.trim_space(m)
    if strings.equal_fold(m, "post") do return "post"
    if strings.equal_fold(m, "dialog") do return "dialog"
    return "get"
}

// ── conjunto de dados + codificação ─────────────────────────────────────────

@(private = "file")
Form_Entry :: struct { name, value: string }

@(private = "file")
attr_on :: proc(n: ^dom.Node, key: string) -> bool {
    v, ok := n.attrs[key]
    return ok && v != "false"
}

// Desabilitado por si OU por um <fieldset disabled> ancestral (spec: salvo se o
// controle estiver dentro do 1º <legend> desse fieldset — essa exceção não é feita).
@(private = "file")
is_disabled :: proc(n: ^dom.Node) -> bool {
    if attr_on(n, "disabled") do return true
    for a := n.parent; a != nil; a = a.parent {
        if a.kind == .Element && a.tag == "fieldset" && attr_on(a, "disabled") do return true
    }
    return false
}

// Lista de entradas do formulário (HTML §4.10.21.4, "constructing the entry list"),
// em ordem de árvore. Strings em temp_allocator.
@(private = "file")
form_entries :: proc(form, submitter: ^dom.Node) -> [dynamic]Form_Entry {
    out := make([dynamic]Form_Entry, context.temp_allocator)
    ctrls := make([dynamic]^dom.Node, context.temp_allocator)
    collect_form_controls(doc_root_of(form), form, &ctrls, false)
    for c in ctrls {
        if is_disabled(c) do continue
        // dentro de <datalist>: nunca envia
        in_datalist := false
        for a := c.parent; a != nil; a = a.parent do if a.kind == .Element && a.tag == "datalist" { in_datalist = true; break }
        if in_datalist do continue
        if c.tag == "object" do continue
        t := strings.to_lower(c.attrs["type"] or_else "", context.temp_allocator)
        name := c.attrs["name"] or_else ""
        // botões só contam quando SÃO o que enviou o formulário
        is_button := c.tag == "button" || (c.tag == "input" && (t == "submit" || t == "button" || t == "reset" || t == "image"))
        if is_button {
            if c != submitter do continue
            if c.tag == "button" && (t == "button" || t == "reset") do continue
            if t == "image" do continue // name.x/name.y: sem coordenada de clique aqui
        }
        if name == "" do continue
        switch c.tag {
        case "select":
            opts := make([dynamic]^dom.Node, context.temp_allocator)
            option_nodes(c, &opts)
            if attr_on(c, "multiple") {
                for o in opts {
                    if attr_on(o, "selected") && !attr_on(o, "disabled") {
                        append(&out, Form_Entry{name, option_value_str(o)})
                    }
                }
            } else if len(opts) > 0 {
                idx := select_index(c)
                if idx >= 0 && idx < len(opts) && !attr_on(opts[idx], "disabled") {
                    append(&out, Form_Entry{name, option_value_str(opts[idx])})
                }
            }
        case "textarea":
            v, has := c.attrs["value"] // onde `el.value = x` aterra neste motor
            if !has {
                sb := strings.builder_make(context.temp_allocator)
                dom.text_content(c, &sb)
                v = strings.to_string(sb)
            }
            append(&out, Form_Entry{name, v})
        case:
            switch t {
            case "checkbox", "radio":
                if !attr_on(c, "checked") do continue
                append(&out, Form_Entry{name, c.attrs["value"] or_else "on"})
            case "file":
                append(&out, Form_Entry{name, ""}) // sem arquivo escolhido: nome vazio
            case:
                append(&out, Form_Entry{name, c.attrs["value"] or_else ""})
            }
        }
    }
    return out
}

// application/x-www-form-urlencoded (URL Standard): espaço vira '+', fica cru só
// `*-._` e alfanumérico, todo o resto vira %XX sobre os bytes UTF-8. Quebras de linha
// viram CRLF antes (spec: "convert to a list of name-value pairs").
@(private = "file")
urlencode_into :: proc(sb: ^strings.Builder, s: string) {
    hex := "0123456789ABCDEF"
    for i := 0; i < len(s); i += 1 {
        c := s[i]
        switch {
        case c == ' ':
            strings.write_byte(sb, '+')
        case (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
             c == '*' || c == '-' || c == '.' || c == '_':
            strings.write_byte(sb, c)
        case c == '\n' && (i == 0 || s[i - 1] != '\r'):
            strings.write_string(sb, "%0D%0A")
        case c == '\r' && (i + 1 >= len(s) || s[i + 1] != '\n'):
            strings.write_string(sb, "%0D%0A")
        case:
            strings.write_byte(sb, '%')
            strings.write_byte(sb, hex[c >> 4])
            strings.write_byte(sb, hex[c & 0xF])
        }
    }
}

form_urlencoded :: proc(entries: []Form_Entry, allocator := context.temp_allocator) -> string {
    sb := strings.builder_make(allocator)
    for e, i in entries {
        if i > 0 do strings.write_byte(&sb, '&')
        urlencode_into(&sb, e.name)
        strings.write_byte(&sb, '=')
        urlencode_into(&sb, e.value)
    }
    return strings.to_string(sb)
}

// ── envio ───────────────────────────────────────────────────────────────────

// Algoritmo de envio (HTML §4.10.21.3), no recorte que este motor consegue fazer.
// from_method = true é o `form.submit()`: NÃO dispara o evento submit (spec).
// Devolve true se um pedido de navegação foi registrado.
form_submit :: proc(vm: ^Interp, form, submitter: ^dom.Node, from_method: bool) -> bool {
    if form == nil || form.tag != "form" do return false
    // desconectado do documento: não envia (spec)
    if doc_root_of(form).kind != .Document do return false
    if !from_method {
        _, prevented := dispatch_event_obj(vm, form, "submit", nil)
        if prevented do return false
        // um handler pode ter tirado o form do documento
        if doc_root_of(form).kind != .Document do return false
    }

    action := ""
    if submitter != nil { if v, ok := submitter.attrs["formaction"]; ok do action = v }
    if action == "" { if v, ok := form.attrs["action"]; ok do action = v }
    action = strings.trim_space(action)
    url := strip_fragment(vm.base_url) if action == "" else net.resolve_url(vm.base_url, action, context.temp_allocator)
    if url == "" do return false // javascript:/mailto: (não suportados como alvo de envio)

    method := form_method(form, submitter)
    switch method {
    case "dialog":
        return false
    case "post":
        // Degradação 1: sem corpo na navegação. Avisa em vez de virar um GET errado.
        console_capture(vm, .Warn, strings.clone("[browser] envio de <form method=POST> ainda não é suportado; nada foi enviado"))
        return false
    }

    // GET: a query da action é SUBSTITUÍDA pelos dados; o fragmento é mantido.
    frag := ""
    if h := strings.index_byte(url, '#'); h >= 0 do frag = url[h:]
    query := form_urlencoded(form_entries(form, submitter)[:])
    final := strings.concatenate({strip_query(url), "?", query, frag}, context.temp_allocator)
    vm.nav_request = own_str_raw(vm, final)
    vm.nav_replace = false
    return true
}

// Ação PADRÃO de um clique não cancelado: se o alvo (ou um ancestral) é um botão
// de envio com formulário, envia por ele (dispara `submit`, que pode cancelar).
// A UI chama depois de despachar o `click`.
click_default_submit :: proc(vm: ^Interp, target: ^dom.Node) -> bool {
    for n := target; n != nil; n = n.parent {
        if n.kind != .Element do continue
        t := strings.to_lower(n.attrs["type"] or_else "", context.temp_allocator)
        is_submit := (n.tag == "button" && (t == "" || t == "submit")) ||
                     (n.tag == "input" && (t == "submit" || t == "image"))
        if !is_submit {
            if n.tag == "a" || n.tag == "button" || n.tag == "input" do return false // outro controle interativo
            continue
        }
        if is_disabled(n) do return false
        f := form_owner(n)
        if f == nil do return false
        return form_submit(vm, f, n, false)
    }
    return false
}

native_form_submit :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    n := node_of(this)
    if n == nil || n.tag != "form" do return nil
    form_submit(vm, n, nil, true)
    return nil
}

// requestSubmit([submitter]): dispara `submit` (cancelável) e só então envia. O
// submitter, se dado, tem de ser um botão de envio DESTE formulário (spec: senão
// TypeError / NotFoundError).
native_form_request_submit :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    n := node_of(this)
    if n == nil || n.tag != "form" do return nil
    submitter: ^dom.Node
    if len(args) > 0 && args[0] != nil {
        if _, is_null := args[0].(JS_Null); !is_null {
            s := node_of(args[0])
            t := strings.to_lower(s.attrs["type"] or_else "", context.temp_allocator) if s != nil else ""
            is_submit := s != nil && ((s.tag == "button" && (t == "" || t == "submit")) ||
                                      (s.tag == "input" && (t == "submit" || t == "image")))
            if !is_submit {
                throw_type_error(vm, "requestSubmit: o submitter não é um botão de envio")
                return nil
            }
            if form_owner(s) != n {
                throw_type_error(vm, "requestSubmit: o submitter não pertence a este formulário")
                return nil
            }
            submitter = s
        }
    }
    form_submit(vm, n, submitter, false)
    return nil
}
