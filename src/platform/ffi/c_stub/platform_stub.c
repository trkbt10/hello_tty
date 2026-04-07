// Platform FFI stub implementation.
// Used as a fallback on platforms where no native adapter is compiled
// (e.g., Linux without GTK4, or headless testing).
//
// On macOS, the real implementation is in platform_macos.m.
// On Linux, this stub will be replaced by platform_linux.c (GTK4) when available.

#include <stdint.h>
#include <string.h>

// Only compile stubs when no real adapter is available.
// On macOS, platform_macos.m provides the real implementations.
#if !defined(__APPLE__)

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

#endif // !__APPLE__
