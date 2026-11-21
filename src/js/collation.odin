package js

// Shared String.localeCompare / Intl.Collator option and coercion handling.
Collation_Options :: struct {
    locale: string,
    sensitivity: string,
    usage: string,
    case_first: string,
    numeric: bool,
    punctuation: bool,
    numeric_set: bool,
    case_first_set: bool,
}

collation_string :: proc(vm: ^Interp, v: Value) -> string {
    p := to_primitive(vm, v, false)
    if vm.throwing do return ""
    if _, symbol := p.(^Symbol); symbol {
        throw_type_error(vm, "Cannot convert a Symbol value to a string")
        return ""
    }
    return key_string(vm, p)
}

collation_error :: proc(vm: ^Interp, message: string) {
    vm.thrown = mk_error(vm, "RangeError", message)
    vm.throwing = true
}

collation_option :: proc(vm: ^Interp, options: Value, name, fallback: string, allowed: []string) -> string {
    if options == nil do return fallback
    v := get_member(vm, options, name)
    if vm.throwing || v == nil do return fallback
    s := collation_string(vm, v)
    if vm.throwing do return fallback
    for a in allowed do if s == a do return s
    collation_error(vm, "Invalid collation option")
    return fallback
}

collation_options :: proc(vm: ^Interp, locales, options: Value) -> Collation_Options {
    o := Collation_Options{}
    if _, is_null := locales.(JS_Null); is_null { throw_type_error(vm, "Collation locales cannot be null"); return o }
    o.locale = first_locale(vm, locales)
    if _, is_null := options.(JS_Null); is_null { throw_type_error(vm, "Collation options cannot be null"); return o }
    o.usage = collation_option(vm, options, "usage", "sort", []string{"sort", "search"})
    if vm.throwing do return o
    collation_option(vm, options, "localeMatcher", "best fit", []string{"lookup", "best fit"})
    if vm.throwing do return o
    // An absent value leaves Unicode locale extension defaults to ICU.
    if options != nil {
        v := get_member(vm, options, "numeric")
        if vm.throwing do return o
        o.numeric_set = v != nil
        o.numeric = truthy(v)
    }
    o.case_first = collation_option(vm, options, "caseFirst", "", []string{"upper", "lower", "false"})
    if vm.throwing do return o
    o.case_first_set = o.case_first != ""
    if !o.case_first_set do o.case_first = "false"
    o.sensitivity = collation_option(vm, options, "sensitivity", "variant", []string{"base", "accent", "case", "variant"})
    if vm.throwing do return o
    if options != nil {
        v := get_member(vm, options, "ignorePunctuation")
        if vm.throwing do return o
        o.punctuation = truthy(v)
    }
    return o
}

store_collation_options :: proc(vm: ^Interp, inst: ^Object, o: Collation_Options) {
    inst.props["#loc"] = own_str(vm, o.locale)
    inst.props["#sensitivity"] = own_str(vm, o.sensitivity)
    inst.props["#usage"] = own_str(vm, o.usage)
    inst.props["#caseFirst"] = own_str(vm, o.case_first)
    inst.props["#numeric"] = o.numeric
    inst.props["#punctuation"] = o.punctuation
    inst.props["#numericSet"] = o.numeric_set
    inst.props["#caseFirstSet"] = o.case_first_set
}

load_collation_options :: proc(inst: ^Object) -> Collation_Options {
    return Collation_Options{
        locale = inst.props["#loc"].(string),
        sensitivity = inst.props["#sensitivity"].(string),
        usage = inst.props["#usage"].(string),
        case_first = inst.props["#caseFirst"].(string),
        numeric = inst.props["#numeric"].(bool),
        punctuation = inst.props["#punctuation"].(bool),
        numeric_set = inst.props["#numericSet"].(bool),
        case_first_set = inst.props["#caseFirstSet"].(bool),
    }
}
