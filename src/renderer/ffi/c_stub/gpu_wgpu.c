// GPU rendering backend using wgpu-native (WebGPU abstraction).
//
// Multi-surface architecture:
//   G (global): instance, adapter, device, queue, pipelines, atlas — shared
//   Surf (per-panel): surface, swapchain, frame state, buffers — independent
//
// This file targets wgpu-native v22.x (pre-spec API style):
//   - Callbacks use (status, result, message, userdata) signatures
//   - Shader modules use WGPUShaderModuleWGSLDescriptor
//   - Surfaces use WGPUSurfaceDescriptorFromMetalLayer

#include "gpu_ffi.h"
#include "shaders_wgsl.h"

#include <webgpu.h>
#include <wgpu.h>

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// ---------- Per-surface state ----------

#define MAX_SURFACES 64

typedef struct {
    WGPUSurface surface;
    int fb_w, fb_h;
    float clear_r, clear_g, clear_b, clear_a;

    // Per-frame
    WGPUSurfaceTexture current_st;
    WGPUTextureView current_view;
    WGPUCommandEncoder encoder;
    WGPURenderPassEncoder render_pass;

    // Per-surface buffers (viewport uniform reflects this surface's size)
    WGPUBuffer uniform_buffer;
    WGPUBuffer vertex_buffer;
    size_t vertex_buffer_capacity;
    WGPUBuffer cursor_vb;

    // Per-surface bind groups (reference shared atlas but own uniform)
    WGPUBindGroup cell_bind_group;
    WGPUBindGroup cursor_bind_group;

    int active; // 1 if slot is in use
} Surf;

// ---------- Global (shared) state ----------

typedef struct {
    WGPUInstance instance;
    WGPUAdapter adapter;
    WGPUDevice device;
    WGPUQueue queue;

    WGPURenderPipeline cell_pipeline;
    WGPURenderPipeline cursor_pipeline;
    WGPUBindGroupLayout cell_bgl;
    WGPUPipelineLayout cell_pl;
    WGPUBindGroupLayout cursor_bgl;
    WGPUPipelineLayout cursor_pl;

    WGPUTexture atlas_texture;
    WGPUTextureView atlas_view;
    WGPUSampler atlas_sampler;
    int atlas_w, atlas_h;

    Surf surfaces[MAX_SURFACES];
    int initialized;
} G;

static G g = {0};

// ---------- Helpers ----------

static Surf *get_surf(int id) {
    if (id < 0 || id >= MAX_SURFACES || !g.surfaces[id].active) return NULL;
    return &g.surfaces[id];
}

static int alloc_surface_slot(void) {
    for (int i = 0; i < MAX_SURFACES; i++) {
        if (!g.surfaces[i].active) return i;
    }
    return -1;
}

// ---------- Callbacks ----------

static void on_adapter(WGPURequestAdapterStatus status, WGPUAdapter adapter,
                        const char *msg, void *ud) {
    (void)msg;
    if (status == WGPURequestAdapterStatus_Success)
        *(WGPUAdapter *)ud = adapter;
}

static void on_device(WGPURequestDeviceStatus status, WGPUDevice device,
                       const char *msg, void *ud) {
    (void)msg;
    if (status == WGPURequestDeviceStatus_Success)
        *(WGPUDevice *)ud = device;
}

static WGPUShaderModule make_shader(const char *wgsl) {
    WGPUShaderModuleWGSLDescriptor wgsl_desc = {
        .chain = { .sType = WGPUSType_ShaderModuleWGSLDescriptor },
        .code = wgsl,
    };
    WGPUShaderModuleDescriptor desc = {
        .nextInChain = &wgsl_desc.chain,
    };
    return wgpuDeviceCreateShaderModule(g.device, &desc);
}

static void configure_surface(Surf *s) {
    WGPUSurfaceConfiguration cfg = {
        .device = g.device,
        .format = WGPUTextureFormat_BGRA8Unorm,
        .usage = WGPUTextureUsage_RenderAttachment,
        .alphaMode = WGPUCompositeAlphaMode_Auto,
        .width = (uint32_t)s->fb_w,
        .height = (uint32_t)s->fb_h,
        .presentMode = WGPUPresentMode_Fifo,
    };
    wgpuSurfaceConfigure(s->surface, &cfg);
}

// ---------- Pipeline creation ----------

static int create_cell_pipeline(void) {
    WGPUShaderModule mod = make_shader(cell_shader_wgsl);
    if (!mod) return -1;

    WGPUBindGroupLayoutEntry bgl_entries[3] = {
        { .binding = 0, .visibility = WGPUShaderStage_Vertex,
          .buffer = { .type = WGPUBufferBindingType_Uniform, .minBindingSize = 8 } },
        { .binding = 1, .visibility = WGPUShaderStage_Fragment,
          .texture = { .sampleType = WGPUTextureSampleType_Float,
                       .viewDimension = WGPUTextureViewDimension_2D } },
        { .binding = 2, .visibility = WGPUShaderStage_Fragment,
          .sampler = { .type = WGPUSamplerBindingType_Filtering } },
    };
    WGPUBindGroupLayoutDescriptor bgl_d = { .entryCount = 3, .entries = bgl_entries };
    g.cell_bgl = wgpuDeviceCreateBindGroupLayout(g.device, &bgl_d);

    WGPUPipelineLayoutDescriptor pl_d = { .bindGroupLayoutCount = 1, .bindGroupLayouts = &g.cell_bgl };
    g.cell_pl = wgpuDeviceCreatePipelineLayout(g.device, &pl_d);

    WGPUVertexAttribute attrs[4] = {
        { .format = WGPUVertexFormat_Float32x2, .offset = 0,  .shaderLocation = 0 },
        { .format = WGPUVertexFormat_Float32x2, .offset = 8,  .shaderLocation = 1 },
        { .format = WGPUVertexFormat_Float32x4, .offset = 16, .shaderLocation = 2 },
        { .format = WGPUVertexFormat_Float32x4, .offset = 32, .shaderLocation = 3 },
    };
    WGPUVertexBufferLayout vbl = {
        .arrayStride = 48, .stepMode = WGPUVertexStepMode_Vertex,
        .attributeCount = 4, .attributes = attrs,
    };

    WGPUBlendState blend = {
        .color = { .operation = WGPUBlendOperation_Add,
                   .srcFactor = WGPUBlendFactor_SrcAlpha,
                   .dstFactor = WGPUBlendFactor_OneMinusSrcAlpha },
        .alpha = { .operation = WGPUBlendOperation_Add,
                   .srcFactor = WGPUBlendFactor_One,
                   .dstFactor = WGPUBlendFactor_OneMinusSrcAlpha },
    };
    WGPUColorTargetState ct = {
        .format = WGPUTextureFormat_BGRA8Unorm, .blend = &blend,
        .writeMask = WGPUColorWriteMask_All,
    };
    WGPUFragmentState frag = {
        .module = mod, .entryPoint = "fs_main",
        .targetCount = 1, .targets = &ct,
    };
    WGPURenderPipelineDescriptor rpd = {
        .layout = g.cell_pl,
        .vertex = {
            .module = mod, .entryPoint = "vs_main",
            .bufferCount = 1, .buffers = &vbl,
        },
        .primitive = { .topology = WGPUPrimitiveTopology_TriangleList,
                       .frontFace = WGPUFrontFace_CCW, .cullMode = WGPUCullMode_None },
        .fragment = &frag,
        .multisample = { .count = 1, .mask = 0xFFFFFFFF },
    };
    g.cell_pipeline = wgpuDeviceCreateRenderPipeline(g.device, &rpd);
    wgpuShaderModuleRelease(mod);
    return g.cell_pipeline ? 0 : -1;
}

static int create_cursor_pipeline(void) {
    WGPUShaderModule mod = make_shader(cursor_shader_wgsl);
    if (!mod) return -1;

    WGPUBindGroupLayoutEntry entry = {
        .binding = 0, .visibility = WGPUShaderStage_Vertex,
        .buffer = { .type = WGPUBufferBindingType_Uniform, .minBindingSize = 8 },
    };
    WGPUBindGroupLayoutDescriptor bgl_d = { .entryCount = 1, .entries = &entry };
    g.cursor_bgl = wgpuDeviceCreateBindGroupLayout(g.device, &bgl_d);

    WGPUPipelineLayoutDescriptor pl_d = { .bindGroupLayoutCount = 1, .bindGroupLayouts = &g.cursor_bgl };
    g.cursor_pl = wgpuDeviceCreatePipelineLayout(g.device, &pl_d);

    WGPUVertexAttribute attrs[2] = {
        { .format = WGPUVertexFormat_Float32x2, .offset = 0, .shaderLocation = 0 },
        { .format = WGPUVertexFormat_Float32x4, .offset = 8, .shaderLocation = 1 },
    };
    WGPUVertexBufferLayout vbl = {
        .arrayStride = 24, .stepMode = WGPUVertexStepMode_Vertex,
        .attributeCount = 2, .attributes = attrs,
    };
    WGPUBlendState blend = {
        .color = { .operation = WGPUBlendOperation_Add,
                   .srcFactor = WGPUBlendFactor_SrcAlpha,
                   .dstFactor = WGPUBlendFactor_OneMinusSrcAlpha },
        .alpha = { .operation = WGPUBlendOperation_Add,
                   .srcFactor = WGPUBlendFactor_One,
                   .dstFactor = WGPUBlendFactor_OneMinusSrcAlpha },
    };
    WGPUColorTargetState ct = {
        .format = WGPUTextureFormat_BGRA8Unorm, .blend = &blend,
        .writeMask = WGPUColorWriteMask_All,
    };
    WGPUFragmentState frag = {
        .module = mod, .entryPoint = "fs_main",
        .targetCount = 1, .targets = &ct,
    };
    WGPURenderPipelineDescriptor rpd = {
        .layout = g.cursor_pl,
        .vertex = {
            .module = mod, .entryPoint = "vs_main",
            .bufferCount = 1, .buffers = &vbl,
        },
        .primitive = { .topology = WGPUPrimitiveTopology_TriangleList,
                       .frontFace = WGPUFrontFace_CCW, .cullMode = WGPUCullMode_None },
        .fragment = &frag,
        .multisample = { .count = 1, .mask = 0xFFFFFFFF },
    };
    g.cursor_pipeline = wgpuDeviceCreateRenderPipeline(g.device, &rpd);
    wgpuShaderModuleRelease(mod);
    return g.cursor_pipeline ? 0 : -1;
}

// Create per-surface buffers and bind groups.
// Must be called after atlas is created (for cell_bind_group).
static int init_surface_buffers(Surf *s) {
    // Uniform buffer (viewport size: 2 floats)
    WGPUBufferDescriptor ub_d = {
        .usage = WGPUBufferUsage_Uniform | WGPUBufferUsage_CopyDst, .size = 8,
    };
    s->uniform_buffer = wgpuDeviceCreateBuffer(g.device, &ub_d);
    float vp[2] = { (float)s->fb_w, (float)s->fb_h };
    wgpuQueueWriteBuffer(g.queue, s->uniform_buffer, 0, vp, 8);

    // Vertex buffers
    size_t vb_cap = 6 * 48 * 4096;
    WGPUBufferDescriptor vb_d = {
        .usage = WGPUBufferUsage_Vertex | WGPUBufferUsage_CopyDst, .size = vb_cap,
    };
    s->vertex_buffer = wgpuDeviceCreateBuffer(g.device, &vb_d);
    s->vertex_buffer_capacity = vb_cap;

    WGPUBufferDescriptor cvb_d = {
        .usage = WGPUBufferUsage_Vertex | WGPUBufferUsage_CopyDst, .size = 6 * 24,
    };
    s->cursor_vb = wgpuDeviceCreateBuffer(g.device, &cvb_d);

    // Cursor bind group
    WGPUBindGroupEntry cbe = { .binding = 0, .buffer = s->uniform_buffer, .size = 8 };
    WGPUBindGroupDescriptor cbg_d = { .layout = g.cursor_bgl, .entryCount = 1, .entries = &cbe };
    s->cursor_bind_group = wgpuDeviceCreateBindGroup(g.device, &cbg_d);

    // Cell bind group (needs atlas — may be created later)
    if (g.atlas_view && g.atlas_sampler) {
        WGPUBindGroupEntry entries[3] = {
            { .binding = 0, .buffer = s->uniform_buffer, .size = 8 },
            { .binding = 1, .textureView = g.atlas_view },
            { .binding = 2, .sampler = g.atlas_sampler },
        };
        WGPUBindGroupDescriptor bgd = { .layout = g.cell_bgl, .entryCount = 3, .entries = entries };
        s->cell_bind_group = wgpuDeviceCreateBindGroup(g.device, &bgd);
    }

    s->clear_r = s->clear_g = s->clear_b = 0; s->clear_a = 1;
    return 0;
}

// Rebuild cell_bind_group for all surfaces (called after atlas recreation).
static void rebuild_cell_bind_groups(void) {
    if (!g.atlas_view || !g.atlas_sampler) return;
    for (int i = 0; i < MAX_SURFACES; i++) {
        Surf *s = &g.surfaces[i];
        if (!s->active) continue;
        if (s->cell_bind_group) wgpuBindGroupRelease(s->cell_bind_group);
        WGPUBindGroupEntry entries[3] = {
            { .binding = 0, .buffer = s->uniform_buffer, .size = 8 },
            { .binding = 1, .textureView = g.atlas_view },
            { .binding = 2, .sampler = g.atlas_sampler },
        };
        WGPUBindGroupDescriptor bgd = { .layout = g.cell_bgl, .entryCount = 3, .entries = entries };
        s->cell_bind_group = wgpuDeviceCreateBindGroup(g.device, &bgd);
    }
}

static void destroy_surface(Surf *s) {
    if (!s->active) return;
#define REL(fn, obj) if (s->obj) fn(s->obj)
    REL(wgpuBindGroupRelease, cell_bind_group);
    REL(wgpuBindGroupRelease, cursor_bind_group);
    REL(wgpuBufferRelease, vertex_buffer);
    REL(wgpuBufferRelease, cursor_vb);
    REL(wgpuBufferRelease, uniform_buffer);
    REL(wgpuSurfaceRelease, surface);
#undef REL
    memset(s, 0, sizeof(*s));
}

// ========== Public API: Device lifecycle ==========

int hello_tty_gpu_init_device(void) {
    if (g.initialized) return 0;
    memset(&g, 0, sizeof(g));

    WGPUInstanceDescriptor inst_d = {0};
    g.instance = wgpuCreateInstance(&inst_d);
    if (!g.instance) return -1;

    // Need a temporary surface for adapter compatibility.
    // We'll create the real surfaces later via gpu_surface_create().
    // For adapter request, pass NULL surface — wgpu-native allows this.
    WGPURequestAdapterOptions ao = {
        .compatibleSurface = NULL,
        .powerPreference = WGPUPowerPreference_LowPower,
    };
    wgpuInstanceRequestAdapter(g.instance, &ao, on_adapter, &g.adapter);
    if (!g.adapter) return -1;

    WGPUDeviceDescriptor dd = {0};
    wgpuAdapterRequestDevice(g.adapter, &dd, on_device, &g.device);
    if (!g.device) return -1;

    g.queue = wgpuDeviceGetQueue(g.device);

    if (create_cell_pipeline() != 0) return -1;
    if (create_cursor_pipeline() != 0) return -1;

    g.initialized = 1;
    fprintf(stderr, "hello_tty: wgpu device init OK\n");
    return 0;
}

void hello_tty_gpu_shutdown(void) {
    if (!g.initialized) return;
    for (int i = 0; i < MAX_SURFACES; i++) {
        destroy_surface(&g.surfaces[i]);
    }
    // Atlas
    if (g.atlas_view) wgpuTextureViewRelease(g.atlas_view);
    if (g.atlas_texture) wgpuTextureRelease(g.atlas_texture);
    if (g.atlas_sampler) wgpuSamplerRelease(g.atlas_sampler);
    // Pipelines
    if (g.cell_pipeline) wgpuRenderPipelineRelease(g.cell_pipeline);
    if (g.cursor_pipeline) wgpuRenderPipelineRelease(g.cursor_pipeline);
    if (g.cell_pl) wgpuPipelineLayoutRelease(g.cell_pl);
    if (g.cursor_pl) wgpuPipelineLayoutRelease(g.cursor_pl);
    if (g.cell_bgl) wgpuBindGroupLayoutRelease(g.cell_bgl);
    if (g.cursor_bgl) wgpuBindGroupLayoutRelease(g.cursor_bgl);
    if (g.device) wgpuDeviceRelease(g.device);
    if (g.adapter) wgpuAdapterRelease(g.adapter);
    if (g.instance) wgpuInstanceRelease(g.instance);
    memset(&g, 0, sizeof(g));
}

// ========== Public API: Surface lifecycle ==========

int hello_tty_gpu_surface_create(uint64_t surface_handle, int width, int height) {
    if (!g.initialized) {
        if (hello_tty_gpu_init_device() != 0) return -1;
    }

    int id = alloc_surface_slot();
    if (id < 0) return -1;

    Surf *s = &g.surfaces[id];
    memset(s, 0, sizeof(*s));
    s->active = 1;
    s->fb_w = width;
    s->fb_h = height;

    if (surface_handle != 0) {
#if defined(__APPLE__)
        WGPUSurfaceDescriptorFromMetalLayer metal = {
            .chain = { .sType = WGPUSType_SurfaceDescriptorFromMetalLayer },
            .layer = (void *)surface_handle,
        };
        WGPUSurfaceDescriptor sd = { .nextInChain = &metal.chain };
        s->surface = wgpuInstanceCreateSurface(g.instance, &sd);
#endif
        if (!s->surface) { s->active = 0; return -1; }
        configure_surface(s);
    }

    if (init_surface_buffers(s) != 0) {
        destroy_surface(s);
        return -1;
    }

    fprintf(stderr, "hello_tty: surface %d created (%dx%d)\n", id, width, height);
    return id;
}

void hello_tty_gpu_surface_destroy(int surface_id) {
    Surf *s = get_surf(surface_id);
    if (s) destroy_surface(s);
}

int hello_tty_gpu_surface_resize(int surface_id, int w, int h) {
    Surf *s = get_surf(surface_id);
    if (!s) return -1;
    s->fb_w = w;
    s->fb_h = h;
    if (s->surface) configure_surface(s);
    float vp[2] = { (float)w, (float)h };
    wgpuQueueWriteBuffer(g.queue, s->uniform_buffer, 0, vp, 8);
    return 0;
}

// ========== Atlas (shared) ==========

int hello_tty_gpu_atlas_create(int w, int h) {
    if (!g.initialized) return -1;
    if (g.atlas_view) wgpuTextureViewRelease(g.atlas_view);
    if (g.atlas_texture) wgpuTextureRelease(g.atlas_texture);
    if (g.atlas_sampler) wgpuSamplerRelease(g.atlas_sampler);

    WGPUTextureDescriptor td = {
        .usage = WGPUTextureUsage_TextureBinding | WGPUTextureUsage_CopyDst,
        .dimension = WGPUTextureDimension_2D,
        .size = { (uint32_t)w, (uint32_t)h, 1 },
        .format = WGPUTextureFormat_RGBA8Unorm,
        .mipLevelCount = 1, .sampleCount = 1,
    };
    g.atlas_texture = wgpuDeviceCreateTexture(g.device, &td);
    if (!g.atlas_texture) return -1;
    g.atlas_view = wgpuTextureCreateView(g.atlas_texture, NULL);

    WGPUSamplerDescriptor sd = {
        .addressModeU = WGPUAddressMode_ClampToEdge,
        .addressModeV = WGPUAddressMode_ClampToEdge,
        .addressModeW = WGPUAddressMode_ClampToEdge,
        .magFilter = WGPUFilterMode_Linear,
        .minFilter = WGPUFilterMode_Linear,
        .mipmapFilter = WGPUMipmapFilterMode_Nearest,
        .lodMinClamp = 0.0f,
        .lodMaxClamp = 1.0f,
        .compare = WGPUCompareFunction_Undefined,
        .maxAnisotropy = 1,
    };
    g.atlas_sampler = wgpuDeviceCreateSampler(g.device, &sd);
    g.atlas_w = w; g.atlas_h = h;

    // Rebuild bind groups for all existing surfaces
    rebuild_cell_bind_groups();
    return 0;
}

int hello_tty_gpu_atlas_upload(int x, int y, int rw, int rh,
                                const uint8_t *data, int data_len) {
    if (!g.initialized || !g.atlas_texture) return -1;
    WGPUImageCopyTexture dest = {
        .texture = g.atlas_texture, .mipLevel = 0,
        .origin = { (uint32_t)x, (uint32_t)y, 0 },
    };
    WGPUTextureDataLayout layout = { .bytesPerRow = (uint32_t)(rw * 4), .rowsPerImage = (uint32_t)rh };
    WGPUExtent3D size = { (uint32_t)rw, (uint32_t)rh, 1 };
    wgpuQueueWriteTexture(g.queue, &dest, data, (size_t)data_len, &layout, &size);
    return 0;
}

// ========== Frame rendering (per-surface) ==========

void hello_tty_gpu_frame_clear(int surface_id, uint8_t r, uint8_t gr, uint8_t b, uint8_t a) {
    Surf *s = get_surf(surface_id);
    if (!s) return;
    s->clear_r = r / 255.0f; s->clear_g = gr / 255.0f;
    s->clear_b = b / 255.0f; s->clear_a = a / 255.0f;
}

int hello_tty_gpu_frame_begin(int surface_id) {
    Surf *s = get_surf(surface_id);
    if (!s || !s->surface) {
        fprintf(stderr, "hello_tty: frame_begin(%d) — no surface (s=%p, surface=%p)\n",
                surface_id, (void*)s, s ? (void*)s->surface : NULL);
        return -1;
    }
    wgpuSurfaceGetCurrentTexture(s->surface, &s->current_st);
    if (s->current_st.status != WGPUSurfaceGetCurrentTextureStatus_Success) {
        fprintf(stderr, "hello_tty: frame_begin(%d) — getCurrentTexture failed, status=%d\n",
                surface_id, (int)s->current_st.status);
        return -1;
    }
    s->current_view = wgpuTextureCreateView(s->current_st.texture, NULL);
    s->encoder = wgpuDeviceCreateCommandEncoder(g.device, NULL);

    WGPURenderPassColorAttachment ca = {
        .view = s->current_view,
        .loadOp = WGPULoadOp_Clear, .storeOp = WGPUStoreOp_Store,
        .clearValue = { s->clear_r, s->clear_g, s->clear_b, s->clear_a },
    };
    WGPURenderPassDescriptor rpd = { .colorAttachmentCount = 1, .colorAttachments = &ca };
    s->render_pass = wgpuCommandEncoderBeginRenderPass(s->encoder, &rpd);
    return 0;
}

int hello_tty_gpu_draw_cells(int surface_id, const float *vertices, int vertex_count) {
    Surf *s = get_surf(surface_id);
    if (!s || !s->render_pass || !s->cell_bind_group) return -1;
    if (vertex_count <= 0) return 0;
    size_t sz = (size_t)vertex_count * 48;

    if (sz > s->vertex_buffer_capacity) {
        if (s->vertex_buffer) wgpuBufferRelease(s->vertex_buffer);
        size_t nc = sz * 2;
        WGPUBufferDescriptor d = { .usage = WGPUBufferUsage_Vertex | WGPUBufferUsage_CopyDst, .size = nc };
        s->vertex_buffer = wgpuDeviceCreateBuffer(g.device, &d);
        s->vertex_buffer_capacity = nc;
    }
    wgpuQueueWriteBuffer(g.queue, s->vertex_buffer, 0, vertices, sz);
    wgpuRenderPassEncoderSetPipeline(s->render_pass, g.cell_pipeline);
    wgpuRenderPassEncoderSetBindGroup(s->render_pass, 0, s->cell_bind_group, 0, NULL);
    wgpuRenderPassEncoderSetVertexBuffer(s->render_pass, 0, s->vertex_buffer, 0, sz);
    wgpuRenderPassEncoderDraw(s->render_pass, (uint32_t)vertex_count, 1, 0, 0);
    return 0;
}

void hello_tty_gpu_draw_cursor(int surface_id,
                                float x, float y, float w, float h,
                                uint8_t r, uint8_t gr, uint8_t b, uint8_t a,
                                int style) {
    Surf *s = get_surf(surface_id);
    if (!s || !s->render_pass) return;
    (void)style;
    float cr = r/255.0f, cg = gr/255.0f, cb = b/255.0f, ca = a/255.0f;
    float v[36] = {
        x,   y,   cr,cg,cb,ca,  x+w, y,   cr,cg,cb,ca,  x,   y+h, cr,cg,cb,ca,
        x+w, y,   cr,cg,cb,ca,  x+w, y+h, cr,cg,cb,ca,  x,   y+h, cr,cg,cb,ca,
    };
    wgpuQueueWriteBuffer(g.queue, s->cursor_vb, 0, v, sizeof(v));
    wgpuRenderPassEncoderSetPipeline(s->render_pass, g.cursor_pipeline);
    wgpuRenderPassEncoderSetBindGroup(s->render_pass, 0, s->cursor_bind_group, 0, NULL);
    wgpuRenderPassEncoderSetVertexBuffer(s->render_pass, 0, s->cursor_vb, 0, sizeof(v));
    wgpuRenderPassEncoderDraw(s->render_pass, 6, 1, 0, 0);
}

int hello_tty_gpu_frame_end(int surface_id) {
    Surf *s = get_surf(surface_id);
    if (!s || !s->render_pass) return -1;
    wgpuRenderPassEncoderEnd(s->render_pass);
    wgpuRenderPassEncoderRelease(s->render_pass);
    s->render_pass = NULL;

    WGPUCommandBuffer cmd = wgpuCommandEncoderFinish(s->encoder, NULL);
    wgpuCommandEncoderRelease(s->encoder);
    s->encoder = NULL;

    wgpuQueueSubmit(g.queue, 1, &cmd);
    wgpuCommandBufferRelease(cmd);
    wgpuSurfacePresent(s->surface);
    wgpuTextureViewRelease(s->current_view);
    s->current_view = NULL;
    return 0;
}

// ========== Legacy single-surface API ==========

// Legacy: first call creates device + surface 0. Subsequent calls resize surface 0.
static int legacy_surface_id = -1;

int hello_tty_gpu_init(uint64_t surface_handle, int width, int height) {
    if (legacy_surface_id >= 0) {
        // Already initialized — just resize
        return hello_tty_gpu_surface_resize(legacy_surface_id, width, height);
    }
    int id = hello_tty_gpu_surface_create(surface_handle, width, height);
    if (id < 0) return -1;
    legacy_surface_id = id;
    return 0;
}

int hello_tty_gpu_resize(int w, int h) {
    if (legacy_surface_id < 0) return -1;
    return hello_tty_gpu_surface_resize(legacy_surface_id, w, h);
}
