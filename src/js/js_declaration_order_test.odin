package js

import "core:testing"
import dom "../dom"
import html "../html"

@(test)
style_css_text_keeps_winning_declaration_order :: proc(t: ^testing.T) {
    root := html.parse(`<div id="x"></div>`)
    defer dom.free_tree(root)
    result := run_with_dom(`
        var s = document.getElementById('x').style;
        s.cssText = 'margin-left: 1px; padding: 3px; margin-left: 5px !important; color: red; margin-left: 9px';
        var ok = s.cssText === 'padding: 3px; margin-left: 5px !important; color: red';
        s.color = 'blue';
        ok && s.cssText === 'padding: 3px; margin-left: 5px !important; color: blue';
    `, root)
    ok, _ := result.(bool)
    testing.expect(t, ok, "cssText and setters must keep the position of each effective declaration")
}

@(test)
style_property_update_keeps_position_after_duplicate_parse :: proc(t: ^testing.T) {
    root := html.parse(`<div id="x" style="margin-left:1px;padding:3px;margin-left:5px"></div>`)
    defer dom.free_tree(root)
    result := run_with_dom(`
        var s = document.getElementById('x').style;
        s.setProperty('padding', '7px');
        var ok = s.cssText === 'padding: 7px; margin-left: 5px';
        ok = ok && s.removeProperty('padding') === '7px';
        ok && s.cssText === 'margin-left: 5px';
    `, root)
    ok, _ := result.(bool)
    testing.expect(t, ok, "updating/removing another property must not restore an earlier duplicate")
}
