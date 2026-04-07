// Platform FFI stub implementation.
// This is a placeholder that will be replaced by platform-specific adapters
// (macOS: AppKit/SwiftUI via dylib, Linux: GTK4 via C).
//
// For now, all functions return failure/no-op so the code can link.
// The real implementation lives in the adapters/ directory and is linked
// at build time.

#include <stdint.h>
#include <string.h>

// Weak symbols allow the real platform adapter to override these stubs.

int hello_tty_platform_init(void) {
  // Stub: no windowing system initialized
  return -1;
}

int hello_tty_platform_create_window(int width, int height) {
  (void)width;
  (void)height;
  return -1;
}

void hello_tty_platform_set_title(
    const uint8_t *title, int title_len, int window) {
  (void)title;
  (void)title_len;
  (void)window;
}

int hello_tty_platform_poll_event(int window, int32_t *event_buf) {
  (void)window;
  (void)event_buf;
  return 0; // No events
}

void hello_tty_platform_request_redraw(int window) {
  (void)window;
}

int hello_tty_platform_get_vulkan_surface(int window) {
  (void)window;
  return 0;
}

int hello_tty_platform_get_dpi_scale(int window) {
  (void)window;
  return 100; // 1x scale
}

void hello_tty_platform_destroy_window(int window) {
  (void)window;
}

void hello_tty_platform_shutdown(void) {
  // No-op
}

int hello_tty_platform_clipboard_set(const uint8_t *text, int len) {
  (void)text;
  (void)len;
  return -1;
}

int hello_tty_platform_clipboard_get(uint8_t *buf, int max_len) {
  (void)buf;
  (void)max_len;
  return -1;
}
