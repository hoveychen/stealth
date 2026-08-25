// Transcribes results/webgl-extension-brands.json into the Zig source for the
// WebGL extension interface objects. There are 53 of them carrying 213 members
// between them, every value measured off a reference Chrome, and hand-copying
// that many GLenums is how a typo becomes a fingerprint. So the file is
// generated and committed, and this script is how it is regenerated when the
// reference browser moves.
//
//   node tools/fingerprint/gen-webgl-extensions.mjs
//
// Writes src/browser/webapi/canvas/webgl_extensions.zig.

import { readFileSync, writeFileSync } from 'node:fs';

const measured = JSON.parse(readFileSync('tools/fingerprint/results/webgl-extension-brands.json', 'utf8'));
const chrome = measured.chrome;

// One extension is only reachable on a SwiftShader driver, so its reading was
// taken from a second run with the GPU forced. It joins the WebGL 2 set here
// because the union has to have a field for it: the linux GPU table advertises
// the name, and a name advertised and then refused is the contradiction this
// whole file exists to remove. See the note in the results JSON.
const swiftshader = measured.chrome_swiftshader ?? {};
const gpuForced = new Set();
for (const key of Object.keys(swiftshader)) {
    const m = /^webgl2 (.+)$/.exec(key);
    if (!m) continue;
    if (chrome[key]) continue;
    chrome[key] = swiftshader[key];
    // Placed where the forced run had it rather than re-sorted: Chrome's order
    // is not a plain sort (EXT_sRGB comes after EXT_texture_*), so the only
    // safe insertion point is behind the nearest name both runs listed.
    const forcedList = swiftshader['webgl2.supported'];
    const before = forcedList.slice(0, forcedList.indexOf(m[1])).reverse()
        .find((n) => chrome['webgl2.supported'].includes(n));
    const at = before ? chrome['webgl2.supported'].indexOf(before) + 1 : 0;
    chrome['webgl2.supported'].splice(at, 0, m[1]);
    gpuForced.add(m[1]);
}

// One entry per extension name, in the order Chrome advertises it. An extension
// both contexts advertise carries identical members in each (asserted below),
// so a single Zig type serves both.
const byName = new Map();
for (const ctx of ['webgl', 'webgl2']) {
    for (const name of chrome[`${ctx}.supported`] ?? []) {
        const row = chrome[`${ctx} ${name}`];
        if (!row || typeof row !== 'object') continue;
        const brand = row.brand.slice('[object '.length, -1);
        const existing = byName.get(name);
        if (existing) {
            const a = JSON.stringify(existing.values);
            const b = JSON.stringify(row.values);
            if (a !== b || existing.brand !== brand) {
                throw new Error(`${name} differs between webgl and webgl2; the one-type-serves-both assumption is broken`);
            }
            existing.contexts.push(ctx);
            continue;
        }
        byName.set(name, { name, brand, values: row.values, contexts: [ctx] });
    }
}

// The ten methods that answer something in Chrome. The other 27 are commands
// that return undefined, so a no-op is already the right answer for them --
// which is why this table is a table and not a rewrite of the generator.
// Measured with probes/webgl-extension-method-returns.js; the bodies are
// hand-written, so they live here rather than in the file this writes.
//
// What is deliberately still a no-op: WEBGL_multi_draw's four methods, which in
// Chrome throw a TypeError when an argument cannot be converted to a sequence.
// That is argument validation rather than a return value, and it belongs with
// the rest of WebGL's argument conversion.
const IMPLEMENTED = {
    'OES_vertex_array_object.createVertexArrayOES': {
        args: '(_: *const OES_vertex_array_object, exec: *js.Execution) !*objects.WebGLVertexArrayObjectOES',
        body: ['    return objects.handle(objects.WebGLVertexArrayObjectOES, exec);'],
    },
    'OES_vertex_array_object.bindVertexArrayOES': {
        args: '(_: *const OES_vertex_array_object, _: ?*objects.WebGLVertexArrayObjectOES) void',
        body: [],
    },
    'OES_vertex_array_object.deleteVertexArrayOES': {
        args: '(_: *const OES_vertex_array_object, _: ?*objects.WebGLVertexArrayObjectOES) void',
        body: [],
    },
    'OES_vertex_array_object.isVertexArrayOES': {
        // A handle that was created and never bound is not a vertex array yet,
        // and nothing here ever binds one -- same answer as the core
        // isVertexArray on WebGL 2.
        args: '(_: *const OES_vertex_array_object, _: ?*objects.WebGLVertexArrayObjectOES) bool',
        body: ['    return false;'],
    },
    'EXT_disjoint_timer_query.createQueryEXT': {
        args: '(_: *const EXT_disjoint_timer_query, exec: *js.Execution) !*objects.WebGLTimerQueryEXT',
        body: ['    return objects.handle(objects.WebGLTimerQueryEXT, exec);'],
    },
    'EXT_disjoint_timer_query.deleteQueryEXT': {
        args: '(_: *const EXT_disjoint_timer_query, _: ?*objects.WebGLTimerQueryEXT) void',
        body: [],
    },
    'EXT_disjoint_timer_query.isQueryEXT': {
        args: '(_: *const EXT_disjoint_timer_query, _: ?*objects.WebGLTimerQueryEXT) bool',
        body: ['    return false;'],
    },
    'EXT_disjoint_timer_query.getQueryEXT': {
        args: '(_: *const EXT_disjoint_timer_query, _: u32, _: u32) ?*objects.WebGLTimerQueryEXT',
        body: ['    return null;'],
    },
    'EXT_disjoint_timer_query.getQueryObjectEXT': {
        // `any` in WebIDL, and null for a query that never ran.
        args: '(_: *const EXT_disjoint_timer_query, _: ?*objects.WebGLTimerQueryEXT, _: u32) ?u32',
        body: ['    return null;'],
    },
    'WEBGL_compressed_texture_astc.getSupportedProfiles': {
        args: '(_: *const WEBGL_compressed_texture_astc) []const []const u8',
        body: ['    return gpu.astc_profiles;'],
    },
    'WEBGL_debug_shaders.getTranslatedShaderSource': {
        // Chrome answers the ANGLE translation of a compiled shader -- several
        // kilobytes of Metal Shading Language on the driver this claims to be --
        // and the empty string for a shader that has not been compiled. There is
        // no shader translator here, so the uncompiled answer is the only one
        // that is right; it is still a string, where undefined was not.
        args: '(_: *const WEBGL_debug_shaders, _: ?*objects.WebGLShader) []const u8',
        body: ['    return "";'],
    },
};

const out = [];
const w = (s = '') => out.push(s);

w('// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)');
w('//');
w('// This program is free software: you can redistribute it and/or modify');
w('// it under the terms of the GNU Affero General Public License as');
w('// published by the Free Software Foundation, either version 3 of the');
w('// License, or (at your option) any later version.');
w('//');
w('// This program is distributed in the hope that it will be useful,');
w('// but WITHOUT ANY WARRANTY; without even the implied warranty of');
w('// MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the');
w('// GNU Affero General Public License for more details.');
w('//');
w('// You should have received a copy of the GNU Affero General Public License');
w('// along with this program.  If not, see <https://www.gnu.org/licenses/>.');
w();
w('// GENERATED by tools/fingerprint/gen-webgl-extensions.mjs from');
w('// tools/fingerprint/results/webgl-extension-brands.json -- edit the generator,');
w('// not this file.');
w('//');
w('// The interface object Chrome hands back for each WebGL extension. A script');
w('// that feature-detects with `if (gl.getExtension(name))` needs an object here:');
w('// answering undefined while getSupportedExtensions lists the name is a');
w('// contradiction no browser produces.');
w('//');
w('// Every brand and every member value is measured, not derived. The brands are');
w('// irregular enough to make that the only safe route -- EXT_sRGB brands as');
w('// EXTsRGB, EXT_shader_texture_lod as EXTShaderTextureLOD,');
w('// OES_fbo_render_mipmap as OESFboRenderMipmap -- and a GLenum transcribed from');
w('// a spec page rather than a driver is a value no real browser reports.');
w('//');
w('// 27 of the 37 methods are commands that return nothing in Chrome, so they are');
w('// no-ops here. The ten that answer a value are implemented, from the IMPLEMENTED');
w('// table in the generator -- see it for what each answers and why. Two gaps are');
w('// left on purpose and named there: getTranslatedShaderSource answers the empty');
w('// string rather than an ANGLE translation, and WEBGL_multi_draw does not refuse');
w('// an argument that cannot be converted to a sequence.');
w();
w('const std = @import("std");');
w();
w('const js = @import("../../js/js.zig");');
w('const objects = @import("webgl_objects.zig");');
w('const gpu = @import("gpu.zig").gpu;');
w();
// Not derived from the JSON -- fixed text, but it lives here because both
// context files need it and this is the module that owns extension interfaces.
w('/// The enum of an extension union\'s field names. Both rendering contexts');
w('/// carry a union of the extensions they advertise; the name a script passes to');
w('/// getExtension has to be turned into one of its tags, and neither context');
w('/// should own a second copy of that.');
w('pub fn Kind(comptime U: type) type {');
w('    const fields = @typeInfo(U).@"union".fields;');
w('    const Tag = std.math.IntFittingRange(0, if (fields.len == 0) 0 else fields.len - 1);');
w('    var names: [fields.len][:0]const u8 = undefined;');
w('    for (fields, 0..) |field, i| {');
w('        names[i] = field.name;');
w('    }');
w('    return @Enum(Tag, .exhaustive, &names, &std.simd.iota(Tag, fields.len));');
w('}');
w();
w('/// The tag of `U` a getExtension name asks for, or null for a name it has no');
w('/// field for. Just to make you really sad, this lookup has to be');
w('/// case-insensitive: `getExtension(\'webgl_lose_context\')` answers in Chrome.');
w('/// So this is `std.meta.stringToEnum` with the comparison swapped.');
w('pub fn find(comptime U: type, name: []const u8) ?Kind(U) {');
w('    const T = Kind(U);');
w('    const kvs = comptime build_kvs: {');
w('        const EnumKV = struct { []const u8, T };');
w('        var kvs_array: [@typeInfo(T).@"enum".fields.len]EnumKV = undefined;');
w('        for (@typeInfo(T).@"enum".fields, 0..) |enumField, i| {');
w('            kvs_array[i] = .{ enumField.name, @field(T, enumField.name) };');
w('        }');
w('        break :build_kvs kvs_array[0..];');
w('    };');
w('    const Map = std.StaticStringMapWithEql(T, std.static_string_map.eqlAsciiIgnoreCase);');
w('    const map = Map.initComptime(kvs);');
w('    return map.get(name);');
w('}');
w();

const zigTypes = [];
for (const ext of byName.values()) {
    const consts = [];
    const fns = [];
    for (const [member, value] of Object.entries(ext.values)) {
        if (typeof value === 'string' && value.startsWith('fn/')) {
            fns.push({ member, arity: Number(value.slice(3)) });
        } else {
            consts.push({ member, value });
        }
    }

    zigTypes.push(ext.name);
    w(`/// ${ext.brand}, advertised by ${ext.contexts.join(' and ')}.`);
    if (gpuForced.has(ext.name)) {
        w('/// Measured off a Chrome forced onto SwiftShader -- the Metal driver the');
        w('/// macOS table claims never advertises this one, so no reading of it can');
        w('/// come from the same run as the rest.');
    }
    w(`pub const ${ext.name} = struct {`);
    w('    _: u8 = 0,');
    if (consts.length) {
        w();
        // Host-level too, not just on the JsApi: getParameter switches on these
        // (that is how the two WEBGL_debug_renderer_info pnames are answered),
        // and a switch case needs a comptime value it can name.
        for (const c of consts) {
            w(`    pub const ${c.member}: u32 = ${c.value};`);
        }
    }
    if (fns.length) {
        w();
        for (const f of fns) {
            const impl = IMPLEMENTED[`${ext.name}.${f.member}`];
            if (impl) {
                if (impl.body.length === 0) {
                    w(`    pub fn ${f.member}${impl.args} {}`);
                } else {
                    w(`    pub fn ${f.member}${impl.args} {`);
                    for (const line of impl.body) w(`    ${line}`);
                    w('    }');
                }
            } else {
                w(`    pub fn ${f.member}(_: *const ${ext.name}) void {}`);
            }
        }
    }
    w();
    w('    pub const JsApi = struct {');
    w(`        pub const bridge = js.Bridge(${ext.name});`);
    w();
    w('        pub const Meta = struct {');
    w(`            pub const name = "${ext.name}";`);
    w();
    w('            // No global for an extension, and no `constructor` on its');
    w('            // prototype; the brand is the only thing that identifies it.');
    w('            pub const no_interface_object = true;');
    w(`            pub const to_string_tag = "${ext.brand}";`);
    w();
    w('            pub const prototype_chain = bridge.prototypeChain();');
    w('            pub var class_id: bridge.ClassId = undefined;');
    w('        };');
    if (consts.length) {
        w();
        for (const c of consts) {
            w(`        pub const ${c.member} = bridge.property(${ext.name}.${c.member}, .{ .template = false, .readonly = true });`);
        }
    }
    if (fns.length) {
        w();
        for (const f of fns) {
            // The arity is measured too, and it is not always derivable: all
            // four OES_vertex_array_object methods report length 0 in Chrome,
            // nullable argument and all, while isQueryEXT next door reports 1.
            const noop = IMPLEMENTED[`${ext.name}.${f.member}`] ? '' : ' .noop = true,';
            w(`        pub const ${f.member} = bridge.function(${ext.name}.${f.member}, .{${noop} .arity = ${f.arity} });`);
        }
    }
    w('    };');
    w('};');
    w();
}

w('/// Every interface above, for registerTypes.');
w('pub const all = [_]type{');
for (const name of zigTypes) w(`    ${name},`);
w('};');
w();

writeFileSync('src/browser/webapi/canvas/webgl_extensions.zig', out.join('\n'));
console.error(`wrote ${zigTypes.length} interface types, ${out.length} lines`);
