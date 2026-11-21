#+build !windows
package js

import "core:strings"

// The browser targets Windows; retain the old fallback for standalone JS builds.
collation_compare :: proc(vm: ^Interp, o: Collation_Options, x, y: string, resolved: ^Collation_Options = nil) -> Value {
    a, b := x, y
    if o.sensitivity == "base" || o.sensitivity == "accent" {
        a = strings.to_lower(x, context.temp_allocator)
        b = strings.to_lower(y, context.temp_allocator)
    }
    return f64(strings.compare(a, b))
}
