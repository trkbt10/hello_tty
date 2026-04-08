// hello_tty_stub.c — C bridge between the stable C ABI and MoonBit exports.
//
// Maps the clean public API (hello_tty_core.h) to MoonBit mangled names.
// Handles Bytes <-> C string conversion.
//
// MoonBit mangling pattern for package "trkbt10/hello_tty/src/bridge":
//   prefix = _M0FP47trkbt1010hello__tty3src6bridge
//
// Generated from moon build output (MoonBit 0.1.20260330).

#include "hello_tty_core.h"

#include <stdlib.h>
#include <string.h>
#include <stdint.h>

// ---------- Mangled MoonBit export names ----------

// Legacy single-session API
#define mbt_ffi_init              _M0FP47trkbt1010hello__tty3src6bridge9ffi__init
#define mbt_ffi_process_output    _M0FP47trkbt1010hello__tty3src6bridge20ffi__process__output
#define mbt_ffi_handle_key        _M0FP47trkbt1010hello__tty3src6bridge16ffi__handle__key
#define mbt_ffi_resize            _M0FP47trkbt1010hello__tty3src6bridge11ffi__resize
#define mbt_ffi_get_title         _M0FP47trkbt1010hello__tty3src6bridge15ffi__get__title
#define mbt_ffi_get_grid          _M0FP47trkbt1010hello__tty3src6bridge14ffi__get__grid
#define mbt_ffi_get_modes         _M0FP47trkbt1010hello__tty3src6bridge15ffi__get__modes
#define mbt_ffi_focus_event       _M0FP47trkbt1010hello__tty3src6bridge17ffi__focus__event
#define mbt_ffi_shutdown          _M0FP47trkbt1010hello__tty3src6bridge13ffi__shutdown

// Session management
#define mbt_ffi_create_session    _M0FP47trkbt1010hello__tty3src6bridge20ffi__create__session
#define mbt_ffi_destroy_session   _M0FP47trkbt1010hello__tty3src6bridge21ffi__destroy__session
#define mbt_ffi_switch_session    _M0FP47trkbt1010hello__tty3src6bridge20ffi__switch__session
#define mbt_ffi_list_sessions     _M0FP47trkbt1010hello__tty3src6bridge19ffi__list__sessions
#define mbt_ffi_get_active_session _M0FP47trkbt1010hello__tty3src6bridge25ffi__get__active__session

// Cursor (lightweight query)
#define mbt_ffi_get_cursor        _M0FP47trkbt1010hello__tty3src6bridge16ffi__get__cursor

// GPU rendering
#define mbt_ffi_gpu_init          _M0FP47trkbt1010hello__tty3src6bridge14ffi__gpu__init
#define mbt_ffi_gpu_resize        _M0FP47trkbt1010hello__tty3src6bridge16ffi__gpu__resize
#define mbt_ffi_render_frame      _M0FP47trkbt1010hello__tty3src6bridge18ffi__render__frame
#define mbt_ffi_render_frame_for  _M0FP47trkbt1010hello__tty3src6bridge23ffi__render__frame__for

// Input classification
#define mbt_ffi_classify_key      _M0FP47trkbt1010hello__tty3src6bridge18ffi__classify__key

// Theme & metrics
#define mbt_ffi_get_theme         _M0FP47trkbt1010hello__tty3src6bridge15ffi__get__theme
#define mbt_ffi_get_cell_metrics  _M0FP47trkbt1010hello__tty3src6bridge23ffi__get__cell__metrics

// Tab & Panel management (layout-aware)
#define mbt_ffi_create_tab        _M0FP47trkbt1010hello__tty3src6bridge16ffi__create__tab
#define mbt_ffi_close_tab         _M0FP47trkbt1010hello__tty3src6bridge15ffi__close__tab
#define mbt_ffi_switch_tab        _M0FP47trkbt1010hello__tty3src6bridge16ffi__switch__tab
#define mbt_ffi_next_tab          _M0FP47trkbt1010hello__tty3src6bridge14ffi__next__tab
#define mbt_ffi_prev_tab          _M0FP47trkbt1010hello__tty3src6bridge14ffi__prev__tab
#define mbt_ffi_list_tabs         _M0FP47trkbt1010hello__tty3src6bridge15ffi__list__tabs
#define mbt_ffi_split_panel       _M0FP47trkbt1010hello__tty3src6bridge17ffi__split__panel
#define mbt_ffi_close_panel       _M0FP47trkbt1010hello__tty3src6bridge17ffi__close__panel
#define mbt_ffi_focus_panel       _M0FP47trkbt1010hello__tty3src6bridge17ffi__focus__panel
#define mbt_ffi_focus_panel_by_index _M0FP47trkbt1010hello__tty3src6bridge28ffi__focus__panel__by__index
#define mbt_ffi_focus_direction   _M0FP47trkbt1010hello__tty3src6bridge21ffi__focus__direction
#define mbt_ffi_get_layout        _M0FP47trkbt1010hello__tty3src6bridge16ffi__get__layout
#define mbt_ffi_get_all_panels    _M0FP47trkbt1010hello__tty3src6bridge21ffi__get__all__panels
#define mbt_ffi_get_focused_panel_id _M0FP47trkbt1010hello__tty3src6bridge28ffi__get__focused__panel__id

// Panel resize notification
#define mbt_ffi_notify_panel_resize _M0FP47trkbt1010hello__tty3src6bridge26ffi__notify__panel__resize

// Layout resize (MoonBit SoT for panel dimensions)
#define mbt_ffi_resize_layout     _M0FP47trkbt1010hello__tty3src6bridge19ffi__resize__layout
#define mbt_ffi_resize_layout_px  _M0FP47trkbt1010hello__tty3src6bridge23ffi__resize__layout__px

// Coordinate conversion
#define mbt_ffi_pixel_to_grid     _M0FP47trkbt1010hello__tty3src6bridge20ffi__pixel__to__grid

// GPU multi-surface
#define mbt_ffi_gpu_register_surface _M0FP47trkbt1010hello__tty3src6bridge27ffi__gpu__register__surface
#define mbt_ffi_gpu_surface_destroy _M0FP47trkbt1010hello__tty3src6bridge26ffi__gpu__surface__destroy
#define mbt_ffi_gpu_surface_resize  _M0FP47trkbt1010hello__tty3src6bridge25ffi__gpu__surface__resize

// Session-targeted operations
#define mbt_ffi_process_output_for _M0FP47trkbt1010hello__tty3src6bridge25ffi__process__output__for
#define mbt_ffi_get_grid_for      _M0FP47trkbt1010hello__tty3src6bridge19ffi__get__grid__for
#define mbt_ffi_handle_key_for    _M0FP47trkbt1010hello__tty3src6bridge21ffi__handle__key__for
#define mbt_ffi_resize_session    _M0FP47trkbt1010hello__tty3src6bridge20ffi__resize__session

// Viewport / Scrollback
#define mbt_ffi_scroll_viewport_up    _M0FP47trkbt1010hello__tty3src6bridge25ffi__scroll__viewport__up
#define mbt_ffi_scroll_viewport_down  _M0FP47trkbt1010hello__tty3src6bridge27ffi__scroll__viewport__down
#define mbt_ffi_reset_viewport        _M0FP47trkbt1010hello__tty3src6bridge20ffi__reset__viewport
#define mbt_ffi_get_viewport_offset   _M0FP47trkbt1010hello__tty3src6bridge26ffi__get__viewport__offset
#define mbt_ffi_get_scrollback_length _M0FP47trkbt1010hello__tty3src6bridge28ffi__get__scrollback__length

// ---------- MoonBit runtime interface ----------

#include "moonbit.h"

extern void moonbit_init(void);

// MoonBit exported functions
// Legacy single-session
extern int32_t         mbt_ffi_init(moonbit_bytes_t rows, moonbit_bytes_t cols);
extern int32_t         mbt_ffi_process_output(moonbit_bytes_t data);
extern moonbit_bytes_t mbt_ffi_handle_key(moonbit_bytes_t key, moonbit_bytes_t mods);
extern int32_t         mbt_ffi_resize(moonbit_bytes_t rows, moonbit_bytes_t cols);
extern moonbit_bytes_t mbt_ffi_get_title(void);
extern moonbit_bytes_t mbt_ffi_get_grid(void);
extern moonbit_bytes_t mbt_ffi_get_modes(void);
extern moonbit_bytes_t mbt_ffi_focus_event(moonbit_bytes_t gained);
extern int32_t         mbt_ffi_shutdown(void);

// Session management (create returns JSON bytes, not int)
extern moonbit_bytes_t mbt_ffi_create_session(moonbit_bytes_t rows, moonbit_bytes_t cols);
extern int32_t         mbt_ffi_destroy_session(moonbit_bytes_t id);
extern int32_t         mbt_ffi_switch_session(moonbit_bytes_t id);
extern moonbit_bytes_t mbt_ffi_list_sessions(void);
extern int32_t         mbt_ffi_get_active_session(void);

// Cursor
extern moonbit_bytes_t mbt_ffi_get_cursor(void);

// GPU rendering
extern int32_t         mbt_ffi_gpu_init(moonbit_bytes_t surface, moonbit_bytes_t width, moonbit_bytes_t height);
extern int32_t         mbt_ffi_gpu_resize(moonbit_bytes_t width, moonbit_bytes_t height);
extern int32_t         mbt_ffi_render_frame(void);
extern int32_t         mbt_ffi_render_frame_for(moonbit_bytes_t session_id);

// Input classification
extern int32_t         mbt_ffi_classify_key(moonbit_bytes_t key, moonbit_bytes_t mods, moonbit_bytes_t has_marked);

// Theme & metrics
extern moonbit_bytes_t mbt_ffi_get_theme(void);
extern moonbit_bytes_t mbt_ffi_get_cell_metrics(void);

// Tab & Panel management
extern moonbit_bytes_t mbt_ffi_create_tab(moonbit_bytes_t rows, moonbit_bytes_t cols);
extern int32_t         mbt_ffi_close_tab(moonbit_bytes_t tab_id);
extern int32_t         mbt_ffi_switch_tab(moonbit_bytes_t tab_id);
extern int32_t         mbt_ffi_next_tab(void);
extern int32_t         mbt_ffi_prev_tab(void);
extern moonbit_bytes_t mbt_ffi_list_tabs(void);
extern moonbit_bytes_t mbt_ffi_split_panel(moonbit_bytes_t panel_id, moonbit_bytes_t direction);
extern int32_t         mbt_ffi_close_panel(moonbit_bytes_t panel_id);
extern int32_t         mbt_ffi_focus_panel(moonbit_bytes_t panel_id);
extern int32_t         mbt_ffi_focus_panel_by_index(moonbit_bytes_t index);
extern int32_t         mbt_ffi_focus_direction(moonbit_bytes_t direction);
extern moonbit_bytes_t mbt_ffi_get_layout(void);
extern moonbit_bytes_t mbt_ffi_get_all_panels(void);
extern int32_t         mbt_ffi_get_focused_panel_id(void);

// Panel resize notification
extern moonbit_bytes_t mbt_ffi_notify_panel_resize(moonbit_bytes_t panel_id, moonbit_bytes_t first_size_px, moonbit_bytes_t total_size_px);

// Layout resize
extern moonbit_bytes_t mbt_ffi_resize_layout(moonbit_bytes_t rows, moonbit_bytes_t cols);
extern moonbit_bytes_t mbt_ffi_resize_layout_px(moonbit_bytes_t width_px, moonbit_bytes_t height_px);

// Coordinate conversion
extern moonbit_bytes_t mbt_ffi_pixel_to_grid(moonbit_bytes_t x_px, moonbit_bytes_t y_px, moonbit_bytes_t view_height_px);

// GPU multi-surface
extern int32_t         mbt_ffi_gpu_register_surface(moonbit_bytes_t session_id, moonbit_bytes_t surface_id);
extern int32_t         mbt_ffi_gpu_surface_destroy(moonbit_bytes_t session_id);
extern int32_t         mbt_ffi_gpu_surface_resize(moonbit_bytes_t session_id, moonbit_bytes_t width, moonbit_bytes_t height);

// Session-targeted operations
extern int32_t         mbt_ffi_process_output_for(moonbit_bytes_t session_id, moonbit_bytes_t data);
extern moonbit_bytes_t mbt_ffi_get_grid_for(moonbit_bytes_t session_id);
extern moonbit_bytes_t mbt_ffi_handle_key_for(moonbit_bytes_t session_id, moonbit_bytes_t key, moonbit_bytes_t mods);
extern int32_t         mbt_ffi_resize_session(moonbit_bytes_t session_id, moonbit_bytes_t rows, moonbit_bytes_t cols);

// Viewport / Scrollback
extern int32_t         mbt_ffi_scroll_viewport_up(moonbit_bytes_t session_id, moonbit_bytes_t lines);
extern int32_t         mbt_ffi_scroll_viewport_down(moonbit_bytes_t session_id, moonbit_bytes_t lines);
extern int32_t         mbt_ffi_reset_viewport(moonbit_bytes_t session_id);
extern int32_t         mbt_ffi_get_viewport_offset(moonbit_bytes_t session_id);
extern int32_t         mbt_ffi_get_scrollback_length(moonbit_bytes_t session_id);

// ---------- Initialization ----------

static int moonbit_initialized = 0;

static void ensure_init(void) {
    if (!moonbit_initialized) {
        moonbit_init();
        moonbit_initialized = 1;
    }
}

// ---------- Bytes <-> C string conversion ----------

static moonbit_bytes_t cstr_to_moonbit_bytes(const char *str) {
    if (!str) {
        return moonbit_make_bytes(0, 0);
    }
    int32_t len = (int32_t)strlen(str);
    moonbit_bytes_t bytes = moonbit_make_bytes_raw(len);
    memcpy((void *)bytes, str, (size_t)len);
    return bytes;
}

static char *moonbit_bytes_to_cstr(moonbit_bytes_t bytes) {
    if (!bytes) return NULL;
    int32_t len = (int32_t)Moonbit_array_length(bytes);
    if (len <= 0) return NULL;
    char *result = (char *)malloc((size_t)(len + 1));
    if (!result) return NULL;
    memcpy(result, (const void *)bytes, (size_t)len);
    result[len] = '\0';
    return result;
}

// ---------- Legacy single-session C API ----------

int32_t hello_tty_init(const char *rows, const char *cols) {
    ensure_init();
    moonbit_bytes_t rb = cstr_to_moonbit_bytes(rows);
    moonbit_bytes_t cb = cstr_to_moonbit_bytes(cols);
    return mbt_ffi_init(rb, cb);
}

int32_t hello_tty_shutdown(void) {
    if (!moonbit_initialized) return 0;
    return mbt_ffi_shutdown();
}

int32_t hello_tty_process_output(const char *data) {
    ensure_init();
    moonbit_bytes_t db = cstr_to_moonbit_bytes(data);
    return mbt_ffi_process_output(db);
}

char *hello_tty_handle_key(const char *key_code, const char *modifiers) {
    ensure_init();
    moonbit_bytes_t kb = cstr_to_moonbit_bytes(key_code);
    moonbit_bytes_t mb = cstr_to_moonbit_bytes(modifiers);
    moonbit_bytes_t result = mbt_ffi_handle_key(kb, mb);
    return moonbit_bytes_to_cstr(result);
}

char *hello_tty_get_grid(void) {
    ensure_init();
    moonbit_bytes_t result = mbt_ffi_get_grid();
    return moonbit_bytes_to_cstr(result);
}

char *hello_tty_get_cursor(void) {
    ensure_init();
    moonbit_bytes_t result = mbt_ffi_get_cursor();
    return moonbit_bytes_to_cstr(result);
}

char *hello_tty_get_title(void) {
    ensure_init();
    moonbit_bytes_t result = mbt_ffi_get_title();
    return moonbit_bytes_to_cstr(result);
}

char *hello_tty_get_modes(void) {
    ensure_init();
    moonbit_bytes_t result = mbt_ffi_get_modes();
    return moonbit_bytes_to_cstr(result);
}

int32_t hello_tty_resize(const char *rows, const char *cols) {
    ensure_init();
    moonbit_bytes_t rb = cstr_to_moonbit_bytes(rows);
    moonbit_bytes_t cb = cstr_to_moonbit_bytes(cols);
    return mbt_ffi_resize(rb, cb);
}

char *hello_tty_focus_event(const char *gained) {
    ensure_init();
    moonbit_bytes_t gb = cstr_to_moonbit_bytes(gained);
    moonbit_bytes_t result = mbt_ffi_focus_event(gb);
    return moonbit_bytes_to_cstr(result);
}

void hello_tty_free_string(char *str) {
    free(str);
}

// ---------- Session Management ----------

char *hello_tty_create_session(const char *rows, const char *cols) {
    ensure_init();
    moonbit_bytes_t rb = cstr_to_moonbit_bytes(rows);
    moonbit_bytes_t cb = cstr_to_moonbit_bytes(cols);
    moonbit_bytes_t result = mbt_ffi_create_session(rb, cb);
    return moonbit_bytes_to_cstr(result);
}

int32_t hello_tty_destroy_session(const char *session_id) {
    ensure_init();
    moonbit_bytes_t ib = cstr_to_moonbit_bytes(session_id);
    return mbt_ffi_destroy_session(ib);
}

int32_t hello_tty_switch_session(const char *session_id) {
    ensure_init();
    moonbit_bytes_t ib = cstr_to_moonbit_bytes(session_id);
    return mbt_ffi_switch_session(ib);
}

char *hello_tty_list_sessions(void) {
    ensure_init();
    moonbit_bytes_t result = mbt_ffi_list_sessions();
    return moonbit_bytes_to_cstr(result);
}

int32_t hello_tty_get_active_session(void) {
    ensure_init();
    return mbt_ffi_get_active_session();
}

// ---------- GPU Rendering ----------

int32_t hello_tty_gpu_init_bridge(const char *surface_handle, const char *width, const char *height) {
    ensure_init();
    moonbit_bytes_t sb = cstr_to_moonbit_bytes(surface_handle);
    moonbit_bytes_t wb = cstr_to_moonbit_bytes(width);
    moonbit_bytes_t hb = cstr_to_moonbit_bytes(height);
    return mbt_ffi_gpu_init(sb, wb, hb);
}

int32_t hello_tty_render_frame(void) {
    if (!moonbit_initialized) return -1;
    return mbt_ffi_render_frame();
}

int32_t hello_tty_render_frame_for(const char *session_id) {
    if (!moonbit_initialized) return -1;
    moonbit_bytes_t sb = cstr_to_moonbit_bytes(session_id);
    return mbt_ffi_render_frame_for(sb);
}

int32_t hello_tty_classify_key(const char *key_code, const char *modifiers, const char *has_marked_text) {
    ensure_init();
    moonbit_bytes_t kb = cstr_to_moonbit_bytes(key_code);
    moonbit_bytes_t mb = cstr_to_moonbit_bytes(modifiers);
    moonbit_bytes_t hb = cstr_to_moonbit_bytes(has_marked_text);
    return mbt_ffi_classify_key(kb, mb, hb);
}

int32_t hello_tty_gpu_resize_bridge(const char *width, const char *height) {
    if (!moonbit_initialized) return -1;
    moonbit_bytes_t wb = cstr_to_moonbit_bytes(width);
    moonbit_bytes_t hb = cstr_to_moonbit_bytes(height);
    return mbt_ffi_gpu_resize(wb, hb);
}

// ---------- Theme ----------

// ---------- Layout Resize ----------

char *hello_tty_resize_layout(const char *total_rows, const char *total_cols) {
    ensure_init();
    moonbit_bytes_t rb = cstr_to_moonbit_bytes(total_rows);
    moonbit_bytes_t cb = cstr_to_moonbit_bytes(total_cols);
    moonbit_bytes_t result = mbt_ffi_resize_layout(rb, cb);
    return moonbit_bytes_to_cstr(result);
}

char *hello_tty_resize_layout_px(const char *width_px, const char *height_px) {
    ensure_init();
    moonbit_bytes_t wb = cstr_to_moonbit_bytes(width_px);
    moonbit_bytes_t hb = cstr_to_moonbit_bytes(height_px);
    moonbit_bytes_t result = mbt_ffi_resize_layout_px(wb, hb);
    return moonbit_bytes_to_cstr(result);
}

// ---------- Coordinate Conversion ----------

char *hello_tty_pixel_to_grid(const char *x_px, const char *y_px, const char *view_height_px) {
    ensure_init();
    moonbit_bytes_t xb = cstr_to_moonbit_bytes(x_px);
    moonbit_bytes_t yb = cstr_to_moonbit_bytes(y_px);
    moonbit_bytes_t hb = cstr_to_moonbit_bytes(view_height_px);
    moonbit_bytes_t result = mbt_ffi_pixel_to_grid(xb, yb, hb);
    return moonbit_bytes_to_cstr(result);
}

// ---------- Panel Resize Notification ----------

char *hello_tty_notify_panel_resize(const char *panel_id,
                                     const char *first_size_px,
                                     const char *total_size_px) {
    ensure_init();
    moonbit_bytes_t pb = cstr_to_moonbit_bytes(panel_id);
    moonbit_bytes_t fb = cstr_to_moonbit_bytes(first_size_px);
    moonbit_bytes_t tb = cstr_to_moonbit_bytes(total_size_px);
    moonbit_bytes_t result = mbt_ffi_notify_panel_resize(pb, fb, tb);
    return moonbit_bytes_to_cstr(result);
}

// ---------- GPU Multi-Surface ----------

int32_t hello_tty_gpu_register_surface(const char *session_id, const char *surface_id) {
    ensure_init();
    moonbit_bytes_t sb = cstr_to_moonbit_bytes(session_id);
    moonbit_bytes_t ib = cstr_to_moonbit_bytes(surface_id);
    return mbt_ffi_gpu_register_surface(sb, ib);
}

int32_t hello_tty_gpu_surface_destroy_bridge(const char *session_id) {
    ensure_init();
    moonbit_bytes_t sb = cstr_to_moonbit_bytes(session_id);
    return mbt_ffi_gpu_surface_destroy(sb);
}

int32_t hello_tty_gpu_surface_resize_bridge(const char *session_id, const char *width, const char *height) {
    ensure_init();
    moonbit_bytes_t sb = cstr_to_moonbit_bytes(session_id);
    moonbit_bytes_t wb = cstr_to_moonbit_bytes(width);
    moonbit_bytes_t hb = cstr_to_moonbit_bytes(height);
    return mbt_ffi_gpu_surface_resize(sb, wb, hb);
}

char *hello_tty_get_theme(void) {
    ensure_init();
    moonbit_bytes_t result = mbt_ffi_get_theme();
    return moonbit_bytes_to_cstr(result);
}

char *hello_tty_get_cell_metrics(void) {
    ensure_init();
    moonbit_bytes_t result = mbt_ffi_get_cell_metrics();
    return moonbit_bytes_to_cstr(result);
}

// ---------- Tab & Panel Management ----------

char *hello_tty_create_tab(const char *rows, const char *cols) {
    ensure_init();
    moonbit_bytes_t rb = cstr_to_moonbit_bytes(rows);
    moonbit_bytes_t cb = cstr_to_moonbit_bytes(cols);
    moonbit_bytes_t result = mbt_ffi_create_tab(rb, cb);
    return moonbit_bytes_to_cstr(result);
}

int32_t hello_tty_close_tab(const char *tab_id) {
    ensure_init();
    moonbit_bytes_t ib = cstr_to_moonbit_bytes(tab_id);
    return mbt_ffi_close_tab(ib);
}

int32_t hello_tty_switch_tab(const char *tab_id) {
    ensure_init();
    moonbit_bytes_t ib = cstr_to_moonbit_bytes(tab_id);
    return mbt_ffi_switch_tab(ib);
}

int32_t hello_tty_next_tab(void) {
    ensure_init();
    return mbt_ffi_next_tab();
}

int32_t hello_tty_prev_tab(void) {
    ensure_init();
    return mbt_ffi_prev_tab();
}

char *hello_tty_list_tabs(void) {
    ensure_init();
    moonbit_bytes_t result = mbt_ffi_list_tabs();
    return moonbit_bytes_to_cstr(result);
}

char *hello_tty_split_panel(const char *panel_id, const char *direction) {
    ensure_init();
    moonbit_bytes_t pb = cstr_to_moonbit_bytes(panel_id);
    moonbit_bytes_t db = cstr_to_moonbit_bytes(direction);
    moonbit_bytes_t result = mbt_ffi_split_panel(pb, db);
    return moonbit_bytes_to_cstr(result);
}

int32_t hello_tty_close_panel(const char *panel_id) {
    ensure_init();
    moonbit_bytes_t pb = cstr_to_moonbit_bytes(panel_id);
    return mbt_ffi_close_panel(pb);
}

int32_t hello_tty_focus_panel(const char *panel_id) {
    ensure_init();
    moonbit_bytes_t pb = cstr_to_moonbit_bytes(panel_id);
    return mbt_ffi_focus_panel(pb);
}

int32_t hello_tty_focus_panel_by_index(const char *index) {
    ensure_init();
    moonbit_bytes_t ib = cstr_to_moonbit_bytes(index);
    return mbt_ffi_focus_panel_by_index(ib);
}

int32_t hello_tty_focus_direction(const char *direction) {
    ensure_init();
    moonbit_bytes_t db = cstr_to_moonbit_bytes(direction);
    return mbt_ffi_focus_direction(db);
}

char *hello_tty_get_layout(void) {
    ensure_init();
    moonbit_bytes_t result = mbt_ffi_get_layout();
    return moonbit_bytes_to_cstr(result);
}

char *hello_tty_get_all_panels(void) {
    ensure_init();
    moonbit_bytes_t result = mbt_ffi_get_all_panels();
    return moonbit_bytes_to_cstr(result);
}

int32_t hello_tty_get_focused_panel_id(void) {
    ensure_init();
    return mbt_ffi_get_focused_panel_id();
}

// ---------- Session-Targeted Operations ----------

int32_t hello_tty_process_output_for(const char *session_id, const char *data) {
    ensure_init();
    moonbit_bytes_t sb = cstr_to_moonbit_bytes(session_id);
    moonbit_bytes_t db = cstr_to_moonbit_bytes(data);
    return mbt_ffi_process_output_for(sb, db);
}

char *hello_tty_get_grid_for(const char *session_id) {
    ensure_init();
    moonbit_bytes_t sb = cstr_to_moonbit_bytes(session_id);
    moonbit_bytes_t result = mbt_ffi_get_grid_for(sb);
    return moonbit_bytes_to_cstr(result);
}

char *hello_tty_handle_key_for(const char *session_id, const char *key_code, const char *modifiers) {
    ensure_init();
    moonbit_bytes_t sb = cstr_to_moonbit_bytes(session_id);
    moonbit_bytes_t kb = cstr_to_moonbit_bytes(key_code);
    moonbit_bytes_t mb = cstr_to_moonbit_bytes(modifiers);
    moonbit_bytes_t result = mbt_ffi_handle_key_for(sb, kb, mb);
    return moonbit_bytes_to_cstr(result);
}

int32_t hello_tty_resize_session(const char *session_id, const char *rows, const char *cols) {
    ensure_init();
    moonbit_bytes_t sb = cstr_to_moonbit_bytes(session_id);
    moonbit_bytes_t rb = cstr_to_moonbit_bytes(rows);
    moonbit_bytes_t cb = cstr_to_moonbit_bytes(cols);
    return mbt_ffi_resize_session(sb, rb, cb);
}

// ---------- Viewport / Scrollback ----------

int32_t hello_tty_scroll_viewport_up(const char *session_id, const char *lines) {
    ensure_init();
    moonbit_bytes_t sb = cstr_to_moonbit_bytes(session_id);
    moonbit_bytes_t lb = cstr_to_moonbit_bytes(lines);
    return mbt_ffi_scroll_viewport_up(sb, lb);
}

int32_t hello_tty_scroll_viewport_down(const char *session_id, const char *lines) {
    ensure_init();
    moonbit_bytes_t sb = cstr_to_moonbit_bytes(session_id);
    moonbit_bytes_t lb = cstr_to_moonbit_bytes(lines);
    return mbt_ffi_scroll_viewport_down(sb, lb);
}

int32_t hello_tty_reset_viewport(const char *session_id) {
    ensure_init();
    moonbit_bytes_t sb = cstr_to_moonbit_bytes(session_id);
    return mbt_ffi_reset_viewport(sb);
}

int32_t hello_tty_get_viewport_offset(const char *session_id) {
    ensure_init();
    moonbit_bytes_t sb = cstr_to_moonbit_bytes(session_id);
    return mbt_ffi_get_viewport_offset(sb);
}

int32_t hello_tty_get_scrollback_length(const char *session_id) {
    ensure_init();
    moonbit_bytes_t sb = cstr_to_moonbit_bytes(session_id);
    return mbt_ffi_get_scrollback_length(sb);
}
