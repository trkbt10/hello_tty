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

#define mbt_ffi_init              _M0FP47trkbt1010hello__tty3src6bridge9ffi__init
#define mbt_ffi_process_output    _M0FP47trkbt1010hello__tty3src6bridge20ffi__process__output
#define mbt_ffi_handle_key        _M0FP47trkbt1010hello__tty3src6bridge16ffi__handle__key
#define mbt_ffi_resize            _M0FP47trkbt1010hello__tty3src6bridge11ffi__resize
#define mbt_ffi_get_title         _M0FP47trkbt1010hello__tty3src6bridge15ffi__get__title
#define mbt_ffi_get_grid          _M0FP47trkbt1010hello__tty3src6bridge14ffi__get__grid
#define mbt_ffi_get_modes         _M0FP47trkbt1010hello__tty3src6bridge15ffi__get__modes
#define mbt_ffi_focus_event       _M0FP47trkbt1010hello__tty3src6bridge17ffi__focus__event
#define mbt_ffi_shutdown          _M0FP47trkbt1010hello__tty3src6bridge13ffi__shutdown

// ---------- MoonBit runtime interface ----------

// Include MoonBit runtime header for type definitions and macros.
#include "moonbit.h"

// moonbit_init is defined in the generated C code, not in the header.
extern void moonbit_init(void);

// MoonBit exported functions (via mangled names above)
extern int32_t        mbt_ffi_init(moonbit_bytes_t rows, moonbit_bytes_t cols);
extern int32_t        mbt_ffi_process_output(moonbit_bytes_t data);
extern moonbit_bytes_t mbt_ffi_handle_key(moonbit_bytes_t key, moonbit_bytes_t mods);
extern int32_t        mbt_ffi_resize(moonbit_bytes_t rows, moonbit_bytes_t cols);
extern moonbit_bytes_t mbt_ffi_get_title(void);
extern moonbit_bytes_t mbt_ffi_get_grid(void);
extern moonbit_bytes_t mbt_ffi_get_modes(void);
extern moonbit_bytes_t mbt_ffi_focus_event(moonbit_bytes_t gained);
extern int32_t        mbt_ffi_shutdown(void);

// ---------- Initialization ----------

static int moonbit_initialized = 0;

static void ensure_init(void) {
    if (!moonbit_initialized) {
        moonbit_init();
        moonbit_initialized = 1;
    }
}

// ---------- Bytes <-> C string conversion ----------

// MoonBit Bytes memory layout (native C backend):
// The runtime header (before the pointer) contains length.
// Moonbit_array_length(ptr) extracts it via macro.
// moonbit_make_bytes(size, fill) allocates from GC heap.
// The data bytes start at the pointer itself.

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

// ---------- Public C API ----------

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
