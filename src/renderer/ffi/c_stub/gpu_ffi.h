// GPU rendering FFI — C API for the MoonBit renderer backend.
//
// This layer provides:
//   1. wgpu device/surface/pipeline lifecycle (Metal on macOS, Vulkan on Linux)
//   2. Font rasterization (CoreText on macOS, FreeType on Linux)
//   3. Per-frame draw calls (upload vertices, draw, present)
//
// The MoonBit side builds RenderCommands; this C layer executes them on the GPU.
// Backend: wgpu-native (WebGPU abstraction over Metal/Vulkan/DX12).

#ifndef HELLO_TTY_GPU_FFI_H
#define HELLO_TTY_GPU_FFI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------- GPU lifecycle ----------

// Initialize the GPU backend (wgpu instance, device, surface).
// surface_handle: platform-specific surface (CAMetalLayer* cast to uint64_t on macOS, or 0 for headless).
// width, height: initial framebuffer size in pixels.
// Returns 0 on success, -1 on failure.
int hello_tty_gpu_init(uint64_t surface_handle, int width, int height);

// Resize the swapchain after a window resize.
int hello_tty_gpu_resize(int width, int height);

// Destroy all GPU resources and shut down.
void hello_tty_gpu_shutdown(void);

// ---------- Texture atlas ----------

// Create or recreate the glyph atlas texture on the GPU.
// width, height: atlas dimensions in pixels.
// Returns 0 on success, -1 on failure.
int hello_tty_gpu_atlas_create(int width, int height);

// Upload a rectangular region of RGBA pixel data into the atlas texture.
// data: packed RGBA bytes (4 * region_w * region_h).
// Returns 0 on success.
int hello_tty_gpu_atlas_upload(
    int x, int y, int region_w, int region_h,
    const uint8_t *data, int data_len);

// Font rasterization is in src/font/ffi/c_stub/ (font_ffi.h).
// Renderer does NOT own font — it consumes font via MoonBit @font package.

// ---------- Per-frame rendering ----------

// Begin a new frame. Acquires the next swapchain image.
// Returns 0 on success, -1 if swapchain needs recreation.
int hello_tty_gpu_frame_begin(void);

// Clear the framebuffer with the given color.
void hello_tty_gpu_frame_clear(uint8_t r, uint8_t g, uint8_t b, uint8_t a);

// Upload cell quad vertex data for drawing.
// vertices: packed float array [x, y, u, v, fg_r, fg_g, fg_b, fg_a, bg_r, bg_g, bg_b, bg_a] per vertex.
// vertex_count: number of vertices (must be multiple of 6 for quads: 2 triangles each).
// Returns 0 on success.
int hello_tty_gpu_draw_cells(const float *vertices, int vertex_count);

// Draw the cursor quad.
// x, y, w, h: pixel position and size.
// r, g, b, a: cursor color.
// style: 0=block, 1=underline, 2=bar.
void hello_tty_gpu_draw_cursor(
    float x, float y, float w, float h,
    uint8_t r, uint8_t g, uint8_t b, uint8_t a,
    int style);

// End the frame and present. Submits command buffer and presents swapchain image.
// Returns 0 on success, -1 if swapchain needs recreation.
int hello_tty_gpu_frame_end(void);

#ifdef __cplusplus
}
#endif

#endif // HELLO_TTY_GPU_FFI_H
