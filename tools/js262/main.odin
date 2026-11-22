package main

import "core:os"
import js "../../src/js"

main :: proc() {
    first := 1
    if len(os.args) > 1 && os.args[1] == "--js262" do first = 2
    os.exit(js.js262_main(os.args[first:]))
}
