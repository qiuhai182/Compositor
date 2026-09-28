# Compositor MCP server

Compositor exposes its editing core as an [MCP](https://modelcontextprotocol.io) server, so AI agents can create and edit `.comp` projects with structured tools instead of writing files by hand. The server speaks MCP Streamable HTTP on `http://127.0.0.1:9666/mcp` (localhost only).

There are two ways to run it:

- **`compositor-mcp`** — a standalone command-line server with no interface. Build the `compositor-mcp` scheme; the binary lands in DerivedData's `Build/Products`.
- **The app itself** — View > **MCP Server** toggles the same server while Compositor runs (off by default). Set `defaults write com.wonderassembly.compositor MCPEnabled -bool YES` to start it at launch, and `MCPPort` to change the port. Agents edit in their own sessions and save into `.comp` packages; a project open in the app follows their saves through the usual [live reload](writing-comp-files.md).

## Connecting

```sh
claude mcp add --transport http compositor http://127.0.0.1:9666/mcp
```

Any MCP client that supports Streamable HTTP works the same way. The CLI accepts `--port` and `--path` to move the endpoint.

## Remote access

The server binds to `127.0.0.1` by default. Agents on other machines can connect over the network:

```sh
compositor-mcp --host 0.0.0.0 --token "$RANDOM_SECRET"
```

A non-loopback host refuses to start without a token; clients then connect with `Authorization: Bearer <token>` (MCP clients take this from their headers configuration, e.g. `claude mcp add --transport http compositor http://mac.local:9666/mcp --header "Authorization: Bearer $RANDOM_SECRET"`). The connection itself is plain HTTP — put it on a trusted network, or terminate TLS in front with a reverse proxy or tunnel.

## Tools

Every tool that touches a project takes the `project_id` that `project_create` / `project_open` returned. `project_info` lists layers **bottom to top** (index 0 is the bottom) with their ids — that is also the order `layer_move`'s `index` uses. Coordinates are document pixels with the origin at the canvas's top-left corner.

### Projects

| Tool | Notes |
|---|---|
| `project_create` | `width`, `height` (1–30000), optional `resolution`. One blank layer to start. |
| `project_open` | Opens a `.comp` package from disk. |
| `project_list` | The open projects and their ids. |
| `project_info` | Full state: canvas, layer tree, transforms, masks, text, `active_layer_id`. |
| `project_save` | Saves in place, or to `path` the first time. |
| `project_close` | Discards unsaved changes. |
| `project_undo` | Undo, or `redo: true`. Each tool call is one undo step, as in the app. |

### Layers

| Tool | Notes |
|---|---|
| `layer_add_image` | Imports PNG, JPEG, HEIC, TIFF, WebP, GIF, BMP or SVG. PSD and RAW imports need the app. |
| `layer_add_blank` | A transparent layer; `width`/`height` default to the canvas. |
| `layer_add_group` | An empty folder layer. |
| `layer_update` | `name`, `visible`, `opacity` (0–1), `blend_mode` (Photoshop-style names, as in the manifest). |
| `layer_move` | Restack (`index`) or regroup (`parent_id`). |
| `layer_delete` | `layer_ids[]`; a group takes its contents. |
| `layer_transform` | `x`, `y`, `width`, `height`, `rotation` (degrees clockwise), `flip_x`, `flip_y`. |
| `layer_set_mask` | A raster mask from any image file (converted to grayscale, white reveals), or a clipping-mask `source_layer_id`. |
| `layer_add_text` | Renders text into a layer that stays editable in the app. `font_name`, `font_size` (1–2000), `color` `#RRGGBB`. |

### Filters, adjustments, canvas

| Tool | Notes |
|---|---|
| `filter_apply` | Any Filter-menu filter by name (`"Gaussian Blur"`, `"Camera Raw Filter"`, …) with optional `settings`. See the tool schema for the per-filter keys. |
| `adjustment_set` | A layer adjustment: `kind`, `hue`, `saturation`, `lightness`, `colorize`. |
| `canvas_crop` | Crops to a rectangle, moving the content with it. |
| `canvas_resize` | Grows/shrinks without scaling layers; optional `anchor` (0–8) and `fill` color. |

### Output

| Tool | Notes |
|---|---|
| `preview` | The flattened composite (or one `layer_id`) as a PNG image, downscaled to `max_width`. |
| `export` | Writes a PNG or JPEG file and returns a preview image. |

Previews and exports come back as MCP image content, so a vision-capable agent can check its own work.

## Sharing a project with the app

The server saves through the same code paths as the app, so the [live-reload rules](writing-comp-files.md) cover everything: open the same `.comp` in Compositor, let the agent edit and save, and the canvas follows about a third of a second after each save. Either side's save triggers the other's reload, and undo in the app covers agent edits that arrive that way. As when two people share one document, save before handing work over — two sides with unsaved changes end last-writer-wins.

## Building

```sh
xcodebuild -project Compositor.xcodeproj -scheme compositor-mcp -destination 'platform=macOS' build
```

The binary is at `DerivedData/Build/Products/<config>/compositor-mcp`. The server implementation lives in `Compositor/IO/MCP/` (shared with the app and the test target) and the CLI entry point and HTTP bridge in `CompositorMCP/`.
