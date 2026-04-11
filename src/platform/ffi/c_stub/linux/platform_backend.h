// Backend interface for Linux platform layer.
//
// Both X11 and Wayland backends implement these prefixed functions.
// The dispatcher (platform_linux.c) routes hello_tty_platform_* calls
// to the active backend at runtime.

#ifndef HELLO_TTY_PLATFORM_BACKEND_H
#define HELLO_TTY_PLATFORM_BACKEND_H

#include <stdint.h>

#define MAX_WINDOWS 16

// Backend type identifiers (returned by hello_tty_platform_get_backend_type)
#define HELLO_TTY_BACKEND_X11     0
#define HELLO_TTY_BACKEND_WAYLAND 1

// Shared keysym translation (defined in platform_x11.c, used by both backends).
// Takes unsigned long to match both X11 KeySym and xkbcommon xkb_keysym_t.
int translate_keysym(unsigned long ks);

// --- X11 backend ---
int   x11_platform_init(void);
int   x11_platform_create_window(int width, int height);
void  x11_platform_set_title(const uint8_t *title, int title_len, int window);
int   x11_platform_poll_event(int window, int32_t *event_buf);
void  x11_platform_request_redraw(int window);
int   x11_platform_get_vulkan_surface(int window);
int   x11_platform_get_dpi_scale(int window);
void  x11_platform_destroy_window(int window);
void  x11_platform_shutdown(void);
int   x11_platform_clipboard_set(const uint8_t *text, int len);
int   x11_platform_clipboard_get(uint8_t *buf, int max_len);
void* x11_platform_get_display(void);

// --- Wayland backend ---
int   wayland_platform_init(void);
int   wayland_platform_create_window(int width, int height);
void  wayland_platform_set_title(const uint8_t *title, int title_len, int window);
int   wayland_platform_poll_event(int window, int32_t *event_buf);
void  wayland_platform_request_redraw(int window);
int   wayland_platform_get_vulkan_surface(int window);
int   wayland_platform_get_dpi_scale(int window);
void  wayland_platform_destroy_window(int window);
void  wayland_platform_shutdown(void);
int   wayland_platform_clipboard_set(const uint8_t *text, int len);
int   wayland_platform_clipboard_get(uint8_t *buf, int max_len);
void* wayland_platform_get_display(void);

#endif // HELLO_TTY_PLATFORM_BACKEND_H
