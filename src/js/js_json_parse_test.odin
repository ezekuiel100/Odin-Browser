package js

import "core:fmt"
import "core:testing"

@(private = "file")
json_parse_expect_syntax_error :: proc(t: ^testing.T, vm: ^Interp, text: string) {
    env_define(vm.global, "jsonInput", text)
    v, ok := vm_exec(vm, `
        var rejected = false, reviverCalls = 0;
        try {
            JSON.parse(jsonInput, function(k, v) { reviverCalls++; return v; });
        } catch (e) { rejected = e instanceof SyntaxError; }
        rejected && reviverCalls === 0;
    `).(bool)
    testing.expectf(t, ok && v, "JSON.parse deve rejeitar %q com SyntaxError antes do reviver", text)
}

@(test)
json_parse_rejects_invalid_numbers :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    cases := []string{
        "+", "-", "+1", "01", "-01", "00", "-00", "001.1", "01e2",
        ".1", "-.1", "1.", "-1.", "1.e2", "0.e1",
        "1e", "1e+", "1e-", "1E", "1E+", "1E-",
        "1ee2", "1e+-2", "1e--2", "1e++2", "1.2.3",
        "--1", "-+1", "1+2", "1-2", "1 2",
        "NaN", "Infinity", "-Infinity", "0x10", "0b10", "0o10", "1_000",
    }
    for text in cases {
        json_parse_expect_syntax_error(t, vm, text)
        json_parse_expect_syntax_error(t, vm, fmt.tprintf("[%s]", text))
        json_parse_expect_syntax_error(t, vm, fmt.tprintf(`{{"n":%s}}`, text))
    }
    root_cases := []string{"", " ", "\t\r\n", "1 true", "[1 2]", `{"n":1 "m":2}`}
    for text in root_cases {
        json_parse_expect_syntax_error(t, vm, text)
    }
}

@(test)
json_parse_valid_numbers :: proc(t: ^testing.T) {
    cases := []string{
        `JSON.parse('0') === 0 && Object.is(JSON.parse('-0'), -0)`,
        `Object.is(JSON.parse('-0.0'), -0) && Object.is(JSON.parse('-0e+2'), -0)`,
        `JSON.parse('1234567890') === 1234567890 && JSON.parse('-123') === -123`,
        `JSON.parse('0.125') === 0.125 && JSON.parse('-12.50') === -12.5`,
        `JSON.parse('1e2') === 100 && JSON.parse('1E+2') === 100`,
        `JSON.parse('1e-2') === 0.01 && JSON.parse('-1.25E-2') === -0.0125`,
        `JSON.parse('0e0') === 0 && JSON.parse('0.0e+0') === 0`,
        `JSON.parse('1e308') === 1e308 && JSON.parse('5e-324') === 5e-324`,
        // Overflow/underflow de Number não são erros de sintaxe JSON.
        `JSON.parse('1e400') === Infinity && JSON.parse('-1e400') === -Infinity`,
        `JSON.parse('1e-400') === 0 && Object.is(JSON.parse('-1e-400'), -0)`,
        `JSON.parse(' \t\r\n-12.5e+1\r\n ') === -125`,
        `var a = JSON.parse('[0,-0,1.25,2E+2]'); a.length === 4 && Object.is(a[1], -0) && a[2] === 1.25 && a[3] === 200`,
        `var o = JSON.parse('{"n":-2.5e1,"a":[0.5,3]}'); o.n === -25 && o.a[0] === 0.5 && o.a[1] === 3`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}

@(test)
json_parse_rejects_unescaped_controls :: proc(t: ^testing.T) {
    vm := vm_create()
    defer vm_free(vm)
    for c in 0 ..< 0x20 {
        buf := [3]u8{'"', u8(c), '"'}
        text := string(buf[:])
        json_parse_expect_syntax_error(t, vm, text)
        json_parse_expect_syntax_error(t, vm, fmt.tprintf("[%s]", text))
        json_parse_expect_syntax_error(t, vm, fmt.tprintf("{{%s:1}}", text))
    }
}

@(test)
json_parse_valid_strings_and_whitespace :: proc(t: ^testing.T) {
    cases := []string{
        `JSON.parse('"\\b\\f\\n\\r\\t"') === '\b\f\n\r\t'`,
        `JSON.parse('"\\u0000\\u001f"') === '\x00\x1f'`,
        `JSON.parse('{"\\u0001":"\\u001f"}')['\x01'] === '\x1f'`,
        `var s = ''; for (var i = 0; i < 32; i++) s += String.fromCharCode(i); JSON.parse(JSON.stringify(s)) === s`,
        `JSON.parse('"é😀"') === 'é😀'`,
        `JSON.parse('"\u2028\u2029"') === '\u2028\u2029'`,
        `JSON.parse('"\\ud83d\\ude00"') === '\ud83d\ude00'`,
        `JSON.parse('"\\ud800"').charCodeAt(0) === 0xd800`,
        `JSON.parse(' \t\r\n{ "a" \t:\n [1,\r 2] }\t ').a[1] === 2`,
    }
    for src in cases { v, ok := run(src).(bool); testing.expect(t, ok && v, src) }
}
