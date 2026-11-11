package net

import "core:testing"

@(test)
data_uri_svg_percent_bytes :: proc(t: ^testing.T) {
    r := fetch("data:image/svg+xml;utf8,%3Csvg%20viewBox%3D%220%200%2024%2024%22%3E%3C%2Fsvg%3E")
    defer delete(r.body)
    testing.expect(t, r.ok)
    testing.expect_value(t, r.body, `<svg viewBox="0 0 24 24"></svg>`)
    plain := fetch("data:text/plain,a+b%20c%25%ZZ")
    defer delete(plain.body)
    testing.expect_value(t, plain.body, "a+b c%%ZZ")
}

@(test)
data_uri_escaped_base64 :: proc(t: ^testing.T) {
    r := fetch("data:text/plain;base64,YQ%3D%3D")
    defer delete(r.body)
    testing.expect(t, r.ok)
    testing.expect_value(t, r.body, "a")
}
