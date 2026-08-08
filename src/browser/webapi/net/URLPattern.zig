// Copyright (C) 2023-2026  Lightpanda (Selecy SAS)
//
// Francis Bouvier <francis@lightpanda.io>
// Pierre Tachoire <pierre@lightpanda.io>
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

// https://developer.mozilla.org/en-US/docs/Web/API/URLPattern
//
// Eight independent patterns, one per URL component, each defaulting to the
// full wildcard `*`. Every component compiles down to a JavaScript regular
// expression -- which is what Chrome does too -- so matching is v8's job and
// this file only has to do the translation and the bookkeeping.
//
// Two details that only a measurement gives you (headed Chrome 150,
// probe-win29):
//
//   * The exec() result's members come out in alphabetical order (hash,
//     hostname, inputs, password, pathname, port, protocol, search, username),
//     not in the order the IDL declares them, and so do each component's own
//     two members (groups, input). That is Blink's dictionary code generator,
//     and it is observable through JSON.stringify.
//   * `hasRegExpGroups` is about explicit `(...)` groups only. `:id` does not
//     set it; `/(\d+)` does.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Page = @import("../../Page.zig");
const URL = @import("../../URL.zig");
const dictionary = @import("../dictionary.zig");

const Execution = js.Execution;
const Allocator = std.mem.Allocator;

const URLPattern = @This();

const Reader = dictionary.Reader("URLPattern", "URLPatternInit");

_rc: lp.RC = .{},
_arena: *lp.Arena,
_components: [component_count]Compiled,
_has_regexp_groups: bool = false,

/// The eight components, in the order the getters are declared in.
const Component = enum {
    protocol,
    username,
    password,
    hostname,
    port,
    pathname,
    search,
    hash,

    /// The characters a bare `:name` group will not cross. Chrome's default
    /// segment charset is per-component: a path segment stops at `/`, a host
    /// label stops at `.`, and everything else runs to the end.
    fn separator(self: Component) ?u8 {
        return switch (self) {
            .pathname => '/',
            .hostname => '.',
            else => null,
        };
    }
};

const component_count = @typeInfo(Component).@"enum".fields.len;

const Compiled = struct {
    /// What the getter reports: the pattern exactly as it was supplied.
    pattern: []const u8,
    /// The anchored JavaScript regular expression it translates to.
    source: []const u8,
    /// One entry per capture group, in order: the `:name` for a named group,
    /// or the group's index rendered as a string for an anonymous one.
    names: []const []const u8,
    /// Whether the pattern used an explicit `(...)` group.
    has_regexp: bool,
};

pub fn constructor(input_: ?js.Value, base_: ?[]const u8, execution: *const Execution) !*URLPattern {
    const arena = try execution.getArena(.small, "URLPattern");
    errdefer arena.release();
    const allocator = arena.allocator();

    var patterns: [component_count][]const u8 = @splat("*");
    if (input_) |input| {
        if (input.isString() != null) {
            const source = try input.toStringSliceWithAlloc(allocator);
            try fromConstructorString(&patterns, source, base_, allocator, execution);
        } else if (input.isObject()) {
            try fromInit(&patterns, input, base_, allocator, execution);
        }
    }

    const self = try allocator.create(URLPattern);
    self.* = .{ ._arena = arena, ._components = undefined };
    for (&self._components, patterns, 0..) |*compiled, pattern, i| {
        compiled.* = try compile(pattern, @enumFromInt(i), allocator);
        if (compiled.has_regexp) {
            self._has_regexp_groups = true;
        }
    }
    return self;
}

pub fn deinit(self: *URLPattern, _: *Page) void {
    self._arena.release();
}

pub fn acquireRef(self: *URLPattern) void {
    self._rc.acquire();
}

pub fn releaseRef(self: *URLPattern, page: *Page) void {
    self._rc.release(self, page);
}

// ---------------------------------------------------------------------------
// The two constructor forms

/// A URLPatternInit dictionary. Any member it leaves out keeps the wildcard,
/// which is why `new URLPattern({pathname: '/books/:id'})` still has
/// `protocol === '*'`.
fn fromInit(
    patterns: *[component_count][]const u8,
    input: js.Value,
    base_: ?[]const u8,
    allocator: Allocator,
    execution: *const Execution,
) !void {
    const init = try Reader.read(input, execution);

    if (try init.present("baseURL")) |value| {
        if (!value.isNullOrUndefined()) {
            const base = try value.toStringSliceWithAlloc(allocator);
            try applyBase(patterns, base, allocator);
        }
    } else if (base_) |base| {
        try applyBase(patterns, base, allocator);
    }

    inline for (@typeInfo(Component).@"enum".fields) |field| {
        if (try init.present(field.name)) |value| {
            if (!value.isNullOrUndefined()) {
                patterns[field.value] = try value.toStringSliceWithAlloc(allocator);
            }
        }
    }
}

/// A constructor string: a URL whose components are themselves patterns. A
/// string with no `://` is relative, and Chrome refuses it outright unless a
/// base URL came with it.
fn fromConstructorString(
    patterns: *[component_count][]const u8,
    source: []const u8,
    base_: ?[]const u8,
    allocator: Allocator,
    execution: *const Execution,
) !void {
    const scheme_end = std.mem.indexOf(u8, source, "://") orelse {
        const base = base_ orelse {
            const message = try std.fmt.allocPrint(
                execution.call_arena,
                "Failed to construct 'URLPattern': Relative constructor string '{s}' " ++
                    "must have a base URL passed as the second argument.",
                .{source},
            );
            return dictionary.throwTypeError(message, execution);
        };
        try applyBase(patterns, base, allocator);
        return splitPath(patterns, source, allocator);
    };

    patterns[@intFromEnum(Component.protocol)] = source[0..scheme_end];

    var rest = source[scheme_end + 3 ..];
    const authority_end = std.mem.indexOfAny(u8, rest, "/?#") orelse rest.len;
    var authority = rest[0..authority_end];
    rest = rest[authority_end..];

    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| {
        const user_info = authority[0..at];
        authority = authority[at + 1 ..];
        if (std.mem.indexOfScalar(u8, user_info, ':')) |colon| {
            patterns[@intFromEnum(Component.username)] = user_info[0..colon];
            patterns[@intFromEnum(Component.password)] = user_info[colon + 1 ..];
        } else {
            patterns[@intFromEnum(Component.username)] = user_info;
        }
    }

    if (portSeparator(authority)) |colon| {
        patterns[@intFromEnum(Component.hostname)] = authority[0..colon];
        patterns[@intFromEnum(Component.port)] = authority[colon + 1 ..];
    } else if (authority.len != 0) {
        patterns[@intFromEnum(Component.hostname)] = authority;
    }

    return splitPath(patterns, rest, allocator);
}

/// The `?search` and `#hash` tail of a constructor string, and whatever comes
/// before it as the pathname.
fn splitPath(patterns: *[component_count][]const u8, input: []const u8, _: Allocator) !void {
    var rest = input;

    if (std.mem.indexOfScalar(u8, rest, '#')) |hash| {
        patterns[@intFromEnum(Component.hash)] = rest[hash + 1 ..];
        rest = rest[0..hash];
    }
    if (std.mem.indexOfScalar(u8, rest, '?')) |search| {
        patterns[@intFromEnum(Component.search)] = rest[search + 1 ..];
        rest = rest[0..search];
    }
    if (rest.len != 0) {
        patterns[@intFromEnum(Component.pathname)] = rest;
    }
}

/// Everything a base URL contributes: its literal components become the
/// patterns for the ones the pattern itself does not name.
fn applyBase(patterns: *[component_count][]const u8, base: []const u8, allocator: Allocator) !void {
    const raw = try allocator.dupeZ(u8, base);

    const protocol = URL.getProtocol(raw);
    if (protocol.len > 1) {
        patterns[@intFromEnum(Component.protocol)] = protocol[0 .. protocol.len - 1];
    }
    patterns[@intFromEnum(Component.username)] = URL.getUsername(raw);
    patterns[@intFromEnum(Component.password)] = URL.getPassword(raw);
    patterns[@intFromEnum(Component.hostname)] = URL.getHostname(raw);
    patterns[@intFromEnum(Component.port)] = URL.getPort(raw);
    patterns[@intFromEnum(Component.pathname)] = URL.getPathname(raw);
    patterns[@intFromEnum(Component.search)] = stripPrefix(URL.getSearch(raw), '?');
    patterns[@intFromEnum(Component.hash)] = stripPrefix(URL.getHash(raw), '#');
}

fn stripPrefix(value: []const u8, prefix: u8) []const u8 {
    if (value.len != 0 and value[0] == prefix) {
        return value[1..];
    }
    return value;
}

/// The colon separating host from port, ignoring the colons inside an IPv6
/// literal and any that a `:name` group owns.
fn portSeparator(authority: []const u8) ?usize {
    if (authority.len != 0 and authority[0] == '[') {
        const bracket = std.mem.indexOfScalar(u8, authority, ']') orelse return null;
        if (bracket + 1 < authority.len and authority[bracket + 1] == ':') {
            return bracket + 1;
        }
        return null;
    }
    const colon = std.mem.lastIndexOfScalar(u8, authority, ':') orelse return null;
    if (colon + 1 >= authority.len) {
        return null;
    }
    for (authority[colon + 1 ..]) |c| {
        if (!std.ascii.isDigit(c) and c != '*') {
            return null;
        }
    }
    return colon;
}

// ---------------------------------------------------------------------------
// Pattern -> regular expression

fn compile(pattern: []const u8, component: Component, allocator: Allocator) !Compiled {
    var source: std.ArrayList(u8) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var has_regexp = false;

    try source.append(allocator, '^');

    var i: usize = 0;
    while (i < pattern.len) {
        const c = pattern[i];
        switch (c) {
            '*' => {
                try appendGroup(&source, &names, allocator, null, "[\\s\\S]*");
                i += 1;
            },
            ':' => {
                const start = i + 1;
                var end = start;
                while (end < pattern.len and isNameChar(pattern[end])) : (end += 1) {}
                if (end == start) {
                    try appendLiteral(&source, allocator, c);
                    i += 1;
                    continue;
                }
                const name = pattern[start..end];
                i = end;
                if (i < pattern.len and pattern[i] == '(') {
                    const close = closingParen(pattern, i) orelse {
                        try appendGroup(&source, &names, allocator, name, defaultCharset(component));
                        continue;
                    };
                    has_regexp = true;
                    try appendGroup(&source, &names, allocator, name, pattern[i + 1 .. close]);
                    i = close + 1;
                    continue;
                }
                try appendGroup(&source, &names, allocator, name, defaultCharset(component));
            },
            '(' => {
                const close = closingParen(pattern, i) orelse {
                    try appendLiteral(&source, allocator, c);
                    i += 1;
                    continue;
                };
                has_regexp = true;
                try appendGroup(&source, &names, allocator, null, pattern[i + 1 .. close]);
                i = close + 1;
            },
            '?', '+' => {
                // A quantifier only means anything after a group; on its own it
                // is a literal character of the URL.
                if (names.items.len != 0 and source.items[source.items.len - 1] == ')') {
                    try source.append(allocator, c);
                } else {
                    try appendLiteral(&source, allocator, c);
                }
                i += 1;
            },
            else => {
                try appendLiteral(&source, allocator, c);
                i += 1;
            },
        }
    }

    try source.append(allocator, '$');
    return .{
        .pattern = pattern,
        .source = source.items,
        .names = names.items,
        .has_regexp = has_regexp,
    };
}

fn appendGroup(
    source: *std.ArrayList(u8),
    names: *std.ArrayList([]const u8),
    allocator: Allocator,
    name: ?[]const u8,
    charset: []const u8,
) !void {
    const group_name = name orelse try std.fmt.allocPrint(allocator, "{d}", .{names.items.len});
    try names.append(allocator, group_name);
    try source.append(allocator, '(');
    try source.appendSlice(allocator, charset);
    try source.append(allocator, ')');
}

fn appendLiteral(source: *std.ArrayList(u8), allocator: Allocator, c: u8) !void {
    if (std.mem.indexOfScalar(u8, "^$\\.*+?()[]{}|/", c) != null) {
        try source.append(allocator, '\\');
    }
    try source.append(allocator, c);
}

fn defaultCharset(component: Component) []const u8 {
    return switch (component.separator() orelse return "[\\s\\S]+?") {
        '/' => "[^/]+?",
        else => "[^.]+?",
    };
}

fn closingParen(pattern: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    while (i < pattern.len) : (i += 1) {
        switch (pattern[i]) {
            '\\' => i += 1,
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) {
                    return i;
                }
            },
            else => {},
        }
    }
    return null;
}

fn isNameChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '$';
}

// ---------------------------------------------------------------------------
// Matching

/// The eight pieces of the URL a match runs against.
const Parts = [component_count][]const u8;

fn split(input: []const u8, allocator: Allocator, base_: ?[]const u8) ?Parts {
    const resolved = if (base_) |base|
        URL.resolve(allocator, base_ptr(allocator, base) catch return null, input, .{}) catch return null
    else
        allocator.dupeZ(u8, input) catch return null;

    if (std.mem.indexOf(u8, resolved, ":") == null) {
        return null;
    }

    const protocol = URL.getProtocol(resolved);
    var parts: Parts = undefined;
    parts[@intFromEnum(Component.protocol)] = if (protocol.len > 1) protocol[0 .. protocol.len - 1] else "";
    parts[@intFromEnum(Component.username)] = URL.getUsername(resolved);
    parts[@intFromEnum(Component.password)] = URL.getPassword(resolved);
    parts[@intFromEnum(Component.hostname)] = URL.getHostname(resolved);
    parts[@intFromEnum(Component.port)] = URL.getPort(resolved);
    parts[@intFromEnum(Component.pathname)] = URL.getPathname(resolved);
    parts[@intFromEnum(Component.search)] = stripPrefix(URL.getSearch(resolved), '?');
    parts[@intFromEnum(Component.hash)] = stripPrefix(URL.getHash(resolved), '#');
    return parts;
}

fn base_ptr(allocator: Allocator, base: []const u8) ![:0]const u8 {
    return allocator.dupeZ(u8, base);
}

pub fn @"test"(self: *URLPattern, input_: ?js.Value, base_: ?[]const u8, execution: *const Execution) !bool {
    const parts = try self.resolveInput(input_, base_, execution) orelse return false;
    for (self._components, parts) |compiled, part| {
        const regexp = try js.RegExp.init(execution.js.local.?, compiled.source, js.RegExp.Flag.none);
        if ((try regexp.exec(part)) == null) {
            return false;
        }
    }
    return true;
}

pub fn execute(self: *URLPattern, input_: ?js.Value, base_: ?[]const u8, execution: *const Execution) !?js.Object {
    const local = execution.js.local.?;
    const parts = try self.resolveInput(input_, base_, execution) orelse return null;

    var results: [component_count]js.Object = undefined;
    for (self._components, parts, 0..) |compiled, part, i| {
        const regexp = try js.RegExp.init(local, compiled.source, js.RegExp.Flag.none);
        const matched = (try regexp.exec(part)) orelse return null;
        results[i] = try groupsFor(compiled, matched, part, local);
    }

    // Alphabetical, which is what Blink's generated bindings emit.
    const result = local.newObject();
    _ = try result.set("hash", results[@intFromEnum(Component.hash)], .{});
    _ = try result.set("hostname", results[@intFromEnum(Component.hostname)], .{});

    const inputs = local.newArray(1);
    _ = try inputs.set(0, try self.inputString(input_, execution), .{});
    _ = try result.set("inputs", inputs, .{});

    _ = try result.set("password", results[@intFromEnum(Component.password)], .{});
    _ = try result.set("pathname", results[@intFromEnum(Component.pathname)], .{});
    _ = try result.set("port", results[@intFromEnum(Component.port)], .{});
    _ = try result.set("protocol", results[@intFromEnum(Component.protocol)], .{});
    _ = try result.set("search", results[@intFromEnum(Component.search)], .{});
    _ = try result.set("username", results[@intFromEnum(Component.username)], .{});
    return result;
}

/// `{groups, input}` -- both members, alphabetical, for one component.
fn groupsFor(
    compiled: Compiled,
    matched: js.Object,
    part: []const u8,
    local: *const js.Local,
) !js.Object {
    const groups = local.newObject();
    const array = matched.toValue().toArray();
    for (compiled.names, 0..) |name, i| {
        const value = try array.get(@intCast(i + 1));
        if (value.isUndefined()) {
            _ = try groups.set(name, null, .{});
        } else {
            _ = try groups.set(name, value, .{});
        }
    }

    const object = local.newObject();
    _ = try object.set("groups", groups, .{});
    _ = try object.set("input", part, .{});
    return object;
}

fn resolveInput(
    self: *URLPattern,
    input_: ?js.Value,
    base_: ?[]const u8,
    execution: *const Execution,
) !?Parts {
    _ = self;
    const input = input_ orelse return null;
    if (input.isString() == null) {
        // A URLPatternInit as the match target is legal but nothing here builds
        // one, and Chrome's own behaviour for it was not measured.
        return null;
    }
    const source = try input.toStringSliceWithAlloc(execution.call_arena);
    return split(source, execution.call_arena, base_);
}

fn inputString(self: *URLPattern, input_: ?js.Value, execution: *const Execution) ![]const u8 {
    _ = self;
    const input = input_ orelse return "";
    return input.toStringSliceWithAlloc(execution.call_arena);
}

// ---------------------------------------------------------------------------
// The eight getters

fn patternOf(self: *const URLPattern, comptime component: Component) []const u8 {
    return self._components[@intFromEnum(component)].pattern;
}

pub fn getProtocol(self: *const URLPattern) []const u8 {
    return self.patternOf(.protocol);
}

pub fn getUsername(self: *const URLPattern) []const u8 {
    return self.patternOf(.username);
}

pub fn getPassword(self: *const URLPattern) []const u8 {
    return self.patternOf(.password);
}

pub fn getHostname(self: *const URLPattern) []const u8 {
    return self.patternOf(.hostname);
}

pub fn getPort(self: *const URLPattern) []const u8 {
    return self.patternOf(.port);
}

pub fn getPathname(self: *const URLPattern) []const u8 {
    return self.patternOf(.pathname);
}

pub fn getSearch(self: *const URLPattern) []const u8 {
    return self.patternOf(.search);
}

pub fn getHash(self: *const URLPattern) []const u8 {
    return self.patternOf(.hash);
}

pub fn getHasRegExpGroups(self: *const URLPattern) bool {
    return self._has_regexp_groups;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(URLPattern);

    pub const Meta = struct {
        pub const name = "URLPattern";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Measured: every argument is optional, so URLPattern.length is 0 and so
    // are exec's and test's.
    pub const constructor = bridge.constructor(URLPattern.constructor, .{ .arity = 0 });

    pub const protocol = bridge.accessor(URLPattern.getProtocol, null, .{});
    pub const username = bridge.accessor(URLPattern.getUsername, null, .{});
    pub const password = bridge.accessor(URLPattern.getPassword, null, .{});
    pub const hostname = bridge.accessor(URLPattern.getHostname, null, .{});
    pub const port = bridge.accessor(URLPattern.getPort, null, .{});
    pub const pathname = bridge.accessor(URLPattern.getPathname, null, .{});
    pub const search = bridge.accessor(URLPattern.getSearch, null, .{});
    pub const hash = bridge.accessor(URLPattern.getHash, null, .{});
    pub const hasRegExpGroups = bridge.accessor(URLPattern.getHasRegExpGroups, null, .{});
    pub const exec = bridge.function(URLPattern.execute, .{ .arity = 0, .js_name = "exec" });
    pub const @"test" = bridge.function(URLPattern.@"test", .{ .arity = 0 });
};

const testing = @import("../../../testing.zig");
test "WebApi: URLPattern" {
    try testing.htmlRunner("url_pattern.html", .{});
}
