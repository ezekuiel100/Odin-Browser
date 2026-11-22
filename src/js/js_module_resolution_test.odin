package js

import "core:testing"
import "core:strings"

@(private = "file")
resolution_vm :: proc() -> ^Interp {
    vm := vm_create()
    vm.module_resolve = proc(vm: ^Interp, spec, referrer: string) -> string { return strings.clone(spec) }
    vm.module_fetch = proc(vm: ^Interp, url: string) -> (string, bool) {
        if src, ok := vm.module_stubs[url]; ok do return strings.clone(src), true
        return "", false
    }
    vm.module_stubs = make(map[string]string)
    vm_run(vm, `var result;`)
    vm.module_stubs["a"] = `export var x = 1; export var unique = 7; export default 99; export function inc(){x++;}`
    vm.module_stubs["b"] = `export var x = 1;`
    return vm
}

@(test)
module_star_conflict_is_omitted_in_both_orders :: proc(t: ^testing.T) {
    for src in ([]string{`export * from 'a'; export * from 'b';`, `export * from 'b'; export * from 'a';`}) {
        vm := resolution_vm()
        vm.module_stubs["barrel"] = src
        vm_run_module(vm, `import * as ns from 'barrel'; result = Object.keys(ns).sort().join(',') + ':' + String(ns.x);`)
        testing.expect_value(t, vm_run(vm, `result`).(string), "inc,unique:undefined")
        vm_free(vm)
    }
}

@(test)
module_star_explicit_exports_take_priority :: proc(t: ^testing.T) {
    for src in ([]string{
        `export * from 'a'; export * from 'b'; export var x = 42;`,
        `export var x = 42; export * from 'a'; export * from 'b';`,
        `export * from 'a'; export {x} from 'b';`,
    }) {
        vm := resolution_vm()
        vm.module_stubs["barrel"] = src
        vm_run_module(vm, `import {x} from 'barrel'; result = x;`)
        testing.expect_value(t, as_number(vm_run(vm, `result`)), 1 if src == `export * from 'a'; export {x} from 'b';` else 42)
        vm_free(vm)
    }
}

@(test)
module_star_diamond_preserves_identity_and_live_binding :: proc(t: ^testing.T) {
    vm := resolution_vm(); defer vm_free(vm)
    vm.module_stubs["left"] = `export * from 'a';`
    vm.module_stubs["right"] = `import {x} from 'a'; export {x};`
    vm.module_stubs["barrel"] = `export * from 'left'; export * from 'right';`
    vm_run_module(vm, `import {x,inc} from 'barrel'; import * as ns from 'barrel'; inc(); result = x + ns.x;`)
    testing.expect_value(t, as_number(vm_run(vm, `result`)), 4)
}

@(test)
module_star_cycle_terminates_and_resolves :: proc(t: ^testing.T) {
    vm := resolution_vm(); defer vm_free(vm)
    vm.module_stubs["left"] = `export * from 'right'; export * from 'a';`
    vm.module_stubs["right"] = `export * from 'left';`
    vm_run_module(vm, `import * as ns from 'right'; result = ns.x;`)
    testing.expect_value(t, as_number(vm_run(vm, `result`)), 1)
}

@(test)
module_star_ambiguous_import_and_reexport_fail :: proc(t: ^testing.T) {
    for src in ([]string{`import {x} from 'barrel'; result = 100;`, `export {x} from 'barrel'; result = 100;`}) {
        vm := resolution_vm()
        vm.module_stubs["barrel"] = `export * from 'a'; export * from 'b';`
        vm_run_module(vm, src, "entry")
        testing.expect_value(t, vm.modules["entry"].state, Module_State.Failed)
        testing.expect(t, vm.modules["entry"].error != nil)
        testing.expect(t, vm_run(vm, `result`) == nil)
        vm_free(vm)
    }
}

@(test)
module_attributes_preserved_on_all_static_requests :: proc(t: ^testing.T) {
    vm := vm_create(); defer vm_free(vm)
    vm_run_module(vm, `
        import 'a' with {type: "json", "custom": "value",};
        import data from 'b' with {type: "json"};
        export {default as data} from 'c' with {type: "json"};
        export * from 'd' with {type: "json"};
        export * as ns from 'e' assert {type: "json"};
    `)
    testing.expect_value(t, vm.syntax_errors, 0)
    ast := vm.all_asts[len(vm.all_asts)-1]
    testing.expect_value(t, len(ast.body), 5)
    for n, i in ast.body {
        testing.expect(t, n.third != nil)
        if n.third == nil do continue
        testing.expect_value(t, n.third.name, "assert" if i == 4 else "with")
        testing.expect_value(t, n.third.body[0].name, "type")
        testing.expect_value(t, n.third.body[0].str, "json")
    }
    testing.expect_value(t, ast.body[0].third.body[1].name, "custom")
    testing.expect_value(t, ast.body[0].third.body[1].str, "value")
}

@(test)
module_attributes_reject_duplicates_and_non_string_values :: proc(t: ^testing.T) {
    for src in ([]string{
        `import 'a' with {type: 'json', "type": 'json'};`,
        `export * from 'a' with {type: true};`,
        `import 'a' with {type};`,
        `export {x} from 'a' with {type: 'json' type: 'json'};`,
    }) {
        vm := vm_create()
        vm_run_module(vm, src)
        testing.expect_value(t, vm.syntax_errors, 1)
        vm_free(vm)
    }
}
