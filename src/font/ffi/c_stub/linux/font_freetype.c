// Font rasterization via FreeType (Linux).
//
// Provides glyph rasterization and font metrics using FreeType2.
// Outputs grayscale (A8) bitmaps suitable for atlas upload.

#if defined(__linux__)

#include "../font_ffi.h"

// FreeType2 include: use the path that resolves both with and without
// -I/usr/include/freetype2 (pkg-config). The ft2build.h internally
// includes <freetype/config/ftheader.h>, which requires the freetype2
// directory to be in the include path.
#pragma GCC diagnostic push
#pragma GCC diagnostic ignored "-Wpedantic"
#include "/usr/include/freetype2/ft2build.h"
#pragma GCC diagnostic pop
#include FT_FREETYPE_H
#include FT_GLYPH_H
#include FT_BITMAP_H

#include <stdlib.h>
#include <string.h>
#include <math.h>

// ---------- Internal state ----------

typedef struct {
    FT_Library library;
    FT_Face face;
    FT_Face bold_face;
    int font_size;
    int cell_width;
    int cell_height;
    int ascent;
    int descent;
    int initialized;
} FontState;

static FontState g_font = {0};

// Common monospace font paths on Linux
static const char *monospace_font_paths[] = {
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationMono-Regular.ttf",
    "/usr/share/fonts/truetype/ubuntu/UbuntuMono-R.ttf",
    "/usr/share/fonts/noto/NotoSansMono-Regular.ttf",
    NULL
};

static const char *monospace_bold_paths[] = {
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono-Bold.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono-Bold.ttf",
    "/usr/share/fonts/truetype/liberation/LiberationMono-Bold.ttf",
    "/usr/share/fonts/truetype/ubuntu/UbuntuMono-B.ttf",
    "/usr/share/fonts/noto/NotoSansMono-Bold.ttf",
    NULL
};

static FT_Face try_load_font(FT_Library lib, const char **paths) {
    for (int i = 0; paths[i] != NULL; i++) {
        FT_Face face;
        if (FT_New_Face(lib, paths[i], 0, &face) == 0) {
            return face;
        }
    }
    return NULL;
}

// ---------- Public API ----------

int hello_tty_font_init(const char *font_path, int font_path_len, int font_size) {
    if (g_font.initialized) {
        hello_tty_font_shutdown();
    }

    if (FT_Init_FreeType(&g_font.library) != 0) return -1;

    g_font.font_size = font_size;

    if (font_path != NULL && font_path_len > 0) {
        char path_buf[512];
        int len = font_path_len < 511 ? font_path_len : 511;
        memcpy(path_buf, font_path, (size_t)len);
        path_buf[len] = '\0';

        if (FT_New_Face(g_font.library, path_buf, 0, &g_font.face) != 0) {
            FT_Done_FreeType(g_font.library);
            return -1;
        }
    } else {
        g_font.face = try_load_font(g_font.library, monospace_font_paths);
        if (!g_font.face) {
            FT_Done_FreeType(g_font.library);
            return -1;
        }
    }

    // Set pixel size
    FT_Set_Pixel_Sizes(g_font.face, 0, (FT_UInt)font_size);

    // Try to load bold face
    g_font.bold_face = try_load_font(g_font.library, monospace_bold_paths);
    if (g_font.bold_face) {
        FT_Set_Pixel_Sizes(g_font.bold_face, 0, (FT_UInt)font_size);
    }

    // Calculate metrics
    g_font.ascent = (int)(g_font.face->size->metrics.ascender >> 6);
    g_font.descent = (int)(-g_font.face->size->metrics.descender >> 6);
    g_font.cell_height = (int)(g_font.face->size->metrics.height >> 6);

    // Cell width from advance of 'M'
    if (FT_Load_Char(g_font.face, 'M', FT_LOAD_DEFAULT) == 0) {
        g_font.cell_width = (int)(g_font.face->glyph->advance.x >> 6);
    } else {
        g_font.cell_width = font_size / 2;
    }

    if (g_font.cell_width < 1) g_font.cell_width = font_size / 2;
    if (g_font.cell_height < 1) g_font.cell_height = font_size;

    g_font.initialized = 1;
    return 0;
}

int hello_tty_font_rasterize(
    int codepoint, int bold, int italic,
    int32_t *metrics_out,
    uint8_t *bitmap_out, int bitmap_max_len) {

    if (!g_font.initialized) return -1;

    FT_Face face = (bold && g_font.bold_face) ? g_font.bold_face : g_font.face;

    FT_Int32 load_flags = FT_LOAD_RENDER;
    if (bold && !g_font.bold_face) {
        load_flags |= FT_LOAD_TARGET_NORMAL;
    }

    // Load glyph
    FT_UInt glyph_index = FT_Get_Char_Index(face, (FT_ULong)codepoint);
    if (glyph_index == 0) {
        // Try fallback face
        glyph_index = FT_Get_Char_Index(g_font.face, (FT_ULong)codepoint);
        face = g_font.face;
    }

    if (FT_Load_Glyph(face, glyph_index, load_flags) != 0)
        return -1;

    FT_GlyphSlot slot = face->glyph;

    // Apply synthetic bold if no bold font and bold requested
    if (bold && !g_font.bold_face && slot->format == FT_GLYPH_FORMAT_BITMAP) {
        FT_Bitmap_Embolden(g_font.library, &slot->bitmap, 64, 0);
    }

    // Apply synthetic italic via oblique transform
    if (italic) {
        FT_Matrix matrix;
        matrix.xx = 0x10000;
        matrix.xy = 0x05700; // ~21 degree skew (tan(12deg) * 65536)
        matrix.yx = 0;
        matrix.yy = 0x10000;
        FT_Set_Transform(face, &matrix, NULL);
        FT_Load_Glyph(face, glyph_index, load_flags);
        FT_Set_Transform(face, NULL, NULL); // Reset
        slot = face->glyph;
    }

    // Ensure rendered
    if (slot->format != FT_GLYPH_FORMAT_BITMAP) {
        if (FT_Render_Glyph(slot, FT_RENDER_MODE_NORMAL) != 0)
            return -1;
    }

    int glyph_width = (int)slot->bitmap.width;
    int glyph_height = (int)slot->bitmap.rows;
    int bearing_x = slot->bitmap_left;
    int bearing_y = slot->bitmap_top;
    int glyph_advance = (int)(slot->advance.x >> 6);

    if (glyph_width < 1) glyph_width = 1;
    if (glyph_height < 1) glyph_height = 1;

    metrics_out[0] = glyph_width;
    metrics_out[1] = glyph_height;
    metrics_out[2] = bearing_x;
    metrics_out[3] = bearing_y;
    metrics_out[4] = glyph_advance;

    int bitmap_size = glyph_width * glyph_height;
    if (bitmap_size > bitmap_max_len) return -1;

    // Copy bitmap (FreeType renders in FT_PIXEL_MODE_GRAY = 8-bit grayscale)
    if (slot->bitmap.pixel_mode == FT_PIXEL_MODE_GRAY) {
        for (int y = 0; y < glyph_height; y++) {
            memcpy(bitmap_out + y * glyph_width,
                   slot->bitmap.buffer + y * slot->bitmap.pitch,
                   (size_t)glyph_width);
        }
    } else {
        memset(bitmap_out, 0, (size_t)bitmap_size);
    }

    return bitmap_size;
}

int hello_tty_font_get_metrics(int32_t *metrics_out) {
    if (!g_font.initialized) return -1;
    metrics_out[0] = g_font.cell_width;
    metrics_out[1] = g_font.cell_height;
    metrics_out[2] = g_font.ascent;
    metrics_out[3] = g_font.descent;
    return 0;
}

void hello_tty_font_shutdown(void) {
    if (g_font.bold_face) { FT_Done_Face(g_font.bold_face); g_font.bold_face = NULL; }
    if (g_font.face) { FT_Done_Face(g_font.face); g_font.face = NULL; }
    if (g_font.library) { FT_Done_FreeType(g_font.library); g_font.library = NULL; }
    g_font.initialized = 0;
}

#endif // __linux__
