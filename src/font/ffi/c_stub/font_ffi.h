// font_ffi.h — C API for font rasterization.
//
// Platform implementations: CoreText (macOS), FreeType (Linux), stub (fallback).

#ifndef HELLO_TTY_FONT_FFI_H
#define HELLO_TTY_FONT_FFI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Initialize the font engine.
// font_path: UTF-8 path to .ttf/.otf, or NULL for system monospace.
// font_size: size in pixels.
int hello_tty_font_init(const char *font_path, int font_path_len, int font_size);

// Rasterize a glyph.
// metrics_out[0..4] = width, height, bearing_x, bearing_y, advance.
// bitmap_out: A8 grayscale bitmap.
// Returns bitmap size in bytes, or -1 on failure.
int hello_tty_font_rasterize(
    int codepoint, int bold, int italic,
    int32_t *metrics_out,
    uint8_t *bitmap_out, int bitmap_max_len);

// Get font metrics.
// metrics_out[0..3] = cell_width, cell_height, ascent, descent.
int hello_tty_font_get_metrics(int32_t *metrics_out);

// Shut down the font engine.
void hello_tty_font_shutdown(void);

#ifdef __cplusplus
}
#endif

#endif // HELLO_TTY_FONT_FFI_H
