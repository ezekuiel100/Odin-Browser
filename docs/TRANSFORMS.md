# Transform composition and projection

The parser retains the original transform operations in an owned `XList`. Layout still receives the scalar compatibility fields and symbolic width/height translation coefficients. Paint resolves the list against the final border box and applies its 4x4 product in CSS order. Individual translate, rotate and scale properties precede the transform list.

Transitions and keyframes interpolate matching translations, scales, skew angles, perspective coefficients and rotations. Matching rotations retain their winding, including 360-degree spins. Incompatible lists interpolate their remaining matrix product through affine decomposition; 2D reflection handling and 3D quaternion rotation avoid a linear blend of matrix entries. Singular decompositions change discretely. Interrupted transitions snapshot the displayed matrix, and transition-owned lists survive style reconstruction.

Projection retains homogeneous coordinates between participating preserve-3d elements. A flat boundary removes depth before the ancestor projection. `perspective()` affects its transform list; the `perspective` property applies to descendants around `perspective-origin`. Origins retain percentages, pixel offsets, calc terms and the transform-origin Z offset.

Within a preserve-3d stacking scope, planes paint from far to near using transformed center depth, with document order retained at equal depths. Parent rotation and sampled keyframes participate in this depth calculation. Opacity, filters, overflow clips and other grouping effects flatten the context.

Box and inline-block interaction and DOM rectangles share a composed geometry traversal with ancestor transforms, origins, perspective, scrolling, fixed/sticky positioning and sampled keyframes. Zero-area planes reject pointer hits. Layout metrics such as offsetWidth remain untransformed.

## Current limits

- Ordering uses plane centers and treats nested stacking scopes atomically. Intersecting planes need polygon splitting, and nested preserve-3d scopes need a shared 3D display list. `@supports (transform-style: preserve-3d)` therefore remains false.
- Triangles crossing the eye plane are discarded rather than clipped into new polygons.
- The SDL renderer interpolates texture coordinates affinely within each triangle; strongly tilted images do not have perspective-correct texture sampling.
- Box pointer targets invert the projected border plane, and DOM bounding rectangles enclose its transformed corners. Inline link/decorations/opacity targets use the inverse plane transform. Text fields remap pointer and drag positions for native editing; resize grips use local deltas. Select previews share the transformed plane while their native popups remain axis-aligned and anchor to the projected bounds. Inline source provenance survives word coalescing and line splitting: getClientRects returns projected line/column fragments and getBoundingClientRect unions them. Empty inline anchors and exact subranges within complex shaped glyph clusters remain incomplete. Eye-plane-crossing geometry remains approximate, consistently with the rendering limitation above.

## Verification

Run `./test.ps1` for the package suites. After building, run:

```powershell
./tools/check-transform-inline-fragments.ps1 -Browser ./browser.exe
./tools/check-transform-inline-controls.ps1 -Browser ./browser.exe
./tools/check-transform-hit-geometry.ps1 -Browser ./browser.exe
./tools/check-projective-transforms.ps1 -Browser ./browser.exe
./tools/check-stacking.ps1 -Browser ./browser.exe
./tools/check-hover-transform-clip.ps1 -Browser ./browser.exe
```

The projective fixture checks both forms of perspective, depth ordering, matrix animation, rotation winding, and rotation/translation order against rendered pixels.
