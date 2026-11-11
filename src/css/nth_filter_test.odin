package css

import "core:testing"

@(test)
nth_filter_specificity_and_validation :: proc(t:^testing.T) {
    for selector in ([]string{":nth-child(2n of .x, #y)", ":nth-last-child(-n + 3 of :is(.a,.b))", ":nth-child(1\tof\t.x)"}) {
        testing.expectf(t,supports_selector(selector),"rejected %s",selector)
    }
    for selector in ([]string{":nth-child(2 of)", ":nth-child(2 of .x,)", ":nth-child(2 of :unknown)", ":nth-of-type(2 of .x)"}) {
        testing.expectf(t,!supports_selector(selector),"accepted %s",selector)
    }
    sel,ok:=parse_complex(":nth-child(2n of .x, #y)")
    testing.expect(t,ok)
    defer free_selector(&sel)
    testing.expect_value(t,sel.specificity,([3]int{1,1,0}))
}
