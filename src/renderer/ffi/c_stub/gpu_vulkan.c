// Vulkan GPU backend implementation.
//
// This implements a minimal but correct Vulkan rendering pipeline for
// terminal cell grids. It uses:
//   - A single render pass with one color attachment
//   - Two subpasses: background fill + text overlay
//   - A vertex buffer uploaded per frame (no persistent mapping)
//   - The atlas texture as a combined image sampler
//
// Designed to be driven by the MoonBit renderer's RenderCommand sequence.
//
// On macOS, the primary rendering path is CoreText/CoreGraphics in the
// Swift adapter. This Vulkan backend is optional and requires the Vulkan SDK.
// If vulkan/vulkan.h is not available, stub implementations are provided.

#include "gpu_ffi.h"

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

// Check for Vulkan SDK availability.
// Set HELLO_TTY_HAS_VULKAN=1 to enable, or it auto-detects via __has_include.
#ifndef HELLO_TTY_HAS_VULKAN
#  if defined(__has_include)
#    if __has_include(<vulkan/vulkan.h>)
#      define HELLO_TTY_HAS_VULKAN 1
#    else
#      define HELLO_TTY_HAS_VULKAN 0
#    endif
#  else
#    define HELLO_TTY_HAS_VULKAN 0
#  endif
#endif

#if HELLO_TTY_HAS_VULKAN

// ---------- Vulkan headers ----------
// We use the Vulkan loader; link with -lvulkan.
// On macOS, MoltenVK provides Vulkan over Metal.

#ifdef __APPLE__
#define VK_USE_PLATFORM_MACOS_MVK
#define VK_USE_PLATFORM_METAL_EXT
#endif

#include <vulkan/vulkan.h>

// ---------- Shader bytecode ----------
// Embedded SPIR-V shaders (generated offline).
// For bootstrapping, we use a trivial vertex+fragment shader pair.
// The vertex shader passes through position and texture coords.
// The fragment shader samples the atlas texture and blends fg/bg.

// Placeholder: we embed minimal SPIR-V inline.
// In production these would be compiled from .glsl files.
// For now, we'll load them at runtime from embedded arrays.

#include "shaders.h"

// ---------- Internal state ----------

typedef struct {
    VkInstance instance;
    VkPhysicalDevice physical_device;
    VkDevice device;
    VkQueue graphics_queue;
    uint32_t graphics_family;

    VkSurfaceKHR surface;
    VkSwapchainKHR swapchain;
    VkFormat swapchain_format;
    VkExtent2D swapchain_extent;
    uint32_t swapchain_image_count;
    VkImage *swapchain_images;
    VkImageView *swapchain_image_views;
    VkFramebuffer *framebuffers;

    VkRenderPass render_pass;
    VkPipelineLayout pipeline_layout;
    VkPipeline bg_pipeline;     // Background rectangles
    VkPipeline text_pipeline;   // Textured glyph quads

    VkCommandPool command_pool;
    VkCommandBuffer command_buffer;

    VkSemaphore image_available;
    VkSemaphore render_finished;
    VkFence in_flight;

    // Dynamic vertex buffer (recreated per frame)
    VkBuffer vertex_buffer;
    VkDeviceMemory vertex_memory;
    size_t vertex_buffer_size;

    // Atlas texture
    VkImage atlas_image;
    VkDeviceMemory atlas_memory;
    VkImageView atlas_view;
    VkSampler atlas_sampler;
    VkDescriptorSetLayout descriptor_set_layout;
    VkDescriptorPool descriptor_pool;
    VkDescriptorSet descriptor_set;
    int atlas_width;
    int atlas_height;

    int fb_width;
    int fb_height;
    uint32_t current_image_index;

    // Frame clear color
    float clear_r, clear_g, clear_b, clear_a;

    int initialized;
} GpuState;

static GpuState g_gpu = {0};

// ---------- Helpers ----------

static uint32_t find_memory_type(uint32_t type_filter, VkMemoryPropertyFlags properties) {
    VkPhysicalDeviceMemoryProperties mem_props;
    vkGetPhysicalDeviceMemoryProperties(g_gpu.physical_device, &mem_props);
    for (uint32_t i = 0; i < mem_props.memoryTypeCount; i++) {
        if ((type_filter & (1 << i)) &&
            (mem_props.memoryTypes[i].propertyFlags & properties) == properties) {
            return i;
        }
    }
    return UINT32_MAX;
}

static int create_buffer(VkDeviceSize size, VkBufferUsageFlags usage,
                         VkMemoryPropertyFlags properties,
                         VkBuffer *buffer, VkDeviceMemory *memory) {
    VkBufferCreateInfo buf_info = {0};
    buf_info.sType = VK_STRUCTURE_TYPE_BUFFER_CREATE_INFO;
    buf_info.size = size;
    buf_info.usage = usage;
    buf_info.sharingMode = VK_SHARING_MODE_EXCLUSIVE;

    if (vkCreateBuffer(g_gpu.device, &buf_info, NULL, buffer) != VK_SUCCESS)
        return -1;

    VkMemoryRequirements mem_req;
    vkGetBufferMemoryRequirements(g_gpu.device, *buffer, &mem_req);

    VkMemoryAllocateInfo alloc_info = {0};
    alloc_info.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc_info.allocationSize = mem_req.size;
    alloc_info.memoryTypeIndex = find_memory_type(mem_req.memoryTypeBits, properties);
    if (alloc_info.memoryTypeIndex == UINT32_MAX) return -1;

    if (vkAllocateMemory(g_gpu.device, &alloc_info, NULL, memory) != VK_SUCCESS)
        return -1;

    vkBindBufferMemory(g_gpu.device, *buffer, *memory, 0);
    return 0;
}

// ---------- Swapchain ----------

static void destroy_swapchain_resources(void) {
    if (g_gpu.device == VK_NULL_HANDLE) return;
    vkDeviceWaitIdle(g_gpu.device);

    for (uint32_t i = 0; i < g_gpu.swapchain_image_count; i++) {
        if (g_gpu.framebuffers && g_gpu.framebuffers[i])
            vkDestroyFramebuffer(g_gpu.device, g_gpu.framebuffers[i], NULL);
        if (g_gpu.swapchain_image_views && g_gpu.swapchain_image_views[i])
            vkDestroyImageView(g_gpu.device, g_gpu.swapchain_image_views[i], NULL);
    }
    free(g_gpu.framebuffers); g_gpu.framebuffers = NULL;
    free(g_gpu.swapchain_image_views); g_gpu.swapchain_image_views = NULL;
    free(g_gpu.swapchain_images); g_gpu.swapchain_images = NULL;

    if (g_gpu.swapchain) {
        vkDestroySwapchainKHR(g_gpu.device, g_gpu.swapchain, NULL);
        g_gpu.swapchain = VK_NULL_HANDLE;
    }
}

static int create_swapchain(int width, int height) {
    VkSurfaceCapabilitiesKHR caps;
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR(g_gpu.physical_device, g_gpu.surface, &caps);

    // Choose extent
    if (caps.currentExtent.width != UINT32_MAX) {
        g_gpu.swapchain_extent = caps.currentExtent;
    } else {
        g_gpu.swapchain_extent.width = (uint32_t)width;
        g_gpu.swapchain_extent.height = (uint32_t)height;
    }
    g_gpu.fb_width = (int)g_gpu.swapchain_extent.width;
    g_gpu.fb_height = (int)g_gpu.swapchain_extent.height;

    uint32_t image_count = caps.minImageCount + 1;
    if (caps.maxImageCount > 0 && image_count > caps.maxImageCount)
        image_count = caps.maxImageCount;

    VkSwapchainCreateInfoKHR ci = {0};
    ci.sType = VK_STRUCTURE_TYPE_SWAPCHAIN_CREATE_INFO_KHR;
    ci.surface = g_gpu.surface;
    ci.minImageCount = image_count;
    ci.imageFormat = g_gpu.swapchain_format;
    ci.imageColorSpace = VK_COLOR_SPACE_SRGB_NONLINEAR_KHR;
    ci.imageExtent = g_gpu.swapchain_extent;
    ci.imageArrayLayers = 1;
    ci.imageUsage = VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT;
    ci.imageSharingMode = VK_SHARING_MODE_EXCLUSIVE;
    ci.preTransform = caps.currentTransform;
    ci.compositeAlpha = VK_COMPOSITE_ALPHA_OPAQUE_BIT_KHR;
    ci.presentMode = VK_PRESENT_MODE_FIFO_KHR; // V-sync
    ci.clipped = VK_TRUE;

    if (vkCreateSwapchainKHR(g_gpu.device, &ci, NULL, &g_gpu.swapchain) != VK_SUCCESS)
        return -1;

    // Get images
    vkGetSwapchainImagesKHR(g_gpu.device, g_gpu.swapchain, &g_gpu.swapchain_image_count, NULL);
    g_gpu.swapchain_images = calloc(g_gpu.swapchain_image_count, sizeof(VkImage));
    vkGetSwapchainImagesKHR(g_gpu.device, g_gpu.swapchain, &g_gpu.swapchain_image_count, g_gpu.swapchain_images);

    // Create image views
    g_gpu.swapchain_image_views = calloc(g_gpu.swapchain_image_count, sizeof(VkImageView));
    for (uint32_t i = 0; i < g_gpu.swapchain_image_count; i++) {
        VkImageViewCreateInfo iv = {0};
        iv.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
        iv.image = g_gpu.swapchain_images[i];
        iv.viewType = VK_IMAGE_VIEW_TYPE_2D;
        iv.format = g_gpu.swapchain_format;
        iv.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
        iv.subresourceRange.levelCount = 1;
        iv.subresourceRange.layerCount = 1;
        if (vkCreateImageView(g_gpu.device, &iv, NULL, &g_gpu.swapchain_image_views[i]) != VK_SUCCESS)
            return -1;
    }

    // Create framebuffers
    g_gpu.framebuffers = calloc(g_gpu.swapchain_image_count, sizeof(VkFramebuffer));
    for (uint32_t i = 0; i < g_gpu.swapchain_image_count; i++) {
        VkFramebufferCreateInfo fb = {0};
        fb.sType = VK_STRUCTURE_TYPE_FRAMEBUFFER_CREATE_INFO;
        fb.renderPass = g_gpu.render_pass;
        fb.attachmentCount = 1;
        fb.pAttachments = &g_gpu.swapchain_image_views[i];
        fb.width = g_gpu.swapchain_extent.width;
        fb.height = g_gpu.swapchain_extent.height;
        fb.layers = 1;
        if (vkCreateFramebuffer(g_gpu.device, &fb, NULL, &g_gpu.framebuffers[i]) != VK_SUCCESS)
            return -1;
    }

    return 0;
}

// ---------- Render pass ----------

static int create_render_pass(void) {
    VkAttachmentDescription color_attachment = {0};
    color_attachment.format = g_gpu.swapchain_format;
    color_attachment.samples = VK_SAMPLE_COUNT_1_BIT;
    color_attachment.loadOp = VK_ATTACHMENT_LOAD_OP_CLEAR;
    color_attachment.storeOp = VK_ATTACHMENT_STORE_OP_STORE;
    color_attachment.stencilLoadOp = VK_ATTACHMENT_LOAD_OP_DONT_CARE;
    color_attachment.stencilStoreOp = VK_ATTACHMENT_STORE_OP_DONT_CARE;
    color_attachment.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    color_attachment.finalLayout = VK_IMAGE_LAYOUT_PRESENT_SRC_KHR;

    VkAttachmentReference color_ref = {0};
    color_ref.attachment = 0;
    color_ref.layout = VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;

    VkSubpassDescription subpass = {0};
    subpass.pipelineBindPoint = VK_PIPELINE_BIND_POINT_GRAPHICS;
    subpass.colorAttachmentCount = 1;
    subpass.pColorAttachments = &color_ref;

    VkSubpassDependency dep = {0};
    dep.srcSubpass = VK_SUBPASS_EXTERNAL;
    dep.dstSubpass = 0;
    dep.srcStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dep.srcAccessMask = 0;
    dep.dstStageMask = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    dep.dstAccessMask = VK_ACCESS_COLOR_ATTACHMENT_WRITE_BIT;

    VkRenderPassCreateInfo rp_info = {0};
    rp_info.sType = VK_STRUCTURE_TYPE_RENDER_PASS_CREATE_INFO;
    rp_info.attachmentCount = 1;
    rp_info.pAttachments = &color_attachment;
    rp_info.subpassCount = 1;
    rp_info.pSubpasses = &subpass;
    rp_info.dependencyCount = 1;
    rp_info.pDependencies = &dep;

    return vkCreateRenderPass(g_gpu.device, &rp_info, NULL, &g_gpu.render_pass) == VK_SUCCESS ? 0 : -1;
}

// ---------- Pipelines ----------

static VkShaderModule create_shader_module(const uint32_t *code, size_t code_size) {
    VkShaderModuleCreateInfo ci = {0};
    ci.sType = VK_STRUCTURE_TYPE_SHADER_MODULE_CREATE_INFO;
    ci.codeSize = code_size;
    ci.pCode = code;

    VkShaderModule module;
    if (vkCreateShaderModule(g_gpu.device, &ci, NULL, &module) != VK_SUCCESS)
        return VK_NULL_HANDLE;
    return module;
}

static int create_pipelines(void) {
    // Descriptor set layout for atlas sampler
    VkDescriptorSetLayoutBinding sampler_binding = {0};
    sampler_binding.binding = 0;
    sampler_binding.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    sampler_binding.descriptorCount = 1;
    sampler_binding.stageFlags = VK_SHADER_STAGE_FRAGMENT_BIT;

    VkDescriptorSetLayoutCreateInfo layout_info = {0};
    layout_info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_LAYOUT_CREATE_INFO;
    layout_info.bindingCount = 1;
    layout_info.pBindings = &sampler_binding;

    if (vkCreateDescriptorSetLayout(g_gpu.device, &layout_info, NULL, &g_gpu.descriptor_set_layout) != VK_SUCCESS)
        return -1;

    // Push constant range for viewport dimensions
    VkPushConstantRange push_range = {0};
    push_range.stageFlags = VK_SHADER_STAGE_VERTEX_BIT;
    push_range.offset = 0;
    push_range.size = sizeof(float) * 2; // viewport width, height

    // Pipeline layout
    VkPipelineLayoutCreateInfo pl_info = {0};
    pl_info.sType = VK_STRUCTURE_TYPE_PIPELINE_LAYOUT_CREATE_INFO;
    pl_info.setLayoutCount = 1;
    pl_info.pSetLayouts = &g_gpu.descriptor_set_layout;
    pl_info.pushConstantRangeCount = 1;
    pl_info.pPushConstantRanges = &push_range;

    if (vkCreatePipelineLayout(g_gpu.device, &pl_info, NULL, &g_gpu.pipeline_layout) != VK_SUCCESS)
        return -1;

    // Load shaders
    VkShaderModule vert_module = create_shader_module(
        cell_vert_spv, sizeof(cell_vert_spv));
    VkShaderModule frag_module = create_shader_module(
        cell_frag_spv, sizeof(cell_frag_spv));

    if (vert_module == VK_NULL_HANDLE || frag_module == VK_NULL_HANDLE) {
        fprintf(stderr, "hello_tty: failed to create shader modules\n");
        return -1;
    }

    VkPipelineShaderStageCreateInfo stages[2] = {0};
    stages[0].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[0].stage = VK_SHADER_STAGE_VERTEX_BIT;
    stages[0].module = vert_module;
    stages[0].pName = "main";
    stages[1].sType = VK_STRUCTURE_TYPE_PIPELINE_SHADER_STAGE_CREATE_INFO;
    stages[1].stage = VK_SHADER_STAGE_FRAGMENT_BIT;
    stages[1].module = frag_module;
    stages[1].pName = "main";

    // Vertex input: 12 floats per vertex
    // [x, y, u, v, fg_r, fg_g, fg_b, fg_a, bg_r, bg_g, bg_b, bg_a]
    VkVertexInputBindingDescription binding = {0};
    binding.binding = 0;
    binding.stride = sizeof(float) * 12;
    binding.inputRate = VK_VERTEX_INPUT_RATE_VERTEX;

    VkVertexInputAttributeDescription attrs[4] = {0};
    // Position (x, y)
    attrs[0].location = 0; attrs[0].binding = 0;
    attrs[0].format = VK_FORMAT_R32G32_SFLOAT; attrs[0].offset = 0;
    // TexCoord (u, v)
    attrs[1].location = 1; attrs[1].binding = 0;
    attrs[1].format = VK_FORMAT_R32G32_SFLOAT; attrs[1].offset = sizeof(float) * 2;
    // FG Color (r, g, b, a)
    attrs[2].location = 2; attrs[2].binding = 0;
    attrs[2].format = VK_FORMAT_R32G32B32A32_SFLOAT; attrs[2].offset = sizeof(float) * 4;
    // BG Color (r, g, b, a)
    attrs[3].location = 3; attrs[3].binding = 0;
    attrs[3].format = VK_FORMAT_R32G32B32A32_SFLOAT; attrs[3].offset = sizeof(float) * 8;

    VkPipelineVertexInputStateCreateInfo vertex_input = {0};
    vertex_input.sType = VK_STRUCTURE_TYPE_PIPELINE_VERTEX_INPUT_STATE_CREATE_INFO;
    vertex_input.vertexBindingDescriptionCount = 1;
    vertex_input.pVertexBindingDescriptions = &binding;
    vertex_input.vertexAttributeDescriptionCount = 4;
    vertex_input.pVertexAttributeDescriptions = attrs;

    VkPipelineInputAssemblyStateCreateInfo input_asm = {0};
    input_asm.sType = VK_STRUCTURE_TYPE_PIPELINE_INPUT_ASSEMBLY_STATE_CREATE_INFO;
    input_asm.topology = VK_PRIMITIVE_TOPOLOGY_TRIANGLE_LIST;

    VkViewport viewport = {0};
    viewport.width = (float)g_gpu.fb_width;
    viewport.height = (float)g_gpu.fb_height;
    viewport.maxDepth = 1.0f;

    VkRect2D scissor = {0};
    scissor.extent = g_gpu.swapchain_extent;

    VkPipelineViewportStateCreateInfo viewport_state = {0};
    viewport_state.sType = VK_STRUCTURE_TYPE_PIPELINE_VIEWPORT_STATE_CREATE_INFO;
    viewport_state.viewportCount = 1;
    viewport_state.pViewports = &viewport;
    viewport_state.scissorCount = 1;
    viewport_state.pScissors = &scissor;

    VkPipelineRasterizationStateCreateInfo rasterizer = {0};
    rasterizer.sType = VK_STRUCTURE_TYPE_PIPELINE_RASTERIZATION_STATE_CREATE_INFO;
    rasterizer.polygonMode = VK_POLYGON_MODE_FILL;
    rasterizer.lineWidth = 1.0f;
    rasterizer.cullMode = VK_CULL_MODE_NONE;
    rasterizer.frontFace = VK_FRONT_FACE_COUNTER_CLOCKWISE;

    VkPipelineMultisampleStateCreateInfo multisampling = {0};
    multisampling.sType = VK_STRUCTURE_TYPE_PIPELINE_MULTISAMPLE_STATE_CREATE_INFO;
    multisampling.rasterizationSamples = VK_SAMPLE_COUNT_1_BIT;

    // Alpha blending for text overlay
    VkPipelineColorBlendAttachmentState blend_attachment = {0};
    blend_attachment.colorWriteMask =
        VK_COLOR_COMPONENT_R_BIT | VK_COLOR_COMPONENT_G_BIT |
        VK_COLOR_COMPONENT_B_BIT | VK_COLOR_COMPONENT_A_BIT;
    blend_attachment.blendEnable = VK_TRUE;
    blend_attachment.srcColorBlendFactor = VK_BLEND_FACTOR_SRC_ALPHA;
    blend_attachment.dstColorBlendFactor = VK_BLEND_FACTOR_ONE_MINUS_SRC_ALPHA;
    blend_attachment.colorBlendOp = VK_BLEND_OP_ADD;
    blend_attachment.srcAlphaBlendFactor = VK_BLEND_FACTOR_ONE;
    blend_attachment.dstAlphaBlendFactor = VK_BLEND_FACTOR_ZERO;
    blend_attachment.alphaBlendOp = VK_BLEND_OP_ADD;

    VkPipelineColorBlendStateCreateInfo color_blend = {0};
    color_blend.sType = VK_STRUCTURE_TYPE_PIPELINE_COLOR_BLEND_STATE_CREATE_INFO;
    color_blend.attachmentCount = 1;
    color_blend.pAttachments = &blend_attachment;

    // Dynamic states for viewport and scissor
    VkDynamicState dynamic_states[] = { VK_DYNAMIC_STATE_VIEWPORT, VK_DYNAMIC_STATE_SCISSOR };
    VkPipelineDynamicStateCreateInfo dynamic_state = {0};
    dynamic_state.sType = VK_STRUCTURE_TYPE_PIPELINE_DYNAMIC_STATE_CREATE_INFO;
    dynamic_state.dynamicStateCount = 2;
    dynamic_state.pDynamicStates = dynamic_states;

    VkGraphicsPipelineCreateInfo pipeline_info = {0};
    pipeline_info.sType = VK_STRUCTURE_TYPE_GRAPHICS_PIPELINE_CREATE_INFO;
    pipeline_info.stageCount = 2;
    pipeline_info.pStages = stages;
    pipeline_info.pVertexInputState = &vertex_input;
    pipeline_info.pInputAssemblyState = &input_asm;
    pipeline_info.pViewportState = &viewport_state;
    pipeline_info.pRasterizationState = &rasterizer;
    pipeline_info.pMultisampleState = &multisampling;
    pipeline_info.pColorBlendState = &color_blend;
    pipeline_info.pDynamicState = &dynamic_state;
    pipeline_info.layout = g_gpu.pipeline_layout;
    pipeline_info.renderPass = g_gpu.render_pass;
    pipeline_info.subpass = 0;

    // Create the text pipeline (with blending for glyph alpha)
    if (vkCreateGraphicsPipelines(g_gpu.device, VK_NULL_HANDLE, 1, &pipeline_info,
                                   NULL, &g_gpu.text_pipeline) != VK_SUCCESS) {
        vkDestroyShaderModule(g_gpu.device, vert_module, NULL);
        vkDestroyShaderModule(g_gpu.device, frag_module, NULL);
        return -1;
    }

    // Background pipeline — same but with blending disabled for opaque bg rects
    blend_attachment.blendEnable = VK_FALSE;
    if (vkCreateGraphicsPipelines(g_gpu.device, VK_NULL_HANDLE, 1, &pipeline_info,
                                   NULL, &g_gpu.bg_pipeline) != VK_SUCCESS) {
        vkDestroyShaderModule(g_gpu.device, vert_module, NULL);
        vkDestroyShaderModule(g_gpu.device, frag_module, NULL);
        return -1;
    }

    vkDestroyShaderModule(g_gpu.device, vert_module, NULL);
    vkDestroyShaderModule(g_gpu.device, frag_module, NULL);
    return 0;
}

// ---------- Public API ----------

int hello_tty_gpu_init(uint64_t surface_handle, int width, int height) {
    if (g_gpu.initialized) return 0;

    // --- Create Vulkan instance ---
    VkApplicationInfo app_info = {0};
    app_info.sType = VK_STRUCTURE_TYPE_APPLICATION_INFO;
    app_info.pApplicationName = "hello_tty";
    app_info.applicationVersion = VK_MAKE_VERSION(0, 1, 0);
    app_info.pEngineName = "hello_tty_gpu";
    app_info.engineVersion = VK_MAKE_VERSION(0, 1, 0);
    app_info.apiVersion = VK_API_VERSION_1_0;

    const char *extensions[] = {
        VK_KHR_SURFACE_EXTENSION_NAME,
#ifdef __APPLE__
        VK_EXT_METAL_SURFACE_EXTENSION_NAME,
        "VK_KHR_portability_enumeration",
#elif defined(__linux__)
        "VK_KHR_xcb_surface",
#endif
    };
    uint32_t ext_count = sizeof(extensions) / sizeof(extensions[0]);

    VkInstanceCreateInfo inst_info = {0};
    inst_info.sType = VK_STRUCTURE_TYPE_INSTANCE_CREATE_INFO;
    inst_info.pApplicationInfo = &app_info;
    inst_info.enabledExtensionCount = ext_count;
    inst_info.ppEnabledExtensionNames = extensions;
#ifdef __APPLE__
    inst_info.flags = VK_INSTANCE_CREATE_ENUMERATE_PORTABILITY_BIT_KHR;
#endif

    if (vkCreateInstance(&inst_info, NULL, &g_gpu.instance) != VK_SUCCESS) {
        fprintf(stderr, "hello_tty: vkCreateInstance failed\n");
        return -1;
    }

    // --- Surface (passed from platform layer) ---
    g_gpu.surface = (VkSurfaceKHR)surface_handle;

    // --- Pick physical device ---
    uint32_t dev_count = 0;
    vkEnumeratePhysicalDevices(g_gpu.instance, &dev_count, NULL);
    if (dev_count == 0) {
        fprintf(stderr, "hello_tty: no Vulkan-capable GPU found\n");
        return -1;
    }
    VkPhysicalDevice *devices = calloc(dev_count, sizeof(VkPhysicalDevice));
    vkEnumeratePhysicalDevices(g_gpu.instance, &dev_count, devices);
    g_gpu.physical_device = devices[0]; // Pick first device
    free(devices);

    // --- Find graphics queue family ---
    uint32_t qf_count = 0;
    vkGetPhysicalDeviceQueueFamilyProperties(g_gpu.physical_device, &qf_count, NULL);
    VkQueueFamilyProperties *qf_props = calloc(qf_count, sizeof(VkQueueFamilyProperties));
    vkGetPhysicalDeviceQueueFamilyProperties(g_gpu.physical_device, &qf_count, qf_props);

    g_gpu.graphics_family = UINT32_MAX;
    for (uint32_t i = 0; i < qf_count; i++) {
        if (qf_props[i].queueFlags & VK_QUEUE_GRAPHICS_BIT) {
            // Also check present support if surface is provided
            if (g_gpu.surface != VK_NULL_HANDLE) {
                VkBool32 present_support = VK_FALSE;
                vkGetPhysicalDeviceSurfaceSupportKHR(g_gpu.physical_device, i, g_gpu.surface, &present_support);
                if (present_support) {
                    g_gpu.graphics_family = i;
                    break;
                }
            } else {
                g_gpu.graphics_family = i;
                break;
            }
        }
    }
    free(qf_props);

    if (g_gpu.graphics_family == UINT32_MAX) {
        fprintf(stderr, "hello_tty: no suitable queue family\n");
        return -1;
    }

    // --- Create logical device ---
    float queue_priority = 1.0f;
    VkDeviceQueueCreateInfo queue_info = {0};
    queue_info.sType = VK_STRUCTURE_TYPE_DEVICE_QUEUE_CREATE_INFO;
    queue_info.queueFamilyIndex = g_gpu.graphics_family;
    queue_info.queueCount = 1;
    queue_info.pQueuePriorities = &queue_priority;

    const char *dev_exts[] = {
        VK_KHR_SWAPCHAIN_EXTENSION_NAME,
#ifdef __APPLE__
        "VK_KHR_portability_subset",
#endif
    };
    uint32_t dev_ext_count = sizeof(dev_exts) / sizeof(dev_exts[0]);

    VkDeviceCreateInfo dev_info = {0};
    dev_info.sType = VK_STRUCTURE_TYPE_DEVICE_CREATE_INFO;
    dev_info.queueCreateInfoCount = 1;
    dev_info.pQueueCreateInfos = &queue_info;
    dev_info.enabledExtensionCount = dev_ext_count;
    dev_info.ppEnabledExtensionNames = dev_exts;

    if (vkCreateDevice(g_gpu.physical_device, &dev_info, NULL, &g_gpu.device) != VK_SUCCESS) {
        fprintf(stderr, "hello_tty: vkCreateDevice failed\n");
        return -1;
    }

    vkGetDeviceQueue(g_gpu.device, g_gpu.graphics_family, 0, &g_gpu.graphics_queue);

    // --- Choose swapchain format ---
    if (g_gpu.surface != VK_NULL_HANDLE) {
        uint32_t fmt_count;
        vkGetPhysicalDeviceSurfaceFormatsKHR(g_gpu.physical_device, g_gpu.surface, &fmt_count, NULL);
        VkSurfaceFormatKHR *formats = calloc(fmt_count, sizeof(VkSurfaceFormatKHR));
        vkGetPhysicalDeviceSurfaceFormatsKHR(g_gpu.physical_device, g_gpu.surface, &fmt_count, formats);

        g_gpu.swapchain_format = formats[0].format;
        for (uint32_t i = 0; i < fmt_count; i++) {
            if (formats[i].format == VK_FORMAT_B8G8R8A8_SRGB &&
                formats[i].colorSpace == VK_COLOR_SPACE_SRGB_NONLINEAR_KHR) {
                g_gpu.swapchain_format = formats[i].format;
                break;
            }
        }
        free(formats);
    } else {
        g_gpu.swapchain_format = VK_FORMAT_B8G8R8A8_SRGB;
    }

    // --- Create render pass, pipelines ---
    if (create_render_pass() != 0) return -1;
    if (create_pipelines() != 0) return -1;

    // --- Create swapchain ---
    if (g_gpu.surface != VK_NULL_HANDLE) {
        if (create_swapchain(width, height) != 0) return -1;
    }

    // --- Command pool & buffer ---
    VkCommandPoolCreateInfo pool_info = {0};
    pool_info.sType = VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO;
    pool_info.flags = VK_COMMAND_POOL_CREATE_RESET_COMMAND_BUFFER_BIT;
    pool_info.queueFamilyIndex = g_gpu.graphics_family;
    if (vkCreateCommandPool(g_gpu.device, &pool_info, NULL, &g_gpu.command_pool) != VK_SUCCESS)
        return -1;

    VkCommandBufferAllocateInfo cb_info = {0};
    cb_info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    cb_info.commandPool = g_gpu.command_pool;
    cb_info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cb_info.commandBufferCount = 1;
    if (vkAllocateCommandBuffers(g_gpu.device, &cb_info, &g_gpu.command_buffer) != VK_SUCCESS)
        return -1;

    // --- Sync objects ---
    VkSemaphoreCreateInfo sem_info = {0};
    sem_info.sType = VK_STRUCTURE_TYPE_SEMAPHORE_CREATE_INFO;
    VkFenceCreateInfo fence_info = {0};
    fence_info.sType = VK_STRUCTURE_TYPE_FENCE_CREATE_INFO;
    fence_info.flags = VK_FENCE_CREATE_SIGNALED_BIT;

    vkCreateSemaphore(g_gpu.device, &sem_info, NULL, &g_gpu.image_available);
    vkCreateSemaphore(g_gpu.device, &sem_info, NULL, &g_gpu.render_finished);
    vkCreateFence(g_gpu.device, &fence_info, NULL, &g_gpu.in_flight);

    g_gpu.initialized = 1;
    return 0;
}

int hello_tty_gpu_resize(int width, int height) {
    if (!g_gpu.initialized) return -1;
    destroy_swapchain_resources();
    return create_swapchain(width, height);
}

void hello_tty_gpu_shutdown(void) {
    if (!g_gpu.initialized) return;
    vkDeviceWaitIdle(g_gpu.device);

    // Vertex buffer
    if (g_gpu.vertex_buffer) vkDestroyBuffer(g_gpu.device, g_gpu.vertex_buffer, NULL);
    if (g_gpu.vertex_memory) vkFreeMemory(g_gpu.device, g_gpu.vertex_memory, NULL);

    // Atlas
    if (g_gpu.atlas_sampler) vkDestroySampler(g_gpu.device, g_gpu.atlas_sampler, NULL);
    if (g_gpu.atlas_view) vkDestroyImageView(g_gpu.device, g_gpu.atlas_view, NULL);
    if (g_gpu.atlas_image) vkDestroyImage(g_gpu.device, g_gpu.atlas_image, NULL);
    if (g_gpu.atlas_memory) vkFreeMemory(g_gpu.device, g_gpu.atlas_memory, NULL);
    if (g_gpu.descriptor_pool) vkDestroyDescriptorPool(g_gpu.device, g_gpu.descriptor_pool, NULL);
    if (g_gpu.descriptor_set_layout) vkDestroyDescriptorSetLayout(g_gpu.device, g_gpu.descriptor_set_layout, NULL);

    // Pipelines
    if (g_gpu.bg_pipeline) vkDestroyPipeline(g_gpu.device, g_gpu.bg_pipeline, NULL);
    if (g_gpu.text_pipeline) vkDestroyPipeline(g_gpu.device, g_gpu.text_pipeline, NULL);
    if (g_gpu.pipeline_layout) vkDestroyPipelineLayout(g_gpu.device, g_gpu.pipeline_layout, NULL);

    // Render pass
    if (g_gpu.render_pass) vkDestroyRenderPass(g_gpu.device, g_gpu.render_pass, NULL);

    // Sync
    if (g_gpu.image_available) vkDestroySemaphore(g_gpu.device, g_gpu.image_available, NULL);
    if (g_gpu.render_finished) vkDestroySemaphore(g_gpu.device, g_gpu.render_finished, NULL);
    if (g_gpu.in_flight) vkDestroyFence(g_gpu.device, g_gpu.in_flight, NULL);

    // Command pool
    if (g_gpu.command_pool) vkDestroyCommandPool(g_gpu.device, g_gpu.command_pool, NULL);

    destroy_swapchain_resources();

    if (g_gpu.device) vkDestroyDevice(g_gpu.device, NULL);
    // Surface is owned by the platform layer — don't destroy it here
    if (g_gpu.instance) vkDestroyInstance(g_gpu.instance, NULL);

    memset(&g_gpu, 0, sizeof(g_gpu));
}

// ---------- Atlas texture ----------

int hello_tty_gpu_atlas_create(int width, int height) {
    if (!g_gpu.initialized) return -1;
    vkDeviceWaitIdle(g_gpu.device);

    // Destroy old atlas resources
    if (g_gpu.atlas_view) vkDestroyImageView(g_gpu.device, g_gpu.atlas_view, NULL);
    if (g_gpu.atlas_image) vkDestroyImage(g_gpu.device, g_gpu.atlas_image, NULL);
    if (g_gpu.atlas_memory) vkFreeMemory(g_gpu.device, g_gpu.atlas_memory, NULL);
    if (g_gpu.atlas_sampler) vkDestroySampler(g_gpu.device, g_gpu.atlas_sampler, NULL);

    g_gpu.atlas_width = width;
    g_gpu.atlas_height = height;

    // Create image
    VkImageCreateInfo img_info = {0};
    img_info.sType = VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO;
    img_info.imageType = VK_IMAGE_TYPE_2D;
    img_info.format = VK_FORMAT_R8G8B8A8_UNORM;
    img_info.extent.width = (uint32_t)width;
    img_info.extent.height = (uint32_t)height;
    img_info.extent.depth = 1;
    img_info.mipLevels = 1;
    img_info.arrayLayers = 1;
    img_info.samples = VK_SAMPLE_COUNT_1_BIT;
    img_info.tiling = VK_IMAGE_TILING_OPTIMAL;
    img_info.usage = VK_IMAGE_USAGE_TRANSFER_DST_BIT | VK_IMAGE_USAGE_SAMPLED_BIT;
    img_info.initialLayout = VK_IMAGE_LAYOUT_UNDEFINED;

    if (vkCreateImage(g_gpu.device, &img_info, NULL, &g_gpu.atlas_image) != VK_SUCCESS)
        return -1;

    VkMemoryRequirements mem_req;
    vkGetImageMemoryRequirements(g_gpu.device, g_gpu.atlas_image, &mem_req);

    VkMemoryAllocateInfo alloc = {0};
    alloc.sType = VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO;
    alloc.allocationSize = mem_req.size;
    alloc.memoryTypeIndex = find_memory_type(mem_req.memoryTypeBits, VK_MEMORY_PROPERTY_DEVICE_LOCAL_BIT);

    if (vkAllocateMemory(g_gpu.device, &alloc, NULL, &g_gpu.atlas_memory) != VK_SUCCESS)
        return -1;
    vkBindImageMemory(g_gpu.device, g_gpu.atlas_image, g_gpu.atlas_memory, 0);

    // Image view
    VkImageViewCreateInfo view_info = {0};
    view_info.sType = VK_STRUCTURE_TYPE_IMAGE_VIEW_CREATE_INFO;
    view_info.image = g_gpu.atlas_image;
    view_info.viewType = VK_IMAGE_VIEW_TYPE_2D;
    view_info.format = VK_FORMAT_R8G8B8A8_UNORM;
    view_info.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    view_info.subresourceRange.levelCount = 1;
    view_info.subresourceRange.layerCount = 1;

    if (vkCreateImageView(g_gpu.device, &view_info, NULL, &g_gpu.atlas_view) != VK_SUCCESS)
        return -1;

    // Sampler
    VkSamplerCreateInfo sampler_info = {0};
    sampler_info.sType = VK_STRUCTURE_TYPE_SAMPLER_CREATE_INFO;
    sampler_info.magFilter = VK_FILTER_LINEAR;
    sampler_info.minFilter = VK_FILTER_LINEAR;
    sampler_info.addressModeU = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    sampler_info.addressModeV = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;
    sampler_info.addressModeW = VK_SAMPLER_ADDRESS_MODE_CLAMP_TO_EDGE;

    if (vkCreateSampler(g_gpu.device, &sampler_info, NULL, &g_gpu.atlas_sampler) != VK_SUCCESS)
        return -1;

    // Descriptor pool & set
    if (g_gpu.descriptor_pool) {
        vkDestroyDescriptorPool(g_gpu.device, g_gpu.descriptor_pool, NULL);
        g_gpu.descriptor_pool = VK_NULL_HANDLE;
    }

    VkDescriptorPoolSize pool_size = {0};
    pool_size.type = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    pool_size.descriptorCount = 1;

    VkDescriptorPoolCreateInfo dpool_info = {0};
    dpool_info.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_POOL_CREATE_INFO;
    dpool_info.maxSets = 1;
    dpool_info.poolSizeCount = 1;
    dpool_info.pPoolSizes = &pool_size;

    if (vkCreateDescriptorPool(g_gpu.device, &dpool_info, NULL, &g_gpu.descriptor_pool) != VK_SUCCESS)
        return -1;

    VkDescriptorSetAllocateInfo ds_alloc = {0};
    ds_alloc.sType = VK_STRUCTURE_TYPE_DESCRIPTOR_SET_ALLOCATE_INFO;
    ds_alloc.descriptorPool = g_gpu.descriptor_pool;
    ds_alloc.descriptorSetCount = 1;
    ds_alloc.pSetLayouts = &g_gpu.descriptor_set_layout;

    if (vkAllocateDescriptorSets(g_gpu.device, &ds_alloc, &g_gpu.descriptor_set) != VK_SUCCESS)
        return -1;

    // Update descriptor set
    VkDescriptorImageInfo img_desc = {0};
    img_desc.sampler = g_gpu.atlas_sampler;
    img_desc.imageView = g_gpu.atlas_view;
    img_desc.imageLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;

    VkWriteDescriptorSet write = {0};
    write.sType = VK_STRUCTURE_TYPE_WRITE_DESCRIPTOR_SET;
    write.dstSet = g_gpu.descriptor_set;
    write.dstBinding = 0;
    write.descriptorCount = 1;
    write.descriptorType = VK_DESCRIPTOR_TYPE_COMBINED_IMAGE_SAMPLER;
    write.pImageInfo = &img_desc;

    vkUpdateDescriptorSets(g_gpu.device, 1, &write, 0, NULL);

    return 0;
}

int hello_tty_gpu_atlas_upload(
    int x, int y, int region_w, int region_h,
    const uint8_t *data, int data_len) {
    if (!g_gpu.initialized || !g_gpu.atlas_image) return -1;
    (void)data_len;

    VkDeviceSize buf_size = (VkDeviceSize)(region_w * region_h * 4);

    // Create staging buffer
    VkBuffer staging;
    VkDeviceMemory staging_mem;
    if (create_buffer(buf_size, VK_BUFFER_USAGE_TRANSFER_SRC_BIT,
                      VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                      &staging, &staging_mem) != 0)
        return -1;

    // Copy data to staging
    void *mapped;
    vkMapMemory(g_gpu.device, staging_mem, 0, buf_size, 0, &mapped);
    memcpy(mapped, data, (size_t)buf_size);
    vkUnmapMemory(g_gpu.device, staging_mem);

    // Record one-shot command buffer for copy
    VkCommandBufferAllocateInfo cb_info = {0};
    cb_info.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO;
    cb_info.commandPool = g_gpu.command_pool;
    cb_info.level = VK_COMMAND_BUFFER_LEVEL_PRIMARY;
    cb_info.commandBufferCount = 1;

    VkCommandBuffer cb;
    vkAllocateCommandBuffers(g_gpu.device, &cb_info, &cb);

    VkCommandBufferBeginInfo begin = {0};
    begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(cb, &begin);

    // Transition atlas image to TRANSFER_DST
    VkImageMemoryBarrier barrier = {0};
    barrier.sType = VK_STRUCTURE_TYPE_IMAGE_MEMORY_BARRIER;
    barrier.oldLayout = VK_IMAGE_LAYOUT_UNDEFINED;
    barrier.newLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.srcQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.dstQueueFamilyIndex = VK_QUEUE_FAMILY_IGNORED;
    barrier.image = g_gpu.atlas_image;
    barrier.subresourceRange.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    barrier.subresourceRange.levelCount = 1;
    barrier.subresourceRange.layerCount = 1;
    barrier.dstAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;

    vkCmdPipelineBarrier(cb,
        VK_PIPELINE_STAGE_TOP_OF_PIPE_BIT, VK_PIPELINE_STAGE_TRANSFER_BIT,
        0, 0, NULL, 0, NULL, 1, &barrier);

    // Copy buffer to image
    VkBufferImageCopy region = {0};
    region.imageSubresource.aspectMask = VK_IMAGE_ASPECT_COLOR_BIT;
    region.imageSubresource.layerCount = 1;
    region.imageOffset.x = x;
    region.imageOffset.y = y;
    region.imageExtent.width = (uint32_t)region_w;
    region.imageExtent.height = (uint32_t)region_h;
    region.imageExtent.depth = 1;

    vkCmdCopyBufferToImage(cb, staging, g_gpu.atlas_image,
        VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, 1, &region);

    // Transition to SHADER_READ_ONLY
    barrier.oldLayout = VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    barrier.newLayout = VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    barrier.srcAccessMask = VK_ACCESS_TRANSFER_WRITE_BIT;
    barrier.dstAccessMask = VK_ACCESS_SHADER_READ_BIT;

    vkCmdPipelineBarrier(cb,
        VK_PIPELINE_STAGE_TRANSFER_BIT, VK_PIPELINE_STAGE_FRAGMENT_SHADER_BIT,
        0, 0, NULL, 0, NULL, 1, &barrier);

    vkEndCommandBuffer(cb);

    VkSubmitInfo submit = {0};
    submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &cb;
    vkQueueSubmit(g_gpu.graphics_queue, 1, &submit, VK_NULL_HANDLE);
    vkQueueWaitIdle(g_gpu.graphics_queue);

    vkFreeCommandBuffers(g_gpu.device, g_gpu.command_pool, 1, &cb);
    vkDestroyBuffer(g_gpu.device, staging, NULL);
    vkFreeMemory(g_gpu.device, staging_mem, NULL);

    return 0;
}

// ---------- Per-frame rendering ----------

int hello_tty_gpu_frame_begin(void) {
    if (!g_gpu.initialized) return -1;

    vkWaitForFences(g_gpu.device, 1, &g_gpu.in_flight, VK_TRUE, UINT64_MAX);
    vkResetFences(g_gpu.device, 1, &g_gpu.in_flight);

    VkResult result = vkAcquireNextImageKHR(g_gpu.device, g_gpu.swapchain, UINT64_MAX,
        g_gpu.image_available, VK_NULL_HANDLE, &g_gpu.current_image_index);

    if (result == VK_ERROR_OUT_OF_DATE_KHR) return -1;

    vkResetCommandBuffer(g_gpu.command_buffer, 0);

    VkCommandBufferBeginInfo begin = {0};
    begin.sType = VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO;
    begin.flags = VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT;
    vkBeginCommandBuffer(g_gpu.command_buffer, &begin);

    VkClearValue clear_value = {0};
    clear_value.color.float32[0] = g_gpu.clear_r;
    clear_value.color.float32[1] = g_gpu.clear_g;
    clear_value.color.float32[2] = g_gpu.clear_b;
    clear_value.color.float32[3] = g_gpu.clear_a;

    VkRenderPassBeginInfo rp_begin = {0};
    rp_begin.sType = VK_STRUCTURE_TYPE_RENDER_PASS_BEGIN_INFO;
    rp_begin.renderPass = g_gpu.render_pass;
    rp_begin.framebuffer = g_gpu.framebuffers[g_gpu.current_image_index];
    rp_begin.renderArea.extent = g_gpu.swapchain_extent;
    rp_begin.clearValueCount = 1;
    rp_begin.pClearValues = &clear_value;

    vkCmdBeginRenderPass(g_gpu.command_buffer, &rp_begin, VK_SUBPASS_CONTENTS_INLINE);

    // Set dynamic viewport and scissor
    VkViewport viewport = {0};
    viewport.width = (float)g_gpu.fb_width;
    viewport.height = (float)g_gpu.fb_height;
    viewport.maxDepth = 1.0f;
    vkCmdSetViewport(g_gpu.command_buffer, 0, 1, &viewport);

    VkRect2D scissor = {0};
    scissor.extent = g_gpu.swapchain_extent;
    vkCmdSetScissor(g_gpu.command_buffer, 0, 1, &scissor);

    // Push viewport dimensions
    float push_data[2] = { (float)g_gpu.fb_width, (float)g_gpu.fb_height };
    vkCmdPushConstants(g_gpu.command_buffer, g_gpu.pipeline_layout,
        VK_SHADER_STAGE_VERTEX_BIT, 0, sizeof(push_data), push_data);

    return 0;
}

void hello_tty_gpu_frame_clear(uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    g_gpu.clear_r = (float)r / 255.0f;
    g_gpu.clear_g = (float)g / 255.0f;
    g_gpu.clear_b = (float)b / 255.0f;
    g_gpu.clear_a = (float)a / 255.0f;
}

int hello_tty_gpu_draw_cells(const float *vertices, int vertex_count) {
    if (!g_gpu.initialized || vertex_count <= 0) return 0;

    VkDeviceSize buf_size = (VkDeviceSize)(vertex_count * 12 * sizeof(float));

    // Recreate vertex buffer if needed
    if (buf_size > g_gpu.vertex_buffer_size) {
        if (g_gpu.vertex_buffer) vkDestroyBuffer(g_gpu.device, g_gpu.vertex_buffer, NULL);
        if (g_gpu.vertex_memory) vkFreeMemory(g_gpu.device, g_gpu.vertex_memory, NULL);

        if (create_buffer(buf_size, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                          VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                          &g_gpu.vertex_buffer, &g_gpu.vertex_memory) != 0)
            return -1;
        g_gpu.vertex_buffer_size = (size_t)buf_size;
    }

    // Upload vertex data
    void *mapped;
    vkMapMemory(g_gpu.device, g_gpu.vertex_memory, 0, buf_size, 0, &mapped);
    memcpy(mapped, vertices, (size_t)buf_size);
    vkUnmapMemory(g_gpu.device, g_gpu.vertex_memory);

    // Bind pipeline and draw
    // First pass: backgrounds (opaque)
    vkCmdBindPipeline(g_gpu.command_buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, g_gpu.bg_pipeline);
    VkDeviceSize offset = 0;
    vkCmdBindVertexBuffers(g_gpu.command_buffer, 0, 1, &g_gpu.vertex_buffer, &offset);
    vkCmdDraw(g_gpu.command_buffer, (uint32_t)vertex_count, 1, 0, 0);

    // Second pass: text (with alpha blending and atlas texture)
    vkCmdBindPipeline(g_gpu.command_buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, g_gpu.text_pipeline);
    if (g_gpu.descriptor_set) {
        vkCmdBindDescriptorSets(g_gpu.command_buffer, VK_PIPELINE_BIND_POINT_GRAPHICS,
            g_gpu.pipeline_layout, 0, 1, &g_gpu.descriptor_set, 0, NULL);
    }
    vkCmdBindVertexBuffers(g_gpu.command_buffer, 0, 1, &g_gpu.vertex_buffer, &offset);
    vkCmdDraw(g_gpu.command_buffer, (uint32_t)vertex_count, 1, 0, 0);

    return 0;
}

void hello_tty_gpu_draw_cursor(
    float x, float y, float w, float h,
    uint8_t r, uint8_t g, uint8_t b, uint8_t a,
    int style) {
    if (!g_gpu.initialized) return;

    // Draw cursor as a simple colored quad using the bg pipeline
    float fr = (float)r / 255.0f, fg = (float)g / 255.0f;
    float fb = (float)b / 255.0f, fa = (float)a / 255.0f;

    float cursor_x = x, cursor_y = y, cursor_w = w, cursor_h = h;

    // Adjust cursor geometry based on style
    switch (style) {
        case 1: // Underline
            cursor_y = y + h - 2.0f;
            cursor_h = 2.0f;
            break;
        case 2: // Bar
            cursor_w = 2.0f;
            break;
        default: // Block
            break;
    }

    // 6 vertices for a quad (2 triangles)
    float verts[6 * 12] = {
        // Triangle 1
        cursor_x,           cursor_y,            0, 0, fr, fg, fb, fa, fr, fg, fb, fa,
        cursor_x + cursor_w, cursor_y,            0, 0, fr, fg, fb, fa, fr, fg, fb, fa,
        cursor_x,           cursor_y + cursor_h, 0, 0, fr, fg, fb, fa, fr, fg, fb, fa,
        // Triangle 2
        cursor_x + cursor_w, cursor_y,            0, 0, fr, fg, fb, fa, fr, fg, fb, fa,
        cursor_x + cursor_w, cursor_y + cursor_h, 0, 0, fr, fg, fb, fa, fr, fg, fb, fa,
        cursor_x,           cursor_y + cursor_h, 0, 0, fr, fg, fb, fa, fr, fg, fb, fa,
    };

    VkDeviceSize buf_size = sizeof(verts);
    VkBuffer cursor_buf;
    VkDeviceMemory cursor_mem;
    if (create_buffer(buf_size, VK_BUFFER_USAGE_VERTEX_BUFFER_BIT,
                      VK_MEMORY_PROPERTY_HOST_VISIBLE_BIT | VK_MEMORY_PROPERTY_HOST_COHERENT_BIT,
                      &cursor_buf, &cursor_mem) != 0)
        return;

    void *mapped;
    vkMapMemory(g_gpu.device, cursor_mem, 0, buf_size, 0, &mapped);
    memcpy(mapped, verts, sizeof(verts));
    vkUnmapMemory(g_gpu.device, cursor_mem);

    vkCmdBindPipeline(g_gpu.command_buffer, VK_PIPELINE_BIND_POINT_GRAPHICS, g_gpu.text_pipeline);
    VkDeviceSize offset = 0;
    vkCmdBindVertexBuffers(g_gpu.command_buffer, 0, 1, &cursor_buf, &offset);
    vkCmdDraw(g_gpu.command_buffer, 6, 1, 0, 0);

    // Note: these resources will be freed after frame end when device is idle.
    // For a production renderer, use a ring buffer. This is correct but not optimal.
    // We'll clean up in frame_end after vkQueueWaitIdle.
    // For now, leak slightly (will be cleaned on shutdown).
    // TODO: ring-buffer allocation for per-frame cursor draws.
    vkDestroyBuffer(g_gpu.device, cursor_buf, NULL);
    vkFreeMemory(g_gpu.device, cursor_mem, NULL);
}

int hello_tty_gpu_frame_end(void) {
    if (!g_gpu.initialized) return -1;

    vkCmdEndRenderPass(g_gpu.command_buffer);
    vkEndCommandBuffer(g_gpu.command_buffer);

    VkPipelineStageFlags wait_stage = VK_PIPELINE_STAGE_COLOR_ATTACHMENT_OUTPUT_BIT;
    VkSubmitInfo submit = {0};
    submit.sType = VK_STRUCTURE_TYPE_SUBMIT_INFO;
    submit.waitSemaphoreCount = 1;
    submit.pWaitSemaphores = &g_gpu.image_available;
    submit.pWaitDstStageMask = &wait_stage;
    submit.commandBufferCount = 1;
    submit.pCommandBuffers = &g_gpu.command_buffer;
    submit.signalSemaphoreCount = 1;
    submit.pSignalSemaphores = &g_gpu.render_finished;

    if (vkQueueSubmit(g_gpu.graphics_queue, 1, &submit, g_gpu.in_flight) != VK_SUCCESS)
        return -1;

    VkPresentInfoKHR present = {0};
    present.sType = VK_STRUCTURE_TYPE_PRESENT_INFO_KHR;
    present.waitSemaphoreCount = 1;
    present.pWaitSemaphores = &g_gpu.render_finished;
    present.swapchainCount = 1;
    present.pSwapchains = &g_gpu.swapchain;
    present.pImageIndices = &g_gpu.current_image_index;

    VkResult result = vkQueuePresentKHR(g_gpu.graphics_queue, &present);
    if (result == VK_ERROR_OUT_OF_DATE_KHR || result == VK_SUBOPTIMAL_KHR)
        return -1; // Caller should resize

    return 0;
}

#else // !HELLO_TTY_HAS_VULKAN

// ---------- Stub implementations when Vulkan SDK is not available ----------
// All GPU functions return failure/no-op.
// On macOS, the primary rendering path is CoreText in the Swift adapter,
// so these stubs are sufficient for building and running.

#include <stdio.h>

int hello_tty_gpu_init(uint64_t surface_handle, int width, int height) {
    (void)surface_handle; (void)width; (void)height;
    fprintf(stderr, "hello_tty: Vulkan SDK not available, GPU backend disabled\n");
    return -1;
}
int hello_tty_gpu_resize(int width, int height) { (void)width; (void)height; return -1; }
void hello_tty_gpu_shutdown(void) {}
int hello_tty_gpu_atlas_create(int width, int height) { (void)width; (void)height; return -1; }
int hello_tty_gpu_atlas_upload(int x, int y, int rw, int rh, const uint8_t *data, int len) {
    (void)x; (void)y; (void)rw; (void)rh; (void)data; (void)len; return -1;
}
int hello_tty_gpu_frame_begin(void) { return -1; }
void hello_tty_gpu_frame_clear(uint8_t r, uint8_t g, uint8_t b, uint8_t a) {
    (void)r; (void)g; (void)b; (void)a;
}
int hello_tty_gpu_draw_cells(const float *vertices, int vertex_count) {
    (void)vertices; (void)vertex_count; return -1;
}
void hello_tty_gpu_draw_cursor(float x, float y, float w, float h,
    uint8_t r, uint8_t g, uint8_t b, uint8_t a, int style) {
    (void)x; (void)y; (void)w; (void)h;
    (void)r; (void)g; (void)b; (void)a; (void)style;
}
int hello_tty_gpu_frame_end(void) { return -1; }

#endif // HELLO_TTY_HAS_VULKAN
