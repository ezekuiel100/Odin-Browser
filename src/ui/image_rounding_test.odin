package ui

import "core:testing"
import im "../../vendor/imgui"

@(test)
image_radius_normalization :: proc(t: ^testing.T) {
    ellipse := image_rounding(120, 60, {0.5, 0.5, 0.5, 0.5}, {true, true, true, true})
    testing.expect(t, ellipse.rx[0] == 60 && ellipse.ry[0] == 30, "percentages resolve independently on each axis")
    full := image_rounding(120, 60, {3.40282e38, 3.40282e38, 3.40282e38, 3.40282e38}, {})
    testing.expect(t, abs(full.rx[0]-30) < 0.001 && abs(full.ry[0]-30) < 0.001, "rounded-full must not overflow to zero")
    mixed := image_rounding(100, 100, {80, 40, 0, 0}, {})
    testing.expect(t, abs(mixed.rx[0]-66.6667) < 0.001 && abs(mixed.rx[1]-33.3333) < 0.001, "overlap scales all corners by the same factor")
    inset := image_rounding(100, 100, {30, 30, 30, 30}, {}, {5, 10, 15, 20})
    testing.expect(t, inset.rx[0] == 10 && inset.ry[0] == 25 && inset.rx[2] == 20 && inset.ry[2] == 15, "content curve subtracts border and padding on the matching side")
}

@(test)
image_radius_polygon_clip :: proc(t: ^testing.T) {
    r := image_rounding(100, 100, {0.5, 0.5, 0.5, 0.5}, {true, true, true, true})
    pts: [160]im.Vec2
    n := image_round_polygon({0, 0}, {100, 100}, r, {20, 30}, {80, 90}, &pts)
    testing.expect(t, n >= 3, "partial clip retains a polygon")
    for p in pts[:n] {
        testing.expect(t, p.x >= 19.999 && p.x <= 80.001 && p.y >= 29.999 && p.y <= 90.001, "all vertices stay inside the image/viewport intersection")
        testing.expect(t, (p.x-50)*(p.x-50)+(p.y-50)*(p.y-50) <= 2500.1, "clipping preserves the original circle")
    }
    testing.expect(t, image_round_polygon({0, 0}, {100, 100}, r, {0, 0}, {4, 4}, &pts) == 0, "visible rectangle entirely outside curve paints nothing")
    testing.expect(t, image_round_polygon({0, 0}, {100, 100}, r, {110, 0}, {100, 100}, &pts) == 0, "fully scrolled out image paints nothing")
}
