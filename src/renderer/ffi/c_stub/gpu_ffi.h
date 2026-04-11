// GPU rendering FFI — C API for the MoonBit renderer backend.
//
// Multi-surface architecture:
//   - Device-level resources (instance, adapter, device, queue, pipelines, atlas)
//     are shared across all surfaces and initialized once.
//   - Each surface (one per terminal panel) has its own swapchain, framebuffer,
//     and per-frame state.
//   - surface_id is an opaque integer handle returned by gpu_surface_create().
//
// The MoonBit side builds RenderCommands; this C layer executes them on the GPU.
// Backend: wgpu-native (WebGPU abstraction over Metal/Vulkan/DX12).

#ifndef HELLO_TTY_GPU_FFI_H
#define HELLO_TTY_GPU_FFI_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// ---------- Device lifecycle (global, once) ----------

// Initialize the GPU device (wgpu instance, adapter, device, queue, pipelines).
// Does NOT create a surface — call gpu_surface_create() for that.
// Returns 0 on success, -1 on failure.
int hello_tty_gpu_init_device(void);

// Destroy all GPU resources (device + all surfaces) and shut down.
void hello_tty_gpu_shutdown(void);

// ---------- Surface lifecycle (per panel) ----------

// Create a new GPU surface from a platform-specific handle.
// surface_handle: CAMetalLayer* cast to uint64_t on macOS.
// width, height: initial framebuffer size in pixels.
// Returns surface_id (>= 0) on success, -1 on failure.
int hello_tty_gpu_surface_create(uint64_t surface_handle, int width, int height);

// Destroy a surface by ID.
void hello_tty_gpu_surface_destroy(int surface_id);

// Resize a surface's swapchain after a view resize.
int hello_tty_gpu_surface_resize(int surface_id, int width, int height);

// ---------- Texture atlas (shared) ----------

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

// ---------- Per-frame rendering (on a specific surface) ----------

// Set the clear color for the next frame_begin.
void hello_tty_gpu_frame_clear(int surface_id, uint8_t r, uint8_t g, uint8_t b, uint8_t a);

// Begin a new frame on a surface. Acquires the next swapchain image.
// Returns 0 on success, -1 if swapchain needs recreation.
int hello_tty_gpu_frame_begin(int surface_id);

// Upload cell quad vertex data for drawing on a surface.
// vertices: packed float array [x, y, u, v, fg_r, fg_g, fg_b, fg_a, bg_r, bg_g, bg_b, bg_a] per vertex.
// vertex_count: number of vertices (must be multiple of 6 for quads: 2 triangles each).
// Returns 0 on success.
int hello_tty_gpu_draw_cells(int surface_id, const float *vertices, int vertex_count);

// Draw the cursor quad on a surface.
// x, y, w, h: pixel position and size.
// r, g, b, a: cursor color.
// style: 0=block, 1=underline, 2=bar.
void hello_tty_gpu_draw_cursor(int surface_id,
    float x, float y, float w, float h,
    uint8_t r, uint8_t g, uint8_t b, uint8_t a,
    int style);

// Set viewport and scissor rect for sub-region rendering (multi-panel).
// Coordinates are in pixels relative to the surface.
// Also updates the uniform buffer for the vertex shader.
void hello_tty_gpu_set_viewport(int surface_id, int x, int y, int w, int h);

// End the frame on a surface and present. Submits command buffer and presents swapchain image.
// Returns 0 on success, -1 if swapchain needs recreation.
int hello_tty_gpu_frame_end(int surface_id);

// ---------- Legacy single-surface API (deprecated, wraps surface_id=0) ----------

int hello_tty_gpu_init(uint64_t surface_handle, int width, int height);
int hello_tty_gpu_resize(int width, int height);

#ifdef __cplusplus
}
#endif

#endif // HELLO_TTY_GPU_FFI_H
