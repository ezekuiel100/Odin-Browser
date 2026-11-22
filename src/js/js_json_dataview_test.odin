package js

import "core:testing"

@(test)
json_reviver_holder :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var holders = {}, order = [], rootHolder;
        var result = JSON.parse('{"obj":{"x":1},"arr":[2]}', function(k, v) {
            'use strict';
            holders[k] = this;
            order.push(k);
            if (k === '') rootHolder = this;
            return typeof v === 'number' ? v * 10 : v;
        });
        holders.x === result.obj && holders['0'] === result.arr &&
            holders.obj === result && holders.arr === result &&
            rootHolder !== result && rootHolder[''] === result &&
            Object.keys(rootHolder).join(',') === '' &&
            Object.prototype.hasOwnProperty.call(rootHolder, '') &&
            order.join(',') === 'x,obj,0,arr,' &&
            result.obj.x === 10 && result.arr[0] === 20;
    `).(bool), true)
}

@(test)
json_reviver_root_holder_primitives_and_errors :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var good = ['1', 'null', 'true', '"text"', '[]'].every(function(text) {
            var holder, value;
            var result = JSON.parse(text, function(k, v) {
                'use strict';
                holder = this; value = v;
                return 42;
            });
            return result === 42 && holder[''] === value &&
                Object.prototype.hasOwnProperty.call(holder, '');
        });
        var deleted = JSON.parse('1', function() { return undefined; });
        var sentinel = {}, caught = false, calls = 0;
        try {
            JSON.parse('{"a":1,"b":2}', function(k, v) {
                calls++;
                throw sentinel;
            });
        } catch(e) { caught = e === sentinel; }
        good && deleted === undefined && caught && calls === 1;
    `).(bool), true)
}

@(test)
dataview_access_bounds_errors :: proc(t: ^testing.T) {
    testing.expect_value(t, run(`
        var buf = new ArrayBuffer(24), view = new DataView(buf, 4, 8);
        var kinds = ['Int8', 'Uint8', 'Int16', 'Uint16', 'Int32', 'Uint32', 'Float32', 'Float64'];
        var widths = [1, 1, 2, 2, 4, 4, 4, 8];
        function throws(C, f) {
            try { f(); return false; } catch(e) { return e instanceof C; }
        }
        kinds.every(function(kind, i) {
            var get = view['get' + kind], set = view['set' + kind], width = widths[i];
            set.call(view, 8 - width, 7, true);
            var good = get.call(view, 8 - width, true) === 7;
            [-1, 9 - width, 8, 24].forEach(function(offset) {
                good = good && throws(RangeError, function() { get.call(view, offset); }) &&
                    throws(RangeError, function() { set.call(view, offset, 1); });
            });
            return good &&
                throws(TypeError, function() { get.call({}, 0); }) &&
                throws(TypeError, function() { get.call(buf, 0); }) &&
                throws(TypeError, function() { set.call(new Uint8Array(buf), 0, 1); }) &&
                throws(RangeError, function() { get.call(new DataView(buf, 4, 0), 0); });
        });
    `).(bool), true)
}

@(test)
dataview_detached_buffer_type_error :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    buffer := vm_run(vm, `var buf = new ArrayBuffer(8), view = new DataView(buf); buf;`).(^Object)
    buffer.ab.detached = true
    testing.expect_value(t, vm_run(vm, `
        var reads = false, writes = false;
        try { view.getUint8(0); } catch(e) { reads = e instanceof TypeError; }
        try { view.setUint8(0, 1); } catch(e) { writes = e instanceof TypeError; }
        reads && writes;
    `).(bool), true)
}
