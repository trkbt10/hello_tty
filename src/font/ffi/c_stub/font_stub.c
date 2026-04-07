// Font rasterization stub — used when no platform-specific font engine is available.
// The real implementations are in font_coretext.c (macOS) and font_freetype.c (Linux),
// compiled only when building via the platform adapter Makefile.

#include "font_ffi.h"

// Only compile stubs when neither CoreText nor FreeType is enabled.
#if !defined(HELLO_TTY_PLATFORM_MACOS) && !defined(__linux__)

#include <stdio.h>

int hello_tty_font_init(const char *font_path, int font_path_len, int font_size) {
    (void)font_path; (void)font_path_len; (void)font_size;
    fprintf(stderr, "hello_tty: font engine not available (stub)\n");
    return -1;
}

int hello_tty_font_rasterize(
    int codepoint, int bold, int italic,
    int32_t *metrics_out,
    uint8_t *bitmap_out, int bitmap_max_len) {
    (void)codepoint; (void)bold; (void)italic;
    (void)metrics_out; (void)bitmap_out; (void)bitmap_max_len;
    return -1;
}

int hello_tty_font_get_metrics(int32_t *metrics_out) {
    (void)metrics_out;
    return -1;
}

void hello_tty_font_shutdown(void) {}

#endif
