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
//   Swift → dlsym("hello_tty_*") → this C API → MoonBit exports

#ifndef HELLO_TTY_CORE_H
#define HELLO_TTY_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------- Lifecycle ----------

// Initialize the terminal with the given dimensions.
// rows, cols: terminal grid size as decimal strings.
// Returns 0 on success, -1 on failure.
int32_t hello_tty_init(const char *rows, const char *cols);

// Shut down the terminal state and free resources.
// Returns 0 on success.
int32_t hello_tty_shutdown(void);

// ---------- Terminal I/O ----------

// Feed raw PTY output into the terminal parser.
// data: raw bytes from the shell process.
// Returns 0 on success, -1 on failure.
int32_t hello_tty_process_output(const char *data);

// Translate a key event into the escape sequence to send to the PTY.
// key_code: virtual key code as decimal string.
// modifiers: modifier bitflags as decimal string (1=shift, 2=ctrl, 4=alt, 8=super).
// Returns the escape sequence string (caller must free), or NULL on error.
char *hello_tty_handle_key(const char *key_code, const char *modifiers);

// ---------- Terminal state ----------

// Get the current terminal grid as a JSON string.
// Returns JSON with rows, cols, cursor, and non-empty cells.
// Caller must free the returned string.
char *hello_tty_get_grid(void);

// Get the window title (set via OSC 0/2).
// Caller must free the returned string.
char *hello_tty_get_title(void);

// Get terminal modes as a JSON string.
// Caller must free the returned string.
char *hello_tty_get_modes(void);

// ---------- Control ----------

// Resize the terminal grid.
// rows, cols: new dimensions as decimal strings.
// Returns 0 on success.
int32_t hello_tty_resize(const char *rows, const char *cols);

// Get focus event escape sequence for focus tracking mode.
// gained: "1" for focus gained, "0" for focus lost.
// Returns escape sequence (caller must free), or NULL if focus tracking is off.
char *hello_tty_focus_event(const char *gained);

// ---------- PTY session (posix_spawn, fork-safe) ----------

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

// ---------- Memory ----------

// Free a string returned by any hello_tty_* function.
void hello_tty_free_string(char *str);

#ifdef __cplusplus
}
#endif

#endif // HELLO_TTY_CORE_H
