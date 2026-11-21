# Polygon fills and clips

`draw.push_clip_polygon` and `draw.path_fill` (a polygon clip over a rect) fill a polygon of one or more contours with
the nonzero or even-odd rule. The pixel shader (`polygon_sdf` in `src/render/rect.wgsl`) computes the winding number
and a signed distance; the coverage is `0.5 - distance` in pixels.

## Only the boundary softens

The distance is to the edges where the fill changes, not to every edge. A path that overlaps itself (a pen's ink
crossing its own line, two contours wound the same way over each other) has edges inside the filled region. A distance
to those edges gave the pixels along them a partial coverage: a light seam through solid ink.

- Pass one counts p's winding `W`. Pass two measures the distance to each edge whose other side is filled differently.
- Crossing an edge from its `side > 0` half-plane to the other one takes 1 from the winding, whatever the edge's
  direction. The winding on the other side is `W - sign(side)`.
- With nonzero, an edge between `W = 2` and `W = 1` is skipped. With even-odd, every edge changes the parity, so every
  edge counts.
- A pixel centre on an edge's line (`side == 0`) takes the side that the count put it on: its ties (`a.y <= p.y`, a
  strict sign of `side`) count p as moved right a little and down much less. The tie becomes `-e.y`, then `e.x`.
  Without it, a pixel centre on an inner edge got 0.5.

## Accepted approximations

- The other side is read from the edge's line, not at the nearest point of the segment. An edge that stops being a
  boundary half way (it enters another contour) is skipped as a whole near the crossing. There, the distance is to the
  rest of the boundary: the concave corner of the union, where the pixels are nearly full anyway.
- Even-odd: two coincident edges cancel, yet each still counts as a boundary, so a thin line shows. A test of the
  coincidence per edge pair costs O(n²) per pixel.

## Refused

- Supersampling the fill rule (as the canvas does: `canvas.wgsl`, 16 samples on boundary pixels). It needs the edges
  binned by band to stay cheap. The clip path keeps its flat list of points and two passes over it.

## The fill rect

`path_fill` draws its rect one screen pixel past the path's bounds. The rect's own soft edge otherwise falls on the
outline's edges that lie on the bounds and softens them twice (0.25 instead of 0.5). `|det| / norm` of the transform
bounds its smallest scale from below, so the pad is at least one pixel in every direction.

Test: `tests/gpufx` `path_fill_overlaps_have_no_seams`.
