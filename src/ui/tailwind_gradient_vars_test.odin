package ui

import "core:testing"

@(test)
tailwind_gradient_resolves_all_stop_variables :: proc(t: ^testing.T) {
    c := test_apply("background-image: linear-gradient(var(--tw-gradient-stops))", `
        --color-violet-500: oklch(60.6% .25 292.717);
        --color-violet-600: oklch(54.1% .281 293.009);
        --tw-gradient-via-stops: initial;
        --tw-gradient-position: to bottom in oklab;
        --tw-gradient-from: var(--color-violet-500);
        --tw-gradient-to: var(--color-violet-600);
        --tw-gradient-from-position: 0%;
        --tw-gradient-to-position: 100%;
        --tw-gradient-stops: var(--tw-gradient-via-stops,var(--tw-gradient-position),var(--tw-gradient-from)var(--tw-gradient-from-position),var(--tw-gradient-to)var(--tw-gradient-to-position));
    `)
    testing.expect(t, c.grad.active, "Tailwind button gradient must paint")
    testing.expect_value(t, c.grad.n, 2)
}
