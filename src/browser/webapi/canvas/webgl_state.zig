// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// This program is free software: you can redistribute it and/or modify
// it under the terms of the GNU Affero General Public License as
// published by the Free Software Foundation, either version 3 of the
// License, or (at your option) any later version.
//
// This program is distributed in the hope that it will be useful,
// but WITHOUT ANY WARRANTY; without even the implied warranty of
// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
// GNU Affero General Public License for more details.
//
// You should have received a copy of the GNU Affero General Public License
// along with this program.  If not, see <https://www.gnu.org/licenses/>.

// The part of a WebGL context that has state: shader and program objects, the
// bound array buffer, the vertex attribute arrays, the viewport, the clear
// colour and the drawing buffer itself. Both WebGLRenderingContext and
// WebGL2RenderingContext delegate here, the way the two 2D contexts share
// context_draw.zig -- they are separate types with separate prototypes, and a
// fix that reached only one of them would leave a detector free to ask the
// other.
//
// Why any of it exists: the widget compiles a fragment shader, links it, draws
// a quad and reads the pixels back. Answering COMPILE_STATUS false sent it
// down a branch that then swept seventy getParameter calls no browser makes,
// so the cheapest way to stop looking strange was to stop failing. Answering
// true over a zeroed buffer would have been worse than failing: a wrong value
// where Chrome has a real one. So the pixels are computed, in glsl.zig.
//
// What this is not: a renderer. There are no textures, no varyings, no
// uniforms, no depth or stencil buffer, no blending and no multisampling. A
// draw that needs any of those is one whose shader did not compile here, and
// the buffer is left as it was rather than filled with a guess. The vertex
// stage runs the same interpreter as the fragment stage; between them sits a
// point-in-triangle test on pixel centres, with no antialiasing -- Chrome
// resolves an antialiased edge and we do not, so a shape with a diagonal edge
// still differs there. The full-screen quads a fingerprint draws have no
// diagonal on screen.

const std = @import("std");

const js = @import("../../js/js.zig");
const glsl = @import("glsl.zig");
const objects = @import("webgl_objects.zig");
const Surface = @import("raster.zig");

const Allocator = std.mem.Allocator;

const State = @This();

/// GL enumerants this module acts on. The contexts declare the full set for
/// JS; these are the handful the pipeline actually branches on.
pub const VERTEX_SHADER: u32 = 0x8B31;
pub const FRAGMENT_SHADER: u32 = 0x8B30;
pub const ARRAY_BUFFER: u32 = 0x8892;
pub const COLOR_BUFFER_BIT: u32 = 0x4000;
pub const POINTS: u32 = 0x0000;
pub const TRIANGLES: u32 = 0x0004;
pub const TRIANGLE_STRIP: u32 = 0x0005;
pub const TRIANGLE_FAN: u32 = 0x0006;
pub const FLOAT: u32 = 0x1406;
pub const RGBA: u32 = 0x1908;
pub const UNSIGNED_BYTE: u32 = 0x1401;

/// Chrome exposes 16 generic attribute slots on this hardware
/// (MAX_VERTEX_ATTRIBS), and the contexts already report that number.
const max_attribs = 16;

/// A draw wider than this is not a fingerprint, and running the interpreter
/// over it would let a page spend our time rather than its own. Sixteen by
/// sixteen is what the widget asks for.
const max_fragments = 1 << 20;

/// Likewise for geometry: the quad is four vertices.
const max_vertices = 1 << 12;

/// Frame-lifetime arena, shared with the canvas backing store.
arena: Allocator,
/// The drawing buffer. Top-down RGBA8, like every other surface in the tree --
/// GL's own coordinates are bottom-up, and the flip happens where window
/// coordinates are turned into rows, not here.
surface: Surface,
clear_color: [4]f32 = @splat(0),
/// Null until the page sets one, which means "the whole drawing buffer".
viewport: ?[4]i32 = null,
program: ?*objects.WebGLProgram = null,
array_buffer: ?*objects.WebGLBuffer = null,
attribs: [max_attribs]Attrib = @splat(.{}),

pub fn init(arena: Allocator) State {
    return .{ .arena = arena, .surface = .{ .arena = arena } };
}

/// One generic vertex attribute array, as `vertexAttribPointer` describes it.
/// The buffer is the one bound to ARRAY_BUFFER at the time of that call, which
/// is how GL captures it.
const Attrib = struct {
    enabled: bool = false,
    buffer: ?*objects.WebGLBuffer = null,
    size: u8 = 4,
    kind: u32 = FLOAT,
    stride: u32 = 0,
    offset: u32 = 0,
};

// ---------------------------------------------------------------------------
// Shaders and programs

pub fn shaderSource(self: *State, shader: ?*objects.WebGLShader, source: []const u8) void {
    const target = shader orelse return;
    // The page's string is borrowed; the shader outlives the call.
    target._source = self.arena.dupe(u8, source) catch return;
    // A new source invalidates the last compile, as it does in GL.
    target._program = null;
}

/// Parsing *is* compiling here: a source this interpreter cannot run is one
/// COMPILE_STATUS reports as failed, which is a state Chrome also reaches.
pub fn compileShader(self: *State, shader: ?*objects.WebGLShader) void {
    const target = shader orelse return;
    target._program = glsl.compile(self.arena, target._source) catch null;
}

pub fn attachShader(_: *State, program: ?*objects.WebGLProgram, shader: ?*objects.WebGLShader) void {
    const p = program orelse return;
    const s = shader orelse return;
    switch (s._kind) {
        VERTEX_SHADER => p._vertex = s,
        FRAGMENT_SHADER => p._fragment = s,
        else => {},
    }
}

pub fn detachShader(_: *State, program: ?*objects.WebGLProgram, shader: ?*objects.WebGLShader) void {
    const p = program orelse return;
    const s = shader orelse return;
    if (p._vertex == s) p._vertex = null;
    if (p._fragment == s) p._fragment = null;
}

/// Linking succeeds when both stages are attached and both compiled. There is
/// nothing here that could fail the way a real linker fails -- no varyings to
/// match up, no uniform budget to blow -- so the stages are the whole check.
pub fn linkProgram(_: *State, program: ?*objects.WebGLProgram) void {
    const p = program orelse return;
    p._linked = p._vertex != null and p._fragment != null and
        p._vertex.?._program != null and p._fragment.?._program != null;
    p._validated = false;
}

/// VALIDATE_STATUS is not LINK_STATUS under another name: Chrome reports false
/// until this call happens, and true afterwards for a program that linked.
pub fn validateProgram(_: *State, program: ?*objects.WebGLProgram) void {
    const p = program orelse return;
    p._validated = p._linked;
}

pub fn useProgram(self: *State, program: ?*objects.WebGLProgram) void {
    self.program = program;
}

pub fn attachedShaders(_: *const State, program: ?*objects.WebGLProgram) i32 {
    const p = program orelse return 0;
    var n: i32 = 0;
    if (p._vertex != null) n += 1;
    if (p._fragment != null) n += 1;
    return n;
}

/// The attributes the vertex stage declares, which is also how many locations
/// the program has. Only a linked program has any: Chrome answers 0 before.
pub fn activeAttributes(self: *const State, program: ?*objects.WebGLProgram) i32 {
    const list = self.attributeList(program) orelse return 0;
    return @intCast(list.len);
}

/// Locations are handed out in declaration order, which is what the drivers
/// measured here do for a shader with no explicit `layout(location=)`.
pub fn attribLocation(self: *const State, program: ?*objects.WebGLProgram, name: []const u8) i32 {
    const list = self.attributeList(program) orelse return -1;
    for (list, 0..) |attribute, i| {
        if (std.mem.eql(u8, attribute.name, name)) return @intCast(i);
    }
    return -1;
}

/// The vertex stage's declared inputs, once there is a linked program to have
/// any. Null rather than empty, so callers can tell "no program" from "a
/// program with no attributes".
pub fn attributeList(_: *const State, program: ?*objects.WebGLProgram) ?[]const glsl.Attribute {
    const p = program orelse return null;
    if (!p._linked) return null;
    const vertex = p._vertex orelse return null;
    const compiled = vertex._program orelse return null;
    return compiled.attributes;
}

/// What `getActiveAttrib` reports: the declared type, not the padded one.
/// Chrome answers FLOAT_VEC2 for `attribute vec2 p` -- measured.
pub fn attribType(components: u8) u32 {
    return switch (components) {
        2 => 0x8B50, // FLOAT_VEC2
        3 => 0x8B51, // FLOAT_VEC3
        4 => 0x8B52, // FLOAT_VEC4
        else => FLOAT,
    };
}

/// The shaders attached to a program, in attach order and by identity -- a
/// caller compares them against the handles it created.
pub fn attachedShaderList(
    _: *const State,
    program: ?*objects.WebGLProgram,
    arena: Allocator,
) ![]const *objects.WebGLShader {
    const p = program orelse return &.{};
    var out: std.ArrayList(*objects.WebGLShader) = .empty;
    if (p._vertex) |vertex| try out.append(arena, vertex);
    if (p._fragment) |fragment| try out.append(arena, fragment);
    return out.items;
}

// ---------------------------------------------------------------------------
// Buffers and attribute arrays

pub fn bindBuffer(self: *State, target: u32, buffer: ?*objects.WebGLBuffer) void {
    if (target == ARRAY_BUFFER) self.array_buffer = buffer;
}

pub fn bufferData(self: *State, target: u32, bytes: []const u8) void {
    if (target != ARRAY_BUFFER) return;
    const buffer = self.array_buffer orelse return;
    buffer._data = self.arena.dupe(u8, bytes) catch return;
}

pub fn enableVertexAttribArray(self: *State, index: u32, enabled: bool) void {
    if (index >= max_attribs) return;
    self.attribs[index].enabled = enabled;
}

pub fn vertexAttribPointer(self: *State, index: u32, size: i32, kind: u32, stride: i32, offset: i32) void {
    if (index >= max_attribs) return;
    if (size < 1 or size > 4 or stride < 0 or offset < 0) return;
    self.attribs[index] = .{
        .enabled = self.attribs[index].enabled,
        .buffer = self.array_buffer,
        .size = @intCast(size),
        .kind = kind,
        .stride = @intCast(stride),
        .offset = @intCast(offset),
    };
}

// ---------------------------------------------------------------------------
// The drawing buffer

pub fn clearColor(self: *State, r: f32, g: f32, b: f32, a: f32) void {
    self.clear_color = .{ r, g, b, a };
}

pub fn setViewport(self: *State, x: i32, y: i32, w: i32, h: i32) void {
    if (w < 0 or h < 0) return;
    self.viewport = .{ x, y, w, h };
}

/// Clears the whole drawing buffer. The scissor test is never enabled here --
/// nothing sets it -- so there is no rectangle to honour.
pub fn clear(self: *State, mask: u32, width: u32, height: u32) void {
    if (mask & COLOR_BUFFER_BIT == 0) return;
    const pixels = self.surface.ensure(width, height) orelse return;
    const rgba: [4]u8 = .{
        glsl.quantise(self.clear_color[0]),
        glsl.quantise(self.clear_color[1]),
        glsl.quantise(self.clear_color[2]),
        glsl.quantise(self.clear_color[3]),
    };
    var i: usize = 0;
    while (i < pixels.len) : (i += 4) {
        pixels[i..][0..4].* = rgba;
    }
}

/// GL hands the caller rows from the bottom up; the surface stores them from
/// the top down. Out-of-range rows and columns are left untouched, which is
/// what a real readback of an area outside the buffer produces.
pub fn readPixels(
    self: *State,
    x: i32,
    y: i32,
    w: i32,
    h: i32,
    format: u32,
    kind: u32,
    dest: []u8,
) void {
    if (w <= 0 or h <= 0) return;
    // The only pair the pipeline can answer for. Any other combination would
    // need a conversion whose rounding we have not measured, and inventing one
    // would put made-up bytes where the caller expects the driver's.
    if (format != RGBA or kind != UNSIGNED_BYTE) return;

    const pixels = self.surface.peek(self.surface.width, self.surface.height) orelse return;
    const width: i32 = @intCast(self.surface.width);
    const height: i32 = @intCast(self.surface.height);

    for (0..@intCast(h)) |row| {
        const window_y = y + @as(i32, @intCast(row));
        if (window_y < 0 or window_y >= height) continue;
        const surface_row: usize = @intCast(height - 1 - window_y);
        for (0..@intCast(w)) |column| {
            const window_x = x + @as(i32, @intCast(column));
            if (window_x < 0 or window_x >= width) continue;
            const src = (surface_row * @as(usize, @intCast(width)) + @as(usize, @intCast(window_x))) * 4;
            const dst = (row * @as(usize, @intCast(w)) + column) * 4;
            if (dst + 4 > dest.len) return;
            dest[dst..][0..4].* = pixels[src..][0..4].*;
        }
    }
}

/// The caller's own view, as bytes we may write through -- `readPixels` fills
/// the array it was handed rather than returning a new one. Null for anything
/// that is not an integer typed array, which is the argument GL refuses.
pub fn destination(view: js.Object) ?[]u8 {
    const into = view.toZig(Destination) catch return null;
    return switch (into) {
        .int8 => |b| @as([]u8, @ptrCast(b))[0..b.len],
        .uint8 => |b| @as([]u8, @ptrCast(b))[0..b.len],
        .int16 => |b| @as([]u8, @ptrCast(b))[0 .. b.len * 2],
        .uint16 => |b| @as([]u8, @ptrCast(b))[0 .. b.len * 2],
        .int32 => |b| @as([]u8, @ptrCast(b))[0 .. b.len * 4],
        .uint32 => |b| @as([]u8, @ptrCast(b))[0 .. b.len * 4],
    };
}

const Destination = union(enum) {
    int8: []i8,
    uint8: []u8,
    int16: []i16,
    uint16: []u16,
    int32: []i32,
    uint32: []u32,
};

// ---------------------------------------------------------------------------
// The pipeline

/// Runs the vertex stage over `count` vertices, assembles them into triangles
/// and shades every pixel centre they cover. A draw that cannot be run at all
/// -- no linked program, an unsupported primitive, a shader that reaches a
/// builtin we do not have -- leaves the buffer exactly as it was.
pub fn drawArrays(self: *State, mode: u32, first: i32, count: i32, width: u32, height: u32) void {
    if (count <= 0 or first < 0 or count > max_vertices) return;
    if (mode != TRIANGLES and mode != TRIANGLE_STRIP and mode != TRIANGLE_FAN) return;

    const program = self.program orelse return;
    if (!program._linked) return;
    const vertex_stage = (program._vertex orelse return)._program orelse return;
    const fragment_stage = (program._fragment orelse return)._program orelse return;

    const vp = self.viewport orelse [4]i32{ 0, 0, @intCast(width), @intCast(height) };
    if (vp[2] <= 0 or vp[3] <= 0) return;

    const n: usize = @intCast(count);
    const positions = self.arena.alloc([4]f32, n) catch return;
    defer self.arena.free(positions);

    for (0..n) |i| {
        var run: glsl.Run = .{};
        for (vertex_stage.attributes, 0..) |attribute, location| {
            const value = self.readAttrib(location, @as(usize, @intCast(first)) + i) orelse return;
            run.set(attribute.name, value) catch return;
        }
        run.run(&vertex_stage) catch return;
        const clip = run.get("gl_Position") orelse return;
        positions[i] = clip.v;
    }

    const pixels = self.surface.ensure(width, height) orelse return;

    var budget: usize = max_fragments;
    var triangle: usize = 0;
    while (nextTriangle(mode, n, triangle)) |indices| : (triangle += 1) {
        shadeTriangle(
            &fragment_stage,
            .{ positions[indices[0]], positions[indices[1]], positions[indices[2]] },
            vp,
            width,
            height,
            pixels,
            &budget,
        ) catch return;
    }
}

/// The `i`th triangle of a primitive assembly, or null once there are no more.
fn nextTriangle(mode: u32, vertices: usize, i: usize) ?[3]usize {
    switch (mode) {
        TRIANGLES => {
            const base = i * 3;
            if (base + 3 > vertices) return null;
            return .{ base, base + 1, base + 2 };
        },
        TRIANGLE_STRIP => {
            if (i + 3 > vertices) return null;
            // Every other triangle has its first two vertices swapped, so the
            // strip keeps one winding.
            return if (i % 2 == 0) .{ i, i + 1, i + 2 } else .{ i + 1, i, i + 2 };
        },
        TRIANGLE_FAN => {
            if (i + 3 > vertices) return null;
            return .{ 0, i + 1, i + 2 };
        },
        else => return null,
    }
}

/// One vertex's value for the attribute at `location`, read out of whichever
/// buffer was bound when its array was described. A disabled array or a short
/// buffer is a draw we decline rather than one we fill with zeroes.
fn readAttrib(self: *const State, location: usize, vertex: usize) ?glsl.Value {
    if (location >= max_attribs) return null;
    const attrib = self.attribs[location];
    if (!attrib.enabled or attrib.kind != FLOAT) return null;
    const buffer = attrib.buffer orelse return null;

    const stride: usize = if (attrib.stride != 0) attrib.stride else @as(usize, attrib.size) * 4;
    const start = attrib.offset + vertex * stride;
    const bytes = @as(usize, attrib.size) * 4;
    if (start + bytes > buffer._data.len) return null;

    var out: glsl.Value = .{ .n = attrib.size };
    for (0..attrib.size) |i| {
        out.v[i] = @bitCast(std.mem.readInt(u32, buffer._data[start + i * 4 ..][0..4], .little));
    }
    // A vec2 attribute read into a vec4 slot still defaults w to 1, the way a
    // generic attribute does.
    if (attrib.size < 4) out.v[3] = 1;
    return out;
}

fn shadeTriangle(
    stage: *const glsl.Shader,
    clip: [3][4]f32,
    vp: [4]i32,
    width: u32,
    height: u32,
    pixels: []u8,
    budget: *usize,
) glsl.Error!void {
    var window: [3][2]f32 = undefined;
    for (clip, 0..) |c, i| {
        // The perspective divide. A w of zero is a degenerate vertex, and the
        // triangle it belongs to puts nothing on screen -- which is exactly
        // what Chrome does with `gl_Position = vec4(0.0)`.
        if (c[3] == 0) return;
        const ndc_x = c[0] / c[3];
        const ndc_y = c[1] / c[3];
        window[i][0] = (ndc_x + 1) * @as(f32, @floatFromInt(vp[2])) / 2 + @as(f32, @floatFromInt(vp[0]));
        window[i][1] = (ndc_y + 1) * @as(f32, @floatFromInt(vp[3])) / 2 + @as(f32, @floatFromInt(vp[1]));
    }

    var min_x = @min(window[0][0], @min(window[1][0], window[2][0]));
    var max_x = @max(window[0][0], @max(window[1][0], window[2][0]));
    var min_y = @min(window[0][1], @min(window[1][1], window[2][1]));
    var max_y = @max(window[0][1], @max(window[1][1], window[2][1]));

    // Clipped to the viewport as well as to the buffer: a viewport is a
    // window into the drawing buffer, not just an offset.
    min_x = @max(min_x, @as(f32, @floatFromInt(vp[0])));
    min_y = @max(min_y, @as(f32, @floatFromInt(vp[1])));
    max_x = @min(max_x, @as(f32, @floatFromInt(vp[0] + vp[2])));
    max_y = @min(max_y, @as(f32, @floatFromInt(vp[1] + vp[3])));

    const x0 = @max(0, @as(i32, @intFromFloat(@floor(min_x))));
    const x1 = @min(@as(i32, @intCast(width)), @as(i32, @intFromFloat(@ceil(max_x))));
    const y0 = @max(0, @as(i32, @intFromFloat(@floor(min_y))));
    const y1 = @min(@as(i32, @intCast(height)), @as(i32, @intFromFloat(@ceil(max_y))));
    if (x1 <= x0 or y1 <= y0) return;

    var window_y = y0;
    while (window_y < y1) : (window_y += 1) {
        const row: usize = @intCast(@as(i32, @intCast(height)) - 1 - window_y);
        var window_x = x0;
        while (window_x < x1) : (window_x += 1) {
            const px = @as(f32, @floatFromInt(window_x)) + 0.5;
            const py = @as(f32, @floatFromInt(window_y)) + 0.5;
            if (!covers(window, px, py)) continue;

            if (budget.* == 0) return;
            budget.* -= 1;

            var run: glsl.Run = .{};
            // Depth is 0.5 for a quad drawn at z = 0 and 1/w is 1; neither
            // shader here reads them, but a shader that did would read the
            // same numbers Chrome gives it.
            try run.set("gl_FragCoord", .vec4(px, py, 0.5, 1));
            try run.run(stage);
            const out = fragmentColor(&run, stage) orelse return;

            const index = (row * width + @as(u32, @intCast(window_x))) * 4;
            pixels[index + 0] = glsl.quantise(out.v[0]);
            pixels[index + 1] = glsl.quantise(out.v[1]);
            pixels[index + 2] = glsl.quantise(out.v[2]);
            pixels[index + 3] = glsl.quantise(out.v[3]);
        }
    }
}

/// Where the fragment stage left its colour. ES 1.0 writes the built-in
/// `gl_FragColor`; ES 3.0 removed it and the shader declares its own `out`, so
/// the declared name is the fallback. A stage that wrote neither drew nothing.
fn fragmentColor(run: *glsl.Run, stage: *const glsl.Shader) ?glsl.Value {
    if (run.get("gl_FragColor")) |value| return value;
    for (stage.outputs) |output| {
        if (run.get(output.name)) |value| return value;
    }
    return null;
}

/// Edge functions, accepting either winding: culling is disabled by default
/// and nothing here turns it on. A point exactly on a shared edge is covered
/// by both triangles, which for the quads this runs on writes the same colour
/// twice rather than leaving a seam.
fn covers(w: [3][2]f32, x: f32, y: f32) bool {
    const e0 = (w[1][0] - w[0][0]) * (y - w[0][1]) - (w[1][1] - w[0][1]) * (x - w[0][0]);
    const e1 = (w[2][0] - w[1][0]) * (y - w[1][1]) - (w[2][1] - w[1][1]) * (x - w[1][0]);
    const e2 = (w[0][0] - w[2][0]) * (y - w[2][1]) - (w[0][1] - w[2][1]) * (x - w[2][0]);
    return (e0 >= 0 and e1 >= 0 and e2 >= 0) or (e0 <= 0 and e1 <= 0 and e2 <= 0);
}

// ---------------------------------------------------------------------------

const testing = std.testing;

/// Drives a whole context the way the widget does, so the pipeline is covered
/// without a JS engine in the way.
fn widgetDraw(arena: Allocator, fragment_source: []const u8, w: u32, h: u32, out: []u8) !bool {
    var state: State = .init(arena);

    const vs = try arena.create(objects.WebGLShader);
    vs.* = .{ ._proto = undefined, ._kind = VERTEX_SHADER };
    state.shaderSource(vs, "attribute vec2 p;void main(){gl_Position=vec4(p,0,1);}");
    state.compileShader(vs);

    const fs = try arena.create(objects.WebGLShader);
    fs.* = .{ ._proto = undefined, ._kind = FRAGMENT_SHADER };
    state.shaderSource(fs, fragment_source);
    state.compileShader(fs);

    const buffer = try arena.create(objects.WebGLBuffer);
    buffer.* = .{ ._proto = undefined };
    state.bindBuffer(ARRAY_BUFFER, buffer);
    const quad = [_]f32{ -1, -1, 1, -1, 1, 1, -1, 1 };
    state.bufferData(ARRAY_BUFFER, std.mem.sliceAsBytes(quad[0..]));

    const program = try arena.create(objects.WebGLProgram);
    program.* = .{ ._proto = undefined };
    state.attachShader(program, vs);
    state.attachShader(program, fs);
    state.linkProgram(program);
    if (!program._linked) return false;
    try testing.expectEqual(@as(i32, 0), state.attribLocation(program, "p"));

    state.useProgram(program);
    state.enableVertexAttribArray(0, true);
    state.vertexAttribPointer(0, 2, FLOAT, 0, 0);
    state.setViewport(0, 0, @intCast(w), @intCast(h));
    state.drawArrays(TRIANGLE_FAN, 0, 4, 300, 150);
    state.readPixels(0, 0, @intCast(w), @intCast(h), RGBA, UNSIGNED_BYTE, out);
    return true;
}

test "webgl: the widget's constant readback, byte for byte" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var out: [16 * 16 * 4]u8 = @splat(0);
    try testing.expect(try widgetDraw(
        arena.allocator(),
        "precision mediump float;void main(){gl_FragColor=vec4(sin(1.0),cos(1.0),sin(1.0)*cos(1.0),1.0);}",
        16,
        16,
        &out,
    ));

    var i: usize = 0;
    while (i < out.len) : (i += 4) {
        try testing.expectEqualSlices(u8, &.{ 0xd7, 0x8a, 0x74, 0xff }, out[i..][0..4]);
    }
}

test "webgl: the widget's per-pixel readback, byte for byte" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var out: [4 * 4]u8 = @splat(0);
    try testing.expect(try widgetDraw(arena.allocator(),
        \\precision highp float;
        \\void main() {
        \\  float a = gl_FragCoord.x;
        \\  float b = 1.0;
        \\  for (int i = 0; i < 20; i++) { b = b * 1.1 + 0.001; }
        \\  float c = sin(cos(sin(cos(a * 0.1))));
        \\  float d = 1.0;
        \\  for (int i = 0; i < 10; i++) { d = inversesqrt(d + 0.01); }
        \\  float e = fract(a * 12345.6789);
        \\  gl_FragColor = vec4(
        \\    fract(b * 0.5 + 0.5),
        \\    fract(c * 0.5 + 0.5),
        \\    fract(d * 0.5 + 0.5),
        \\    fract(e)
        \\  );
        \\}
    , 4, 1, &out));

    try testing.expectEqualSlices(u8, &.{
        0xe4, 0xce, 0xff, 0xd6,
        0xe4, 0xcf, 0xff, 0x84,
        0xe4, 0xd0, 0xff, 0x32,
        0xe4, 0xd1, 0xff, 0xdf,
    }, &out);
}

test "webgl: a shader we cannot run leaves the buffer alone" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    // Two different failures, one outcome. This one does not parse, so the
    // program never links and there is nothing to draw with.
    var refused: [4 * 4]u8 = @splat(0xaa);
    try testing.expectEqual(false, try widgetDraw(arena.allocator(), "not a shader", 4, 1, &refused));
    try testing.expectEqual(@as(u8, 0xaa), refused[0]);

    // This one parses, but reaches a builtin we cannot evaluate. It is
    // refused at compile time too, rather than reported as compiled and then
    // drawing nothing -- a page told its shader is fine and handed an empty
    // readback has been misled twice.
    var unrunnable: [4 * 4]u8 = @splat(0xaa);
    try testing.expectEqual(false, try widgetDraw(
        arena.allocator(),
        "precision mediump float;void main(){gl_FragColor=vec4(texture2D(s,vec2(0.0)));}",
        4,
        1,
        &unrunnable,
    ));
    try testing.expectEqualSlices(u8, &@as([16]u8, @splat(0xaa)), &unrunnable);
}

test "webgl: clear fills the whole buffer and readPixels reads it bottom-up" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    var state: State = .init(arena.allocator());
    state.clearColor(0, 0, 0, 1);
    state.clear(COLOR_BUFFER_BIT, 4, 4);

    var out: [4]u8 = @splat(0);
    state.readPixels(0, 0, 1, 1, RGBA, UNSIGNED_BYTE, &out);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, &out);

    // A window that runs off the buffer leaves the bytes outside it alone
    // rather than reading somebody else's memory.
    var edge: [2 * 2 * 4]u8 = @splat(0x11);
    state.readPixels(3, 3, 2, 2, RGBA, UNSIGNED_BYTE, &edge);
    try testing.expectEqualSlices(u8, &.{ 0, 0, 0, 255 }, edge[0..4]);
    try testing.expectEqual(@as(u8, 0x11), edge[4]);
}
