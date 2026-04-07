// Font rasterization via CoreText (macOS).
//
// Provides glyph rasterization and font metrics for the terminal renderer.
// Uses CTFont for glyph outlines and CGBitmapContext for rasterization
// to grayscale (A8) bitmaps suitable for atlas upload.

// CoreText font rasterization requires macOS frameworks.
// Only compiled when explicitly building via the macOS adapter Makefile.
// When building directly via moon build, stub implementations are used.
#if defined(__APPLE__) && defined(HELLO_TTY_PLATFORM_MACOS)

#include "font_ffi.h"

#include <CoreText/CoreText.h>
#include <CoreGraphics/CoreGraphics.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

// ---------- Internal state ----------

typedef struct {
    CTFontRef font;
    CTFontRef bold_font;
    int font_size;
    int cell_width;
    int cell_height;
    int ascent;
    int descent;
    int leading;
    int initialized;
} FontState;

static FontState g_font = {0};

// ---------- Helpers ----------

// Get the system monospace font name.
static CFStringRef get_monospace_font_name(void) {
    // Try common monospace fonts in preference order
    CFStringRef candidates[] = {
        CFSTR("Menlo"),
        CFSTR("Monaco"),
        CFSTR("SF Mono"),
        CFSTR("Courier New"),
    };
    int count = sizeof(candidates) / sizeof(candidates[0]);
    for (int i = 0; i < count; i++) {
        CTFontRef test = CTFontCreateWithName(candidates[i], 14.0, NULL);
        if (test) {
            CFRelease(test);
            return candidates[i];
        }
    }
    return CFSTR("Menlo"); // Fallback
}

// ---------- Public API ----------

int hello_tty_font_init(const char *font_path, int font_path_len, int font_size) {
    if (g_font.initialized) {
        hello_tty_font_shutdown();
    }

    g_font.font_size = font_size;
    CGFloat size = (CGFloat)font_size;

    if (font_path != NULL && font_path_len > 0) {
        // Load font from file path
        CFStringRef path_str = CFStringCreateWithBytes(
            kCFAllocatorDefault, (const UInt8 *)font_path, font_path_len,
            kCFStringEncodingUTF8, false);
        if (!path_str) return -1;

        CFURLRef url = CFURLCreateWithFileSystemPath(
            kCFAllocatorDefault, path_str, kCFURLPOSIXPathStyle, false);
        CFRelease(path_str);
        if (!url) return -1;

        CGDataProviderRef provider = CGDataProviderCreateWithURL(url);
        CFRelease(url);
        if (!provider) return -1;

        CGFontRef cg_font = CGFontCreateWithDataProvider(provider);
        CGDataProviderRelease(provider);
        if (!cg_font) return -1;

        g_font.font = CTFontCreateWithGraphicsFont(cg_font, size, NULL, NULL);
        CGFontRelease(cg_font);
    } else {
        // Use system monospace font
        CFStringRef font_name = get_monospace_font_name();
        g_font.font = CTFontCreateWithName(font_name, size, NULL);
    }

    if (!g_font.font) return -1;

    // Create bold variant
    CTFontSymbolicTraits bold_traits = kCTFontBoldTrait;
    g_font.bold_font = CTFontCreateCopyWithSymbolicTraits(
        g_font.font, size, NULL, bold_traits, bold_traits);
    if (!g_font.bold_font) {
        // Fallback: use regular font for bold
        g_font.bold_font = (CTFontRef)CFRetain(g_font.font);
    }

    // Calculate metrics
    CGFloat ascent = CTFontGetAscent(g_font.font);
    CGFloat descent = CTFontGetDescent(g_font.font);
    CGFloat leading = CTFontGetLeading(g_font.font);

    g_font.ascent = (int)ceil(ascent);
    g_font.descent = (int)ceil(descent);
    g_font.leading = (int)ceil(leading);
    g_font.cell_height = g_font.ascent + g_font.descent + g_font.leading;

    // Calculate cell width from the advance of 'M'
    UniChar m_char = 'M';
    CGGlyph m_glyph;
    CTFontGetGlyphsForCharacters(g_font.font, &m_char, &m_glyph, 1);
    CGSize advance;
    CTFontGetAdvancesForGlyphs(g_font.font, kCTFontOrientationDefault, &m_glyph, &advance, 1);
    g_font.cell_width = (int)ceil(advance.width);

    // Ensure minimum dimensions
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

    CTFontRef font = bold ? g_font.bold_font : g_font.font;

    // Apply italic via affine transform if needed
    CGAffineTransform transform = CGAffineTransformIdentity;
    if (italic) {
        // Skew transform for synthetic italic (~12 degrees)
        transform = CGAffineTransformMake(1.0, 0.0, 0.21, 1.0, 0.0, 0.0);
        font = CTFontCreateCopyWithAttributes(font, (CGFloat)g_font.font_size, &transform, NULL);
    }

    // Get glyph for codepoint
    UniChar chars[2];
    int char_count;
    if (codepoint > 0xFFFF) {
        // Supplementary plane — encode as surrogate pair
        int code = codepoint - 0x10000;
        chars[0] = (UniChar)(0xD800 + (code >> 10));
        chars[1] = (UniChar)(0xDC00 + (code & 0x3FF));
        char_count = 2;
    } else {
        chars[0] = (UniChar)codepoint;
        char_count = 1;
    }

    CGGlyph glyphs[2] = {0};
    CTFontRef draw_font = font;
    int need_release_draw_font = 0;

    if (!CTFontGetGlyphsForCharacters(font, chars, glyphs, char_count)) {
        // Glyph not in this font — try system font fallback (handles CJK, emoji, etc.)
        CFStringRef str_ref = CFStringCreateWithCharacters(kCFAllocatorDefault, chars, char_count);
        if (str_ref) {
            CTFontRef fallback = CTFontCreateForString(font, str_ref, CFRangeMake(0, CFStringGetLength(str_ref)));
            CFRelease(str_ref);
            if (fallback) {
                if (CTFontGetGlyphsForCharacters(fallback, chars, glyphs, char_count)) {
                    draw_font = fallback;
                    need_release_draw_font = 1;
                } else {
                    CFRelease(fallback);
                    glyphs[0] = 0; // truly missing
                }
            }
        }
    }

    CGGlyph glyph = glyphs[0];

    // Get glyph bounding box and advance (using the actual font that has the glyph)
    CGRect bbox = CTFontGetBoundingRectsForGlyphs(
        draw_font, kCTFontOrientationDefault, &glyph, NULL, 1);
    CGSize advance;
    CTFontGetAdvancesForGlyphs(draw_font, kCTFontOrientationDefault, &glyph, &advance, 1);

    int glyph_width = (int)ceil(bbox.size.width) + 2; // +2 for padding
    int glyph_height = (int)ceil(bbox.size.height) + 2;
    int bearing_x = (int)floor(bbox.origin.x);
    int bearing_y = (int)ceil(bbox.origin.y + bbox.size.height);
    int glyph_advance = (int)ceil(advance.width);

    // Clamp minimum size
    if (glyph_width < 1) glyph_width = 1;
    if (glyph_height < 1) glyph_height = 1;

    // Fill metrics output
    metrics_out[0] = glyph_width;
    metrics_out[1] = glyph_height;
    metrics_out[2] = bearing_x;
    metrics_out[3] = bearing_y;
    metrics_out[4] = glyph_advance;

    int bitmap_size = glyph_width * glyph_height;
    if (bitmap_size > bitmap_max_len) {
        if (need_release_draw_font) CFRelease(draw_font);
        if (italic && font != g_font.bold_font && font != g_font.font)
            CFRelease(font);
        return -1; // Buffer too small
    }

    // Rasterize into a grayscale bitmap using CGBitmapContext
    memset(bitmap_out, 0, (size_t)bitmap_size);

    CGColorSpaceRef gray_space = CGColorSpaceCreateDeviceGray();
    CGContextRef ctx = CGBitmapContextCreate(
        bitmap_out, (size_t)glyph_width, (size_t)glyph_height,
        8, (size_t)glyph_width, gray_space, kCGImageAlphaNone);
    CGColorSpaceRelease(gray_space);

    if (!ctx) {
        if (italic && font != g_font.bold_font && font != g_font.font)
            CFRelease(font);
        return -1;
    }

    // Set up drawing parameters
    CGContextSetGrayFillColor(ctx, 1.0, 1.0);
    CGContextSetAllowsFontSmoothing(ctx, true);
    CGContextSetShouldSmoothFonts(ctx, true);
    CGContextSetAllowsAntialiasing(ctx, true);
    CGContextSetShouldAntialias(ctx, true);

    // Draw the glyph
    // Position: offset to account for bearing
    CGPoint position = CGPointMake(
        -bbox.origin.x + 1.0, // +1 for padding
        -bbox.origin.y + 1.0
    );

    CTFontDrawGlyphs(draw_font, &glyph, &position, 1, ctx);
    CGContextRelease(ctx);

    if (need_release_draw_font)
        CFRelease(draw_font);
    if (italic && font != g_font.bold_font && font != g_font.font)
        CFRelease(font);

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
    if (g_font.bold_font) { CFRelease(g_font.bold_font); g_font.bold_font = NULL; }
    if (g_font.font) { CFRelease(g_font.font); g_font.font = NULL; }
    g_font.initialized = 0;
}

#endif // __APPLE__ && HELLO_TTY_PLATFORM_MACOS
