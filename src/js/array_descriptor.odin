package js

import "core:math"

// Own indexed Get, preserving Receiver for accessors. A present undefined value
// must stop lookup; only a hole continues through the prototype chain.
array_get_own_index :: proc(vm: ^Interp, a: ^Array, index: int, key: string, receiver: Value) -> (Value, bool) {
    if m := a.descriptors; m != nil {
        if getter, exists := m.getters[key]; exists {
            if getter == nil do return nil, true
            return call_function(vm, getter, receiver, nil), true
        }
        if _, exists := m.setters[key]; exists do return nil, true
    }
    if arr_has_index(a, index) do return a.items[index], true
    return nil, false
}

// Only explicitly defined properties need metadata. Ordinary arrays retain
// their dense storage and do not allocate an attribute map.
array_attrs :: proc(a: ^Array, key: string) -> Prop_Attrs {
    attrs := ATTRS_DEFAULT
    if key == "length" do attrs = {.Writable}
    if a.descriptors != nil {
        if explicit, ok := a.descriptors.attrs[key]; ok do attrs = explicit
    }
    if a.frozen do attrs -= {.Writable, .Configurable}
    if a.sealed do attrs -= {.Configurable}
    return attrs
}

array_define_property :: proc(vm: ^Interp, a: ^Array, key: string, source: ^Object) {
    desc := normalize_descriptor(vm, source)
    if vm.throwing do return
    value, has_value := desc.props["value"]
    if key == "length" && has_value {
        u := to_number(vm, value)
        if vm.throwing do return
        n := to_number(vm, value)
        if vm.throwing do return
        if u != u || math.trunc(u) != u || u < 0 || u >= 4294967296 || n != u {
            vm.thrown = mk_error(vm, "RangeError", "Invalid array length"); vm.throwing = true
            return
        }
        desc.props["value"] = n
    }
    // Validate against the current property using the ordinary descriptor rules.
    // This view is temporary: items/props remain the single source of data values.
    view := new_object(vm)
    old := obj_get_own_property_descriptor(vm, nil, []Value{a, key})
    if d, exists := old.(^Object); exists {
        apply_normalized_descriptor(vm, view, key, d)
    }
    view.non_extensible = a.frozen || a.sealed
    apply_normalized_descriptor(vm, view, key, desc)
    if vm.throwing do return
    attrs := prop_attrs(view, key)
    if key == "length" {
        success := true
        if has_value && as_int(desc.props["value"]) != len(a.items) {
            success = array_set_length(vm, a, desc.props["value"])
        }
        // A failed truncation still applies writable:false (ArraySetLength).
        if a.descriptors == nil do a.descriptors = new_object(vm)
        if a.descriptors.attrs == nil do a.descriptors.attrs = make(map[string]Prop_Attrs)
        a.descriptors.attrs[key] = attrs
        if !success && !vm.throwing do throw_type_error(vm, "Cannot redefine array length")
        return
    }
    if idx, indexed := array_index_name(key); indexed {
        if idx >= len(a.items) {
            if .Writable not_in array_attrs(a, "length") { throw_type_error(vm, "Array length is read only"); return }
            if idx > 100_000_000 { throw_type_error(vm, "Array index exceeds storage limit"); return }
            arr_mark_holes(a, len(a.items), idx + 1)
            for len(a.items) <= idx do append(&a.items, nil)
        }
        a.items[idx] = view.props[key]
        arr_fill_slot(a, idx)
    } else {
        if a.props == nil do a.props = make(map[string]Value)
        a.props[key] = view.props[key]
    }
    if a.descriptors == nil do a.descriptors = new_object(vm)
    m := a.descriptors
    if m.attrs == nil do m.attrs = make(map[string]Prop_Attrs)
    m.attrs[key] = attrs
    if m.getters == nil do m.getters = make(map[string]^Function)
    if m.setters == nil do m.setters = make(map[string]^Function)
    delete_key(&m.getters, key); delete_key(&m.setters, key)
    if getter, ok := view.getters[key]; ok do m.getters[key] = getter
    if setter, ok := view.setters[key]; ok do m.setters[key] = setter
}

array_delete_property :: proc(a: ^Array, key: string) -> bool {
    if key == "length" do return false
    idx, indexed := array_index_name(key)
    exists := false
    if indexed { exists = arr_has_index(a, idx) } else { _, exists = a.props[key] }
    if !exists do return true
    if .Configurable not_in array_attrs(a, key) do return false
    if indexed {
        a.items[idx] = nil
        arr_mark_hole(a, idx)
        if a.args != nil && idx < 64 do a.args.unmapped |= u64(1) << uint(idx)
    } else { delete_key(&a.props, key) }
    if m := a.descriptors; m != nil {
        delete_key(&m.attrs, key); delete_key(&m.getters, key); delete_key(&m.setters, key)
    }
    return true
}
