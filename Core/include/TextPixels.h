#ifndef TextPixels_h
#define TextPixels_h
#include <stdint.h>
#include <stddef.h>

// A clean C wrapper over stb_truetype for the portable text rasterizer: Swift never sees stb's
// types. A text_font owns a private copy of the font bytes it was loaded from, so callers may
// free their own buffer once loading returns.

typedef struct text_font text_font;

// Loads a font from TTF/OTF/TTC bytes (the first face of a collection). Returns NULL for bad
// bytes or when memory runs out.
text_font *text_font_init(const uint8_t *data, size_t size);
void text_font_release(text_font *font);

// The scale that maps the font's internal units to pixels at `pixel_height` em size. The calls
// below already apply it; nothing else in this header speaks font units.
float text_scale_for_pixel_height(const text_font *font, float pixel_height);

// The font's ascent above the baseline and descent below it, in pixels, both positive, plus the
// extra line gap that belongs between them.
void text_font_vmetrics(const text_font *font, float scale, float *ascent, float *descent, float *line_gap);

// The glyph for a Unicode codepoint. 0 is the .notdef glyph, also returned for missing ones.
int text_glyph_index(const text_font *font, uint32_t codepoint);

// The glyph's advance, and its kerning with the previous glyph, in pixels.
float text_glyph_advance(const text_font *font, float scale, int glyph_index);
float text_glyph_kern_advance(const text_font *font, float scale, int left_glyph, int right_glyph);

// Rasterizes a glyph into a freshly allocated 8-bit coverage bitmap: one byte per pixel, rows
// packed, 0 (no ink) to 255 (full). Returns NULL for a glyph that draws nothing (a space) or
// when memory runs out; in the empty case *out_width and *out_height come back 0 and the caller
// just moves the pen on. The bitmap's top-left corner sits at (pen + *out_x_offset, baseline +
// *out_y_offset) in a y-down layout, and the offsets may be negative. Free with
// text_bitmap_release.
uint8_t *text_rasterize_glyph(const text_font *font, float scale, int glyph_index,
                              int *out_width, int *out_height, int *out_x_offset, int *out_y_offset);
void text_bitmap_release(uint8_t *bitmap);
#endif
