package js

// Only syntactically anonymous definitions receive a binding name. Passing an
// existing function through an identifier, call or comma expression never does.
infer_binding_name :: proc(n: ^Node, value: Value, name: string) {
    if n == nil || name == "" || n.name != "" do return
    if n.kind != .Func && n.kind != .Class do return
    if f, ok := value.(^Function); ok {
        f.name = name
        if f.metadata_name do f.props["name"] = name
    }
}
