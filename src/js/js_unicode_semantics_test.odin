package js

import "core:testing"

@(private = "file")
unicode_expect :: proc(t: ^testing.T, source: string, loc := #caller_location) {
    vm := vm_create()
    defer vm_free(vm)
    result := vm_run(vm, source)
    testing.expectf(t, !vm.throwing && result == Value(true), "%s\nresult=%v throwing=%v", source, result, vm.throwing, loc = loc)
}

@(test)
unicode_string_surrogate_slices :: proc(t: ^testing.T) {
    unicode_expect(t, `var s = "\u{1F600}";
        s.slice(0,1) === "\uD83D" && s.slice(1) === "\uDE00" &&
        s.substring(1,0) === "\uD83D" && s.substr(1,1) === "\uDE00" &&
        s[0] === "\uD83D" && s[1] === "\uDE00" &&
        s.charAt(0) === "\uD83D" && s.at(-1) === "\uDE00"`)
}

@(test)
unicode_string_recombines_surrogates :: proc(t: ^testing.T) {
    unicode_expect(t, `var s = "a\u{1F600}b";
        var ok = true;
        for (var i=0; i<=s.length; i++) ok = ok && s.slice(0,i)+s.slice(i) === s;
        ok && ("\uD83D" + "\uDE00") === "\u{1F600}" &&
        ["\uD83D", "\uDE00"].join("") === "\u{1F600}" &&
        "\uD83D".concat("\uDE00").codePointAt(0) === 0x1F600`)
}

@(test)
unicode_string_search_code_units :: proc(t: ^testing.T) {
    unicode_expect(t, `var s = "x\u{1F600}x\u{1F600}";
        s.indexOf("\uDE00") === 2 && s.indexOf("",2) === 2 &&
        s.indexOf("\uD83D",2) === 4 && s.includes("\uDE00",2) &&
        !s.includes("\uD83D",5) && s.lastIndexOf("\uDE00",4) === 2 &&
        s.startsWith("\uDE00",2) && s.endsWith("\uD83D",2)`)
}

@(test)
unicode_string_split_and_padding :: proc(t: ^testing.T) {
    unicode_expect(t, `var s = "\u{1F600}";
        var a = s.split("");
        a.length === 2 && a[0] === "\uD83D" && a[1] === "\uDE00" &&
        a.join("") === s && s.split("\uDE00")[0] === "\uD83D" &&
        s.split("",0).length === 0 && s.split("",1).length === 1 &&
        "x".padStart(2,s) === "\uD83Dx" && "x".padEnd(4,s) === "x\u{1F600}\uD83D" &&
        "x".padStart(5,"") === "x"`)
}

@(test)
unicode_string_lone_surrogate_roundtrip :: proc(t: ^testing.T) {
    unicode_expect(t, `var s = "\uD800x\uDC00";
        s.slice(0,1).codePointAt(0) === 0xD800 && s.at(-1).charCodeAt(0) === 0xDC00 &&
        s.split("").join("") === s && JSON.parse(JSON.stringify(s)) === s &&
        !"\u{1F600}".slice(0,1).isWellFormed()`)
}

@(test)
unicode_string_iteration_preserves_surrogates :: proc(t: ^testing.T) {
    unicode_expect(t, `var s = "\uD800\u{1F600}\uDC00";
        var values = []; for (var ch of s) values.push(ch);
        var spread = [...s];
        function* chars() { yield* s; }
        values.length === 3 && values.join("") === s && spread.length === 3 &&
        spread[0] === "\uD800" && Array.from(s)[2] === "\uDC00" &&
        Array.from(chars()).join("") === s`)
}

@(test)
unicode_string_order_is_utf16 :: proc(t: ^testing.T) {
    unicode_expect(t, `"\u{1F600}" < "\uE000" && "\u{1F600}" <= "\uE000" &&
        "\uE000" > "\u{1F600}" && "\uE000" >= "\u{1F600}" &&
        ["\uE000", "\u{1F600}"].sort()[0] === "\u{1F600}"`)
}

@(test)
unicode_regex_code_units_and_points :: proc(t: ^testing.T) {
    unicode_expect(t, `var s = "\u{1F600}";
        /^..$/.test(s) && !/^.$/.test(s) && /^.$/u.test(s) &&
        /\uD83D/.exec(s)[0] === "\uD83D" && /\uDE00/.exec(s).index === 1 &&
        /\uD83D\uDE00/u.test(s) && /[\u{1F600}]/u.test(s)`)
}

@(test)
unicode_regex_indices_and_empty_matches :: proc(t: ^testing.T) {
    unicode_expect(t, `var s = "\u{1F600}", r = /./dg;
        var a = r.exec(s), b = r.exec(s);
        a[0] === "\uD83D" && b[0] === "\uDE00" && b.index === 1 &&
        a.indices[0][1] === 1 && b.indices[0][0] === 1 && r.lastIndex === 2 &&
        s.match(/(?:)/g).length === 3 && s.match(/(?:)/gu).length === 2 &&
        s.replace(/(?:)/g,"-") === "-\uD83D-\uDE00-" &&
        s.replace(/(?:)/gu,"-") === "-\u{1F600}-"`)
}

@(test)
unicode_regex_property_categories :: proc(t: ^testing.T) {
    unicode_expect(t, ` /\p{General_Category=Space_Separator}/u.test(" ") &&
        !/\p{Zs}/u.test("\t") && /\p{White_Space}/u.test("\t") &&
        /\p{Other}/u.test("\uE000") && !/\p{Control}/u.test("\uE000") &&
        /\p{Alphabetic}/u.test("\u0345") && !/\p{Letter}/u.test("\u0345") &&
        /\p{gc=Cs}/u.test("\uD800") && /\p{Assigned}/u.test("A")`)
}

@(test)
unicode_regex_script_extensions :: proc(t: ^testing.T) {
    unicode_expect(t, ` /\p{Script=Greek}/u.test("\u03B1") &&
        /\p{sc=Grek}/u.test("\u03B1") && !/\p{Script=Latin}/u.test("\u03B1") &&
        /\p{Script=Han}/u.test("\u{20000}") &&
        /\p{scx=Hira}/u.test("\u30FC") && !/\p{sc=Hira}/u.test("\u30FC") &&
        /\P{Script=Latin}/u.test("\u03B1")`)
}

@(test)
unicode_regex_binary_properties :: proc(t: ^testing.T) {
    unicode_expect(t, ` /\p{Emoji}/u.test("\u{1F600}") && /\p{ASCII_Hex_Digit}/u.test("F") &&
        !/\p{ASCII_Hex_Digit}/u.test("G") && /\p{ID_Start}/u.test("\u03B1") &&
        /\p{Default_Ignorable_Code_Point}/u.test("\u200D")`)
}

@(test)
unicode_regex_property_case_folding :: proc(t: ^testing.T) {
    unicode_expect(t, `/\P{Lowercase_Letter}/iu.test("a") && !/\P{Lowercase_Letter}/iv.test("a") &&
        /\p{Uppercase_Letter}/iu.test("\u{10597}") && /[\u03C2]/iu.test("\u03C3")`)
}

@(test)
unicode_regex_emoji_strings :: proc(t: ^testing.T) {
    unicode_expect(t, `var family = "\u{1F468}\u200D\u{1F469}\u200D\u{1F467}";
        /^\p{RGI_Emoji}$/v.test(family) && /\p{RGI_Emoji}/v.exec(family)[0] === family &&
        /^\p{RGI_Emoji_Flag_Sequence}$/v.test("\u{1F1E7}\u{1F1F7}") &&
        /^[\p{RGI_Emoji}--\q{\u{1F600}}]$/v.test(family) &&
        !/^[\p{RGI_Emoji}--\q{\u{1F600}}]$/v.test("\u{1F600}")`)
}

@(test)
unicode_regex_invalid_properties_rejected :: proc(t: ^testing.T) {
    unicode_expect(t, `function invalid(s,f) {try {new RegExp(s,f); return false;} catch(e) {return e.name === "SyntaxError";}}
        invalid("\\p{letter}","u") && invalid("\\p{Script=greek}","u") &&
        invalid("\\p{Latin}","u") && invalid("\\p{Script=Hrkt}","u") && invalid("\\p{Block=ASCII}","u") &&
        invalid("\\p{RGI_Emoji}","u") && invalid("\\P{RGI_Emoji}","v") &&
        invalid("[^\\p{RGI_Emoji}]","v") && invalid("\\p{garbage}","u") &&
        /\p{L}/.test("p{L}")`)
}

@(test)
unicode_regex_property_literal_is_early_error :: proc(t: ^testing.T) {
    unicode_expect(t, `var ran = false, syntax = false;
        try {eval("ran = true; /\\p{garbage}/u");} catch(e) {syntax = e.name === "SyntaxError";}
        syntax && !ran`)
}
