// WGSL shaders for terminal cell rendering via wgpu.
//
// Rendering strategy: each terminal cell is a quad (2 triangles, 6 vertices).
// Per-vertex data: position, texcoord, fg color, bg color.
// The fragment shader samples the glyph atlas and blends:
//   output = mix(bg_color, fg_color, glyph_alpha)
//
// This means background and foreground are drawn in a single pass.

#ifndef HELLO_TTY_SHADERS_WGSL_H
#define HELLO_TTY_SHADERS_WGSL_H

static const char *cell_shader_wgsl =
    // Uniforms: viewport size for NDC conversion
    "struct Uniforms {\n"
    "    viewport_size: vec2f,\n"
    "}\n"
    "\n"
    "@group(0) @binding(0) var<uniform> uniforms: Uniforms;\n"
    "@group(0) @binding(1) var atlas_tex: texture_2d<f32>;\n"
    "@group(0) @binding(2) var atlas_sampler: sampler;\n"
    "\n"
    // Vertex input: 12 floats per vertex
    "struct VertexInput {\n"
    "    @location(0) position: vec2f,\n"
    "    @location(1) texcoord: vec2f,\n"
    "    @location(2) fg_color: vec4f,\n"
    "    @location(3) bg_color: vec4f,\n"
    "}\n"
    "\n"
    "struct VertexOutput {\n"
    "    @builtin(position) clip_position: vec4f,\n"
    "    @location(0) texcoord: vec2f,\n"
    "    @location(1) fg_color: vec4f,\n"
    "    @location(2) bg_color: vec4f,\n"
    "}\n"
    "\n"
    "@vertex\n"
    "fn vs_main(in: VertexInput) -> VertexOutput {\n"
    "    var out: VertexOutput;\n"
    "    // Convert pixel coords to NDC [-1, 1]\n"
    "    let ndc = (in.position / uniforms.viewport_size) * 2.0 - 1.0;\n"
    "    // Flip Y: pixel Y=0 is top, NDC Y=1 is top\n"
    "    out.clip_position = vec4f(ndc.x, -ndc.y, 0.0, 1.0);\n"
    "    out.texcoord = in.texcoord;\n"
    "    out.fg_color = in.fg_color;\n"
    "    out.bg_color = in.bg_color;\n"
    "    return out;\n"
    "}\n"
    "\n"
    "@fragment\n"
    "fn fs_main(in: VertexOutput) -> @location(0) vec4f {\n"
    "    let glyph = textureSample(atlas_tex, atlas_sampler, in.texcoord);\n"
    "    // Alpha from the alpha channel (RGBA atlas)\n"
    "    let alpha = glyph.a;\n"
    "    // Mix: background where no glyph, foreground where glyph\n"
    "    return mix(in.bg_color, in.fg_color, alpha);\n"
    "}\n";

// Cursor shader: solid color quad, no texture sampling
static const char *cursor_shader_wgsl =
    "struct Uniforms {\n"
    "    viewport_size: vec2f,\n"
    "}\n"
    "\n"
    "@group(0) @binding(0) var<uniform> uniforms: Uniforms;\n"
    "\n"
    "struct VertexInput {\n"
    "    @location(0) position: vec2f,\n"
    "    @location(1) color: vec4f,\n"
    "}\n"
    "\n"
    "struct VertexOutput {\n"
    "    @builtin(position) clip_position: vec4f,\n"
    "    @location(0) color: vec4f,\n"
    "}\n"
    "\n"
    "@vertex\n"
    "fn vs_main(in: VertexInput) -> VertexOutput {\n"
    "    var out: VertexOutput;\n"
    "    let ndc = (in.position / uniforms.viewport_size) * 2.0 - 1.0;\n"
    "    out.clip_position = vec4f(ndc.x, -ndc.y, 0.0, 1.0);\n"
    "    out.color = in.color;\n"
    "    return out;\n"
    "}\n"
    "\n"
    "@fragment\n"
    "fn fs_main(in: VertexOutput) -> @location(0) vec4f {\n"
    "    return in.color;\n"
    "}\n";

#endif // HELLO_TTY_SHADERS_WGSL_H
