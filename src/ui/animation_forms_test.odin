package ui

import "core:testing"
import htmlp "../html"
import csspkg "../css"

@(test)
animation_timing_direction_fill :: proc(t: ^testing.T) {
    c := test_compute_anim(".x{animation: Fade 2s 1s 2.5 alternate-reverse both cubic-bezier(0, 0, 1, 1)}@keyframes Fade{from{opacity:0}to{opacity:1}}", "div", "x")
    testing.expect(t, c.anim.active && c.anim.reverse && c.anim.alternate)
    testing.expect(t, c.anim.fill_before && c.anim.fill_after)
    testing.expect(t, abs(test_eval_anim(&c.anim, 0).op - 1) < 0.01, "backwards uses reversed start")
    testing.expect(t, abs(test_eval_anim(&c.anim, 1.5).op - 0.75) < 0.01, "bezier commas survive shorthand parsing")
    testing.expect(t, abs(test_eval_anim(&c.anim, 8).op - 0.5) < 0.01, "fractional final iteration")
}

@(test)
animation_longhand_and_no_fill :: proc(t: ^testing.T) {
    c := test_compute_anim(".x{animation:fade 2s 1s;animation-timing-function:steps(4, end);animation-direction:reverse;animation-play-state:paused}@keyframes fade{from{opacity:0}to{opacity:1}}", "div", "x")
    testing.expect(t, c.anim.paused && c.anim.reverse)
    testing.expect(t, !test_eval_anim(&c.anim, 0).has_op, "no backwards fill by default")
    testing.expect(t, !test_eval_anim(&c.anim, 4).has_op, "no forwards fill by default")
    testing.expect(t, abs(test_eval_anim(&c.anim, 1.4).op - 0.75) < 0.01, "steps longhand governs interpolation")
}

@(test)
animation_names_case_sensitive :: proc(t: ^testing.T) {
    c := test_compute_anim(".x{animation:fade 2s}@keyframes Fade{from{opacity:0}to{opacity:1}}", "div", "x")
    testing.expect(t, !c.anim.active)
}

@(test)
animation_zero_iterations :: proc(t: ^testing.T) {
    c := test_compute_anim(".x{animation:fade 2s 0}@keyframes fade{from{opacity:0}to{opacity:1}}", "div", "x")
    testing.expect(t, !c.anim.active, "zero iterations must not loop forever")
}

@(test)
animation_keyframe_timing_override :: proc(t: ^testing.T) {
    c := test_compute_anim(".x{animation:fade 2s linear}@keyframes fade{from{opacity:0;animation-timing-function:steps(2,end)}to{opacity:1}}", "div", "x")
    testing.expect(t, abs(test_eval_anim(&c.anim, 0.5).op) < 0.01, "keyframe curve overrides animation curve for its segment")
}

@(test)
forms_readonly_and_disabled_are_independent :: proc(t: ^testing.T) {
    doc := htmlp.parse("<html><body><input readonly value='copy'><input disabled value='off'><textarea readonly>copy</textarea><textarea disabled>off</textarea></body></html>")
    rules, _ := csspkg.parse("")
    styles, _ := compute_styles(doc, &rules)
    root := build_layout(doc, styles, "")
    defer free_layout(root)
    count := 0
    visit :: proc(b: ^Box, t: ^testing.T, count: ^int) {
        if b.ctrl == .Text || b.ctrl == .Textarea {
            count^ += 1
            ro := "readonly" in b.node.attrs
            testing.expect_value(t, b.ctrl_readonly, ro)
            testing.expect_value(t, b.ctrl_disabled, !ro)
            testing.expect(t, b.edit_buf[0] != 0, "both states retain their value")
        }
        for child in b.children do visit(child, t, count)
        for item in b.inlines {
            if item.kind == .InlineBox && item.box != nil do visit(item.box, t, count)
        }
    }
    visit(root, t, &count)
    testing.expect_value(t, count, 4)
}
