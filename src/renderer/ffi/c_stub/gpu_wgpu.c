// GPU rendering backend using wgpu-native (WebGPU abstraction).
//
// Implements all functions from gpu_ffi.h.
// Backend selection is automatic: Metal on macOS, Vulkan on Linux.
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

// ---------- Internal state ----------

typedef struct {
    WGPUInstance instance;
    WGPUSurface surface;
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
    WGPUBindGroup cell_bind_group;
    WGPUBindGroup cursor_bind_group;

    WGPUBuffer vertex_buffer;
    size_t vertex_buffer_capacity;
    WGPUBuffer cursor_vb;
    WGPUBuffer uniform_buffer;

    // Frame
    WGPUSurfaceTexture current_st;
    WGPUTextureView current_view;
    WGPUCommandEncoder encoder;
    WGPURenderPassEncoder render_pass;

    float clear_r, clear_g, clear_b, clear_a;
    int fb_w, fb_h;
    int atlas_w, atlas_h;
    int initialized;
} S;

static S g = {0};

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

// ---------- Helpers ----------

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

static void configure_surface(int w, int h) {
    WGPUSurfaceConfiguration cfg = {
        .device = g.device,
        .format = WGPUTextureFormat_BGRA8Unorm,
        .usage = WGPUTextureUsage_RenderAttachment,
        .alphaMode = WGPUCompositeAlphaMode_Auto,
        .width = (uint32_t)w,
        .height = (uint32_t)h,
        .presentMode = WGPUPresentMode_Fifo,
    };
    wgpuSurfaceConfigure(g.surface, &cfg);
    g.fb_w = w;
    g.fb_h = h;
}

// ---------- Pipeline creation ----------

static int create_cell_pipeline(void) {
    WGPUShaderModule mod = make_shader(cell_shader_wgsl);
    if (!mod) return -1;

    // Bind group: uniform(0), texture(1), sampler(2)
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

    // Vertex: 12 floats = pos(2) + uv(2) + fg(4) + bg(4) = 48 bytes
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

// ---------- Public API ----------

int hello_tty_gpu_init(uint64_t surface_handle, int width, int height) {
    // If already initialized (e.g., surface was set up by Swift calling directly),
    // just update dimensions and return success.
    if (g.initialized) {
        if (width > 0 && height > 0) {
            configure_surface(width, height);
            float vp[2] = { (float)width, (float)height };
            wgpuQueueWriteBuffer(g.queue, g.uniform_buffer, 0, vp, 8);
        }
        return 0;
    }
    memset(&g, 0, sizeof(g));

    WGPUInstanceDescriptor inst_d = {0};
    g.instance = wgpuCreateInstance(&inst_d);
    if (!g.instance) return -1;

    if (surface_handle != 0) {
#if defined(__APPLE__)
        WGPUSurfaceDescriptorFromMetalLayer metal = {
            .chain = { .sType = WGPUSType_SurfaceDescriptorFromMetalLayer },
            .layer = (void *)surface_handle,
        };
        WGPUSurfaceDescriptor sd = { .nextInChain = &metal.chain };
        g.surface = wgpuInstanceCreateSurface(g.instance, &sd);
#endif
        if (!g.surface) return -1;
    }

    // Adapter (synchronous via polling)
    WGPURequestAdapterOptions ao = {
        .compatibleSurface = g.surface,
        .powerPreference = WGPUPowerPreference_LowPower,
    };
    wgpuInstanceRequestAdapter(g.instance, &ao, on_adapter, &g.adapter);
    // wgpu-native completes callbacks synchronously for RequestAdapter
    if (!g.adapter) return -1;

    // Device
    WGPUDeviceDescriptor dd = {0};
    wgpuAdapterRequestDevice(g.adapter, &dd, on_device, &g.device);
    if (!g.device) return -1;

    g.queue = wgpuDeviceGetQueue(g.device);

    if (g.surface) configure_surface(width, height);

    // Uniform buffer (viewport size: 2 floats)
    WGPUBufferDescriptor ub_d = {
        .usage = WGPUBufferUsage_Uniform | WGPUBufferUsage_CopyDst, .size = 8,
    };
    g.uniform_buffer = wgpuDeviceCreateBuffer(g.device, &ub_d);
    float vp[2] = { (float)width, (float)height };
    wgpuQueueWriteBuffer(g.queue, g.uniform_buffer, 0, vp, 8);

    // Vertex buffers
    size_t vb_cap = 6 * 48 * 4096;
    WGPUBufferDescriptor vb_d = {
        .usage = WGPUBufferUsage_Vertex | WGPUBufferUsage_CopyDst, .size = vb_cap,
    };
    g.vertex_buffer = wgpuDeviceCreateBuffer(g.device, &vb_d);
    g.vertex_buffer_capacity = vb_cap;

    WGPUBufferDescriptor cvb_d = {
        .usage = WGPUBufferUsage_Vertex | WGPUBufferUsage_CopyDst, .size = 6 * 24,
    };
    g.cursor_vb = wgpuDeviceCreateBuffer(g.device, &cvb_d);

    if (create_cell_pipeline() != 0) return -1;
    if (create_cursor_pipeline() != 0) return -1;

    // Cursor bind group
    WGPUBindGroupEntry cbe = { .binding = 0, .buffer = g.uniform_buffer, .size = 8 };
    WGPUBindGroupDescriptor cbg_d = { .layout = g.cursor_bgl, .entryCount = 1, .entries = &cbe };
    g.cursor_bind_group = wgpuDeviceCreateBindGroup(g.device, &cbg_d);

    g.clear_r = g.clear_g = g.clear_b = 0; g.clear_a = 1;
    g.initialized = 1;
    fprintf(stderr, "hello_tty: wgpu GPU init OK (%dx%d)\n", width, height);
    return 0;
}

int hello_tty_gpu_resize(int w, int h) {
    if (!g.initialized || !g.surface) return -1;
    configure_surface(w, h);
    float vp[2] = { (float)w, (float)h };
    wgpuQueueWriteBuffer(g.queue, g.uniform_buffer, 0, vp, 8);
    return 0;
}

void hello_tty_gpu_shutdown(void) {
    if (!g.initialized) return;
#define REL(fn, obj) if (g.obj) fn(g.obj)
    REL(wgpuBindGroupRelease, cell_bind_group);
    REL(wgpuBindGroupRelease, cursor_bind_group);
    REL(wgpuTextureViewRelease, atlas_view);
    REL(wgpuTextureRelease, atlas_texture);
    REL(wgpuSamplerRelease, atlas_sampler);
    REL(wgpuBufferRelease, vertex_buffer);
    REL(wgpuBufferRelease, cursor_vb);
    REL(wgpuBufferRelease, uniform_buffer);
    REL(wgpuRenderPipelineRelease, cell_pipeline);
    REL(wgpuRenderPipelineRelease, cursor_pipeline);
    REL(wgpuPipelineLayoutRelease, cell_pl);
    REL(wgpuPipelineLayoutRelease, cursor_pl);
    REL(wgpuBindGroupLayoutRelease, cell_bgl);
    REL(wgpuBindGroupLayoutRelease, cursor_bgl);
    REL(wgpuSurfaceRelease, surface);
    REL(wgpuDeviceRelease, device);
    REL(wgpuAdapterRelease, adapter);
    REL(wgpuInstanceRelease, instance);
#undef REL
    memset(&g, 0, sizeof(g));
}

// ---------- Atlas ----------

int hello_tty_gpu_atlas_create(int w, int h) {
    if (!g.initialized) return -1;
    if (g.atlas_view) wgpuTextureViewRelease(g.atlas_view);
    if (g.atlas_texture) wgpuTextureRelease(g.atlas_texture);
    if (g.atlas_sampler) wgpuSamplerRelease(g.atlas_sampler);
    if (g.cell_bind_group) wgpuBindGroupRelease(g.cell_bind_group);

    WGPUTextureDescriptor td = {
        .usage = WGPUTextureUsage_TextureBinding | WGPUTextureUsage_CopyDst,
        .dimension = WGPUTextureDimension_2D,
        .size = { (uint32_t)w, (uint32_t)h, 1 },
        .format = WGPUTextureFormat_RGBA8Unorm, // MoonBit sends RGBA (A8→RGBA converted)
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

    WGPUBindGroupEntry entries[3] = {
        { .binding = 0, .buffer = g.uniform_buffer, .size = 8 },
        { .binding = 1, .textureView = g.atlas_view },
        { .binding = 2, .sampler = g.atlas_sampler },
    };
    WGPUBindGroupDescriptor bgd = { .layout = g.cell_bgl, .entryCount = 3, .entries = entries };
    g.cell_bind_group = wgpuDeviceCreateBindGroup(g.device, &bgd);
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

// ---------- Frame ----------

int hello_tty_gpu_frame_begin(void) {
    if (!g.initialized || !g.surface) return -1;
    wgpuSurfaceGetCurrentTexture(g.surface, &g.current_st);
    if (g.current_st.status != WGPUSurfaceGetCurrentTextureStatus_Success)
        return -1;
    g.current_view = wgpuTextureCreateView(g.current_st.texture, NULL);
    g.encoder = wgpuDeviceCreateCommandEncoder(g.device, NULL);

    WGPURenderPassColorAttachment ca = {
        .view = g.current_view,
        .loadOp = WGPULoadOp_Clear, .storeOp = WGPUStoreOp_Store,
        .clearValue = { g.clear_r, g.clear_g, g.clear_b, g.clear_a },
    };
    WGPURenderPassDescriptor rpd = { .colorAttachmentCount = 1, .colorAttachments = &ca };
    g.render_pass = wgpuCommandEncoderBeginRenderPass(g.encoder, &rpd);
    return 0;
}

void hello_tty_gpu_frame_clear(uint8_t r, uint8_t gr, uint8_t b, uint8_t a) {
    g.clear_r = r / 255.0f; g.clear_g = gr / 255.0f;
    g.clear_b = b / 255.0f; g.clear_a = a / 255.0f;
}

int hello_tty_gpu_draw_cells(const float *vertices, int vertex_count) {
    if (!g.initialized || !g.render_pass || !g.cell_bind_group) return -1;
    if (vertex_count <= 0) return 0;
    size_t sz = (size_t)vertex_count * 48;

    if (sz > g.vertex_buffer_capacity) {
        if (g.vertex_buffer) wgpuBufferRelease(g.vertex_buffer);
        size_t nc = sz * 2;
        WGPUBufferDescriptor d = { .usage = WGPUBufferUsage_Vertex | WGPUBufferUsage_CopyDst, .size = nc };
        g.vertex_buffer = wgpuDeviceCreateBuffer(g.device, &d);
        g.vertex_buffer_capacity = nc;
    }
    wgpuQueueWriteBuffer(g.queue, g.vertex_buffer, 0, vertices, sz);
    wgpuRenderPassEncoderSetPipeline(g.render_pass, g.cell_pipeline);
    wgpuRenderPassEncoderSetBindGroup(g.render_pass, 0, g.cell_bind_group, 0, NULL);
    wgpuRenderPassEncoderSetVertexBuffer(g.render_pass, 0, g.vertex_buffer, 0, sz);
    wgpuRenderPassEncoderDraw(g.render_pass, (uint32_t)vertex_count, 1, 0, 0);
    return 0;
}

void hello_tty_gpu_draw_cursor(float x, float y, float w, float h,
                                uint8_t r, uint8_t gr, uint8_t b, uint8_t a,
                                int style) {
    if (!g.initialized || !g.render_pass) return;
    (void)style;
    float cr = r/255.0f, cg = gr/255.0f, cb = b/255.0f, ca = a/255.0f;
    float v[36] = {
        x,   y,   cr,cg,cb,ca,  x+w, y,   cr,cg,cb,ca,  x,   y+h, cr,cg,cb,ca,
        x+w, y,   cr,cg,cb,ca,  x+w, y+h, cr,cg,cb,ca,  x,   y+h, cr,cg,cb,ca,
    };
    wgpuQueueWriteBuffer(g.queue, g.cursor_vb, 0, v, sizeof(v));
    wgpuRenderPassEncoderSetPipeline(g.render_pass, g.cursor_pipeline);
    wgpuRenderPassEncoderSetBindGroup(g.render_pass, 0, g.cursor_bind_group, 0, NULL);
    wgpuRenderPassEncoderSetVertexBuffer(g.render_pass, 0, g.cursor_vb, 0, sizeof(v));
    wgpuRenderPassEncoderDraw(g.render_pass, 6, 1, 0, 0);
}

int hello_tty_gpu_frame_end(void) {
    if (!g.initialized || !g.render_pass) return -1;
    wgpuRenderPassEncoderEnd(g.render_pass);
    wgpuRenderPassEncoderRelease(g.render_pass);
    g.render_pass = NULL;

    WGPUCommandBuffer cmd = wgpuCommandEncoderFinish(g.encoder, NULL);
    wgpuCommandEncoderRelease(g.encoder);
    g.encoder = NULL;

    wgpuQueueSubmit(g.queue, 1, &cmd);
    wgpuCommandBufferRelease(cmd);
    wgpuSurfacePresent(g.surface);
    wgpuTextureViewRelease(g.current_view);
    g.current_view = NULL;
    return 0;
}
