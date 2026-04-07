// Glue functions bridging MoonBit types to the GPU FFI C API.
//
// MoonBit passes FixedArray[Float] as float*, FixedArray[Int] as int32_t*,
// FixedArray[Byte] as uint8_t*. Surface handles are passed as two int32
// halves (lo/hi) since MoonBit Int is 32-bit.

#include "gpu_ffi.h"

// Bridge: surface handle passed as two 32-bit halves → uint64_t
int hello_tty_gpu_init_i32(int surface_lo, int surface_hi, int width, int height) {
    uint64_t surface = ((uint64_t)(uint32_t)surface_hi << 32) | (uint64_t)(uint32_t)surface_lo;
    return hello_tty_gpu_init(surface, width, height);
}

// Bridge: MoonBit FixedArray[Float] → const float*
int hello_tty_gpu_draw_cells_fa(const float *vertices, int vertex_count) {
    return hello_tty_gpu_draw_cells(vertices, vertex_count);
}
