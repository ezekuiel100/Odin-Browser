package ui

import "core:testing"
import htmlpkg "../html"
import dompkg "../dom"
import jspkg "../js"
import csspkg "../css"

@(test)
selector_invalid_rules_and_support_queries :: proc(t: ^testing.T) {
    c := test_compute_one(`div { width: 123px }
        div, :made-up { width: 999px }
        div > { width: 888px }
        div.x:is() { width: 777px }
        @supports selector(div >) { div { width: 666px } }
        @supports selector([data-x="a),b]"]) { div { color: red } }`)
    testing.expect_value(t, c.width, 123)
    testing.expect_value(t, c.color, 0xff0000)
    testing.expect(t, csspkg.supports_selector("[x='ABC' i]"))
    testing.expect(t, !sup_js(t, `CSS.supports('selector(div >)')`))
    testing.expect(t, sup_js(t, `CSS.supports('selector(:scope > .x)')`))
}

@(test)
selector_dom_queries :: proc(t: ^testing.T) {
    root := htmlpkg.parse(`<main id="m"><div id="a" class="x" data-x="a],b)"><span class="x"></span></div><div id="b" class="x"></div></main>`)
    defer dompkg.free_tree(root)
    scripts := []string{
        `document.getElementById('m').querySelectorAll(':scope > .x').length === 2`,
        `document.getElementById('m').querySelector(':scope') === null`,
        `document.getElementById('a').matches(':scope')`,
        `document.getElementById('a').closest('main').id === 'm'`,
        `document.createElement('div').matches('div')`,
        `document.getElementById('a').closest(':scope.x') === document.getElementById('a')`,
        `document.querySelector('span').closest(':scope.x#a') === null`,
        `!document.getElementById('a').matches('div::before')`,
        `document.querySelector('div::before') === null`,
        `document.createElement('div').matches(':scope')`,
        `document.querySelectorAll('.x, #a').length === 3`,
        `document.querySelectorAll(':is(.x):is(#b)').length === 1`,
        `document.querySelectorAll(':is(:is(.x))').length === 3`,
        `document.querySelectorAll('.x:is()').length === 0`,
        `document.querySelectorAll(':is([data-x=\"a],b)\"], #b)').length === 2`,
        `document.querySelectorAll(':is(.x, :made-up)').length === 3`,
        `document.querySelectorAll('[data-x="a],b)"]').length === 1`,
        `document.getElementById('m').querySelectorAll(':is(:scope) > .x').length === 2`,
        `document.querySelector(':scope') === document.querySelector('main')`,
    }
    for script in scripts {
        result := jspkg.run_with_dom(script, root)
        ok, _ := result.(bool)
        testing.expectf(t, ok, "query failed: %s (got %v)", script, result)
    }
}

@(test)
selector_dom_syntax_errors :: proc(t: ^testing.T) {
    root := htmlpkg.parse(`<div id="a"></div>`)
    defer dompkg.free_tree(root)
    scripts := []string{
        `var caught = ''; try { document.querySelector('div >'); } catch(e) { caught = e.name; } caught === 'SyntaxError'`,
        `var caught = ''; try { document.querySelectorAll('div,'); } catch(e) { caught = e.name; } caught === 'SyntaxError'`,
        `var caught = ''; try { document.getElementById('a').matches(':made-up'); } catch(e) { caught = e.name; } caught === 'SyntaxError'`,
        `var caught = ''; try { document.getElementById('a').closest('['); } catch(e) { caught = e.name; } caught === 'SyntaxError'`,
    }
    for script in scripts {
        result := jspkg.run_with_dom(script, root)
        ok, _ := result.(bool)
        testing.expectf(t, ok, "missing SyntaxError: %s (got %v)", script, result)
    }
}

@(test)
selector_filtered_nth_and_has_scope :: proc(t: ^testing.T) {
    root := htmlpkg.parse(`<main id="m"><div id="a" class="x"><span></span></div><i></i><div id="b" class="x"></div><div id="c" class="x"></div></main>`)
    defer dompkg.free_tree(root)
    scripts := []string{
        `document.querySelector(':nth-child(2 of .x)').id === 'b'`,
        `document.querySelector(':nth-last-child(2 of .x)').id === 'b'`,
        `document.querySelectorAll(':nth-child(-n + 2 of .x, i)').length === 2`,
        `document.getElementById('m').querySelector(':nth-child(2 of :scope > .x)').id === 'b'`,
        `document.getElementById('a').matches(':has(> :is(:scope > span))')`,
        `document.getElementById('m').querySelectorAll('div:has(> :is(:scope > span))').length === 0`,
        `!CSS.supports('selector(:nth-of-type(2 of .x))')`,
        `!CSS.supports('selector(:nth-child(2 of ))')`,
    }
    for script in scripts {
        result := jspkg.run_with_dom(script, root)
        ok, _ := result.(bool)
        testing.expectf(t, ok, "%s: %v", script, result)
    }
}
