package ui

import "core:testing"
import "core:fmt"
import css "../css"
import dom "../dom"
import html "../html"
import js "../js"

@(test)
css_effects_invalid_grammars :: proc(t: ^testing.T) {
    cases := [][2]string{
        {"box-shadow", "1px"}, {"box-shadow", "0 0 -2px red"},
        {"box-shadow", "0 red 0"}, {"box-shadow", "0 0 red blue"},
        {"box-shadow", "inset inset 0 0"}, {"box-shadow", "0 0,"},
        {"text-shadow", "inset 0 0"}, {"text-shadow", "0 0 1px 2px"},
        {"transform", "translate(2px) garbage"}, {"transform", "scale(1,2,3)"},
        {"transform", "translate(1px,)"}, {"transform", "matrix(1,0,0,1,0)"},
        {"transform", "rotate(10px)"}, {"transform", "translateZ(10%)"},
        {"transform", "unknown(1)"}, {"transform", "rotate3d(1,0,0)"},
        {"translate", "1px 2px 3%"}, {"scale", "1px"}, {"rotate", "x y 2deg"},
        {"animation", "slide -1s"}, {"animation", "slide 1s 2s 3s"},
        {"animation", "slide other 1s"}, {"animation", "slide 1s,"},
        {"transition", "none, opacity 1s"}, {"transition", "opacity -1s"},
        {"transition", "opacity 1s 2s 3s"}, {"transition", "opacity transform 1s"},
        {"animation-name", "slide other"}, {"transition-property", "opacity,"},
        {"background", "red blue"}, {"background", "red, url(a.png)"},
        {"background", "url(a) / cover"}, {"background", "center /"},
        {"background", "center / cover auto"}, {"background", "fixed local"},
        {"background", "left left"}, {"background", "url(a) url(b)"},
        {"background-image", "url(a) nonsense"}, {"background-image", "url(a b)"},
        {"background-image", "url(a),"}, {"background-size", "-1px auto"},
        {"background-size", "cover contain"}, {"background-repeat", "repeat-x no-repeat"},
        {"background-position", "left right"}, {"background-origin", "content-box bogus"},
        {"width", "calc(1px + 2)"}, {"width", "calc(2)"},
        {"width", "calc(1px+2px)"}, {"width", "calc(1px * 2px)"},
        {"width", "calc(10px / 2px)"}, {"width", "min(1px, 2)"},
        {"padding-inline", "1px -2px"}, {"inline-size", "banana"},
        {"-webkit-transform", "translate(1px) garbage"},
        {"font", "italic 20px"}, {"font", "bold bold 16px Arial"},
        {"font", "16px/ Arial"}, {"font", "16px/-1 Arial"},
        {"font-family", "Arial,"}, {"font-family", "Arial serif"},
    }
    for c in cases {
        valid, checked := css_value_valid(c[0], c[1])
        testing.expectf(t, checked && !valid, "invalid value accepted %v", c)
        testing.expectf(t, !css_supports_decl(c[0], c[1]), "support false positive %v", c)
        testing.expectf(t, !css.supports_condition(fmt.tprintf("(%s:%s)", c[0], c[1])), "@supports false positive %v", c)
        d := css.parse_decls(fmt.tprintf("%s:initial; %s:%s !important", c[0], c[0], c[1]), context.temp_allocator)
        testing.expectf(t, d[c[0]] == "initial", "invalid duplicate won %v", c)
    }
}

@(test)
css_effects_valid_grammars :: proc(t: ^testing.T) {
    cases := [][2]string{
        {"box-shadow", "inset 0 -2px 3px -4px rgb(1 2 3 / .5), 0 0 blue"},
        {"text-shadow", "red 0 0 2px, 1px -1px currentColor"},
        {"transform", "translate(10%, calc(2px * 3))rotate(1turn) scale(-1, 2)"},
        {"transform", "matrix(1,0,0,1,2,3) perspective(200px) rotate3d(1,0,0,30deg)"},
        {"translate", "10% 20px -3px"}, {"scale", "-1 150%"}, {"rotate", "1 0 0 30deg"},
        {"animation", "slide 1s ease-in -200ms 2 alternate both paused, fade .5s"},
        {"animation", "reverse reverse 2s"}, {"animation", "\"ease\" 2s"},
        {"transition", "opacity 1s ease -200ms, transform 2s steps(2, end)"},
        {"transition", "none"}, {"animation-name", "none, slide"},
        {"background", "url(a.png) left top / 20px auto no-repeat padding-box border-box red"},
        {"background", "url(a), linear-gradient(red, blue) center / cover fixed #fff"},
        {"background", "transparent"}, {"background-image", "url(\"a b.png\"), none"},
        {"background-size", "auto 40%, cover"}, {"background-repeat", "space round, repeat-x"},
        {"background-position", "right 10px bottom 20px, center"},
        {"width", "calc((2 + 1) * 10px)"}, {"width", "min(50%, 200px)"},
        {"padding-inline", "1px 2%"}, {"inline-size", "max-content"},
        {"-webkit-transform", "translate(1px)"},
        {"font", "italic small-caps 700 condensed 20px/1.5 \"Open Sans\", Arial"},
        {"font-family", "Open Sans, sans-serif"},
        {"font-family", "\"2ch env(foo)\""}, {"background-image", "url(\"2ch-env(foo)\")"},
        {"background-position", "center right 10px"},
    }
    for c in cases {
        valid, checked := css_value_valid(c[0], c[1])
        testing.expectf(t, valid && checked, "valid grammar rejected %v", c)
        testing.expectf(t, css_supports_decl(c[0], c[1]), "valid support rejected %v", c)
        d := css.parse_decls(fmt.tprintf("%s:%s", c[0], c[1]), context.temp_allocator)
        testing.expectf(t, len(d) == 1, "valid declaration rejected %v", c)
    }
}

@(test)
css_effects_cssom_and_cascade :: proc(t: ^testing.T) {
    root := html.parse(`<div id="x" style="transform:translateX(12px);box-shadow:0 0 red;animation:slide 1s"></div>`)
    defer dom.free_tree(root)
    r := js.run_with_dom(`var s=document.getElementById('x').style;
        s.transform='translateX(20px) garbage'; s.boxShadow='0 0 -1px';
        s.setProperty('animation','slide -1s');
        s.transform==='translateX(12px)' && s.boxShadow==='0 0 red' && s.animation==='slide 1s'
            && !CSS.supports('transform','scale(1,2,3)') && CSS.supports('box-shadow','0 0 red');`, root)
    testing.expect(t, r == true)
    c := declaration_order_compute(`.x { transform:translateX(12px); box-shadow:1px 0 red }
        .x { transform:translateX(20px) garbage !important; box-shadow:0 0 -1px !important }`)
    testing.expect_value(t, c.transform_tx, 12)
    testing.expect_value(t, c.shadow_n, 1)
    d := declaration_order_compute(`.x {--bad:0 0 -1px; box-shadow:0 0 red; box-shadow:var(--bad)}`)
    testing.expect_value(t, d.shadow_n, 0)
}
