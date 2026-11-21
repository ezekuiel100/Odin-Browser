package js

// Error.stack com frames + Error.captureStackTrace / stackTraceLimit (stack_trace.odin).
// Antes `stack` era só "Name: msg". Os casos comparam a pilha INTEIRA (linha:coluna
// incluídas): uma pilha de uma linha só, ou frames na ordem errada, falham aqui.
// Rodar: odin test src/js

import "core:strings"
import "core:testing"

@(private = "file")
URL :: "https://x.test/app.js"

// Roda `src` como script externo de URL conhecida (as linhas do stack citam a URL).
@(private = "file")
run_url :: proc(src: string, probe := "") -> string {
    vm := vm_create()
    defer vm_free(vm)
    v := vm_run(vm, src, URL)
    if probe != "" do v = vm_run(vm, probe)
    s, _ := v.(string)
    return strings.clone(s, context.temp_allocator)
}

@(test)
test_stack_nested_calls :: proc(t: ^testing.T) {
    got := run_url("function inner(){ return new Error('boom').stack }\n" +
                   "function outer(){ return inner() }\n" +
                   "outer()")
    testing.expect_value(t, got,
        "Error: boom\n" +
        "    at inner (" + URL + ":1:26)\n" +
        "    at outer (" + URL + ":2:26)\n" +
        "    at " + URL + ":3:1")
}

@(test)
test_stack_restored_after_throw :: proc(t: ^testing.T) {
    // o unwind de uma exceção não pode deixar frames pendurados
    got := run_url("function deep(n){ if (n == 0) throw new Error('d'); deep(n - 1) }\n" +
                   "try { deep(5) } catch (e) {}\n" +
                   "new Error('t').stack")
    testing.expect_value(t, got, "Error: t\n    at " + URL + ":3:1")
}

@(test)
test_stack_engine_error_points_statement :: proc(t: ^testing.T) {
    got := run_url("function g(){ null.x }\n" +
                   "var s; try { g() } catch (e) { s = e.stack }\n" +
                   "s")
    testing.expect_value(t, got,
        "TypeError: Cannot read properties of null (reading 'x')\n" +
        "    at g (" + URL + ":1:15)\n" +
        "    at " + URL + ":2:14")
}

@(test)
test_stack_new_and_anonymous :: proc(t: ^testing.T) {
    got := run_url("function C(){ this.s = new Error().stack }\n" +
                   "var f = function f(){ return new C().s }\n" +
                   "f()")
    // construtor sai como "new C". (`var f = function(){}` ainda NÃO ganha nome: falta
    // NamedEvaluation em declaração/atribuição — por isso a expressão nomeada aqui.)
    testing.expect_value(t, got,
        "Error\n" +
        "    at new C (" + URL + ":1:24)\n" +
        "    at f (" + URL + ":2:30)\n" +
        "    at " + URL + ":3:1")
    // arrow anônima: só o local, sem nome nem parênteses (formato do V8)
    got2 := run_url("[1].map(() => new Error().stack)[0]")
    testing.expect_value(t, got2,
        "Error\n" +
        "    at " + URL + ":1:15\n" +
        "    at " + URL + ":1:5")
}

@(test)
test_stack_class_extends_error :: proc(t: ^testing.T) {
    got := run_url("class E extends Error { constructor(m){ super(m) } }\n" +
                   "function mk(){ return new E('z') }\n" +
                   "mk().stack")
    testing.expect_value(t, got,
        "Error: z\n" +
        "    at new E (" + URL + ":1:41)\n" +
        "    at mk (" + URL + ":2:23)\n" +
        "    at " + URL + ":3:1")
}

@(test)
test_class_ctor_name :: proc(t: ^testing.T) {
    testing.expect_value(t, run_url("class E { constructor(){} } E.name"), "E")
}

@(test)
test_capture_stack_trace_hides_ctor :: proc(t: ^testing.T) {
    got := run_url("function MyErr(m){ this.name = 'MyErr'; this.message = m; Error.captureStackTrace(this, MyErr) }\n" +
                   "function f(){ return new MyErr('x') }\n" +
                   "f().stack")
    testing.expect_value(t, got,
        "MyErr: x\n" +
        "    at f (" + URL + ":2:22)\n" +
        "    at " + URL + ":3:1")
}

@(test)
test_capture_stack_trace_plain_object :: proc(t: ^testing.T) {
    got := run_url("function where(){ var o = {}; Error.captureStackTrace(o); return o }\n" +
                   "var o = where();\n" +
                   "typeof Error.captureStackTrace + '|' + Object.keys(o).length + '|' + o.stack")
    testing.expect_value(t, got,
        "function|0|Error\n" +
        "    at where (" + URL + ":1:37)\n" +
        "    at " + URL + ":2:9")
    // ctorOpt que não está na pilha: nenhum frame (V8)
    got2 := run_url("var o = {}; Error.captureStackTrace(o, function nope(){}); o.stack")
    testing.expect_value(t, got2, "Error")
    // não-objeto: TypeError
    got3 := run_url("var r; try { Error.captureStackTrace(1) } catch (e) { r = e.name } r")
    testing.expect_value(t, got3, "TypeError")
}

@(test)
test_stack_trace_limit :: proc(t: ^testing.T) {
    src := "function a(){ return new Error('x').stack }\n" +
           "function b(){ return a() }\n"
    got := run_url(strings.concatenate({src, "Error.stackTraceLimit = 1; b()"}, context.temp_allocator))
    testing.expect_value(t, got, "Error: x\n    at a (" + URL + ":1:22)")
    got0 := run_url(strings.concatenate({src, "Error.stackTraceLimit = 0; b()"}, context.temp_allocator))
    testing.expect_value(t, got0, "Error: x")
    // default 10, gravável e enumerável (como no V8); não-número → sem `stack`
    got2 := run_url("var d = Object.getOwnPropertyDescriptor(Error, 'stackTraceLimit');\n" +
                    "Error.stackTraceLimit = 'n';\n" +
                    "d.value + '|' + d.writable + d.enumerable + '|' + typeof new Error('q').stack")
    testing.expect_value(t, got2, "10|truetrue|undefined")
}

@(test)
test_stack_generator_frame :: proc(t: ^testing.T) {
    got := run_url("function* gen(){ yield new Error('g').stack }\n" +
                   "function caller(){ return gen().next().value }\n" +
                   "caller()")
    testing.expect_value(t, got,
        "Error: g\n" +
        "    at gen (" + URL + ":1:24)\n" +
        "    at caller (" + URL + ":2:33)\n" +
        "    at " + URL + ":3:1")
}

@(test)
test_stack_async_after_await :: proc(t: ^testing.T) {
    // depois do await quem retoma é o executor de microtasks: só o frame da async
    got := run_url("var out; async function a(){ await 0; out = new Error('a').stack }\n" +
                   "a()", "out")
    testing.expect_value(t, got, "Error: a\n    at a (" + URL + ":1:45)")
    // antes do 1º await o corpo roda síncrono: o chamador aparece
    got2 := run_url("var out; async function a(){ out = new Error('a').stack }\n" +
                    "a(); out")
    testing.expect_value(t, got2,
        "Error: a\n" +
        "    at a (" + URL + ":1:36)\n" +
        "    at " + URL + ":2:1")
}

@(test)
test_stack_eval_code_is_anonymous :: proc(t: ^testing.T) {
    got := run_url("function viaEval(){ return eval('\\n  new Error(\"e\").stack') }\n" +
                   "viaEval()")
    testing.expect_value(t, got,
        "Error: e\n" +
        "    at <anonymous>:2:3\n" +
        "    at viaEval (" + URL + ":1:28)\n" +
        "    at " + URL + ":2:1")
}

@(test)
test_script_line_col_utf16 :: proc(t: ^testing.T) {
    s := Script_Src{src = "aé😀b\r\nc d"}
    defer delete(s.lines)
    l, c := script_line_col(&s, 1 + 7) // 'b': a(1) é(1) 😀(2 code units) → coluna 5
    testing.expect_value(t, l, 1); testing.expect_value(t, c, 5)
    l, c = script_line_col(&s, 1 + 10) // 'c' depois de \r\n
    testing.expect_value(t, l, 2); testing.expect_value(t, c, 1)
    l, c = script_line_col(&s, 1 + 14) // 'd' depois de U+2028
    testing.expect_value(t, l, 3); testing.expect_value(t, c, 1)
}

@(test)
test_stack_not_enumerable :: proc(t: ^testing.T) {
    got := run_url("var e = new Error('k'); var t; try { null.y } catch (x) { t = x }\n" +
                   "Object.keys(e).indexOf('stack') + '|' + Object.keys(t).indexOf('stack') + '|' + JSON.stringify(e).indexOf('stack')")
    testing.expect_value(t, got, "-1|-1|-1")
}
