// Linux platform dispatcher — runtime X11/Wayland backend selection.
//
// Checks WAYLAND_DISPLAY at init time:
//   - If set and Wayland connection succeeds → Wayland backend
//   - Otherwise → X11 backend
//
// All hello_tty_platform_* FFI symbols are defined here and dispatch
// to the active backend.

#if defined(__linux__) && defined(HELLO_TTY_PLATFORM_LINUX)

#include <stdint.h>
#include <stdlib.h>
#include <stdio.h>

#include "platform_backend.h"

// Active backend (set once in hello_tty_platform_init)
static int g_backend = -1; // -1 = not initialized

// ---------- FFI entry points ----------

int hello_tty_platform_init(void) {
    if (g_backend >= 0) return 0; // Already initialized

    // Try Wayland first if WAYLAND_DISPLAY is set
    const char *wl_display = getenv("WAYLAND_DISPLAY");
    if (wl_display && wl_display[0] != '\0') {
        if (wayland_platform_init() == 0) {
            g_backend = HELLO_TTY_BACKEND_WAYLAND;
            fprintf(stderr, "hello_tty: using Wayland backend\n");
            return 0;
        }
        fprintf(stderr, "hello_tty: Wayland init failed, falling back to X11\n");
    }

    // Fall back to X11
    if (x11_platform_init() == 0) {
        g_backend = HELLO_TTY_BACKEND_X11;
        fprintf(stderr, "hello_tty: using X11 backend\n");
        return 0;
    }

    fprintf(stderr, "hello_tty: no display backend available\n");
    return -1;
}

int hello_tty_platform_create_window(int width, int height) {
    if (g_backend == HELLO_TTY_BACKEND_WAYLAND)
        return wayland_platform_create_window(width, height);
    return x11_platform_create_window(width, height);
}

void hello_tty_platform_set_title(const uint8_t *title, int title_len, int window) {
    if (g_backend == HELLO_TTY_BACKEND_WAYLAND)
        wayland_platform_set_title(title, title_len, window);
    else
        x11_platform_set_title(title, title_len, window);
}

int hello_tty_platform_poll_event(int window, int32_t *event_buf) {
    if (g_backend == HELLO_TTY_BACKEND_WAYLAND)
        return wayland_platform_poll_event(window, event_buf);
    return x11_platform_poll_event(window, event_buf);
}

void hello_tty_platform_request_redraw(int window) {
    if (g_backend == HELLO_TTY_BACKEND_WAYLAND)
        wayland_platform_request_redraw(window);
    else
        x11_platform_request_redraw(window);
}

int hello_tty_platform_get_vulkan_surface(int window) {
    if (g_backend == HELLO_TTY_BACKEND_WAYLAND)
        return wayland_platform_get_vulkan_surface(window);
    return x11_platform_get_vulkan_surface(window);
}

int hello_tty_platform_get_dpi_scale(int window) {
    if (g_backend == HELLO_TTY_BACKEND_WAYLAND)
        return wayland_platform_get_dpi_scale(window);
    return x11_platform_get_dpi_scale(window);
}

void hello_tty_platform_destroy_window(int window) {
    if (g_backend == HELLO_TTY_BACKEND_WAYLAND)
        wayland_platform_destroy_window(window);
    else
        x11_platform_destroy_window(window);
}

void hello_tty_platform_shutdown(void) {
    if (g_backend == HELLO_TTY_BACKEND_WAYLAND)
        wayland_platform_shutdown();
    else if (g_backend == HELLO_TTY_BACKEND_X11)
        x11_platform_shutdown();
    g_backend = -1;
}

int hello_tty_platform_clipboard_set(const uint8_t *text, int len) {
    if (g_backend == HELLO_TTY_BACKEND_WAYLAND)
        return wayland_platform_clipboard_set(text, len);
    return x11_platform_clipboard_set(text, len);
}

int hello_tty_platform_clipboard_get(uint8_t *buf, int max_len) {
    if (g_backend == HELLO_TTY_BACKEND_WAYLAND)
        return wayland_platform_clipboard_get(buf, max_len);
    return x11_platform_clipboard_get(buf, max_len);
}

// ---------- Accessors for GPU layer ----------

void* hello_tty_platform_get_display(void) {
    if (g_backend == HELLO_TTY_BACKEND_WAYLAND)
        return wayland_platform_get_display();
    return x11_platform_get_display();
}

int hello_tty_platform_get_backend_type(void) {
    return g_backend;
}

#endif // __linux__ && HELLO_TTY_PLATFORM_LINUX
