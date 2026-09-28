# Cross-platform (macOS · Windows · Linux)

Compositor is a macOS app, but its model vocabulary now compiles everywhere. This document records what is shared, what stays Apple-only, and the path toward more.

## What is cross-platform today

**`Core/`** — compiled by the app, by `compositor-mcp`, and independently as the [SwiftPM](../Package.swift) library `CompositorCore` (`swift build && swift test`; on Windows and Linux, `build.bat`/`build.sh` wrap the same build and keep every intermediate and product under `output/`):

- `LayerTransform` + `LayerSampling` — placement geometry (rotation, flips, sampling)
- `LayerBlendMode` — the 24 blend modes and their menu grouping; their raw values are what `.comp` manifests store
- `CanvasUnit` / `CanvasSizeDraft` / `CanvasSizeOptions` / `CanvasExtensionColor`
- `DocumentLimits` — the shared size and memory ceilings
- `Pixels/` + `Rendering/` — the `PixelBuffer` raster, the `Renderer` protocol, `BlendMath` (the 24 blend modes as pure Swift) and the CPU `SoftwareRenderer` (see "Renderer backends" below)
- `Filters/` — the portable slice of the Filter menu: the three Core Image filters rewritten in pure Swift (`GaussianBlur`, `MotionBlur`, `Bloom`) and the four that were always portable C (Add Noise, Vignette, Tonal Contrast, Lens Correction), dispatched by `PortableFilter` over `FilterParameters` (see "Filters" below). The nine C pixel kernels now live here too, in `Filters/C/`, with their headers in `include/` so the package's Swift sources and the app's bridging header share them.
- `Text/` — the portable Type tool core: a `LayerTextStyle` rasterized into a `PixelBuffer` through stb_truetype with layout in plain Swift (see "Text" below).
- `PNG/PNGCodec.swift` — PNG decode/encode between raw bytes and `PixelBuffer`, on [swift-png](https://github.com/tayloraswift/swift-png) (a Foundation-free pure-Swift PNG library) (see "PNG codec" below). The file compiles to nothing on targets without the dependency, so the Xcode app target keeps building untouched.
- `Project/LayerHierarchy.swift` — the layer-tree validation (`LayerHierarchy`), effective-opacity math (`LayerOpacity`) and `ProjectError`, moved out of the app tree so the headless engine and the app share one copy.
- `Project/HeadlessProject.swift` — the headless document engine: the 22 MCP tools' document operations on plain `PixelBuffer` layers, with undo, save/open and PNG export (see "The headless engine" below).

Two things make this possible:

- Apple-framework specifics stay in the app tree: `LayerTransform`'s rendering-facing helpers (`unitToDocument`, `placing`, `following`, the transform-edit machinery) live in `Document/LayerTransformSupport.swift`; `LayerBlendMode`'s `cgMode`/`coreImageFilter` stay in `Document/LayerAppearance.swift`.
- On platforms without Core Graphics, `Core/CoreGraphicsShim.swift` provides the few geometry types (`CGPoint`, `CGSize`, `CGRect`, `CGInterpolationQuality`); `CGFloat` comes from Foundation. Files import Core Graphics through `#if canImport(CoreGraphics)`.

CI builds and tests the package on Ubuntu, Windows and macOS (`core` job in `.github/workflows/verify.yml`).

**The MCP HTTP bridge's platform-neutral half** also builds everywhere as the `MCPBridge` package target: `MCPHTTPBridge` holds the HTTP parser, the Bearer authentication and the response writer, and hands socket work to an `MCPHTTPTransport` — Network.framework on Apple platforms (`MCPHTTPNetworkTransport`), swift-nio elsewhere (`MCPHTTPNIOTransport`). The tool-handler layer is now split the same way:

- `MCPToolSupport.swift` — the shared vocabulary (argument readers, schemas, `MCPToolError`, color parsing), UI-free and Apple-framework-free, used by both the app's handlers and the headless ones.
- `HeadlessMCPHandlers.swift` + `HeadlessMCPServer.swift` — the headless half: the same 22 tools, dispatched against `HeadlessProject` (see "The headless engine" below).
- `CLI/HeadlessMain.swift` — the `compositor-mcp` executable for every platform (`swift run compositor-mcp`, or `swift build` and the product under `output/` on Windows/Linux), with the same `--host`/`--port`/`--token` interface as the macOS server.

The MCP server's HTTP transport is a network protocol, so agents on any OS can already drive a macOS Compositor remotely (`compositor-mcp --host 0.0.0.0 --token …`, see [mcp-server.md](mcp-server.md)).

## What stays macOS-only, and why

| Layer | Apple dependency |
|---|---|
| JPEG (and other non-PNG) image import and export | ImageIO / Core Graphics |
| The app's compositing renderer (`ImageExporter`, `LayerRenderer`) | Core Graphics |
| 7 of 17 filters — the color adjustments (through `ImageAdjustmentPixels`), Camera Raw, Dither | C kernels (portable) behind CG contexts |
| Remove Background, Content-Aware Fill | Vision / CG plumbing around a portable kernel |
| Adjustment layers' application to pixels at render time (headless stores them but doesn't apply them) | `ImageAdjustmentPixels` behind CG contexts |
| Brush engine, effects | Metal |
| Text beyond the portable core — shaping (Arabic, Indic), bidirectional text, vertical layout, OpenType features | CoreText (`NSTextStorage`) |
| File dialogs, panels, the interface | AppKit/SwiftUI |
| `CGImage` pixel containers (`ImportedImage`, `ProjectSnapshot`) | Core Graphics |

## Roadmap toward a Windows/Linux server (and beyond)

1. **Free the manifest from `CGImage` (done for the headless engine).** `ProjectManifest`/`ProjectLayerRecord` are plain Codable data, but `ProjectSnapshot` carries `ImportedImage` (a `CGImage` pair). The headless engine sidesteps `ProjectSnapshot` entirely: `HeadlessProject` holds the manifest plus a plain `[UUID: PixelBuffer]` table, and saves/opens `.comp` files directly — the app keeps its `ProjectSnapshot` until the format layer itself moves into `Core/`.
2. **A pure-Swift renderer (done — see "Renderer backends" below).** Decode PNGs (e.g. swift-png), composite with the documented blend-mode math behind a `Renderer` protocol (macOS keeps Core Graphics; other platforms use the pure implementation). The existing export pixel tests become the cross-backend parity baseline.
3. **Port the filters (in progress).** The C kernels moved into `Core/Filters/C` and the three Core Image filters are rewritten in pure Swift behind `PortableFilter`; the remaining filters follow — each accepted with documented per-filter differences until validated against the macOS reference (step "Filters" below).
4. **swift-nio HTTP bridge + headless MCP server (done — see "The headless engine" below).** The bridge's shared logic sits behind an `MCPHTTPTransport` socket abstraction: NWListener on Apple platforms, swift-nio elsewhere, both built by CI through the `MCPBridge` package target. The `compositor-mcp` executable now builds on every platform, driving `HeadlessProject` through the same 22 tools.
5. **Port the Type tool's rasterizer (done — see "Text" below).** Glyphs come from the vendored stb_truetype behind a clean C wrapper; layout (advance, kerning, tracking, leading, alignment) is plain Swift over `LayerTextStyle`. Complex scripts stay macOS-only, documented as a downgrade.
6. **UI decision.** A full GUI port is a second product (Qt/Tauri rewrite on top of the cross-platform core); the MCP server is the pragmatic interface for non-mac platforms until then.

## Renderer backends (roadmap step 2)

Step 2 is in place. `Core/Rendering/` holds the pieces every platform compiles:

- `Renderer.swift` — the backend protocol (`begin`/`draw`/`finish`). Coordinates are document pixels, y down, rotations clockwise. A mask is a layer-local coverage image mapped over the layer's rectangle: its alpha channel is per-pixel opacity, and it is sampled at its own resolution, independent of the layer's.
- `BlendMath.swift` — all 24 blend modes as plain Swift, straight from the W3C Compositing and Blending formulas. `composite` applies the general equation and returns premultiplied color, which is what both backends store.
- `SoftwareRenderer.swift` — the CPU backend: the transformed corners give a bounding box, each destination pixel center maps back through the inverse transform, sources are sampled nearest or bilinear (masks always bilinear), and blending goes through `BlendMath`, with a premultiplied fast path for normal.

`Compositor/Rendering/CGRenderer.swift` (app tree, not `Core/`) adapts the existing Core Graphics path to the same protocol: it wraps `LayerRenderer.draw`, including the `SeparableBlend` Core Image detour for the modes Core Graphics can't draw or computes wrongly.

`CompositorTests/RenderParityTests.swift` renders identical cases through both backends and compares pixels: solid layers across the full matrix (24 modes × two opacities × three scales × two rotations, with and without a mask), plus gradient layers drawn at exact 1:1 to isolate the blend math from resampling. The tests assert ≤ 2/255 per channel for the separable modes and ≤ 6/255 for the non-separable modes and soft/vivid light; the content is chosen so Lanczos downsampling and edge antialiasing can't hide math differences.

Known, documented differences between the backends:

- Magnification: at exact 1:1 both backends copy texels straight through, but enlarging beyond that uses each backend's own filter, so the parity suite avoids upscale cases. Minification parity holds because the CG path's Lanczos cache leaves pure fills untouched at every level.
- Effects (shadows, strokes, filters) are not part of the protocol yet; both backends draw plain layers carrying one transform, blend mode, opacity and optional mask.

## Filters (roadmap step 3)

Seven of the Filter menu's seventeen run without Apple frameworks through `Core/Filters/PortableFilter`, which takes a `FilterParameters` value and a `PixelBuffer` and returns one:

- **Gaussian Blur, Motion Blur, Bloom / Glow** — rewritten in pure Swift (`GaussianBlur`, `MotionBlur`, `Bloom`). The Gaussian is three box passes (the boxes-for-Gauss sizes); Motion Blur averages an even streak, Photoshop-style; Bloom passes the brights through a soft knee at 50% luminance, spreads them with the Gaussian, and adds them back, clamped to each pixel's alpha.
- **Add Noise, Vignette, Tonal Contrast, Lens Correction** — the same portable C kernels the app has always run (`Core/Filters/C/NoisePixels.c`, `AdjustPixels.c`, `LensPixels.c`), called through `PixelKernels` on `PixelBuffer` bytes.

macOS keeps the app's own pipeline (Core Image plus the same C kernels behind CGContext) as the reference. `CoreTests/FilterParityTests` renders the pure and Core Image results through one sRGB pipeline and compares them; the tolerances there are provisional, to be tightened on macOS once the real deltas are measured. Known, documented differences:

- The Gaussian's three-box profile vs Core Image's: a few levels in a hard edge's first ring, near-equal elsewhere.
- Motion Blur is an even streak where `CIMotionBlur` tapers like a Gaussian; the app's pipeline already hands Core Image the radius that matches an even streak's spread (`1/√12` of the length), so reach agrees and the profile differs within the streak.
- Bloom's soft knee is an approximation of Core Image's internal bright pass; dark pixels and pixels past the glow's reach match exactly.
- Blur-family filters treat samples past the image's edge as transparent (the streak thins there instead of dragging the border along), matching how the app's pipeline grows the layer for a blur.

Still on the app pipeline: the color adjustments (Curves, Exposure, Gradient Map, Grain, Black & White, Color Balance — portable C kernels behind `ImageAdjustmentPixels`), Camera Raw, Dither, Content-Aware Fill and Remove Background (Vision). The C kernels under `Core/Filters/C` cover most of their math already; what remains is moving the CG context plumbing behind `PixelBuffer`/`Renderer`.

## Text (roadmap step 5)

`Core/Text/` renders a `LayerTextStyle` — the Type tool's stored style — into a `PixelBuffer` on every platform:

- **Glyphs** come from [stb_truetype](Core/Text/C/stb_truetype.h) (v1.26, public domain, vendored), matching the project's style of portable single-purpose C. `Core/Text/C/TextPixels.c` is its one implementation site; `include/TextPixels.h` is the clean wrapper Swift sees (load a face, ask for metrics, advances, kerning and coverage bitmaps), reached through the same umbrella header as the pixel kernels.
- **Font discovery** is `FontBook`: a one-time scan of the platform's font directories (`/System/Library/Fonts` and friends on macOS, `C:\Windows\Fonts` on Windows, `/usr/share/fonts` on Linux) with fuzzy filename matching plus a small alias table ("Helvetica" → Arial / Liberation Sans / DejaVu Sans), and a last-resort fallback to the first font that loads.
- **Layout** is plain Swift in `TextRasterizer`: line breaks at `\n`, advances with kerning (within one face) and tracking, leading as `LayerTextStyle.lineHeight` (0 = Auto = 120%), left/center/right alignment inside the measured box, and the per-UTF-16-offset color and font runs the style stores. Glyph coverage is composited source-over onto premultiplied pixels.

Documented downgrades from the macOS Type tool (CoreText):

- No shaping: Arabic, Indic and other complex scripts render unjoined or wrong; no bidirectional text, no vertical layout, no OpenType features beyond the font's default kerning.
- Font matching is by filename, not font metadata — a style asking for a face no directory carries gets the fallback font, not the closest relative.
- The buffer hugs the text (no box wrapping yet); `boxSize` styles render with the same measured width as point text.

`CoreTests/TextRasterizerTests` is a smoke suite (ink inside the canvas, blank text draws nothing, determinism, size scaling, leading, alignment, color runs) that skips when a runner has no loadable system font; CI's Ubuntu, Windows and macOS images all have one. There is deliberately no pixel parity test against CoreText — the portable renderer is its own reference, per the tolerance strategy in "Filters".

## PNG codec

`Core/PNG/PNGCodec.swift` is the file-format boundary for the headless engine: `Data` in, `PixelBuffer` out, and back. It sits on [swift-png](https://github.com/tayloraswift/swift-png) (v4.5+), which is pure Swift with no Foundation dependency, so the codec behaves identically on every platform.

- **Decode** unpacks to straight alpha and hands the premultiplied result to `PixelBuffer` — the raster's native storage, shared with the renderers and filters.
- **Encode** straightens before packing into `rgba8`, at compression level 9. Round trips of opaque pixels are exact; translucent ones move by at most the packing's own rounding (±1/255), which is what `CoreTests/PNGCodecTests` pins.
- **Masks** travel as 8-bit grayscale (`v8`): encode takes the buffer's alpha channel, decode maps luminance to white coverage with the 0.2126/0.7152/0.0722 weights, so any RGB grayscale PNG reads back as the same coverage.
- Sizes are validated against `DocumentLimits` before pixels are allocated.

The whole file is wrapped in `#if canImport(PNG)`: the Xcode app target compiles `Core/` without the swift-png dependency and gets an empty translation unit, so no project-file changes are needed. Only the package targets — which declare the dependency in `Package.swift` — build the codec.

## The headless engine

`Core/Project/HeadlessProject.swift` is the macOS app's document model, rebuilt on portable parts: a `ProjectManifest` plus a plain `[UUID: PixelBuffer]` image table, undo snapshots being whole-state copies (cheap, because `PixelBuffer` is a value type), and `SoftwareRenderer` + `LayerHierarchy` + `LayerOpacity.effective` doing the compositing. It implements the document operations behind all 22 MCP tools — add/move/update/delete/transform layers, masks (raster masks, plus a simplified live-mask read of the source layer's rendered alpha), text layers through `TextRasterizer`, filters through `PortableFilter`, canvas crop/resize with the app's anchor and fill semantics, render, export and save/open of `.comp` files (atomic: write to a temp file, then move over the old one).

On top of it sit `HeadlessMCPHandlers` and `HeadlessMCPServer` (`Compositor/IO/MCP/`, UI-free), exposing the same 22 tools with the same names and parameter schemas as the macOS server, and `CLI/HeadlessMain.swift` wrapping them in the same `--host`/`--port`/`--token` HTTP interface. `swift run compositor-mcp` on any platform starts a Compositor agent server with no app involved.

Documented downgrades from the macOS app (each returns a clear error rather than misbehaving):

- Image import is PNG-only; JPEG and other formats need ImageIO on macOS.
- Adjustment layers and effects are stored in the manifest but not applied to pixels at render time.
- Live masks are a simplified read: the source layer's rendered alpha sampled over the target layer's space, not the app's per-update re-render pipeline.
- Text has the portable rasterizer's limits (see "Text" above): no shaping, no wrapping.
