// stb_truetype behind TextPixels.h: the single implementation of the vendored header. Text goes
// through this rather than a platform text framework so the same words rasterize to the same
// pixels on every OS; see docs/cross-platform.md.
#define STB_TRUETYPE_IMPLEMENTATION
#include "stb_truetype.h"

// The header lives in Core/include (where SwiftPM looks for it); the path is relative to this
// file so it resolves for both SwiftPM and the Xcode bridging header.
#include "../../include/TextPixels.h"
#include <stdlib.h>
#include <string.h>

struct text_font {
    stbtt_fontinfo info;
    uint8_t *data;  // stb reads the glyph outlines straight from these bytes
};

text_font *text_font_init(const uint8_t *data, size_t size) {
    if (!data || size == 0) return NULL;
    text_font *font = (text_font *)malloc(sizeof(text_font));
    if (!font) return NULL;
    font->data = (uint8_t *)malloc(size);
    if (!font->data) {
        free(font);
        return NULL;
    }
    memcpy(font->data, data, size);
    if (!stbtt_InitFont(&font->info, font->data, 0)) {
        free(font->data);
        free(font);
        return NULL;
    }
    return font;
}

void text_font_release(text_font *font) {
    if (!font) return;
    free(font->data);
    free(font);
}

float text_scale_for_pixel_height(const text_font *font, float pixel_height) {
    return stbtt_ScaleForPixelHeight(&font->info, pixel_height);
}

void text_font_vmetrics(const text_font *font, float scale, float *ascent, float *descent, float *line_gap) {
    int ascentUnits = 0, descentUnits = 0, lineGapUnits = 0;
    stbtt_GetFontVMetrics(&font->info, &ascentUnits, &descentUnits, &lineGapUnits);
    // stb stores the descent below the baseline as a negative; hand back a positive distance.
    *ascent = (float)ascentUnits * scale;
    *descent = (float)-descentUnits * scale;
    *line_gap = (float)lineGapUnits * scale;
}

int text_glyph_index(const text_font *font, uint32_t codepoint) {
    return stbtt_FindGlyphIndex(&font->info, (int)codepoint);
}

float text_glyph_advance(const text_font *font, float scale, int glyph_index) {
    int advanceUnits = 0, leftBearing = 0;
    stbtt_GetGlyphHMetrics(&font->info, glyph_index, &advanceUnits, &leftBearing);
    return (float)advanceUnits * scale;
}

float text_glyph_kern_advance(const text_font *font, float scale, int left_glyph, int right_glyph) {
    return (float)stbtt_GetGlyphKernAdvance(&font->info, left_glyph, right_glyph) * scale;
}

uint8_t *text_rasterize_glyph(const text_font *font, float scale, int glyph_index,
                              int *out_width, int *out_height, int *out_x_offset, int *out_y_offset) {
    *out_width = 0;
    *out_height = 0;
    *out_x_offset = 0;
    *out_y_offset = 0;
    int left = 0, bottom = 0, right = 0, top = 0;
    stbtt_GetGlyphBitmapBox(&font->info, glyph_index, scale, scale, &left, &bottom, &right, &top);
    int width = right - left, height = top - bottom;
    if (width <= 0 || height <= 0) return NULL;
    uint8_t *bitmap = (uint8_t *)malloc((size_t)width * (size_t)height);
    if (!bitmap) return NULL;
    stbtt_MakeGlyphBitmap(&font->info, bitmap, width, height, width, scale, scale, glyph_index);
    *out_width = width;
    *out_height = height;
    // The box coordinates are relative to the pen and baseline with y up; the layout is y down.
    *out_x_offset = left;
    *out_y_offset = -top;
    return bitmap;
}

void text_bitmap_release(uint8_t *bitmap) {
    free(bitmap);
}
