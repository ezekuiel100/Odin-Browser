package js

import "core:testing"
import dom "../dom"

@(test)
stylesheet_owner_rules_and_mutations :: proc(t: ^testing.T) {
    root := dom.make_node(.Document)
    defer dom.free_tree(root)
    vm := vm_create_with_dom(root)
    defer vm_free(vm)
    r := vm_run(vm, `
        var el = document.createElement('style');
        el.textContent = '.a { color: red; }';
        var sheet = el.sheet, live = sheet.cssRules;
        var a = [sheet === el.sheet, sheet instanceof CSSStyleSheet,
                 sheet.ownerNode === el, live.length];
        a.push(sheet.insertRule('@media (min-width: 1px) { .b { content: "};"; } }', 0));
        a.push(live.length, live[1].cssText.indexOf('.a') >= 0,
               el.textContent.indexOf('@media') >= 0);
        sheet.deleteRule(1);
        a.push(live.length, el.textContent.indexOf('.a') < 0);
        el.textContent = '.c { color: blue }';
        a.push(sheet.cssRules === live, live[0].cssText.indexOf('.c') >= 0);
        try { sheet.insertRule('.x {}', 9); } catch(e) { a.push(e.name); }
        try { sheet.insertRule('invalid'); } catch(e) { a.push(e.name); }
        try { sheet.insertRule('.a {} .b {'); } catch(e) { a.push(e.name); }
        var constructed = new CSSStyleSheet();
        constructed.insertRule('/* before */ .x { color: red } /* after */');
        a.push(constructed.cssRules.length, constructed.ownerNode === null);
        a.join('|');
    `)
    testing.expect_value(t, r.(string), "true|true|true|1|0|2|true|true|1|true|true|true|IndexSizeError|SyntaxError|SyntaxError|1|true")
    testing.expect_value(t, vm.uncaught_total, 0)
    testing.expect_value(t, vm.cssom_revision, u64(2))
}
