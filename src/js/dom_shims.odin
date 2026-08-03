package js

// M157 — Path2D e XPathEvaluator: SHELLS honestos de feature-detect.
//
// Últimos nomes do ranking de globais que ainda eram do MOTOR (o resto é do-site:
// $/jQuery/etc.). `Path2D is not defined` (twitch) e `XPathEvaluator is not
// defined` (htmx) matavam o bundle no feature-detect.
//
// ── O QUE SÃO E O QUE NÃO SÃO ────────────────────────────────────────────────
// • Path2D: não temos contexto de canvas 2D que renderize path (só a interface
//   HTMLCanvasElement existe). Então Path2D CONSTRÓI e tem todos os métodos de
//   path (moveTo/lineTo/arc/…), mas eles são NO-OP — não há para onde desenhar.
//   Honesto: o path não é pintado. `new Path2D()`, `typeof Path2D`, e chamar os
//   métodos sem estourar é tudo que o feature-detect precisa.
// • XPathEvaluator/document.evaluate: NÃO avaliamos XPath (seria um motor
//   inteiro). O shell CONSTRÓI e `evaluate()` devolve um XPathResult VAZIO
//   (snapshotLength 0, iterateNext()→null, singleNodeValue→null). Um site que
//   dependa de XPath p/ ACHAR nós não vai achar — mas não inventamos matches
//   (mentir seria pior) e não estouramos. A maioria só feature-detecta.
//   Documentado em cada ponto: degradar com honestidade.

@(private = "file")
shim_noop :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return nil }
@(private = "file")
shim_null :: proc(vm: ^Interp, this: Value, args: []Value) -> Value { return JS_Null{} }

// Liga a instância recém-construída ao prototype do construtor em execução
// (vm.native_bound = fn.bound, publicado por construct_object no caminho nativo).
@(private = "file")
shim_adopt_proto :: proc(vm: ^Interp, o: ^Object) {
    if p, ok := vm.native_bound.(^Object); ok do o.proto = p
}

// Anexa `.prototype` a um construtor (cópia local do attach_prototype de
// dom_bindings.odin, que é file-private). Devolve o proto p/ popular.
@(private = "file")
shim_attach_prototype :: proc(vm: ^Interp, f: ^Function, parent_proto: ^Object) -> ^Object {
    if f.props == nil do f.props = make(map[string]Value)
    proto := new_object(vm)
    proto.proto = parent_proto
    proto.props["constructor"] = f
    mark_non_enumerable(proto, "constructor") // não-enumerável (spec)
    f.props["prototype"] = proto
    return proto
}

// ── Path2D ───────────────────────────────────────────────────────────────────

@(private = "file")
path2d_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    // arg opcional (outro Path2D ou string de path SVG) é IGNORADO — sem renderer
    // não há geometria observável a reter.
    o := new_object(vm)
    shim_adopt_proto(vm, o)
    return o
}

// ── XPathResult (shell vazio) ────────────────────────────────────────────────

// Constantes de tipo do XPathResult (spec). Postas no global XPathResult e em
// cada resultado (código real lê `XPathResult.ORDERED_NODE_SNAPSHOT_TYPE`).
// Recebe o MAP de props (Object.props e Function.props têm o mesmo tipo; map é
// referência em Odin, então as escritas persistem). Serve a instância (^Object)
// e o construtor global XPathResult (^Function).
@(private = "file")
xpath_result_consts :: proc(p: ^map[string]Value) {
    p^["ANY_TYPE"]                     = f64(0)
    p^["NUMBER_TYPE"]                  = f64(1)
    p^["STRING_TYPE"]                  = f64(2)
    p^["BOOLEAN_TYPE"]                 = f64(3)
    p^["UNORDERED_NODE_ITERATOR_TYPE"] = f64(4)
    p^["ORDERED_NODE_ITERATOR_TYPE"]   = f64(5)
    p^["UNORDERED_NODE_SNAPSHOT_TYPE"] = f64(6)
    p^["ORDERED_NODE_SNAPSHOT_TYPE"]   = f64(7)
    p^["ANY_UNORDERED_NODE_TYPE"]      = f64(8)
    p^["FIRST_ORDERED_NODE_TYPE"]      = f64(9)
}

// Constrói um XPathResult VAZIO do tipo pedido. Não avalia nada.
@(private = "file")
xpath_make_result :: proc(vm: ^Interp, result_type: f64) -> Value {
    r := new_object(vm)
    r.props["resultType"]           = result_type
    r.props["numberValue"]          = f64(0)
    r.props["stringValue"]          = own_str(vm, "")
    r.props["booleanValue"]         = false
    r.props["singleNodeValue"]      = JS_Null{}
    r.props["invalidIteratorState"] = false
    r.props["snapshotLength"]       = f64(0)
    r.props["iterateNext"]          = mk_native(vm, shim_null)  // sempre null (vazio)
    r.props["snapshotItem"]         = mk_native(vm, shim_null)
    xpath_result_consts(&r.props)
    return r
}

@(private = "file")
xpath_result_type_arg :: proc(args: []Value, idx: int) -> f64 {
    if v, ok := arg(args, idx).(f64); ok do return v
    return 0 // ANY_TYPE
}

// evaluate(xpath, contextNode, resolver, resultType, result) — devolve resultado vazio.
@(private = "file")
xpath_evaluate :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return xpath_make_result(vm, xpath_result_type_arg(args, 3))
}

// createExpression(xpath, resolver) — devolve um XPathExpression cujo evaluate
// também dá resultado vazio.
@(private = "file")
xpath_create_expression :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    e := new_object(vm)
    e.props["evaluate"] = mk_native(vm, xpath_expr_evaluate) // evaluate(contextNode, type, result)
    return e
}

// evaluate de um XPathExpression: type é o 2º arg (não o 4º como no document.evaluate).
@(private = "file")
xpath_expr_evaluate :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    return xpath_make_result(vm, xpath_result_type_arg(args, 1))
}

// createNSResolver(node) — devolve um resolver inócuo (lookupNamespaceURI→null).
@(private = "file")
xpath_create_ns_resolver :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    r := new_object(vm)
    r.props["lookupNamespaceURI"] = mk_native(vm, shim_null)
    return r
}

@(private = "file")
xpath_evaluator_ctor :: proc(vm: ^Interp, this: Value, args: []Value) -> Value {
    o := new_object(vm)
    shim_adopt_proto(vm, o)
    o.props["evaluate"]          = mk_native(vm, xpath_evaluate)
    o.props["createExpression"]  = mk_native(vm, xpath_create_expression)
    o.props["createNSResolver"]  = mk_native(vm, xpath_create_ns_resolver)
    return o
}

// Instala Path2D, XPathEvaluator, XPathResult e os métodos XPath no document.
// Chamado por install_dom (dom_bindings.odin) — são globais do WINDOW/DOM.
install_dom_shims :: proc(vm: ^Interp, doc: ^Object) {
    // Path2D: construtor + métodos de path no prototype (compartilhados). Todos
    // no-op: sem contexto 2D que renderize, o path não tem efeito observável.
    p2d := mk_native(vm, path2d_ctor)
    p2d_proto := shim_attach_prototype(vm, p2d, vm.object_proto)
    p2d_methods := []string{
        "moveTo", "lineTo", "bezierCurveTo", "quadraticCurveTo",
        "arc", "arcTo", "ellipse", "rect", "roundRect", "closePath", "addPath",
    }
    for m in p2d_methods {
        p2d_proto.props[m] = mk_native(vm, shim_noop)
    }
    p2d.bound = p2d_proto // instanceof: instância adota este proto (shim_adopt_proto)
    env_define(vm.global, "Path2D", p2d)

    // XPathEvaluator: construtor + evaluate/createExpression/createNSResolver.
    xev := mk_native(vm, xpath_evaluator_ctor)
    xev_proto := shim_attach_prototype(vm, xev, vm.object_proto)
    xev_proto.props["evaluate"]         = mk_native(vm, xpath_evaluate)
    xev_proto.props["createExpression"] = mk_native(vm, xpath_create_expression)
    xev_proto.props["createNSResolver"] = mk_native(vm, xpath_create_ns_resolver)
    xev.bound = xev_proto
    env_define(vm.global, "XPathEvaluator", xev)

    // XPathResult global: só carrega as constantes de tipo (código lê
    // `XPathResult.ORDERED_NODE_SNAPSHOT_TYPE` p/ passar no evaluate).
    xres := new_function(vm)
    xres.name = "XPathResult"
    xres.props = make(map[string]Value)
    xres_proto := shim_attach_prototype(vm, xres, vm.object_proto)
    xpath_result_consts(&xres.props)     // constantes também no próprio construtor (spec)
    xpath_result_consts(&xres_proto.props) // e no prototype (algumas libs leem via instância)
    env_define(vm.global, "XPathResult", xres)

    // XPathExpression global: casca só p/ feature-detect / `x instanceof XPathExpression`.
    xexpr := new_function(vm)
    xexpr.name = "XPathExpression"
    xexpr.props = make(map[string]Value)
    shim_attach_prototype(vm, xexpr, vm.object_proto)
    env_define(vm.global, "XPathExpression", xexpr)

    // Document também implementa XPathEvaluatorBase: document.evaluate(...) é a
    // porta de entrada mais usada (mais que `new XPathEvaluator()`).
    if doc != nil {
        doc.props["evaluate"]         = mk_native(vm, xpath_evaluate)
        doc.props["createExpression"] = mk_native(vm, xpath_create_expression)
        doc.props["createNSResolver"] = mk_native(vm, xpath_create_ns_resolver)
    }
}
