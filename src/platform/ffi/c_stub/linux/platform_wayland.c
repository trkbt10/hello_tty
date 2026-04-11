// Wayland windowing backend for Linux.
//
// Implements the platform FFI functions using:
//   - wl_compositor + xdg-shell for window management
//   - xkbcommon for keyboard input with proper key repeat via timerfd
//   - zwp_text_input_v3 for IME / composed input (CJK etc.)
//   - wl_data_device for native clipboard (no subprocess fallback)
//   - wl_pointer for mouse events
//   - wl_output scale for DPI
//   - wl_surface_frame() for proper frame callback timing
//   - wl_surface handle for wgpu Vulkan surface creation
//
// Compile with: -lwayland-client -lxkbcommon

#if defined(__linux__) && defined(HELLO_TTY_PLATFORM_LINUX)

#define _GNU_SOURCE  // for pipe2()
#include <wayland-client.h>
#include <xkbcommon/xkbcommon.h>

#include <stdint.h>
#include <string.h>
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>
#include <sys/mman.h>
#include <sys/timerfd.h>
#include <errno.h>
#include <time.h>
#include <poll.h>
#include <fcntl.h>

#include "protocols/xdg-shell-client-protocol.h"
#include "protocols/xdg-decoration-client-protocol.h"
#include "protocols/text-input-unstable-v3-client-protocol.h"

#include "platform_backend.h"

// ---------- Internal state ----------

typedef struct {
    struct wl_display *display;
    struct wl_registry *registry;
    struct wl_compositor *compositor;
    struct wl_seat *seat;
    struct wl_keyboard *keyboard;
    struct wl_pointer *pointer;
    struct wl_output *output;
    struct xdg_wm_base *xdg_wm_base;
    struct zxdg_decoration_manager_v1 *decoration_manager;

    // Data device (clipboard)
    struct wl_data_device_manager *data_device_manager;
    struct wl_data_device *data_device;
    struct wl_data_source *data_source;   // Active when we own clipboard
    char *clipboard_text;                  // Text we're offering
    int clipboard_len;
    // Incoming paste
    struct wl_data_offer *data_offer;      // Current incoming offer
    int data_offer_has_text;               // Whether offer includes text/plain

    // Text input (IME)
    struct zwp_text_input_manager_v3 *text_input_manager;
    struct zwp_text_input_v3 *text_input;

    // Keyboard state
    struct xkb_context *xkb_context;
    struct xkb_keymap *xkb_keymap;
    struct xkb_state *xkb_state;

    // Key repeat via timerfd
    int repeat_fd;         // timerfd file descriptor (-1 if not created)
    int32_t repeat_rate;   // keys per second (0 = disabled)
    int32_t repeat_delay;  // ms before first repeat
    uint32_t repeat_keycode; // keycode currently repeating
    xkb_keysym_t repeat_sym;
    int repeat_mods;

    // Output scale
    int output_scale;

    // Serial tracking (needed for clipboard)
    uint32_t last_serial;

    // Track which window slot has keyboard/pointer focus
    int keyboard_focus_slot;
    int pointer_focus_slot;

    int initialized;
} WaylandState;

static WaylandState g_wl = {0};

typedef struct {
    struct wl_surface *surface;
    struct xdg_surface *xdg_surface;
    struct xdg_toplevel *toplevel;
    struct zxdg_toplevel_decoration_v1 *decoration;
    struct wl_callback *frame_callback;
    int alive;
    int width, height;
    int configured;
    int frame_done;  // Set by frame callback

    // Event queue (ring buffer, same as X11)
    int event_types[256];
    int event_data[256][4];
    int event_head;
    int event_tail;
} WaylandWindow;

static WaylandWindow g_wl_windows[MAX_WINDOWS] = {0};

// ---------- Event queue helpers ----------

static void wl_push_event(int slot, int type, int d0, int d1, int d2, int d3) {
    int next = (g_wl_windows[slot].event_tail + 1) % 256;
    if (next == g_wl_windows[slot].event_head) return;
    g_wl_windows[slot].event_types[g_wl_windows[slot].event_tail] = type;
    g_wl_windows[slot].event_data[g_wl_windows[slot].event_tail][0] = d0;
    g_wl_windows[slot].event_data[g_wl_windows[slot].event_tail][1] = d1;
    g_wl_windows[slot].event_data[g_wl_windows[slot].event_tail][2] = d2;
    g_wl_windows[slot].event_data[g_wl_windows[slot].event_tail][3] = d3;
    g_wl_windows[slot].event_tail = next;
}

static int wl_pop_event(int slot, int *type, int data[4]) {
    if (g_wl_windows[slot].event_head == g_wl_windows[slot].event_tail) return 0;
    *type = g_wl_windows[slot].event_types[g_wl_windows[slot].event_head];
    memcpy(data, g_wl_windows[slot].event_data[g_wl_windows[slot].event_head], sizeof(int) * 4);
    g_wl_windows[slot].event_head = (g_wl_windows[slot].event_head + 1) % 256;
    return 1;
}

static int wl_find_slot_by_surface(struct wl_surface *surface) {
    for (int i = 0; i < MAX_WINDOWS; i++) {
        if (g_wl_windows[i].alive && g_wl_windows[i].surface == surface) return i;
    }
    return -1;
}

// ---------- Key repeat ----------

static void arm_key_repeat(uint32_t keycode, xkb_keysym_t sym, int mods) {
    if (g_wl.repeat_rate <= 0 || g_wl.repeat_fd < 0) return;

    g_wl.repeat_keycode = keycode;
    g_wl.repeat_sym = sym;
    g_wl.repeat_mods = mods;

    // interval_ns = 1e9 / rate
    long interval_ns = 1000000000L / g_wl.repeat_rate;
    struct itimerspec its = {
        .it_value = {
            .tv_sec = g_wl.repeat_delay / 1000,
            .tv_nsec = (g_wl.repeat_delay % 1000) * 1000000L,
        },
        .it_interval = {
            .tv_sec = interval_ns / 1000000000L,
            .tv_nsec = interval_ns % 1000000000L,
        },
    };
    timerfd_settime(g_wl.repeat_fd, 0, &its, NULL);
}

static void disarm_key_repeat(void) {
    if (g_wl.repeat_fd < 0) return;
    struct itimerspec its = {0};
    timerfd_settime(g_wl.repeat_fd, 0, &its, NULL);
    g_wl.repeat_keycode = 0;
}

// Push key event for a keysym (shared by key press and repeat)
static void push_key_for_sym(int slot, xkb_keysym_t sym, int mods, xkb_keycode_t xkb_key) {
    int key = translate_keysym((unsigned long)sym);
    if (key != 0) {
        wl_push_event(slot, 1, key, mods, 0, 0);
        return;
    }

    // Try UTF-8 text
    if (g_wl.xkb_state) {
        char buf[32];
        int len = (int)xkb_state_key_get_utf8(g_wl.xkb_state, xkb_key, buf, sizeof(buf));
        if (len > 0) {
            for (int i = 0; i < len; i++) {
                wl_push_event(slot, 1, (int)(unsigned char)buf[i], 0, 0, 0);
            }
        }
    }
}

static void process_key_repeat(void) {
    if (g_wl.repeat_fd < 0) return;

    uint64_t expirations = 0;
    ssize_t n = read(g_wl.repeat_fd, &expirations, sizeof(expirations));
    if (n != sizeof(expirations) || expirations == 0) return;

    int slot = g_wl.keyboard_focus_slot;
    if (slot < 0 || slot >= MAX_WINDOWS || !g_wl_windows[slot].alive) return;

    // Generate repeat events (cap to avoid flood)
    if (expirations > 8) expirations = 8;
    xkb_keycode_t xkb_key = g_wl.repeat_keycode + 8;
    for (uint64_t i = 0; i < expirations; i++) {
        push_key_for_sym(slot, g_wl.repeat_sym, g_wl.repeat_mods, xkb_key);
    }
}

// ---------- Frame callback ----------

static void frame_done(void *data, struct wl_callback *callback, uint32_t time) {
    (void)time;
    WaylandWindow *win = (WaylandWindow *)data;
    win->frame_done = 1;
    if (callback) {
        wl_callback_destroy(callback);
        win->frame_callback = NULL;
    }
}

static const struct wl_callback_listener frame_listener = {
    .done = frame_done,
};

// ---------- XDG WM Base listener ----------

static void xdg_wm_base_ping(void *data, struct xdg_wm_base *wm_base, uint32_t serial) {
    (void)data;
    xdg_wm_base_pong(wm_base, serial);
}

static const struct xdg_wm_base_listener xdg_wm_base_listener = {
    .ping = xdg_wm_base_ping,
};

// ---------- XDG Surface listener ----------

static void xdg_surface_configure(void *data, struct xdg_surface *xdg_surface, uint32_t serial) {
    WaylandWindow *win = (WaylandWindow *)data;
    xdg_surface_ack_configure(xdg_surface, serial);
    win->configured = 1;
}

static const struct xdg_surface_listener xdg_surface_listener = {
    .configure = xdg_surface_configure,
};

// ---------- XDG Toplevel listener ----------

static void xdg_toplevel_configure(void *data, struct xdg_toplevel *toplevel,
                                   int32_t width, int32_t height,
                                   struct wl_array *states) {
    (void)toplevel;
    (void)states;
    WaylandWindow *win = (WaylandWindow *)data;

    if (width > 0 && height > 0) {
        if (width != win->width || height != win->height) {
            win->width = width;
            win->height = height;
            for (int i = 0; i < MAX_WINDOWS; i++) {
                if (&g_wl_windows[i] == win) {
                    wl_push_event(i, 2, width, height, 0, 0);
                    break;
                }
            }
        }
    }
}

static void xdg_toplevel_close(void *data, struct xdg_toplevel *toplevel) {
    (void)toplevel;
    WaylandWindow *win = (WaylandWindow *)data;
    for (int i = 0; i < MAX_WINDOWS; i++) {
        if (&g_wl_windows[i] == win) {
            wl_push_event(i, 3, 0, 0, 0, 0);
            break;
        }
    }
}

static void xdg_toplevel_configure_bounds(void *data, struct xdg_toplevel *toplevel,
                                          int32_t width, int32_t height) {
    (void)data; (void)toplevel; (void)width; (void)height;
}

static void xdg_toplevel_wm_capabilities(void *data, struct xdg_toplevel *toplevel,
                                         struct wl_array *capabilities) {
    (void)data; (void)toplevel; (void)capabilities;
}

static const struct xdg_toplevel_listener xdg_toplevel_listener = {
    .configure = xdg_toplevel_configure,
    .close = xdg_toplevel_close,
    .configure_bounds = xdg_toplevel_configure_bounds,
    .wm_capabilities = xdg_toplevel_wm_capabilities,
};

// ---------- Text Input v3 listener (IME) ----------

static void text_input_enter(void *data, struct zwp_text_input_v3 *ti,
                             struct wl_surface *surface) {
    (void)data; (void)surface;
    // Enable text input when surface gets focus
    zwp_text_input_v3_enable(ti);
    zwp_text_input_v3_set_content_type(ti,
        ZWP_TEXT_INPUT_V3_CONTENT_HINT_NONE,
        ZWP_TEXT_INPUT_V3_CONTENT_PURPOSE_TERMINAL);
    zwp_text_input_v3_commit(ti);
}

static void text_input_leave(void *data, struct zwp_text_input_v3 *ti,
                             struct wl_surface *surface) {
    (void)data; (void)surface;
    zwp_text_input_v3_disable(ti);
    zwp_text_input_v3_commit(ti);
}

static void text_input_preedit_string(void *data, struct zwp_text_input_v3 *ti,
                                      const char *text, int32_t cursor_begin,
                                      int32_t cursor_end) {
    (void)data; (void)ti; (void)cursor_begin; (void)cursor_end;
    // Preedit (composition preview) — we could display this inline,
    // but for a terminal emulator we just wait for commit_string.
    (void)text;
}

static void text_input_commit_string(void *data, struct zwp_text_input_v3 *ti,
                                     const char *text) {
    (void)data; (void)ti;
    if (!text || text[0] == '\0') return;

    int slot = g_wl.keyboard_focus_slot;
    if (slot < 0 || slot >= MAX_WINDOWS || !g_wl_windows[slot].alive) return;

    // Push committed text as individual bytes (MoonBit side handles UTF-8)
    int len = (int)strlen(text);
    for (int i = 0; i < len; i++) {
        wl_push_event(slot, 1, (int)(unsigned char)text[i], 0, 0, 0);
    }
}

static void text_input_delete_surrounding_text(void *data, struct zwp_text_input_v3 *ti,
                                               uint32_t before_length,
                                               uint32_t after_length) {
    (void)data; (void)ti; (void)before_length; (void)after_length;
}

static void text_input_done(void *data, struct zwp_text_input_v3 *ti,
                            uint32_t serial) {
    (void)data; (void)ti; (void)serial;
}

static const struct zwp_text_input_v3_listener text_input_listener = {
    .enter = text_input_enter,
    .leave = text_input_leave,
    .preedit_string = text_input_preedit_string,
    .commit_string = text_input_commit_string,
    .delete_surrounding_text = text_input_delete_surrounding_text,
    .done = text_input_done,
};

// ---------- Keyboard listener ----------

static void keyboard_keymap(void *data, struct wl_keyboard *keyboard,
                           uint32_t format, int32_t fd, uint32_t size) {
    (void)data; (void)keyboard;

    if (format != WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) {
        close(fd);
        return;
    }

    char *map_str = mmap(NULL, size, PROT_READ, MAP_PRIVATE, fd, 0);
    if (map_str == MAP_FAILED) {
        close(fd);
        return;
    }

    if (g_wl.xkb_state) { xkb_state_unref(g_wl.xkb_state); g_wl.xkb_state = NULL; }
    if (g_wl.xkb_keymap) { xkb_keymap_unref(g_wl.xkb_keymap); g_wl.xkb_keymap = NULL; }

    g_wl.xkb_keymap = xkb_keymap_new_from_string(g_wl.xkb_context, map_str,
                                                   XKB_KEYMAP_FORMAT_TEXT_V1,
                                                   XKB_KEYMAP_COMPILE_NO_FLAGS);
    munmap(map_str, size);
    close(fd);

    if (g_wl.xkb_keymap) {
        g_wl.xkb_state = xkb_state_new(g_wl.xkb_keymap);
    }
}

static void keyboard_enter(void *data, struct wl_keyboard *keyboard,
                           uint32_t serial, struct wl_surface *surface,
                           struct wl_array *keys) {
    (void)data; (void)keyboard; (void)keys;
    g_wl.last_serial = serial;
    int slot = wl_find_slot_by_surface(surface);
    if (slot >= 0) {
        g_wl.keyboard_focus_slot = slot;
        wl_push_event(slot, 4, 0, 0, 0, 0);
    }
}

static void keyboard_leave(void *data, struct wl_keyboard *keyboard,
                           uint32_t serial, struct wl_surface *surface) {
    (void)data; (void)keyboard; (void)serial;
    int slot = wl_find_slot_by_surface(surface);
    if (slot >= 0) {
        wl_push_event(slot, 5, 0, 0, 0, 0);
        g_wl.keyboard_focus_slot = -1;
    }
    disarm_key_repeat();
}

static int translate_xkb_modifiers(void) {
    if (!g_wl.xkb_state) return 0;
    int mods = 0;
    if (xkb_state_mod_name_is_active(g_wl.xkb_state, XKB_MOD_NAME_SHIFT, XKB_STATE_MODS_EFFECTIVE))
        mods |= 1;
    if (xkb_state_mod_name_is_active(g_wl.xkb_state, XKB_MOD_NAME_CTRL, XKB_STATE_MODS_EFFECTIVE))
        mods |= 2;
    if (xkb_state_mod_name_is_active(g_wl.xkb_state, XKB_MOD_NAME_ALT, XKB_STATE_MODS_EFFECTIVE))
        mods |= 4;
    if (xkb_state_mod_name_is_active(g_wl.xkb_state, XKB_MOD_NAME_LOGO, XKB_STATE_MODS_EFFECTIVE))
        mods |= 8;
    return mods;
}

static void keyboard_key(void *data, struct wl_keyboard *keyboard,
                         uint32_t serial, uint32_t time,
                         uint32_t keycode, uint32_t state) {
    (void)data; (void)keyboard; (void)time;
    g_wl.last_serial = serial;

    int slot = g_wl.keyboard_focus_slot;
    if (slot < 0 || slot >= MAX_WINDOWS || !g_wl_windows[slot].alive) return;
    if (!g_wl.xkb_state) return;

    xkb_keycode_t xkb_key = keycode + 8;
    xkb_keysym_t sym = xkb_state_key_get_one_sym(g_wl.xkb_state, xkb_key);

    if (state == WL_KEYBOARD_KEY_STATE_PRESSED) {
        int mods = translate_xkb_modifiers();
        push_key_for_sym(slot, sym, mods, xkb_key);

        // Arm key repeat if the key produces output and keymap says it repeats
        if (g_wl.xkb_keymap && xkb_keymap_key_repeats(g_wl.xkb_keymap, xkb_key)) {
            arm_key_repeat(keycode, sym, mods);
        }
    } else {
        // Key released — disarm repeat if it's the repeating key
        if (keycode == g_wl.repeat_keycode) {
            disarm_key_repeat();
        }
    }
}

static void keyboard_modifiers(void *data, struct wl_keyboard *keyboard,
                               uint32_t serial,
                               uint32_t mods_depressed, uint32_t mods_latched,
                               uint32_t mods_locked, uint32_t group) {
    (void)data; (void)keyboard;
    g_wl.last_serial = serial;
    if (g_wl.xkb_state) {
        xkb_state_update_mask(g_wl.xkb_state,
                              mods_depressed, mods_latched, mods_locked,
                              0, 0, group);
    }
}

static void keyboard_repeat_info(void *data, struct wl_keyboard *keyboard,
                                 int32_t rate, int32_t delay) {
    (void)data; (void)keyboard;
    g_wl.repeat_rate = rate;
    g_wl.repeat_delay = delay;
}

static const struct wl_keyboard_listener keyboard_listener = {
    .keymap = keyboard_keymap,
    .enter = keyboard_enter,
    .leave = keyboard_leave,
    .key = keyboard_key,
    .modifiers = keyboard_modifiers,
    .repeat_info = keyboard_repeat_info,
};

// ---------- Pointer listener ----------

static double g_pointer_x = 0, g_pointer_y = 0;

static void pointer_enter(void *data, struct wl_pointer *pointer,
                          uint32_t serial, struct wl_surface *surface,
                          wl_fixed_t sx, wl_fixed_t sy) {
    (void)data; (void)pointer; (void)serial;
    g_pointer_x = wl_fixed_to_double(sx);
    g_pointer_y = wl_fixed_to_double(sy);
    g_wl.pointer_focus_slot = wl_find_slot_by_surface(surface);
}

static void pointer_leave(void *data, struct wl_pointer *pointer,
                          uint32_t serial, struct wl_surface *surface) {
    (void)data; (void)pointer; (void)serial; (void)surface;
    g_wl.pointer_focus_slot = -1;
}

static void pointer_motion(void *data, struct wl_pointer *pointer,
                           uint32_t time, wl_fixed_t sx, wl_fixed_t sy) {
    (void)data; (void)pointer; (void)time;
    g_pointer_x = wl_fixed_to_double(sx);
    g_pointer_y = wl_fixed_to_double(sy);
    int slot = g_wl.pointer_focus_slot;
    if (slot >= 0 && slot < MAX_WINDOWS && g_wl_windows[slot].alive) {
        wl_push_event(slot, 6, (int)g_pointer_x, (int)g_pointer_y, -1, 0);
    }
}

static void pointer_button(void *data, struct wl_pointer *pointer,
                           uint32_t serial, uint32_t time,
                           uint32_t button, uint32_t state) {
    (void)data; (void)pointer; (void)serial; (void)time;
    int slot = g_wl.pointer_focus_slot;
    if (slot < 0 || slot >= MAX_WINDOWS || !g_wl_windows[slot].alive) return;

    int x = (int)g_pointer_x;
    int y = (int)g_pointer_y;

    // Linux button codes: BTN_LEFT=0x110, BTN_RIGHT=0x111, BTN_MIDDLE=0x112
    int btn = 0;
    if (button == 0x110)      btn = 0;
    else if (button == 0x111) btn = 2;
    else if (button == 0x112) btn = 1;

    if (state == WL_POINTER_BUTTON_STATE_PRESSED) {
        int mods = translate_xkb_modifiers();
        wl_push_event(slot, 6, x, y, btn, mods);
    } else {
        wl_push_event(slot, 6, x, y, btn | 0x100, 0);
    }
}

static void pointer_axis(void *data, struct wl_pointer *pointer,
                         uint32_t time, uint32_t axis, wl_fixed_t value) {
    (void)data; (void)pointer; (void)time;
    int slot = g_wl.pointer_focus_slot;
    if (slot < 0 || slot >= MAX_WINDOWS || !g_wl_windows[slot].alive) return;

    if (axis == WL_POINTER_AXIS_VERTICAL_SCROLL) {
        double v = wl_fixed_to_double(value);
        int delta = v < 0 ? 3 : -3;
        wl_push_event(slot, 6, (int)g_pointer_x, (int)g_pointer_y, -2, delta);
    }
}

static void pointer_frame(void *data, struct wl_pointer *pointer) {
    (void)data; (void)pointer;
}
static void pointer_axis_source(void *data, struct wl_pointer *pointer, uint32_t source) {
    (void)data; (void)pointer; (void)source;
}
static void pointer_axis_stop(void *data, struct wl_pointer *pointer,
                              uint32_t time, uint32_t axis) {
    (void)data; (void)pointer; (void)time; (void)axis;
}
static void pointer_axis_discrete(void *data, struct wl_pointer *pointer,
                                  uint32_t axis, int32_t discrete) {
    (void)data; (void)pointer; (void)axis; (void)discrete;
}
static void pointer_axis_value120(void *data, struct wl_pointer *pointer,
                                  uint32_t axis, int32_t value120) {
    (void)data; (void)pointer; (void)axis; (void)value120;
}
static void pointer_axis_relative_direction(void *data, struct wl_pointer *pointer,
                                            uint32_t axis, uint32_t direction) {
    (void)data; (void)pointer; (void)axis; (void)direction;
}

static const struct wl_pointer_listener pointer_listener = {
    .enter = pointer_enter,
    .leave = pointer_leave,
    .motion = pointer_motion,
    .button = pointer_button,
    .axis = pointer_axis,
    .frame = pointer_frame,
    .axis_source = pointer_axis_source,
    .axis_stop = pointer_axis_stop,
    .axis_discrete = pointer_axis_discrete,
    .axis_value120 = pointer_axis_value120,
    .axis_relative_direction = pointer_axis_relative_direction,
};

// ---------- Data device listener (clipboard) ----------

static void data_offer_offer(void *data, struct wl_data_offer *offer,
                             const char *mime_type) {
    (void)data; (void)offer;
    if (strcmp(mime_type, "text/plain;charset=utf-8") == 0 ||
        strcmp(mime_type, "text/plain") == 0) {
        g_wl.data_offer_has_text = 1;
    }
}

static void data_offer_source_actions(void *data, struct wl_data_offer *offer,
                                      uint32_t source_actions) {
    (void)data; (void)offer; (void)source_actions;
}

static void data_offer_action(void *data, struct wl_data_offer *offer,
                              uint32_t dnd_action) {
    (void)data; (void)offer; (void)dnd_action;
}

static const struct wl_data_offer_listener data_offer_listener = {
    .offer = data_offer_offer,
    .source_actions = data_offer_source_actions,
    .action = data_offer_action,
};

static void data_device_data_offer(void *data, struct wl_data_device *device,
                                   struct wl_data_offer *offer) {
    (void)data; (void)device;
    // New offer — destroy old one if any
    if (g_wl.data_offer) {
        wl_data_offer_destroy(g_wl.data_offer);
    }
    g_wl.data_offer = offer;
    g_wl.data_offer_has_text = 0;
    wl_data_offer_add_listener(offer, &data_offer_listener, NULL);
}

static void data_device_enter(void *data, struct wl_data_device *device,
                              uint32_t serial, struct wl_surface *surface,
                              wl_fixed_t x, wl_fixed_t y,
                              struct wl_data_offer *offer) {
    (void)data; (void)device; (void)serial; (void)surface;
    (void)x; (void)y; (void)offer;
}

static void data_device_leave(void *data, struct wl_data_device *device) {
    (void)data; (void)device;
}

static void data_device_motion(void *data, struct wl_data_device *device,
                               uint32_t time, wl_fixed_t x, wl_fixed_t y) {
    (void)data; (void)device; (void)time; (void)x; (void)y;
}

static void data_device_drop(void *data, struct wl_data_device *device) {
    (void)data; (void)device;
}

static void data_device_selection(void *data, struct wl_data_device *device,
                                  struct wl_data_offer *offer) {
    (void)data; (void)device;
    // Track the current clipboard selection offer
    if (g_wl.data_offer && g_wl.data_offer != offer) {
        wl_data_offer_destroy(g_wl.data_offer);
    }
    g_wl.data_offer = offer;
    // Note: data_offer_offer callback already set data_offer_has_text
}

static const struct wl_data_device_listener data_device_listener = {
    .data_offer = data_device_data_offer,
    .enter = data_device_enter,
    .leave = data_device_leave,
    .motion = data_device_motion,
    .drop = data_device_drop,
    .selection = data_device_selection,
};

// Data source listener (for when other apps request our clipboard)
static void data_source_target(void *data, struct wl_data_source *source,
                               const char *mime_type) {
    (void)data; (void)source; (void)mime_type;
}

static void data_source_send(void *data, struct wl_data_source *source,
                             const char *mime_type, int32_t fd) {
    (void)data; (void)source; (void)mime_type;
    // Write our clipboard text to the requesting app's fd
    if (g_wl.clipboard_text && g_wl.clipboard_len > 0) {
        // Write in a loop to handle partial writes
        int written = 0;
        while (written < g_wl.clipboard_len) {
            ssize_t n = write(fd, g_wl.clipboard_text + written,
                              (size_t)(g_wl.clipboard_len - written));
            if (n <= 0) break;
            written += (int)n;
        }
    }
    close(fd);
}

static void data_source_cancelled(void *data, struct wl_data_source *source) {
    (void)data;
    // We lost clipboard ownership
    wl_data_source_destroy(source);
    if (g_wl.data_source == source) {
        g_wl.data_source = NULL;
    }
}

static void data_source_dnd_drop_performed(void *data, struct wl_data_source *source) {
    (void)data; (void)source;
}
static void data_source_dnd_finished(void *data, struct wl_data_source *source) {
    (void)data; (void)source;
}
static void data_source_action(void *data, struct wl_data_source *source,
                               uint32_t dnd_action) {
    (void)data; (void)source; (void)dnd_action;
}

static const struct wl_data_source_listener data_source_listener = {
    .target = data_source_target,
    .send = data_source_send,
    .cancelled = data_source_cancelled,
    .dnd_drop_performed = data_source_dnd_drop_performed,
    .dnd_finished = data_source_dnd_finished,
    .action = data_source_action,
};

// ---------- Output listener ----------

static void output_geometry(void *data, struct wl_output *output,
                           int32_t x, int32_t y, int32_t pw, int32_t ph,
                           int32_t subpixel, const char *make, const char *model,
                           int32_t transform) {
    (void)data; (void)output; (void)x; (void)y; (void)pw; (void)ph;
    (void)subpixel; (void)make; (void)model; (void)transform;
}
static void output_mode(void *data, struct wl_output *output,
                        uint32_t flags, int32_t w, int32_t h, int32_t refresh) {
    (void)data; (void)output; (void)flags; (void)w; (void)h; (void)refresh;
}
static void output_scale(void *data, struct wl_output *output, int32_t factor) {
    (void)data; (void)output;
    g_wl.output_scale = factor;
}
static void output_done(void *data, struct wl_output *output) {
    (void)data; (void)output;
}
static void output_name(void *data, struct wl_output *output, const char *name) {
    (void)data; (void)output; (void)name;
}
static void output_description(void *data, struct wl_output *output, const char *desc) {
    (void)data; (void)output; (void)desc;
}

static const struct wl_output_listener output_listener = {
    .geometry = output_geometry,
    .mode = output_mode,
    .scale = output_scale,
    .done = output_done,
    .name = output_name,
    .description = output_description,
};

// ---------- Seat listener ----------

static void seat_capabilities(void *data, struct wl_seat *seat, uint32_t caps) {
    (void)data;

    if (caps & WL_SEAT_CAPABILITY_KEYBOARD) {
        if (!g_wl.keyboard) {
            g_wl.keyboard = wl_seat_get_keyboard(seat);
            wl_keyboard_add_listener(g_wl.keyboard, &keyboard_listener, NULL);
        }
    } else if (g_wl.keyboard) {
        wl_keyboard_destroy(g_wl.keyboard);
        g_wl.keyboard = NULL;
    }

    if (caps & WL_SEAT_CAPABILITY_POINTER) {
        if (!g_wl.pointer) {
            g_wl.pointer = wl_seat_get_pointer(seat);
            wl_pointer_add_listener(g_wl.pointer, &pointer_listener, NULL);
        }
    } else if (g_wl.pointer) {
        wl_pointer_destroy(g_wl.pointer);
        g_wl.pointer = NULL;
    }
}

static void seat_name(void *data, struct wl_seat *seat, const char *name) {
    (void)data; (void)seat; (void)name;
}

static const struct wl_seat_listener seat_listener = {
    .capabilities = seat_capabilities,
    .name = seat_name,
};

// ---------- Registry listener ----------

static void registry_global(void *data, struct wl_registry *registry,
                           uint32_t name, const char *interface, uint32_t version) {
    (void)data;

    if (strcmp(interface, wl_compositor_interface.name) == 0) {
        g_wl.compositor = wl_registry_bind(registry, name, &wl_compositor_interface,
                                            version < 4 ? version : 4);
    } else if (strcmp(interface, xdg_wm_base_interface.name) == 0) {
        g_wl.xdg_wm_base = wl_registry_bind(registry, name, &xdg_wm_base_interface,
                                              version < 2 ? version : 2);
        xdg_wm_base_add_listener(g_wl.xdg_wm_base, &xdg_wm_base_listener, NULL);
    } else if (strcmp(interface, wl_seat_interface.name) == 0) {
        g_wl.seat = wl_registry_bind(registry, name, &wl_seat_interface,
                                      version < 5 ? version : 5);
        wl_seat_add_listener(g_wl.seat, &seat_listener, NULL);
    } else if (strcmp(interface, wl_output_interface.name) == 0) {
        if (!g_wl.output) {
            g_wl.output = wl_registry_bind(registry, name, &wl_output_interface,
                                            version < 4 ? version : 4);
            wl_output_add_listener(g_wl.output, &output_listener, NULL);
        }
    } else if (strcmp(interface, zxdg_decoration_manager_v1_interface.name) == 0) {
        g_wl.decoration_manager = wl_registry_bind(registry, name,
                                                    &zxdg_decoration_manager_v1_interface, 1);
    } else if (strcmp(interface, wl_data_device_manager_interface.name) == 0) {
        g_wl.data_device_manager = wl_registry_bind(registry, name,
                                                     &wl_data_device_manager_interface,
                                                     version < 3 ? version : 3);
    } else if (strcmp(interface, zwp_text_input_manager_v3_interface.name) == 0) {
        g_wl.text_input_manager = wl_registry_bind(registry, name,
                                                    &zwp_text_input_manager_v3_interface, 1);
    }
}

static void registry_global_remove(void *data, struct wl_registry *registry, uint32_t name) {
    (void)data; (void)registry; (void)name;
}

static const struct wl_registry_listener registry_listener = {
    .global = registry_global,
    .global_remove = registry_global_remove,
};

// ---------- Public Wayland backend API ----------

int wayland_platform_init(void) {
    if (g_wl.initialized) return 0;

    g_wl.display = wl_display_connect(NULL);
    if (!g_wl.display) {
        fprintf(stderr, "hello_tty: failed to connect to Wayland display\n");
        return -1;
    }

    g_wl.output_scale = 1;
    g_wl.keyboard_focus_slot = -1;
    g_wl.pointer_focus_slot = -1;
    g_wl.repeat_fd = -1;

    g_wl.xkb_context = xkb_context_new(XKB_CONTEXT_NO_FLAGS);
    if (!g_wl.xkb_context) {
        wl_display_disconnect(g_wl.display);
        g_wl.display = NULL;
        return -1;
    }

    g_wl.registry = wl_display_get_registry(g_wl.display);
    wl_registry_add_listener(g_wl.registry, &registry_listener, NULL);

    wl_display_roundtrip(g_wl.display);
    wl_display_roundtrip(g_wl.display);

    if (!g_wl.compositor || !g_wl.xdg_wm_base) {
        fprintf(stderr, "hello_tty: Wayland compositor missing required interfaces\n");
        wayland_platform_shutdown();
        return -1;
    }

    // Create timerfd for key repeat
    g_wl.repeat_fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);

    // Set up data device for clipboard
    if (g_wl.data_device_manager && g_wl.seat) {
        g_wl.data_device = wl_data_device_manager_get_data_device(
            g_wl.data_device_manager, g_wl.seat);
        if (g_wl.data_device) {
            wl_data_device_add_listener(g_wl.data_device, &data_device_listener, NULL);
        }
    }

    // Set up text input for IME
    if (g_wl.text_input_manager && g_wl.seat) {
        g_wl.text_input = zwp_text_input_manager_v3_get_text_input(
            g_wl.text_input_manager, g_wl.seat);
        if (g_wl.text_input) {
            zwp_text_input_v3_add_listener(g_wl.text_input, &text_input_listener, NULL);
        }
    }

    g_wl.initialized = 1;
    fprintf(stderr, "hello_tty: Wayland backend initialized (scale=%d, clipboard=%s, ime=%s)\n",
            g_wl.output_scale,
            g_wl.data_device ? "native" : "unavailable",
            g_wl.text_input ? "text-input-v3" : "unavailable");
    return 0;
}

int wayland_platform_create_window(int width, int height) {
    if (!g_wl.initialized) return -1;

    int slot = -1;
    for (int i = 0; i < MAX_WINDOWS; i++) {
        if (!g_wl_windows[i].alive) { slot = i; break; }
    }
    if (slot < 0) return -1;

    WaylandWindow *win = &g_wl_windows[slot];
    memset(win, 0, sizeof(*win));

    win->surface = wl_compositor_create_surface(g_wl.compositor);
    if (!win->surface) return -1;

    win->xdg_surface = xdg_wm_base_get_xdg_surface(g_wl.xdg_wm_base, win->surface);
    if (!win->xdg_surface) {
        wl_surface_destroy(win->surface);
        win->surface = NULL;
        return -1;
    }
    xdg_surface_add_listener(win->xdg_surface, &xdg_surface_listener, win);

    win->toplevel = xdg_surface_get_toplevel(win->xdg_surface);
    if (!win->toplevel) {
        xdg_surface_destroy(win->xdg_surface);
        wl_surface_destroy(win->surface);
        win->xdg_surface = NULL;
        win->surface = NULL;
        return -1;
    }
    xdg_toplevel_add_listener(win->toplevel, &xdg_toplevel_listener, win);
    xdg_toplevel_set_title(win->toplevel, "hello_tty");
    xdg_toplevel_set_app_id(win->toplevel, "hello_tty");
    xdg_toplevel_set_min_size(win->toplevel, 200, 100);

    if (g_wl.decoration_manager) {
        win->decoration = zxdg_decoration_manager_v1_get_toplevel_decoration(
            g_wl.decoration_manager, win->toplevel);
        if (win->decoration) {
            zxdg_toplevel_decoration_v1_set_mode(win->decoration,
                ZXDG_TOPLEVEL_DECORATION_V1_MODE_SERVER_SIDE);
        }
    }

    win->width = width;
    win->height = height;
    win->alive = 1;
    win->frame_done = 1; // Ready for first frame

    wl_surface_commit(win->surface);

    while (!win->configured) {
        wl_display_roundtrip(g_wl.display);
    }

    return slot + 1;
}

void wayland_platform_set_title(const uint8_t *title, int title_len, int window) {
    int slot = window - 1;
    if (slot < 0 || slot >= MAX_WINDOWS || !g_wl_windows[slot].alive) return;

    char buf[1024];
    int len = title_len < 1023 ? title_len : 1023;
    memcpy(buf, title, (size_t)len);
    buf[len] = '\0';
    xdg_toplevel_set_title(g_wl_windows[slot].toplevel, buf);
}

int wayland_platform_poll_event(int window, int32_t *event_buf) {
    int slot = window - 1;
    if (slot < 0 || slot >= MAX_WINDOWS || !g_wl_windows[slot].alive) return 0;

    // Check both Wayland fd and key repeat timerfd
    struct pollfd pfds[2];
    int nfds = 0;

    pfds[nfds].fd = wl_display_get_fd(g_wl.display);
    pfds[nfds].events = POLLIN;
    nfds++;

    if (g_wl.repeat_fd >= 0) {
        pfds[nfds].fd = g_wl.repeat_fd;
        pfds[nfds].events = POLLIN;
        nfds++;
    }

    wl_display_flush(g_wl.display);

    if (poll(pfds, (nfds_t)nfds, 0) > 0) {
        if (pfds[0].revents & POLLIN) {
            wl_display_dispatch(g_wl.display);
        }
        if (nfds > 1 && (pfds[1].revents & POLLIN)) {
            process_key_repeat();
        }
    } else {
        wl_display_dispatch_pending(g_wl.display);
    }

    int type = 0;
    int data[4] = {0};
    if (wl_pop_event(slot, &type, data)) {
        event_buf[0] = data[0];
        event_buf[1] = data[1];
        event_buf[2] = data[2];
        event_buf[3] = data[3];
        return type;
    }

    return 0;
}

void wayland_platform_request_redraw(int window) {
    int slot = window - 1;
    if (slot < 0 || slot >= MAX_WINDOWS || !g_wl_windows[slot].alive) return;

    WaylandWindow *win = &g_wl_windows[slot];

    // Request a frame callback for vblank-synchronized rendering
    if (!win->frame_callback) {
        win->frame_callback = wl_surface_frame(win->surface);
        wl_callback_add_listener(win->frame_callback, &frame_listener, win);
        win->frame_done = 0;
    }
    wl_surface_commit(win->surface);
}

int wayland_platform_get_vulkan_surface(int window) {
    int slot = window - 1;
    if (slot < 0 || slot >= MAX_WINDOWS || !g_wl_windows[slot].alive) return 0;
    return (int)(uintptr_t)g_wl_windows[slot].surface;
}

int wayland_platform_get_dpi_scale(int window) {
    (void)window;
    int scale = g_wl.output_scale;
    if (scale < 1) scale = 1;
    return scale * 100;
}

void wayland_platform_destroy_window(int window) {
    int slot = window - 1;
    if (slot < 0 || slot >= MAX_WINDOWS || !g_wl_windows[slot].alive) return;

    WaylandWindow *win = &g_wl_windows[slot];

    if (win->frame_callback) {
        wl_callback_destroy(win->frame_callback);
        win->frame_callback = NULL;
    }
    if (win->decoration) {
        zxdg_toplevel_decoration_v1_destroy(win->decoration);
        win->decoration = NULL;
    }
    if (win->toplevel) {
        xdg_toplevel_destroy(win->toplevel);
        win->toplevel = NULL;
    }
    if (win->xdg_surface) {
        xdg_surface_destroy(win->xdg_surface);
        win->xdg_surface = NULL;
    }
    if (win->surface) {
        wl_surface_destroy(win->surface);
        win->surface = NULL;
    }

    win->alive = 0;
}

void wayland_platform_shutdown(void) {
    if (!g_wl.initialized && !g_wl.display) return;

    disarm_key_repeat();

    for (int i = 0; i < MAX_WINDOWS; i++) {
        if (g_wl_windows[i].alive) {
            wayland_platform_destroy_window(i + 1);
        }
    }

    if (g_wl.text_input) {
        zwp_text_input_v3_destroy(g_wl.text_input);
        g_wl.text_input = NULL;
    }
    if (g_wl.text_input_manager) {
        zwp_text_input_manager_v3_destroy(g_wl.text_input_manager);
        g_wl.text_input_manager = NULL;
    }

    if (g_wl.data_source) {
        wl_data_source_destroy(g_wl.data_source);
        g_wl.data_source = NULL;
    }
    if (g_wl.data_offer) {
        wl_data_offer_destroy(g_wl.data_offer);
        g_wl.data_offer = NULL;
    }
    if (g_wl.data_device) {
        wl_data_device_destroy(g_wl.data_device);
        g_wl.data_device = NULL;
    }
    if (g_wl.data_device_manager) {
        wl_data_device_manager_destroy(g_wl.data_device_manager);
        g_wl.data_device_manager = NULL;
    }

    if (g_wl.clipboard_text) {
        free(g_wl.clipboard_text);
        g_wl.clipboard_text = NULL;
        g_wl.clipboard_len = 0;
    }

    if (g_wl.keyboard) { wl_keyboard_destroy(g_wl.keyboard); g_wl.keyboard = NULL; }
    if (g_wl.pointer) { wl_pointer_destroy(g_wl.pointer); g_wl.pointer = NULL; }
    if (g_wl.seat) { wl_seat_destroy(g_wl.seat); g_wl.seat = NULL; }
    if (g_wl.output) { wl_output_destroy(g_wl.output); g_wl.output = NULL; }
    if (g_wl.decoration_manager) {
        zxdg_decoration_manager_v1_destroy(g_wl.decoration_manager);
        g_wl.decoration_manager = NULL;
    }
    if (g_wl.xdg_wm_base) { xdg_wm_base_destroy(g_wl.xdg_wm_base); g_wl.xdg_wm_base = NULL; }
    if (g_wl.compositor) { wl_compositor_destroy(g_wl.compositor); g_wl.compositor = NULL; }
    if (g_wl.registry) { wl_registry_destroy(g_wl.registry); g_wl.registry = NULL; }

    if (g_wl.repeat_fd >= 0) { close(g_wl.repeat_fd); g_wl.repeat_fd = -1; }
    if (g_wl.xkb_state) { xkb_state_unref(g_wl.xkb_state); g_wl.xkb_state = NULL; }
    if (g_wl.xkb_keymap) { xkb_keymap_unref(g_wl.xkb_keymap); g_wl.xkb_keymap = NULL; }
    if (g_wl.xkb_context) { xkb_context_unref(g_wl.xkb_context); g_wl.xkb_context = NULL; }

    if (g_wl.display) { wl_display_disconnect(g_wl.display); g_wl.display = NULL; }

    g_wl.initialized = 0;
}

int wayland_platform_clipboard_set(const uint8_t *text, int len) {
    if (!g_wl.initialized || len <= 0) return -1;
    if (!g_wl.data_device_manager || !g_wl.data_device) return -1;

    // Store the text
    if (g_wl.clipboard_text) free(g_wl.clipboard_text);
    g_wl.clipboard_text = (char *)malloc((size_t)len + 1);
    if (!g_wl.clipboard_text) return -1;
    memcpy(g_wl.clipboard_text, text, (size_t)len);
    g_wl.clipboard_text[len] = '\0';
    g_wl.clipboard_len = len;

    // Destroy old source
    if (g_wl.data_source) {
        wl_data_source_destroy(g_wl.data_source);
    }

    // Create new data source
    g_wl.data_source = wl_data_device_manager_create_data_source(g_wl.data_device_manager);
    if (!g_wl.data_source) return -1;

    wl_data_source_add_listener(g_wl.data_source, &data_source_listener, NULL);
    wl_data_source_offer(g_wl.data_source, "text/plain;charset=utf-8");
    wl_data_source_offer(g_wl.data_source, "text/plain");

    // Set as selection (clipboard)
    wl_data_device_set_selection(g_wl.data_device, g_wl.data_source, g_wl.last_serial);
    wl_display_flush(g_wl.display);

    return 0;
}

int wayland_platform_clipboard_get(uint8_t *buf, int max_len) {
    if (!g_wl.initialized) return -1;
    if (!g_wl.data_offer || !g_wl.data_offer_has_text) return -1;

    // Create a pipe and request the data
    int fds[2];
    if (pipe2(fds, O_CLOEXEC) != 0) return -1;

    wl_data_offer_receive(g_wl.data_offer, "text/plain;charset=utf-8", fds[1]);
    close(fds[1]);

    // We need to flush so the compositor sees our request,
    // then roundtrip so the source app writes to the pipe
    wl_display_flush(g_wl.display);
    wl_display_roundtrip(g_wl.display);

    // Read from pipe (non-blocking with timeout)
    int total = 0;
    struct pollfd pfd = { .fd = fds[0], .events = POLLIN };
    while (total < max_len) {
        if (poll(&pfd, 1, 100) <= 0) break; // 100ms timeout
        ssize_t n = read(fds[0], buf + total, (size_t)(max_len - total));
        if (n <= 0) break;
        total += (int)n;
    }
    close(fds[0]);

    return total > 0 ? total : -1;
}

void* wayland_platform_get_display(void) {
    return (void *)g_wl.display;
}

#endif // __linux__ && HELLO_TTY_PLATFORM_LINUX
