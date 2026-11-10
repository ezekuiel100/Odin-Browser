package ui

import "core:testing"
import "core:time"
import "core:strings"
import im "../../vendor/imgui"

// Reservation tests do not start threads or need an ImGui context.
@(test)
test_font_retry_recovers_and_is_bounded :: proc(t: ^testing.T) {
    saved := g_faces
    g_faces = nil
    defer {
        for f in g_faces { delete(f.url); delete(f.payload) }
        delete(g_faces)
        g_faces = saved
    }
    now := time.tick_now()
    idx, result := fontface_reserve(1, 400, false, "regular.ttf", now)
    testing.expect(t, idx == 0 && result == .Start)
    g_faces[idx].state = .Failed
    _, too_soon := fontface_reserve(1, 400, false, "regular.ttf", now)
    testing.expect(t, too_soon == .Deferred, "restyles must not start a request storm")
    for attempt in 2 ..= FONT_MAX_ATTEMPTS {
        now = time.tick_add(now, FONT_RETRY_DELAY)
        retry, state := fontface_reserve(1, 400, false, "regular.ttf", now)
        testing.expect(t, retry == idx && state == .Start)
        testing.expect_value(t, len(g_faces), 1)
        testing.expect_value(t, g_faces[idx].attempts, attempt)
        g_faces[idx].state = .Failed
    }
    now = time.tick_add(now, FONT_RETRY_DELAY)
    _, exhausted := fontface_reserve(1, 400, false, "regular.ttf", now)
    testing.expect(t, exhausted == .Deferred)
    // Correcting the stylesheet URL must not inherit the old URL's failures.
    replaced, state := fontface_reserve(1, 400, false, "fixed.ttf", now)
    testing.expect(t, replaced == idx && state == .Start)
    testing.expect_value(t, g_faces[idx].attempts, 1)
    testing.expect_value(t, g_faces[idx].url, "fixed.ttf")
}

@(test)
test_font_capacity_counts_live_faces_and_reuses_failures :: proc(t: ^testing.T) {
    saved := g_faces
    g_faces = nil
    defer {
        for f in g_faces { delete(f.url); delete(f.payload) }
        delete(g_faces)
        g_faces = saved
    }
    now := time.tick_now()
    for i in 0 ..< MAX_FACES {
        _, state := fontface_reserve(u8(i + 1), 400, false, "font.ttf", now)
        testing.expect(t, state == .Start, "more than the old twelve-face limit must fit")
    }
    _, existing := fontface_reserve(1, 400, false, "font.ttf", now)
    testing.expect(t, existing == .Existing, "check duplicates before capacity")
    _, full := fontface_reserve(200, 700, false, "bold.ttf", now)
    testing.expect(t, full == .Limit)
    g_faces[4].state = .Failed
    idx, reused := fontface_reserve(200, 700, false, "bold.ttf", now)
    testing.expect(t, idx == 4 && reused == .Start, "a failed download must not block a new face")
    testing.expect_value(t, len(g_faces), MAX_FACES)
    testing.expect_value(t, g_faces[4].weight, 700)
    // Installed payloads and font pointers survive unrelated reservations.
    testing.expect_value(t, g_faces[0].url, "font.ttf")
}

@(test)
test_font_three_variants_choose_their_own_face :: proc(t: ^testing.T) {
    saved := g_faces
    faces := [3]im.Font{}
    g_faces = make([dynamic]Loaded_Face)
    defer { delete(g_faces); g_faces = saved }
    append(&g_faces, Loaded_Face{fam_id=1, weight=400, state=.Ready})
    append(&g_faces, Loaded_Face{fam_id=1, weight=700, state=.Ready})
    append(&g_faces, Loaded_Face{fam_id=1, weight=400, italic=true, state=.Ready})
    for &f, i in g_faces do f.fonts[0] = &faces[i]
    regular, _ := fontface_pick(1, 400, false, 0)
    bold, _ := fontface_pick(1, 700, false, 0)
    italic, _ := fontface_pick(1, 400, true, 0)
    testing.expect(t, regular == &faces[0] && bold == &faces[1] && italic == &faces[2])
}

@(test)
test_font_log_hides_embedded_payloads :: proc(t: ^testing.T) {
    testing.expect_value(t, font_log_url("data:font/ttf;base64,SECRET"), "data:<embedded font>")
    long := strings.repeat("x", 300, context.temp_allocator)
    testing.expect_value(t, len(font_log_url(long)), 180)
}
@(test)
test_font_automatic_retry_only_for_transient_failures :: proc(t: ^testing.T) {
    now := time.tick_now()
    f := Loaded_Face{state=.Failed, retryable=true, attempts=1, last_attempt=now}
    testing.expect(t, !fontface_retry_due(&f, now))
    later := time.tick_add(now, FONT_RETRY_DELAY)
    testing.expect(t, fontface_retry_due(&f, later))
    f.retryable = false // decoding errors and HTTP 404 do not get automatic retries
    testing.expect(t, !fontface_retry_due(&f, later))
    f.retryable = true
    f.attempts = FONT_MAX_ATTEMPTS
    testing.expect(t, !fontface_retry_due(&f, later))
    f.attempts = 1
    f.state = .Ready
    testing.expect(t, !fontface_retry_due(&f, later))
}