// hello_tty_core.h — Stable C ABI for the MoonBit terminal core.
//
// This header defines the public interface that platform adapters (Swift, GTK4)
// use to interact with the terminal state engine.
//
// All data crosses the boundary as C strings (UTF-8, null-terminated).
// Structured data is serialized as JSON.
// Returned strings MUST be freed by the caller via hello_tty_free_string().
//
// Following bartleby's FFI pattern:
//   Swift -> dlsym("hello_tty_*") -> this C API -> MoonBit exports

#ifndef HELLO_TTY_CORE_H
#define HELLO_TTY_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------- Session Management ----------
//
// Sessions are the MoonBit SoT for tab/window lifecycle.
// Each session owns an independent terminal + parser.
// Platform adapters (Swift TabManager) delegate here.

// Create a new session (terminal init + PTY spawn).
// Returns JSON: {"id":N,"fd":N} where id=session_id, fd=PTY master fd.
// Caller must free the returned string.
char *hello_tty_create_session(const char *rows, const char *cols);

// Destroy a session by ID. Returns 0 on success.
int32_t hello_tty_destroy_session(const char *session_id);

// Switch the active session. Returns 0 on success, -1 if not found.
int32_t hello_tty_switch_session(const char *session_id);

// List all sessions as JSON: [{"id":N,"title":"...","active":bool}, ...]
// Caller must free the returned string.
char *hello_tty_list_sessions(void);

// Get the active session ID. Returns -1 if no sessions.
int32_t hello_tty_get_active_session(void);

// ---------- Legacy Lifecycle (operates on active session) ----------

// Initialize terminal state. Creates a default session if none exists.
// rows, cols: terminal grid size as decimal strings.
// Returns 0 on success, -1 on failure.
int32_t hello_tty_init(const char *rows, const char *cols);

// Shut down all sessions and free resources.
// Returns 0 on success.
int32_t hello_tty_shutdown(void);

// ---------- Terminal I/O (active session) ----------

// Feed raw PTY output into the active session's terminal parser.
// data: raw bytes from the shell process.
// Returns 0 on success, -1 on failure.
int32_t hello_tty_process_output(const char *data);

// Translate a key event into the escape sequence to send to the PTY.
// key_code: virtual key code as decimal string.
// modifiers: modifier bitflags as decimal string (1=shift, 2=ctrl, 4=alt, 8=super).
// Returns the escape sequence string (caller must free), or NULL on error.
char *hello_tty_handle_key(const char *key_code, const char *modifiers);

// ---------- Terminal State (active session) ----------

// Get the current terminal grid as a JSON string.
// Colors are FULLY RESOLVED as [r,g,b] arrays (0-255).
// Platform adapters should NOT perform color resolution.
// Caller must free the returned string.
char *hello_tty_get_grid(void);

// Get cursor position and visibility (lightweight, no JSON overhead).
// Returns "row,col,visible,style" e.g. "5,12,1,block".
// Caller must free the returned string.
char *hello_tty_get_cursor(void);

// Get the window title (set via OSC 0/2).
// Caller must free the returned string.
char *hello_tty_get_title(void);

// Get terminal modes as a JSON string.
// Caller must free the returned string.
char *hello_tty_get_modes(void);

// ---------- Control (active session) ----------

// Resize the active session's terminal grid.
// rows, cols: new dimensions as decimal strings.
// Returns 0 on success.
int32_t hello_tty_resize(const char *rows, const char *cols);

// Get focus event escape sequence for focus tracking mode.
// gained: "1" for focus gained, "0" for focus lost.
// Returns escape sequence (caller must free), or NULL if focus tracking is off.
char *hello_tty_focus_event(const char *gained);

// ---------- Input Classification (MoonBit SoT) ----------

// Classify a key event. Returns:
//   0 = DirectToPty, 1 = ForwardToIme, 2 = ClipboardCopy, 3 = ClipboardPaste
int32_t hello_tty_classify_key(const char *key_code, const char *modifiers, const char *has_marked_text);

// ---------- Theme (MoonBit SoT) ----------

// Get theme configuration as JSON.
// Includes: name, is_dark, bg_alpha, fg/bg/cursor/selection as [r,g,b].
// Caller must free the returned string.
char *hello_tty_get_theme(void);

// Get cell metrics from the GPU font engine as JSON.
// Returns: {"cell_width":N, "cell_height":N, "dpi_scale":F}
// Ensures GPU is initialized. Caller must free the returned string.
char *hello_tty_get_cell_metrics(void);

// ---------- GPU Rendering (MoonBit Pipeline, Multi-Surface) ----------

// Register an already-created GPU surface with a session.
// The surface was created via hello_tty_gpu_surface_create (direct C FFI).
// This registers the session→surface mapping in MoonBit and ensures
// the GPU device/font/atlas are initialized.
int32_t hello_tty_gpu_register_surface(const char *session_id, const char *surface_id);

// Destroy a GPU surface for a session.
int32_t hello_tty_gpu_surface_destroy_bridge(const char *session_id);

// Resize a session's GPU surface.
int32_t hello_tty_gpu_surface_resize_bridge(const char *session_id, const char *width, const char *height);

// Legacy: Initialize GPU backend via MoonBit renderer (single surface).
int32_t hello_tty_gpu_init_bridge(const char *surface_handle, const char *width, const char *height);

// Render the current terminal state to the GPU.
int32_t hello_tty_render_frame(void);

// Render a specific session's terminal state to its own surface.
int32_t hello_tty_render_frame_for(const char *session_id);

// Legacy: Resize the GPU surface.
int32_t hello_tty_gpu_resize_bridge(const char *width, const char *height);

// ---------- PTY Session (posix_spawn, fork-safe) ----------

// Start a PTY session. Spawns a shell via posix_spawn (not fork).
// shell: path to shell executable.
// rows, cols: terminal dimensions.
// Returns master_fd (>= 0) on success, -1 on failure.
// Writes child PID to *pid_out.
int32_t hello_tty_pty_start(const char *shell, int32_t rows, int32_t cols, int32_t *pid_out);

// Poll PTY master for readability.
// Returns 1 if readable, 0 if timeout, -2 if EOF/HUP, -1 on error.
int32_t hello_tty_pty_poll(int32_t master_fd, int32_t timeout_ms);

// Read from PTY master. Returns bytes read into buf, 0 on EOF, -1 on error.
int32_t hello_tty_pty_read(int32_t master_fd, uint8_t *buf, int32_t max_len);

// Write to PTY master. Returns bytes written, -1 on error.
int32_t hello_tty_pty_write(int32_t master_fd, const uint8_t *data, int32_t len);

// Close PTY master fd.
void hello_tty_pty_close(int32_t master_fd);

// Resize PTY window (sends TIOCSWINSZ ioctl).
// Returns 0 on success, -1 on error.
int32_t hello_tty_pty_resize(int32_t master_fd, int32_t rows, int32_t cols);

// ---------- Tab & Panel Management (Layout-aware) ----------

// Create a new tab with a single panel.
// Returns JSON: {"tab_id":N,"panel_id":N,"session_id":N,"fd":N}
char *hello_tty_create_tab(const char *rows, const char *cols);

// Close a tab and all its panels/sessions.
int32_t hello_tty_close_tab(const char *tab_id);

// Switch to a tab by ID.
int32_t hello_tty_switch_tab(const char *tab_id);

// Switch to next/previous tab.
int32_t hello_tty_next_tab(void);
int32_t hello_tty_prev_tab(void);

// List all tabs as JSON: [{"id":N,"title":"...","active":bool}, ...]
char *hello_tty_list_tabs(void);

// Split a panel. direction: "0"=vertical, "1"=horizontal.
// Returns JSON: {"panel_id":N,"session_id":N,"fd":N,"existing_rows":N,"existing_cols":N}
// Returns NULL if panel is too small to split.
char *hello_tty_split_panel(const char *panel_id, const char *direction);

// Close a panel. Returns new focused session_id, or -1 if tab was closed.
int32_t hello_tty_close_panel(const char *panel_id);

// Focus a panel by ID.
int32_t hello_tty_focus_panel(const char *panel_id);

// Focus panel by DFS index (0-based).
int32_t hello_tty_focus_panel_by_index(const char *index);

// Focus neighboring panel. direction: "0"=up, "1"=down, "2"=left, "3"=right.
int32_t hello_tty_focus_direction(const char *direction);

// Get the layout tree of the active tab as JSON.
char *hello_tty_get_layout(void);

// Get all panels in the active tab as JSON.
char *hello_tty_get_all_panels(void);

// Get the focused panel ID (-1 if none).
int32_t hello_tty_get_focused_panel_id(void);

// ---------- Session-Targeted Operations ----------

// Feed PTY output into a specific session.
int32_t hello_tty_process_output_for(const char *session_id, const char *data);

// Get the grid of a specific session as JSON.
char *hello_tty_get_grid_for(const char *session_id);

// Handle a key on a specific session.
char *hello_tty_handle_key_for(const char *session_id, const char *key_code, const char *modifiers);

// Resize a specific session's terminal.
int32_t hello_tty_resize_session(const char *session_id, const char *rows, const char *cols);

// ---------- Layout Resize (MoonBit SoT) ----------

// Resize the layout using grid dimensions (rows/cols).
// Returns JSON: [{"panel_id":N,"session_id":N,"rows":N,"cols":N}, ...]
char *hello_tty_resize_layout(const char *total_rows, const char *total_cols);

// Resize the layout using pixel dimensions.
// MoonBit converts pixels → grid cells using its own cell metrics.
// Returns JSON: [{"panel_id":N,"session_id":N,"rows":N,"cols":N}, ...]
char *hello_tty_resize_layout_px(const char *width_px, const char *height_px);

// ---------- Panel Resize Notification ----------

// Notify that a divider has moved, giving the first child's new pixel size.
// panel_id: first leaf's panel ID (identifies which split).
// first_size_px: first child's pixel size along split axis.
// total_size_px: total available pixel size along split axis.
// Returns JSON: [{"panel_id":N,"session_id":N,"rows":N,"cols":N}, ...]
char *hello_tty_notify_panel_resize(const char *panel_id,
                                     const char *first_size_px,
                                     const char *total_size_px);

// ---------- Coordinate Conversion (MoonBit SoT for cell metrics) ----------

// Convert pixel coordinates to grid cell coordinates.
// Returns "row,col" string. Caller must free.
char *hello_tty_pixel_to_grid(const char *x_px, const char *y_px, const char *view_height_px);

// ---------- Memory ----------

// Free a string returned by any hello_tty_* function.
void hello_tty_free_string(char *str);

#ifdef __cplusplus
}
#endif

#endif // HELLO_TTY_CORE_H
