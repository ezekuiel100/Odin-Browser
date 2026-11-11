package js

import "core:testing"

@(test)
cssom_shared_token_boundaries :: proc(t: ^testing.T) {
    testing.expect(t, run(`CSS.supports('(content: "a) and (b")')`).(bool))
    testing.expect(t, run(`CSS.supports('content: fn(";}")')`).(bool))
    testing.expect(t, !run(`CSS.supports('content: fn([)]')`).(bool))
    testing.expect(t, !run(`CSS.supports('content: red; color: blue')`).(bool))
    testing.expect(t, run(`CSS.supports('(/* ) */ content: "(;")')`).(bool))
}
