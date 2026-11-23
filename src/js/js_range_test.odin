package js

import "core:strings"
import "core:testing"
import dom "../dom"

@(private = "file")
range_eval :: proc(t: ^testing.T, source: string) -> string {
    root := dom.make_node(.Document)
    defer dom.free_tree(root)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    result := vm_run(vm, source)
    testing.expect(t, !vm.throwing)
    s, _ := result.(string)
    return strings.clone(s, context.temp_allocator)
}

@(test)
range_reddit_fragment :: proc(t: ^testing.T) {
    testing.expect_value(t, range_eval(t, `
        var r = document.createRange();
        var f = r.createContextualFragment('<shreddit-app-attrs count="2"></shreddit-app-attrs><p>A &amp; B</p>');
        var host = document.createElement('div');
        var first = f.firstChild;
        var before = [f.nodeType, f.children.length, f.parentNode === null,
                      r.startContainer === document, r.collapsed].join('|');
        host.appendChild(f);
        before + '|' + host.children.length + '|' + f.childNodes.length + '|' +
            (first === host.firstChild) + '|' + host.textContent;
    `), "11|2|true|true|true|2|0|true|A & B")
}

@(test)
range_context_table_and_svg :: proc(t: ^testing.T) {
    testing.expect_value(t, range_eval(t, `
        var r = document.createRange();
        var table = document.createElement('table');
        r.selectNodeContents(table);
        var f = r.createContextualFragment('<tr><td>x</td></tr>');
        var host = document.createElement('div'); host.appendChild(f);
        var a = host.innerHTML;
        host.innerHTML = '<svg></svg>';
        var svg = host.firstChild;
        r.selectNodeContents(svg);
        // tagName preserves case for foreign elements; namespaceURI's legacy
        // getter in this browser still only special-cases the svg root.
        var b = r.createContextualFragment('<circle cx="2"/>').firstChild.tagName;
        a + '|' + b + '|' + table.childNodes.length;
    `), "<tbody><tr><td>x</td></tr></tbody>|circle|0")
}

@(test)
range_text_context_and_offsets :: proc(t: ^testing.T) {
    testing.expect_value(t, range_eval(t, `
        var p = document.createElement('p');
        p.textContent = 'a\uD83D\uDE00';
        var r = document.createRange();
        r.selectNodeContents(p.firstChild);
        var f = r.createContextualFragment('<b>ok</b>');
        var host = document.createElement('div'); host.appendChild(f);
        [r.startOffset, r.endOffset, r.collapsed, host.innerHTML,
         r.commonAncestorContainer === p.firstChild].join('|');
    `), "0|3|false|<b>ok</b>|true")
}

@(test)
range_detached_document_conversion_and_errors :: proc(t: ^testing.T) {
    testing.expect_value(t, range_eval(t, `
        var d = document.implementation.createHTMLDocument('test');
        var r = d.createRange();
        var f = r.createContextualFragment({toString: function(){return '<em>ok</em>'}});
        var missing = false, invalid = false;
        try { r.createContextualFragment(); } catch(e) { missing = e.name === 'TypeError'; }
        try { r.selectNodeContents(null); } catch(e) { invalid = e.name === 'TypeError'; }
        var host = d.createElement('div'); host.appendChild(f);
        [r.startContainer === d, host.innerHTML, missing, invalid,
         r.createContextualFragment('').childNodes.length].join('|');
    `), "true|<em>ok</em>|true|true|0")
}
