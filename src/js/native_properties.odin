package js

// Native objects keep their internal slots separate from ordinary own properties.
// The optional storage uses the same ordering, descriptors and GC as Object.
native_own_properties :: proc(vm: ^Interp, value: Value, create := false) -> ^Object {
    slot: ^^Object
    #partial switch v in value {
    case ^Regex: slot = &v.own
    case ^Collection: slot = &v.own
    case: return nil
    }
    if slot^ == nil && create {
        slot^ = new_object(vm)
        slot^.proto = nil // storage only; getters must retain the native receiver
    }
    return slot^
}

native_property_proto :: proc(vm: ^Interp, value: Value) -> ^Object {
    #partial switch v in value {
    case ^Regex: return vm.regex_proto
    case ^Collection: return vm.collection_protos[v.kind]
    }
    return nil
}

native_property_set :: proc(vm: ^Interp, receiver: Value, key: string, value: Value) -> bool {
    own := native_own_properties(vm, receiver, true)
    if setter, exists := own.setters[key]; exists {
        if setter == nil do return false
        call_function(vm, setter, receiver, []Value{value})
        return !vm.throwing
    }
    if _, exists := own.getters[key]; exists do return false
    if okey_alive(own, key) {
        if .Writable not_in prop_attrs(own, key) do return false
    } else {
        if own.non_extensible do return false
        for cur := native_property_proto(vm, receiver); cur != nil; cur = cur.proto {
            if setter, exists := cur.setters[key]; exists {
                if setter == nil do return false
                call_function(vm, setter, receiver, []Value{value})
                return !vm.throwing
            }
            if _, exists := cur.getters[key]; exists do return false
            if _, exists := cur.props[key]; exists {
                if .Writable not_in prop_attrs(cur, key) do return false
                break
            }
        }
    }
    oput(own, own_str_raw(vm, key), value)
    return true
}
