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

const std = @import("std");
const zenai = @import("zenai");
const lp = @import("lightpanda");

const cli = @import("cli.zig");
const string = @import("string.zig");
const dump = @import("browser/dump.zig");
const claimed_platform = @import("claimed_platform.zig");
const Mime = @import("browser/Mime.zig");

const WebBotAuthConfig = @import("network/WebBotAuth.zig").Config;
const HttpHeader = @import("network/http.zig").Header;

const log = lp.log;
const crypto = @import("sys/libcrypto.zig");
const Allocator = std.mem.Allocator;

// TCP keepalive parameters applied to accepted CDP connections.
// Detection window ≈ IDLE + CNT * INTVL = 4 + 3*2 = 10s.
pub const CDP_KEEPALIVE_IDLE_S: c_int = 4;
pub const CDP_KEEPALIVE_INTVL_S: c_int = 2;
pub const CDP_KEEPALIVE_CNT: c_int = 3;
pub const CDP_TCP_USER_TIMEOUT_MS: c_int = 10_000;

const Config = @This();

fn logFilterValidator(allocator: Allocator, args: *std.process.Args.Iterator, list: *std.ArrayList(log.FilterRule)) !void {
    const str = args.next() orelse return error.InvalidOption;

    defer log.opts.scope_enabled = log.resolveFilters(list.items);

    var it = std.mem.splitScalar(u8, str, ',');
    while (it.next()) |part| {
        if (part.len == 0) continue;

        // `+X` filters in, `-X` filters out, bare `X` is an alias for `-X`
        // (backward compatible). `all` targets every scope.
        var name = part;
        var enable = false;
        switch (part[0]) {
            '+' => {
                enable = true;
                name = part[1..];
            },
            '-' => name = part[1..],
            else => {},
        }

        if (std.mem.eql(u8, name, "all")) {
            try list.append(allocator, .{ .scope = null, .enable = enable });
            continue;
        }

        const v = std.meta.stringToEnum(log.Scope, name) orelse {
            log.fatal(.app, "invalid option choice", .{ .arg = "--log-filter", .value = part });
            return error.InvalidOption;
        };

        try list.append(allocator, .{ .scope = v, .enable = enable });
    }
}

fn logLevelValidator(_: Allocator, args: *std.process.Args.Iterator, target: *?log.Level) !void {
    const str = args.next() orelse return error.MissingArgument;
    if (std.mem.eql(u8, str, "error")) {
        target.* = .err;
        log.opts.level = .err;
        return;
    }

    target.* = std.meta.stringToEnum(log.Level, str) orelse {
        log.fatal(.app, "invalid option choice", .{ .arg = "--log-level", .value = str });
        return error.InvalidArgument;
    };
    log.opts.level = target.*.?;
}

// The MCP host captures stderr into a log file, where pretty's ANSI
// escapes and multi-line entries are noise. Runs before any option is
// read so parse-time lines match; --log-format still overrides.
fn mcpLogDefaults() void {
    log.opts.format = .logfmt;
}

fn logFormatValidator(_: Allocator, args: *std.process.Args.Iterator, target: *?log.Format) !void {
    const str = args.next() orelse return error.MissingArgument;
    const format = std.meta.stringToEnum(log.Format, str) orelse {
        log.fatal(.app, "invalid option choice", .{ .arg = "--log-format", .value = str });
        return error.InvalidArgument;
    };
    target.* = format;
    log.opts.format = format;
}

fn httpHeaderValidator(allocator: Allocator, args: *std.process.Args.Iterator, list: *std.ArrayList(HttpHeader)) !void {
    const str = args.next() orelse return error.MissingArgument;
    const header = HttpHeader.parse(str) orelse {
        log.fatal(.app, "invalid option value", .{ .arg = "--http-header", .value = str, .hint = "expected \"Name: Value\"" });
        return error.InvalidArgument;
    };

    // The same shape script-set headers go through in `Headers`: a name that
    // is an HTTP token, a value that is a CR/LF-free byte string.
    if (Mime.isHttpToken(header.name) == false) {
        log.fatal(.app, "invalid option value", .{ .arg = "--http-header", .value = str, .hint = "name must be a non-empty HTTP token" });
        return error.InvalidArgument;
    }

    if (Mime.isHttpHeaderValue(header.value) == false) {
        log.fatal(.app, "invalid option value", .{ .arg = "--http-header", .value = str, .hint = "value must be Latin-1 text without CR, LF or NUL" });
        return error.InvalidArgument;
    }

    // Upstream refused User-Agent and Sec-Ch-Ua here outright. This fork
    // parameterises both (--user-agent, --sec-ch-ua), and a caller who wants a
    // different identity than the flags express has nowhere else to put it, so
    // there is nothing to reserve: the header goes through like any other and
    // the later-applied source wins.
    try list.append(allocator, .{
        .name = try allocator.dupe(u8, header.name),
        .value = try allocator.dupe(u8, header.value),
    });
}

const Cert = struct {
    /// On successful CLI argument parsing phase, ownership of this transferred
    /// to `Network`. Consider it as invalid.
    store: ?*crypto.X509_STORE = null,
    // Number of certificate sources loaded into `store`.
    count: usize = 0,

    fn deinit(self: *Cert) void {
        if (self.store) |store| {
            crypto.X509_STORE_free(store);
        }
        self.* = .{};
    }

    /// Returns the store, creating it on first use. The store is shared by
    /// every `--ca-cert`/`--ca-path` occurrence.
    fn getOrCreate(self: *Cert) !*crypto.X509_STORE {
        if (self.store) |store| {
            return store;
        }
        const store = crypto.X509_STORE_new() orelse
            return error.FailedToCreateCertStore;
        self.store = store;
        return store;
    }
};

fn caCertValidator(
    _: Allocator,
    args: *std.process.Args.Iterator,
    cert: *Cert,
) !void {
    const file_name = args.next() orelse return error.MissingArgument;
    const store = try cert.getOrCreate();
    errdefer cert.deinit();

    if (crypto.X509_STORE_load_locations(store, file_name, null) != 1) {
        log.fatal(.app, "Invalid CA cert", .{ .arg = "--ca-cert", .value = file_name });
        return error.InvalidArgument;
    }
    cert.count += 1;
}

fn caPathValidator(
    allocator: Allocator,
    args: *std.process.Args.Iterator,
    cert: *Cert,
) !void {
    const dir_path = args.next() orelse return error.MissingArgument;

    var dir = std.Io.Dir.cwd().openDir(lp.io, dir_path, .{ .iterate = true }) catch {
        log.fatal(.app, "Invalid CA path", .{ .arg = "--ca-path", .value = dir_path });
        return error.InvalidArgument;
    };
    defer dir.close(lp.io);

    const store = try cert.getOrCreate();
    errdefer cert.deinit();

    // Eagerly load every certificate in the directory rather than
    // registering a lazy hashed lookup: the directory doesn't need to be
    // c_rehash'ed, bad entries surface at startup and `count` reflects
    // what was actually loaded.
    const count_before = cert.count;
    var it = dir.iterate();
    while (it.next(lp.io) catch {
        log.fatal(.app, "Invalid CA path", .{ .arg = "--ca-path", .value = dir_path });
        return error.InvalidArgument;
    }) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;

        const path = try std.fs.path.joinZ(allocator, &.{ dir_path, entry.name });
        defer allocator.free(path);

        if (crypto.X509_STORE_load_locations(store, path, null) != 1) {
            log.warn(.app, "Skipping invalid CA cert", .{ .arg = "--ca-path", .value = path });
            continue;
        }
        cert.count += 1;
    }

    // An empty directory (or one with no readable certificates) is
    // indistinguishable from a typo; treat it as an error.
    if (cert.count == count_before) {
        log.fatal(.app, "No certificates loaded", .{ .arg = "--ca-path", .value = dir_path });
        return error.InvalidArgument;
    }
}

pub const HttpVersion = enum {
    auto,
    @"1.1",
};

// Upstream defaults all four off and has `--load-resources X` turn them on.
// This fork defaults them ON and keeps the `--disable-*` opt-outs, because a
// client that fetches no stylesheets, runs no workers and loads no iframes is
// separable server-side on that alone, whatever its headers look like -- and
// skipping CSS also costs accurate visibility checks. `--load-resources` still
// works; it just has nothing left to turn on unless something turned it off.
pub const LoadResources = packed struct(u4) {
    image: bool = true,
    iframe: bool = true,
    worker: bool = true,
    stylesheet: bool = true,
};

pub const ExperimentalFeatures = packed struct(u1) {
    cors: bool = false,
};

/// Common CLI args.
const CommonOptions = .{
    .{ .name = "obey_robots", .type = bool },
    .{ .name = "proxy_bearer_token", .type = ?[:0]const u8 },
    .{ .name = "http_proxy", .type = ?[:0]const u8 },
    .{ .name = "http_max_concurrent", .type = ?u8 },
    .{ .name = "http_max_host_open", .type = ?u8 },
    .{ .name = "http_nav_delay", .type = ?u32 },
    .{ .name = "http_nav_burst", .type = ?u32 },
    .{ .name = "http_timeout", .type = ?u31 },
    .{ .name = "http_version", .type = HttpVersion, .default = .auto },
    .{ .name = "http_connect_timeout", .type = ?u31 },
    .{ .name = "http_header", .type = HttpHeader, .multiple = true, .validator = httpHeaderValidator },
    .{ .name = "http_max_response_size", .type = ?usize },
    .{ .name = "ws_max_concurrent", .type = ?u8 },
    .{ .name = "insecure_disable_tls_host_verification", .type = bool },
    .{ .name = "log_level", .type = ?log.Level, .validator = logLevelValidator },
    .{ .name = "log_format", .type = ?log.Format, .validator = logFormatValidator },
    .{ .name = "log_filter", .type = log.FilterRule, .multiple = true, .validator = logFilterValidator },
    .{ .name = "log_filter_scopes", .type = log.FilterRule, .multiple = true, .validator = logFilterValidator, .deprecated = "use --log-filter" },
    .{ .name = "user_agent_suffix", .type = ?[]const u8 },
    .{ .name = "http_cache_dir", .type = ?[]const u8 },
    .{ .name = "http_cache_entry_limit", .type = ?u32, .default = 1000 },
    .{ .name = "web_bot_auth_key_file", .type = ?[]const u8 },
    .{ .name = "web_bot_auth_keyid", .type = ?[]const u8 },
    .{ .name = "web_bot_auth_domain", .type = ?[]const u8 },
    .{ .name = "user_agent", .type = ?[]const u8, .validator = userAgentValidator },
    .{ .name = "sec_ch_ua", .type = ?[]const u8 },
    .{ .name = "sec_ch_ua_platform", .type = ?[]const u8 },
    .{ .name = "accept_language", .type = ?[]const u8 },
    .{ .name = "locale", .type = [:0]const u8, .default = HttpHeaders.default_locale, .validator = localeValidator },
    .{ .name = "timezone", .type = ?[:0]const u8, .validator = timezoneValidator },
    .{ .name = "block_private_networks", .type = bool },
    .{ .name = "block_cidrs", .type = ?[]const u8, .validator = accumulateValidator },
    .{ .name = "block_urls", .type = ?[]const u8, .validator = accumulateValidator },
    .{ .name = "adblock_lists", .type = ?[]const u8, .validator = accumulateValidator },
    .{ .name = "cookie", .type = ?[]const u8 },
    .{ .name = "cookie_jar", .type = ?[]const u8 },
    .{ .name = "disable_subframes", .type = bool },
    .{ .name = "disable_workers", .type = bool },
    .{ .name = "webmcp", .type = bool },
    .{ .name = "disable_external_stylesheets", .type = bool },
    .{ .name = "experimental_features", .type = ExperimentalFeatures, .default = ExperimentalFeatures{} },
    .{ .name = "load_resources", .type = LoadResources, .default = LoadResources{} },
    .{ .name = "v8_flags_unsafe", .type = ?[]const u8 },
    .{ .name = "v8_max_heap_mb", .type = ?u32 },
    .{ .name = "watchdog_ms", .type = ?u32 },
    .{
        .name = "ca_cert",
        .field_name = "cert",
        .type = .{
            .cli = [:0]const u8,
            .memory = Cert,
        },
        .default = Cert{},
        .validator = caCertValidator,
    },
    .{
        .name = "ca_path",
        .field_name = "cert",
        .type = .{
            .cli = []const u8,
            .memory = Cert,
        },
        .default = Cert{},
        .validator = caPathValidator,
    },
};

fn dumpValidator(_: Allocator, args: *std.process.Args.Iterator, target: *?DumpFormat) !void {
    // Peek next argument.
    var peek_args = args.*;
    if (peek_args.next()) |next_arg| {
        const mode = std.meta.stringToEnum(DumpFormat, next_arg) orelse {
            // Anything else is the positional url, unless it is a misspelt format.
            if (string.closest(next_arg, tagNames(DumpFormat), 2)) |near| {
                log.fatal(.app, "invalid option choice", .{ .arg = "--dump", .value = log.red(next_arg), .did_you_mean = log.green(near) });
                return error.InvalidArgument;
            }
            target.* = .html;
            return;
        };

        // Skip the argument we peek if successful.
        _ = args.next();
        target.* = mode;
        return;
    }

    // Means we couldn't get something like `--dump html` but we do have
    // `--dump`; which should fall to `html` by default.
    target.* = .html;
}

pub const AiProvider = std.meta.Tag(zenai.provider.Client);

/// Per-turn reasoning budget for `agent` mode, mirroring Claude's effort
/// levels. Maps to each provider's native thinking/reasoning knob. Resolved
/// in `Agent.init` (explicit flag > remembered > mode default), so there is
/// no Config-level accessor like `agentVerbosity`.
pub const Effort = zenai.provider.Effort;

/// Controls how chatty `agent` mode is on stderr.
pub const AgentVerbosity = enum {
    /// REPL: spinner + per-turn summary. Non-REPL: final answer + errors only.
    low,
    /// + one `● [tool: …]` line per tool call.
    medium,
    /// + the matching `[result: …]` body for each call.
    high,

    pub fn atLeast(self: AgentVerbosity, min: AgentVerbosity) bool {
        return @intFromEnum(self) >= @intFromEnum(min);
    }
};

fn waitScriptFileValidator(allocator: Allocator, args: *std.process.Args.Iterator, target: *?[:0]const u8) !void {
    const path = args.next() orelse {
        log.fatal(.app, "missing argument value", .{ .arg = "--wait-script-file" });
        return error.InvalidArgument;
    };

    target.* = std.Io.Dir.cwd().readFileAllocOptions(lp.io, path, allocator, .limited(1024 * 1024), .of(u8), 0) catch |err| {
        log.fatal(.app, "failed to read file", .{ .arg = "--wait-script-file", .path = path, .err = err });
        return error.InvalidArgument;
    };
}

fn injectScriptFileValidator(
    allocator: Allocator,
    args: *std.process.Args.Iterator,
    list: *std.ArrayList([]const u8),
) !void {
    const path = args.next() orelse {
        log.fatal(.app, "missing argument value", .{ .arg = "--inject-script-file" });
        return error.InvalidArgument;
    };

    const bytes = std.Io.Dir.cwd().readFileAllocOptions(lp.io, path, allocator, .unlimited, .of(u8), null) catch |err| {
        log.fatal(.app, "failed to read file", .{ .arg = "--inject-script-file", .path = path, .err = err });
        return error.InvalidArgument;
    };

    return list.append(allocator, bytes);
}

/// Definition for all the commands and its arguments. See @cli.zig for further.
const Commands = cli.Builder(.{
    .{
        .name = "serve",
        .options = .{
            .{ .name = "host", .type = []const u8, .default = "127.0.0.1" },
            .{ .name = "port", .type = u16, .default = 9222 },
            .{ .name = "advertise_host", .type = ?[]const u8 },
            // Repeatable; one server can speak several on the same port.
            .{ .name = "protocol", .type = Protocol, .multiple = true },
            .{ .name = "cdp_max_connections", .type = u16, .default = 16 },
            .{ .name = "cdp_max_pending_connections", .type = u16, .default = 128 },
            .{ .name = "cdp_max_message_size", .type = u32, .default = 1024 * 1024 },
            // Don't widen this without growing the reader buffer in the HTTP path.
            .{ .name = "cdp_max_http_message_size", .type = u14, .default = 4096 },
            .{ .name = "disable_metrics", .type = bool },
        },
        .shared_options = CommonOptions,
    },
    .{
        .name = "fetch",
        // One or more URLs; can be given out of order, interleaved with options.
        .positional = .{ .name = "url", .type = [:0]const u8, .multiple = true },
        .options = .{
            .{ .name = "dump", .type = ?DumpFormat, .validator = dumpValidator },
            .{ .name = "with_base", .type = bool },
            .{ .name = "with_frames", .type = bool },
            .{ .name = "strip_mode", .type = dump.Opts.Strip, .default = dump.Opts.Strip{} },
            .{ .name = "dump_selector", .type = ?[:0]const u8 },
            .{ .name = "dump_max_bytes", .type = ?u32 },
            .{ .name = "fail_on_http_error", .type = bool },
            .{ .name = "wait_ms", .type = u32, .default = 5_000 },
            .{ .name = "wait_until", .type = ?WaitUntil },
            .{
                .name = "wait_script",
                .type = ?[:0]const u8,
                .variants = .{
                    .{ .name = "wait_script_file", .validator = waitScriptFileValidator },
                },
            },
            .{ .name = "wait_selector", .type = ?[:0]const u8 },
            .{
                .name = "inject_script",
                .type = []const u8,
                .multiple = true,
                .variants = .{
                    .{ .name = "inject_script_file", .validator = injectScriptFileValidator },
                },
            },
            .{ .name = "terminate_ms", .type = ?u32 },
            .{ .name = "json", .type = bool },
            .{ .name = "metrics", .type = bool },
        },
        .shared_options = CommonOptions,
    },
    .{
        .name = "mcp",
        .before_parse = mcpLogDefaults,
        .options = .{
            .{ .name = "port", .type = ?u16 },
            .{ .name = "host", .type = []const u8, .default = "127.0.0.1" },
            .{ .name = "cdp_port", .type = ?u16 },
        },
        .shared_options = CommonOptions,
    },
    .{
        .name = "agent",
        .positional = .{ .name = "script_file", .type = ?[:0]const u8 },
        .options = .{
            .{ .name = "provider", .type = ?AiProvider },
            .{ .name = "model", .type = ?[:0]const u8 },
            .{ .name = "base_url", .type = ?[:0]const u8 },
            .{ .name = "system_prompt", .type = ?[:0]const u8 },
            .{ .name = "task", .type = ?[]const u8 },
            .{ .name = "save", .type = ?[]const u8 },
            .{ .name = "attach", .short = 'a', .type = []const u8, .multiple = true },
            .{ .name = "verbosity", .type = ?AgentVerbosity },
            .{ .name = "effort", .type = ?Effort },
            .{ .name = "list_models", .type = bool },
            .{ .name = "no_llm", .type = bool },
        },
        .shared_options = CommonOptions,
    },
    .{
        // Normalized to `.agent` in `parseArgs`; intentionally no LLM options.
        .name = "run",
        .positional = .{ .name = "script_file", .type = ?[:0]const u8 },
        .options = .{},
        .shared_options = CommonOptions,
    },
    .{ .name = "version", .options = .{
        .{ .name = "check", .type = bool },
    } },
});

pub const RunMode = Commands.Enum;
pub const Mode = Commands.Union;
pub const Agent = @FieldType(Mode, "agent");

mode: Mode,
// The command as typed. Mirrors `mode`, except `run` normalizes to `.agent`
// for execution while this keeps `.run` for telemetry.
command: RunMode,
exec_name: []const u8,
http_headers: HttpHeaders,

fn modeNeedsHttp(mode: Mode) bool {
    return switch (mode) {
        .help => false,
        .version => |opts| opts.check,
        else => true,
    };
}

pub fn init(allocator: Allocator, exec_name: []const u8, mode: Mode) !Config {
    var config = Config{
        .mode = mode,
        .command = std.meta.activeTag(mode),
        .exec_name = exec_name,
        .http_headers = undefined,
    };
    if (modeNeedsHttp(mode)) {
        config.http_headers = try HttpHeaders.init(allocator, &config);
    }

    // The fork's opt-out flags map onto the same store `--load-resources` writes,
    // so there is one answer per resource rather than two that can disagree.
    switch (config.mode) {
        inline else => |*m| {
            if (@hasField(@TypeOf(m.*), "disable_external_stylesheets")) {
                if (m.disable_external_stylesheets) m.load_resources.stylesheet = false;
            }
            if (@hasField(@TypeOf(m.*), "disable_subframes")) {
                if (m.disable_subframes) m.load_resources.iframe = false;
            }
            if (@hasField(@TypeOf(m.*), "disable_workers")) {
                if (m.disable_workers) m.load_resources.worker = false;
            }
        },
    }

    return config;
}

pub fn deinit(self: *const Config, allocator: Allocator) void {
    if (modeNeedsHttp(self.mode)) {
        self.http_headers.deinit(allocator);
    }
}

pub fn interactive(self: *const Config) bool {
    return switch (self.mode) {
        .fetch => false,
        .serve, .mcp => true,
        .agent => |opts| opts.script_file == null,
        else => unreachable,
    };
}

pub fn tlsVerifyHost(self: *const Config) bool {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| !opts.insecure_disable_tls_host_verification,
        // `version --check` talks to the release endpoint; always verify.
        .version => true,
        else => unreachable,
    };
}

pub fn obeyRobots(self: *const Config) bool {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.obey_robots,
        else => unreachable,
    };
}

pub fn httpVersion(self: *const Config) HttpVersion {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.http_version,
        else => unreachable,
    };
}

pub fn experimentalFeatures(self: *const Config) ExperimentalFeatures {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.experimental_features,
        else => unreachable,
    };
}

// Whether a document gets this fork's WebMCP surface: `navigator.modelContext`
// plus the `ModelContext` / `ModelContextClient` interface objects.
//
// Chrome has none of those three names, so carrying them is a one-expression
// identification -- and not a theoretical one: Kasada was measured reading
// `navigator.modelContext` twice on x-hyatt (see the prop_read log in
// tools/fingerprint/results/prop-reads-hyatt.json). So the surface is opt-in.
//
// `mcp` is the run mode whose entire purpose is WebMCP, so it always carries
// it. The modes that only speak CDP have to ask with `--webmcp`, which is what
// keeps the CDP `WebMCP` domain usable from `serve` -- a page cannot register a
// tool through a surface it cannot see.
pub fn enableWebMcp(self: *const Config) bool {
    return switch (self.mode) {
        .mcp => true,
        inline .serve, .fetch, .agent => |opts| opts.webmcp,
        else => unreachable,
    };
}

pub fn watchdogMs(self: *const Config) ?u32 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| {
            const ms = opts.watchdog_ms orelse 30000;
            return if (ms == 0) null else ms;
        },
        else => unreachable,
    };
}

pub fn loadResources(self: *const Config) LoadResources {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.load_resources,
        else => unreachable,
    };
}

pub fn v8Flags(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.v8_flags_unsafe,
        else => unreachable,
    };
}

pub fn v8MaxHeapMb(self: *const Config) ?u32 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.v8_max_heap_mb,
        else => unreachable,
    };
}

pub fn httpProxy(self: *const Config) ?[:0]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.http_proxy,
        .version => null,
        else => unreachable,
    };
}

pub fn httpHeaders(self: *const Config) []const HttpHeader {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.http_header.items,
        else => &.{},
    };
}

pub fn proxyBearerToken(self: *const Config) ?[:0]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.proxy_bearer_token,
        else => null,
    };
}

pub fn httpMaxConcurrent(self: *const Config) u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.http_max_concurrent orelse 40,
        else => unreachable,
    };
}

pub fn httpMaxHostOpen(self: *const Config) u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.http_max_host_open orelse 6,
        else => unreachable,
    };
}

pub fn httpNavDelay(self: *const Config) ?u32 {
    const ms = switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.http_nav_delay,
        else => unreachable,
    } orelse return null;
    return if (ms == 0) null else ms;
}

pub fn httpNavBurst(self: *const Config) u32 {
    const burst = switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.http_nav_burst,
        else => unreachable,
    } orelse 1;
    return @max(burst, 1);
}

pub fn httpConnectTimeout(self: *const Config) u31 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.http_connect_timeout orelse 8000,
        .version => 0,
        else => unreachable,
    };
}

/// Ceiling on a whole transfer, and the last resort that keeps a stalled
/// request from holding a pooled connection forever. Real fingerprinting APIs
/// are slow — amiunique.org takes ~21s to answer its POST, which Chrome waits
/// out — so this has to be generous enough not to be mistaken for the page's
/// own timeout. See `--http-timeout` to tighten it for a crawl.
const DEFAULT_HTTP_TIMEOUT_MS = 30_000;

pub fn httpTimeout(self: *const Config) u31 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.http_timeout orelse DEFAULT_HTTP_TIMEOUT_MS,
        .version => DEFAULT_HTTP_TIMEOUT_MS,
        else => unreachable,
    };
}

pub fn httpMaxRedirects(_: *const Config) u8 {
    return 10;
}

pub fn httpMaxResponseSize(self: *const Config) ?usize {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.http_max_response_size,
        else => unreachable,
    };
}

pub fn wsMaxConcurrent(self: *const Config) u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.ws_max_concurrent orelse 8,
        else => unreachable,
    };
}

/// Resolve --verbosity. Explicit value wins. Else: --task with stderr
/// captured (pipe/file) defaults to .high so benchmark harnesses and
/// other programmatic consumers get the [tool/result] trace; REPL and
/// --task on a TTY default to .low.
pub fn agentVerbosity(opts: Agent) AgentVerbosity {
    if (opts.verbosity) |v| return v;
    const piped_one_shot = opts.task != null and !stderrIsTty();
    return if (piped_one_shot) .high else .low;
}

/// `isatty(STDERR)` is a syscall and `agentVerbosity` is on the log hot
/// path (every gate check resolves through it). Cache once — the fd
/// doesn't change after process start.
var stderr_tty_cached: bool = undefined;
var stderr_tty_once = lp.once(initStderrTty);
fn initStderrTty() void {
    stderr_tty_cached = std.Io.File.stderr().isTty(lp.io) catch false;
}
fn stderrIsTty() bool {
    stderr_tty_once.call();
    return stderr_tty_cached;
}

pub fn userAgentSuffix(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.user_agent_suffix,
        else => null,
    };
}

pub fn userAgent(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.user_agent,
        else => null,
    };
}

pub fn secChUa(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.sec_ch_ua,
        else => null,
    };
}

pub fn secChUaPlatform(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.sec_ch_ua_platform,
        else => null,
    };
}

pub fn acceptLanguage(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.accept_language,
        else => null,
    };
}

pub fn locale(self: *const Config) [:0]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.locale,
        else => HttpHeaders.default_locale,
    };
}

pub fn timezone(self: *const Config) ?[:0]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.timezone,
        else => null,
    };
}

pub fn httpCacheDir(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.http_cache_dir,
        else => null,
    };
}

pub fn httpCacheEntryLimit(self: *const Config) u32 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.http_cache_entry_limit.?,
        else => 1000,
    };
}

pub fn cookieFile(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.cookie,
        else => null,
    };
}

pub fn cookieJarFile(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .fetch, .mcp, .agent => |opts| opts.cookie_jar,
        else => null,
    };
}

pub fn port(self: *const Config) u16 {
    return switch (self.mode) {
        .serve => |opts| opts.port,
        .mcp => |opts| opts.cdp_port orelse 0,
        else => unreachable,
    };
}

pub fn advertiseHost(self: *const Config) []const u8 {
    return switch (self.mode) {
        .serve => |opts| opts.advertise_host orelse advertiseHostFallback(opts.host),
        .mcp => "127.0.0.1",
        else => unreachable,
    };
}

// Wildcard bind addresses (0.0.0.0, ::) are not routable for clients
// resolving /json/version. Fall back to a loopback address so the
// advertised webSocketDebuggerUrl is at least connectable from the same
// host (covers the official Docker image, which exposes 9222 via the
// container's published port, and the WSL localhost bridge).
// For remote hosts, users can still pin the URL with --advertise-host.
// See issue #1922.
fn advertiseHostFallback(host: []const u8) []const u8 {
    if (isHostWildcard(host)) {
        return "127.0.0.1";
    }
    return host;
}

// True when serve is binding a wildcard address (e.g. Docker --host
// 0.0.0.0) without an explicit --advertise-host. /json/version replaces
// the wildcard with 127.0.0.1 in advertiseHostFallback so the URL stays
// resolvable, but the caller still benefits from emitting a guidance log.
pub fn bindIsWildcard(self: *const Config) bool {
    return switch (self.mode) {
        .serve => |opts| opts.advertise_host == null and isHostWildcard(opts.host),
        else => false,
    };
}

fn isHostWildcard(host: []const u8) bool {
    return std.mem.eql(u8, host, "0.0.0.0") or std.mem.eql(u8, host, "::");
}

pub fn webBotAuth(self: *const Config) ?WebBotAuthConfig {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| WebBotAuthConfig{
            .key_file = opts.web_bot_auth_key_file orelse return null,
            .keyid = opts.web_bot_auth_keyid orelse return null,
            .domain = opts.web_bot_auth_domain orelse return null,
        },
        else => null,
    };
}

pub fn blockPrivateNetworks(self: *const Config) bool {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.block_private_networks,
        else => unreachable,
    };
}

pub fn blockCidrs(self: *const Config) ?[]const u8 {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.block_cidrs,
        else => unreachable,
    };
}

pub fn blockedUrlPatterns(self: *const Config) ?std.mem.SplitIterator(u8, .scalar) {
    const patterns = switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.block_urls,
        else => unreachable,
    } orelse return null;
    return std.mem.splitScalar(u8, patterns, ',');
}

pub fn adblockLists(self: *const Config) ?std.mem.SplitIterator(u8, .scalar) {
    const paths = switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| opts.adblock_lists,
        else => unreachable,
    } orelse return null;
    return std.mem.splitScalar(u8, paths, ',');
}

pub const Protocol = enum {
    cdp,
    webdriver,
};

pub fn protocols(self: *const Config) []const Protocol {
    return switch (self.mode) {
        .serve => |opts| if (opts.protocol.items.len == 0) &.{.cdp} else opts.protocol.items,
        .mcp => &.{.cdp},
        else => unreachable,
    };
}

pub fn maxConnections(self: *const Config) u16 {
    return switch (self.mode) {
        .serve => |opts| opts.cdp_max_connections,
        .mcp => 16,
        .fetch, .agent => 0,
        else => unreachable,
    };
}

pub fn maxPendingConnections(self: *const Config) u31 {
    return switch (self.mode) {
        .serve => |opts| opts.cdp_max_pending_connections,
        .mcp => 128,
        else => unreachable,
    };
}

pub fn cdpMaxMessageSize(self: *const Config) u32 {
    return switch (self.mode) {
        .serve => |opts| opts.cdp_max_message_size,
        // `mcp --cdp-port` runs a CDP server without carrying serve's flags for
        // it, so it takes serve's defaults. Same shape as
        // cdpMaxPendingConnections above.
        .mcp => 1024 * 1024,
        else => unreachable,
    };
}

pub fn metricsEndpointEnabled(self: *const Config) bool {
    return switch (self.mode) {
        .serve => |opts| !opts.disable_metrics,
        .mcp => true,
        else => unreachable,
    };
}

pub fn dumpMetricsOnExit(self: *const Config) bool {
    return switch (self.mode) {
        .fetch => |opts| opts.metrics,
        else => false,
    };
}

pub fn cdpMaxHTTPMessageSize(self: *const Config) u14 {
    return switch (self.mode) {
        .serve => |opts| opts.cdp_max_http_message_size,
        .mcp => 4096,
        else => unreachable,
    };
}

/// Returns the user-supplied certificate store (`--ca-cert`/`--ca-path`),
/// if any was loaded during argument parsing. The caller takes ownership.
pub fn customCertStore(self: *const Config) ?*crypto.X509_STORE {
    return switch (self.mode) {
        inline .serve, .fetch, .mcp, .agent => |opts| {
            const store = opts.cert.store orelse return null;
            // Validators guarantee a created store loaded something.
            lp.assert(opts.cert.count > 0, "empty custom cert store", .{});
            return store;
        },
        else => null,
    };
}

pub const DumpFormat = enum {
    html,
    markdown,
    png,
    pdf,
    wpt,
    semantic_tree,
    semantic_tree_text,
};

pub const WaitUntil = enum {
    load,
    domcontentloaded,
    networkalmostidle,
    networkidle,
    done,
};

/// HTTP header values shared across Http and Client.
/// Must be initialized with an allocator that outlives all HTTP connections.
pub const HttpHeaders = struct {
    /// The version we claim to be. One constant so the User-Agent's
    /// "Chrome/153.0.0.0" and the Sec-Ch-Ua brands' v="153" can't drift apart —
    /// a mismatch between the two is a stronger signal than either value alone.
    ///
    /// This number is not free to move on its own. Several tables in
    /// src/browser/webapi are recorded from a specific Chrome, and 151 changed
    /// two of them: it added the `ruby-overhang` longhand (474 computed
    /// properties became 475) and rewrote a large part of the offer SDP
    /// (`a=rtcp-xr:rcvr-rtt=all`, an `rrtr` feedback line per payload type, and
    /// renumbered video payload types). Claiming a version whose tables were
    /// recorded from a different one is a contradiction a detector reads for
    /// free — so bump this together with the tables, never alone. 152 added the
    /// `window-drag` longhand (475 -> 476) and moved the eight
    /// `corner-*-shape` initial values from `round` to `superellipse(1)`; it
    /// left the offer SDP and the media mime table untouched. 153 added the
    /// `scroll-axis-lock` longhand (476 -> 477) and dropped every per-payload
    /// `a=rtcp-fb:<pt> rrtr` line 151 had introduced, leaving the
    /// `a=rtcp-xr:rcvr-rtt=all` line that announces the same capability once;
    /// the media mime table came back byte-identical.
    ///
    /// Nor is standing still free. A stale major is not a neutral choice: the
    /// number is checked at the edge, before any JavaScript runs. Akamai
    /// refused ak-kohls outright — 403 on the first document, an eight-node
    /// "Access Denied" — for a client claiming 151 on the day Chrome 152 was
    /// what browsers sent, and the same binary passed 3/3 with nothing changed
    /// but this constant and the brands below.
    const chrome_major = "153";
    const chrome_reduced_version = chrome_major ++ ".0.0.0";
    /// The build the reference Chrome reported. This used to be the Linux
    /// build's .137, "because that is what claimed_platform says we are" — and
    /// then the claim moved to macOS (48efdc6b8) and this did not follow, so it
    /// named a build no Mac ever ran. The Mac reference is 153.0.8010.48, read
    /// off the reference Chrome's own `sec-ch-ua-full-version`
    /// (tools/fingerprint/accept-ch-echo.mjs). It does not track chrome_major:
    /// the build number is the browser's, not a function of the major.
    /// Only navigator.userAgentData.getHighEntropyValues carries it: the
    /// user-agent string zeroes everything after the major (that is what
    /// Chrome's user-agent reduction does), so a Chrome whose UA says 153.0.0.0
    /// and whose uaFullVersion says 153.0.8010.48 is not contradicting itself —
    /// it's the normal shape, and a full version ending .0.0.0 is the anomaly.
    const chrome_full_version = "153.0.8010.48";

    /// Default User-Agent. Since Chrome's user-agent reduction the string is
    /// frozen apart from the major version and a platform token from a closed
    /// set, so this is a complete Chrome UA rather than an approximation of one.
    ///
    /// The token comes from claimed_platform, which is a constant rather than
    /// the build host — a UA that moves with the machine while the recorded
    /// fingerprint tables beside it do not is a contradiction, not a courtesy.
    /// Everything around the token is Chrome's frozen string, byte-for-byte what
    /// the Chrome 150 install on the reference machine sent
    /// (tools/fingerprint/results/reference-chrome-headed.json).
    const user_agent_base: [:0]const u8 = "Mozilla/5.0 (" ++ claimed_platform.user_agent_token ++
        ") AppleWebKit/537.36 (KHTML, like Gecko) Chrome/" ++ chrome_reduced_version ++ " Safari/537.36";

    pub const Brand = struct {
        brand: []const u8,
        version: []const u8,
    };

    /// Brands used when --sec-ch-ua isn't given. Measured from the Chrome 153
    /// build this claims to be, GREASE entry included: Chrome deliberately
    /// ships one deliberately-odd brand so servers can't hardcode the list, and
    /// omitting it is itself distinctive.
    ///
    /// Both the GREASE token and the *order* move between builds — that is the
    /// point of GREASE — so neither can be carried across a version bump, and
    /// all three have now moved three times: 150 answered `Not;A=Brand` at v8
    /// with Chromium first, 151 answered `Not=A?Brand` at v99 with Chrome ahead
    /// of Chromium, 152 answered `Not?A_Brand` at v24 with Chromium first
    /// again, and 153 answers `Not_A Brand` at v8 with Chrome first — the
    /// separator, the version and the order all moved at once. The 153 row is
    /// the reference browser's own header, read off
    /// tools/fingerprint/accept-ch-echo.mjs rather than recalled. The real
    /// versions track chrome_major so the header and the User-Agent agree.
    pub const default_brands = [_]Brand{
        .{ .brand = "Google Chrome", .version = chrome_major },
        .{ .brand = "Not_A Brand", .version = "8" },
        .{ .brand = "Chromium", .version = chrome_major },
    };

    /// The same brands with the four-part versions the high-entropy hints
    /// carry, in the same order. Measured alongside default_brands off
    /// `sec-ch-ua-full-version-list`, GREASE included: its version pads to
    /// 8.0.0.0 rather than carrying a build number of its own.
    pub const default_full_version_brands = [_]Brand{
        .{ .brand = "Google Chrome", .version = chrome_full_version },
        .{ .brand = "Not_A Brand", .version = "8.0.0.0" },
        .{ .brand = "Chromium", .version = chrome_full_version },
    };

    /// Accept values real Chrome sends, keyed by fetch destination. Measured
    /// rather than recalled — see tools/fingerprint/results/reference-chrome-*.json
    /// for the capture these came from.
    pub const Accept = struct {
        pub const document: [:0]const u8 = "text/html,application/xhtml+xml,application/xml;q=0.9,image/avif,image/webp,image/apng,*/*;q=0.8,application/signed-exchange;v=b3;q=0.7";
        pub const style: [:0]const u8 = "text/css,*/*;q=0.1";
        pub const image: [:0]const u8 = "image/avif,image/webp,image/apng,image/svg+xml,image/*,*/*;q=0.8";
        pub const event_stream: [:0]const u8 = "text/event-stream";
        /// script, fetch and xhr all send this.
        pub const any: [:0]const u8 = "*/*";
    };

    /// Chrome sends this on every top-level and iframe navigation.
    pub const upgrade_insecure_requests: [:0]const u8 = "1";

    /// Mobile-ness of the client hint. Desktop Chrome sends "?0".
    pub const sec_ch_ua_mobile: [:0]const u8 = "?0";

    /// The high-entropy hints whose value the claim fixes rather than a flag,
    /// only ever sent to an origin that asked for them via Accept-CH. Quoted:
    /// every UA client hint but the boolean-ish sec-ch-ua-mobile is a
    /// structured-field string, and Chrome sends the quotes even around the
    /// empty ones.
    ///
    /// Same source as navigator.userAgentData.getHighEntropyValues reads
    /// (NavigatorUAData.uaArchitecture and friends), because a header and a JS
    /// call describing different machines is a contradiction one page can see.
    pub const sec_ch_ua_arch: [:0]const u8 = "\"" ++ claimed_platform.architecture ++ "\"";
    pub const sec_ch_ua_bitness: [:0]const u8 = "\"" ++ claimed_platform.bitness ++ "\"";
    pub const sec_ch_ua_platform_version: [:0]const u8 = "\"" ++ claimed_platform.platform_version ++ "\"";
    /// A desktop has no device model, and Chrome answers the empty string
    /// rather than dropping the hint -- measured, the nine-hint requests in
    /// tools/fingerprint/results/acceptch-chrome.json.
    pub const sec_ch_ua_model: [:0]const u8 = "\"\"";

    user_agent: [:0]const u8, // Full User-Agent value

    /// Source of truth for client-hints brand data. Both the Sec-Ch-Ua HTTP
    /// header and navigator.userAgentData.brands derive from this list, so the
    /// two sides cannot drift. Owned by `allocator` unless it aliases
    /// `default_brands`.
    brands: []const Brand,
    /// Same brands, four-part versions, for
    /// navigator.userAgentData.getHighEntropyValues. Padded from `brands` when
    /// --sec-ch-ua is given, since a bare major is all that flag carries.
    full_version_brands: []const Brand,
    sec_ch_ua: [:0]const u8,
    /// The same list with four-part versions, which is the whole difference
    /// between the two headers. Derived from full_version_brands, so
    /// --sec-ch-ua moves this too.
    sec_ch_ua_full_version_list: [:0]const u8,
    /// Chrome's own full version: the last brand's, which is the rule
    /// navigator.userAgentData's uaFullVersion already follows.
    sec_ch_ua_full_version: [:0]const u8,
    sec_ch_ua_platform: [:0]const u8,
    /// Bare value (e.g. "macOS"), for navigator.userAgentData.platform.
    platform: []const u8,

    // Some bot-protection frontends (e.g. Akamai on canada.ca) RST the HTTP/2
    // stream when a client sends Accept-Encoding without Accept-Language,
    // treating it as a bot signal. Ship a neutral default so we look like a
    // normal client.
    /// The header and the tags it lists. `languages` doubles as
    /// navigator.languages, so the header and the JS list cannot name
    /// different languages.
    accept_language: AcceptLanguage,

    proxy_bearer_header: ?[:0]const u8,

    /// An Accept-Language header and the tags it lists.
    pub const AcceptLanguage = struct {
        header: [:0]const u8,
        // Sub-slices of `header`.
        languages: []const []const u8,

        pub fn init(allocator: Allocator, value: []const u8) !AcceptLanguage {
            const header = try allocator.dupeZ(u8, value);
            errdefer allocator.free(header);

            var languages: std.ArrayList([]const u8) = .empty;
            errdefer languages.deinit(allocator);

            var it = std.mem.splitScalar(u8, header, ',');
            while (it.next()) |item| {
                const end = std.mem.indexOfScalar(u8, item, ';') orelse item.len;
                const tag = std.mem.trim(u8, item[0..end], " \t");
                if (tag.len > 0) {
                    try languages.append(allocator, tag);
                }
            }

            return .{
                .header = header,
                .languages = try languages.toOwnedSlice(allocator),
            };
        }

        pub fn deinit(self: *const AcceptLanguage, allocator: Allocator) void {
            allocator.free(self.languages);
            allocator.free(self.header);
        }
    };

    /// The claimed OS, in the spelling the Sec-Ch-Ua-Platform hint and
    /// navigator.userAgentData.platform use. Same source as the user-agent's
    /// token, so the header and the string cannot name different systems.
    const default_platform = claimed_platform.hint;
    const default_languages = "en-US,en;q=0.9";

    /// The locale `--locale` defaults to, from which `default_languages` is
    /// derived when no explicit `--accept-language` is given.
    pub const default_locale: [:0]const u8 = "en-US";

    pub fn init(allocator: Allocator, config: *const Config) !HttpHeaders {
        const user_agent: [:0]const u8 = if (config.userAgent()) |ua|
            try allocator.dupeZ(u8, ua)
        else if (config.userAgentSuffix()) |suffix|
            try std.fmt.allocPrintSentinel(allocator, "{s} {s}", .{ user_agent_base, suffix }, 0)
        else
            user_agent_base;
        errdefer if (user_agent.ptr != user_agent_base.ptr) allocator.free(user_agent);

        // --sec-ch-ua takes the header's own wire syntax, so one flag drives
        // both the header and navigator.userAgentData without a bespoke format
        // to learn, and whatever is passed round-trips verbatim.
        const brands: []const Brand = if (config.secChUa()) |raw|
            try parseBrands(allocator, raw)
        else
            &default_brands;
        errdefer if (brands.ptr != &default_brands) allocator.free(brands);

        const full_version_brands: []const Brand = if (config.secChUa() == null)
            &default_full_version_brands
        else
            try padBrandVersions(allocator, brands);
        errdefer if (full_version_brands.ptr != &default_full_version_brands) freeBrands(allocator, full_version_brands);

        const sec_ch_ua = try formatSecChUa(allocator, brands);
        errdefer allocator.free(sec_ch_ua);

        const sec_ch_ua_full_version_list = try formatSecChUa(allocator, full_version_brands);
        errdefer allocator.free(sec_ch_ua_full_version_list);

        const sec_ch_ua_full_version = try std.fmt.allocPrintSentinel(allocator, "\"{s}\"", .{
            if (full_version_brands.len == 0) "" else full_version_brands[full_version_brands.len - 1].version,
        }, 0);
        errdefer allocator.free(sec_ch_ua_full_version);

        const platform = config.secChUaPlatform() orelse default_platform;
        const sec_ch_ua_platform = try std.fmt.allocPrintSentinel(allocator, "\"{s}\"", .{platform}, 0);
        errdefer allocator.free(sec_ch_ua_platform);

        const proxy_bearer_header: ?[:0]const u8 = if (config.proxyBearerToken()) |token|
            try std.fmt.allocPrintSentinel(allocator, "Proxy-Authorization: Bearer {s}", .{token}, 0)
        else
            null;
        errdefer if (proxy_bearer_header) |hdr| allocator.free(hdr);

        // `--accept-language` names the header outright; `--locale` names one
        // tag and the q-ladder is derived from it, the way Chrome builds it.
        var buf: [64]u8 = undefined;
        const accept_language: AcceptLanguage = try .init(
            allocator,
            config.acceptLanguage() orelse acceptLanguageFor(&buf, config.locale()),
        );
        errdefer accept_language.deinit(allocator);

        return .{
            .user_agent = user_agent,
            .brands = brands,
            .full_version_brands = full_version_brands,
            .sec_ch_ua = sec_ch_ua,
            .sec_ch_ua_full_version_list = sec_ch_ua_full_version_list,
            .sec_ch_ua_full_version = sec_ch_ua_full_version,
            .sec_ch_ua_platform = sec_ch_ua_platform,
            .platform = platform,
            .accept_language = accept_language,
            .proxy_bearer_header = proxy_bearer_header,
        };
    }

    /// Parses the Sec-Ch-Ua wire syntax: `"Brand";v="1", "Other";v="2"`.
    /// Anything that doesn't look like a quoted brand followed by v="…" is
    /// skipped rather than fatal — a malformed flag degrades to fewer brands,
    /// it doesn't take the browser down.
    // Turns each brand's version into the four-part form the high-entropy
    // hints use. A version that already carries a dot is copied as-is, so a
    // --sec-ch-ua giving full versions round-trips untouched.
    fn padBrandVersions(allocator: Allocator, brands: []const Brand) ![]const Brand {
        const out = try allocator.alloc(Brand, brands.len);
        var built: usize = 0;
        errdefer {
            for (out[0..built]) |b| {
                allocator.free(b.brand);
                allocator.free(b.version);
            }
            allocator.free(out);
        }

        for (brands, out) |brand, *entry| {
            const name = try allocator.dupe(u8, brand.brand);
            errdefer allocator.free(name);
            const version = if (std.mem.indexOfScalar(u8, brand.version, '.') != null)
                try allocator.dupe(u8, brand.version)
            else
                try std.fmt.allocPrint(allocator, "{s}.0.0.0", .{brand.version});
            entry.* = .{ .brand = name, .version = version };
            built += 1;
        }
        return out;
    }

    fn freeBrands(allocator: Allocator, brands: []const Brand) void {
        for (brands) |b| {
            allocator.free(b.brand);
            allocator.free(b.version);
        }
        allocator.free(brands);
    }

    fn parseBrands(allocator: Allocator, raw: []const u8) ![]const Brand {
        var list: std.ArrayList(Brand) = .empty;
        errdefer list.deinit(allocator);

        var rest = raw;
        while (std.mem.indexOfScalar(u8, rest, '"')) |open| {
            rest = rest[open + 1 ..];
            const close = std.mem.indexOfScalar(u8, rest, '"') orelse break;
            const brand = rest[0..close];
            rest = rest[close + 1 ..];

            // v="…" — the version follows the brand's closing quote.
            const v = std.mem.indexOf(u8, rest, "v=\"") orelse break;
            rest = rest[v + 3 ..];
            const v_close = std.mem.indexOfScalar(u8, rest, '"') orelse break;
            const version = rest[0..v_close];
            rest = rest[v_close + 1 ..];

            if (brand.len == 0) continue;
            try list.append(allocator, .{
                .brand = try allocator.dupe(u8, brand),
                .version = try allocator.dupe(u8, version),
            });
        }
        return list.toOwnedSlice(allocator);
    }

    fn formatSecChUa(allocator: Allocator, brands: []const Brand) ![:0]const u8 {
        var aw: std.Io.Writer.Allocating = .init(allocator);
        defer aw.deinit();
        for (brands, 0..) |b, i| {
            try aw.writer.print("{s}\"{s}\";v=\"{s}\"", .{ if (i == 0) "" else ", ", b.brand, b.version });
        }
        return aw.toOwnedSliceSentinel(0);
    }

    pub fn deinit(self: *const HttpHeaders, allocator: Allocator) void {
        if (self.proxy_bearer_header) |hdr| {
            allocator.free(hdr);
        }
        self.accept_language.deinit(allocator);
        allocator.free(self.sec_ch_ua_platform);
        allocator.free(self.sec_ch_ua_full_version);
        allocator.free(self.sec_ch_ua_full_version_list);
        allocator.free(self.sec_ch_ua);
        if (self.brands.ptr != &default_brands) {
            freeBrands(allocator, self.brands);
        }
        if (self.full_version_brands.ptr != &default_full_version_brands) {
            freeBrands(allocator, self.full_version_brands);
        }
        if (self.user_agent.ptr != user_agent_base.ptr) {
            allocator.free(self.user_agent);
        }
    }

    /// Chrome's shape: the tag, then its language alone, then English as a
    /// last resort, with descending q values. `buf` must hold the longest
    /// output for a tag that passed validateLocale (35 + 24 bytes).
    fn acceptLanguageFor(buf: *[64]u8, tag: []const u8) []const u8 {
        const primary = tag[0 .. std.mem.indexOfScalar(u8, tag, '-') orelse tag.len];
        var w: std.Io.Writer = .fixed(buf);
        w.writeAll(tag) catch unreachable;
        var q: u8 = 9;
        if (primary.len != tag.len) {
            w.print(",{s};q=0.{d}", .{ primary, q }) catch unreachable;
            q -= 1;
        }
        if (!std.ascii.eqlIgnoreCase(primary, "en")) {
            w.print(",en;q=0.{d}", .{q}) catch unreachable;
        }
        return w.buffered();
    }
};

pub fn printUsageAndExit(self: *const Config, allocator: Allocator, help_for: RunMode, success: bool) !void {
    const exec_name = self.exec_name;
    const Help = @import("help.zon");
    const info_or_warn = if (comptime lp.IS_DEBUG) "info" else "warn";
    const pretty_or_logfmt = if (comptime lp.IS_DEBUG) "pretty" else "logfmt";
    const comptimePrint = std.fmt.comptimePrint;

    const text = switch (help_for) {
        // Requested help for everything.
        .help => text: {
            const template = comptimePrint(
                \\{s}
                \\
            , .{Help.general});
            break :text try std.fmt.allocPrint(allocator, template, .{exec_name});
        },
        inline .fetch, .serve, .mcp, .agent, .run => |tag| text: {
            const template = comptimePrint(
                \\{s}
                \\
                \\{s}
                \\
            , .{ @field(Help, @tagName(tag)), Help.common_options });
            break :text try std.fmt.allocPrint(allocator, template, .{ exec_name, info_or_warn, pretty_or_logfmt });
        },
        .version => text: {
            const template = Help.version ++ "\n";
            break :text try std.fmt.allocPrint(allocator, template, .{exec_name});
        },
    };
    defer allocator.free(text);

    if (success) {
        printPaged(allocator, text);
        return std.process.cleanExit(lp.io);
    }
    var stderr = std.Io.File.stderr().writerStreaming(lp.io, &.{});
    stderr.interface.writeAll(text) catch {};
    std.process.exit(1);
}

fn printPlain(text: []const u8) void {
    var stdout = std.Io.File.stdout().writerStreaming(lp.io, &.{});
    stdout.interface.writeAll(text) catch {};
}

/// Pages explicitly requested help through $PAGER (fallback: less) when
/// stdout is an interactive terminal; prints plainly otherwise.
fn printPaged(allocator: Allocator, text: []const u8) void {
    const is_tty = std.Io.File.stdout().isTty(lp.io) catch false;
    if (!is_tty) {
        return printPlain(text);
    }
    const term = if (std.c.getenv("TERM")) |t| std.mem.span(t) else "";
    if (term.len == 0 or std.mem.eql(u8, term, "dumb")) {
        return printPlain(text);
    }

    const pager = if (std.c.getenv("PAGER")) |p| std.mem.span(p) else "";
    const argv: []const []const u8 = if (pager.len > 0)
        &.{ "/bin/sh", "-c", pager }
    else
        &.{ "less", "-FIRX" };

    // Pass the real environment so the pager sees TERM/LESS.
    var environ_map = lp.environMap(allocator) catch return printPlain(text);
    defer environ_map.deinit();

    // lp.io cannot spawn children: failing allocator, empty environ (no PATH).
    var pager_threaded: std.Io.Threaded = .init(allocator, .{ .environ = lp.environ() });
    defer pager_threaded.deinit();
    const pager_io = pager_threaded.io();

    var child = std.process.spawn(pager_io, .{
        .argv = argv,
        .environ_map = &environ_map,
        .stdin = .pipe,
    }) catch return printPlain(text);

    if (child.stdin) |stdin| {
        var writer = stdin.writerStreaming(pager_io, &.{});
        // A write error here is the pager exiting early (user quit, or the
        // command failed) — wait() below decides which.
        writer.interface.writeAll(text) catch {};
        stdin.close(pager_io);
        child.stdin = null;
    }

    const term_result = child.wait(pager_io) catch return printPlain(text);
    const clean_exit = term_result == .exited and term_result.exited == 0;
    // Quitting the pager early is still exit 0; a non-zero exit means the
    // pager failed (e.g. $PAGER not found) and the help was never shown.
    if (!clean_exit) {
        printPlain(text);
    }
}

pub fn parseArgs(allocator: Allocator, proc_args: std.process.Args) !Config {
    const exec_name, var command = try Commands.parse(allocator, proc_args);
    const invoked = std.meta.activeTag(command);
    // Rewrite `run` to `.agent` so nothing downstream needs a `.run` case.
    if (command == .run) {
        const run = command.run;
        if (run.script_file == null) {
            log.fatal(.app, "missing script file", .{ .hint = "usage: lightpanda run <script.js>" });
            return error.MissingArgument;
        }
        // run's fields are a strict subset of Agent's (compile error otherwise).
        var agent_opts: Agent = .{};
        inline for (@typeInfo(@TypeOf(run)).@"struct".fields) |f| {
            @field(agent_opts, f.name) = @field(run, f.name);
        }
        command = .{ .agent = agent_opts };
    }

    // Agent mode quiets page-driven `console.error` noise unless
    // verbosity=high. Depends on --verbosity/--task, so it can only be
    // resolved after the options are parsed; an explicit --log-level wins.
    if (command == .agent) {
        const opts = command.agent;
        if (opts.log_level == null and agentVerbosity(opts) != .high) {
            log.opts.level = .err;
        }
    }

    var config = try Config.init(allocator, exec_name, command);
    config.command = invoked;
    return config;
}

test "Config: every external resource loads by default" {
    // A client that never fetches CSS, never runs a worker and never loads an
    // iframe is trivially separable server-side, so all four defaults have to
    // be on; the flags exist to opt back out. Upstream defaults them off.
    var on = try Config.init(std.testing.allocator, "test", .{ .serve = .{} });
    defer on.deinit(std.testing.allocator);
    try std.testing.expectEqual(LoadResources{
        .image = true,
        .iframe = true,
        .worker = true,
        .stylesheet = true,
    }, on.loadResources());

    var off = try Config.init(std.testing.allocator, "test", .{ .serve = .{
        .disable_external_stylesheets = true,
        .disable_subframes = true,
        .disable_workers = true,
    } });
    defer off.deinit(std.testing.allocator);
    try std.testing.expectEqual(LoadResources{
        .image = true,
        .iframe = false,
        .worker = false,
        .stylesheet = false,
    }, off.loadResources());
}

test "Config: the CDP limits answer for mcp's second listener too" {
    // `mcp --cdp-port` advertises a CDP server, and Connection.init asks the
    // config for these three the moment a client connects. They used to answer
    // for `serve` only, so the first connection reached `unreachable` -- the
    // whole mcp+CDP path crashed on contact.
    var mcp = try Config.init(std.testing.allocator, "test", .{ .mcp = .{} });
    defer mcp.deinit(std.testing.allocator);
    try std.testing.expectEqual(1024 * 1024, mcp.cdpMaxMessageSize());
    try std.testing.expectEqual(4096, mcp.cdpMaxHTTPMessageSize());
    try std.testing.expectEqual(true, mcp.metricsEndpointEnabled());

    // Unchanged for the mode that owns the flags.
    var serve = try Config.init(std.testing.allocator, "test", .{ .serve = .{ .disable_metrics = true } });
    defer serve.deinit(std.testing.allocator);
    try std.testing.expectEqual(false, serve.metricsEndpointEnabled());
}

test "Config: WebMCP is off unless the run asked for it" {
    // Chrome has none of the three names this fork's WebMCP surface adds, and
    // Kasada reads one of them, so `serve`/`fetch` -- the modes whose job is to
    // look like a browser -- start without it.
    var off = try Config.init(std.testing.allocator, "test", .{ .serve = .{} });
    defer off.deinit(std.testing.allocator);
    try std.testing.expectEqual(false, off.enableWebMcp());

    var on = try Config.init(std.testing.allocator, "test", .{ .serve = .{ .webmcp = true } });
    defer on.deinit(std.testing.allocator);
    try std.testing.expectEqual(true, on.enableWebMcp());

    var fetch = try Config.init(std.testing.allocator, "test", .{ .fetch = .{} });
    defer fetch.deinit(std.testing.allocator);
    try std.testing.expectEqual(false, fetch.enableWebMcp());

    // `mcp` exists to serve WebMCP; the flag is not its to refuse.
    var mcp = try Config.init(std.testing.allocator, "test", .{ .mcp = .{} });
    defer mcp.deinit(std.testing.allocator);
    try std.testing.expectEqual(true, mcp.enableWebMcp());
}

test "Config: adblockLists splits comma-separated paths" {
    var config = try Config.init(std.testing.allocator, "test", .{ .serve = .{
        .adblock_lists = "easylist.txt,easyprivacy.txt",
    } });
    defer config.deinit(std.testing.allocator);

    var paths = config.adblockLists().?;
    try std.testing.expectEqualStrings("easylist.txt", paths.next().?);
    try std.testing.expectEqualStrings("easyprivacy.txt", paths.next().?);
    try std.testing.expectEqual(null, paths.next());
}

test "Config: blockedUrlPatterns splits comma-separated patterns" {
    var config = try Config.init(std.testing.allocator, "test", .{ .serve = .{
        .block_urls = "*doubleclick*,*://*/*.png",
    } });
    defer config.deinit(std.testing.allocator);

    var patterns = config.blockedUrlPatterns().?;
    try std.testing.expectEqualStrings("*doubleclick*", patterns.next().?);
    try std.testing.expectEqualStrings("*://*/*.png", patterns.next().?);
    try std.testing.expectEqual(null, patterns.next());
}

test "Config: HttpHeaders default to Chrome's identity" {
    var config = try Config.init(std.testing.allocator, "test", .{ .serve = .{} });
    defer config.deinit(std.testing.allocator);

    const h = config.http_headers;
    try std.testing.expectEqualStrings(
        "\"Google Chrome\";v=\"153\", \"Not_A Brand\";v=\"8\", \"Chromium\";v=\"153\"",
        h.sec_ch_ua,
    );
    try std.testing.expectEqualStrings("en-US,en;q=0.9", h.accept_language.header);
    try std.testing.expectEqual(@as(usize, 3), h.brands.len);
    try std.testing.expectEqualStrings("Google Chrome", h.brands[0].brand);
    try std.testing.expectEqualStrings("Chromium", h.brands[2].brand);

    // The default User-Agent is a whole Chrome string, and its version has to
    // be the one the brands above carry.
    try std.testing.expectEqual(true, std.mem.startsWith(u8, h.user_agent, "Mozilla/5.0 ("));
    try std.testing.expectEqual(true, std.mem.endsWith(u8, h.user_agent, " Safari/537.36"));
    try std.testing.expectEqual(
        true,
        std.mem.indexOf(u8, h.user_agent, "AppleWebKit/537.36 (KHTML, like Gecko) Chrome/153.0.0.0") != null,
    );
    try std.testing.expectEqual(null, std.mem.indexOf(u8, h.user_agent, "Lightpanda"));
}

test "Config: --user-agent-suffix appends to the Chrome default" {
    var config = try Config.init(std.testing.allocator, "test", .{ .serve = .{
        .user_agent_suffix = "marker",
    } });
    defer config.deinit(std.testing.allocator);

    try std.testing.expectEqual(true, std.mem.startsWith(u8, config.http_headers.user_agent, "Mozilla/5.0 ("));
    try std.testing.expectEqual(true, std.mem.endsWith(u8, config.http_headers.user_agent, " Safari/537.36 marker"));
}

test "Config: --sec-ch-ua drives both the header and the brand list" {
    var config = try Config.init(std.testing.allocator, "test", .{ .serve = .{
        .sec_ch_ua = "\"Not;A=Brand\";v=\"8\", \"Chromium\";v=\"150\", \"Google Chrome\";v=\"150\"",
        .sec_ch_ua_platform = "Windows",
        .accept_language = "de-DE,de;q=0.9",
    } });
    defer config.deinit(std.testing.allocator);

    const h = config.http_headers;
    // The header round-trips the flag verbatim, so what was asked for is what
    // goes on the wire -- including a major that is deliberately not the one
    // this build claims by default, which is the whole point of the override.
    try std.testing.expectEqualStrings(
        "\"Not;A=Brand\";v=\"8\", \"Chromium\";v=\"150\", \"Google Chrome\";v=\"150\"",
        h.sec_ch_ua,
    );
    try std.testing.expectEqualStrings("\"Windows\"", h.sec_ch_ua_platform);
    try std.testing.expectEqualStrings("de-DE,de;q=0.9", h.accept_language.header);

    // ...and navigator.userAgentData.brands reads this same list.
    try std.testing.expectEqual(@as(usize, 3), h.brands.len);
    try std.testing.expectEqualStrings("Not;A=Brand", h.brands[0].brand);
    try std.testing.expectEqualStrings("8", h.brands[0].version);
    try std.testing.expectEqualStrings("Google Chrome", h.brands[2].brand);
    try std.testing.expectEqualStrings("150", h.brands[2].version);
}

test "Config: httpTimeout leaves room for a slow real API" {
    // amiunique.org answers POST /api/fingerprints in ~21s — Chrome waits it
    // out and renders, measured on the same route. A 5s cap killed the request
    // mid-flight and the page stayed blank, and Chrome has no comparable fixed
    // ceiling on an ordinary request, so the default cannot be that tight.
    var config = try Config.init(std.testing.allocator, "test", .{ .serve = .{} });
    defer config.deinit(std.testing.allocator);
    try std.testing.expectEqual(30000, config.httpTimeout());

    var explicit = try Config.init(std.testing.allocator, "test", .{ .serve = .{
        .http_timeout = 1234,
    } });
    defer explicit.deinit(std.testing.allocator);
    try std.testing.expectEqual(1234, explicit.httpTimeout());
}

test "Config: a Chrome User-Agent is accepted" {
    // Upstream rejected this outright; the fork's whole purpose needs it.
    try validateUserAgent("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/150.0.0.0");
    try std.testing.expectError(error.NonPrintable, validateUserAgent("Chrome/150\r\nX: y"));
}

// Upstream lightpanda additionally rejected any User-Agent containing
// "Mozilla", as a deliberate no-impersonation policy. This fork exists to
// present a Chrome-consistent fingerprint, so that check is gone: every real
// browser's UA starts with "Mozilla/5.0", and forbidding it forbids the goal.
// The non-printable check stays — that one is wire safety (header injection),
// not policy.
// /json/version must never advertise a wildcard bind address because
// clients (Chromedp, Playwright MCP, etc.) cannot dial 0.0.0.0/::. See
// issue #1922.
test "Config: advertiseHost falls back to loopback for wildcard binds" {
    {
        var config = try Config.init(std.testing.allocator, "test", .{ .serve = .{
            .host = "0.0.0.0",
        } });
        defer config.deinit(std.testing.allocator);
        try std.testing.expect(config.bindIsWildcard());
        try std.testing.expectEqualStrings("127.0.0.1", config.advertiseHost());
    }
    {
        var config = try Config.init(std.testing.allocator, "test", .{ .serve = .{
            .host = "::",
        } });
        defer config.deinit(std.testing.allocator);
        try std.testing.expect(config.bindIsWildcard());
        try std.testing.expectEqualStrings("127.0.0.1", config.advertiseHost());
    }
}

test "Config: advertiseHost honors explicit --advertise-host override" {
    var config = try Config.init(std.testing.allocator, "test", .{ .serve = .{
        .host = "0.0.0.0",
        .advertise_host = "192.168.0.5",
    } });
    defer config.deinit(std.testing.allocator);
    // The explicit --advertise-host silences the wildcard guidance log.
    try std.testing.expect(!config.bindIsWildcard());
    try std.testing.expectEqualStrings("192.168.0.5", config.advertiseHost());
}

test "Config: advertiseHost preserves concrete host when not a wildcard" {
    var config = try Config.init(std.testing.allocator, "test", .{ .serve = .{
        .host = "127.0.0.1",
    } });
    defer config.deinit(std.testing.allocator);
    try std.testing.expect(!config.bindIsWildcard());
    try std.testing.expectEqualStrings("127.0.0.1", config.advertiseHost());
}

test "Config: parseArgs --http-version" {
    // parseArgs allocations live for the process; an arena stands in for main's.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    {
        const argv = [_][*:0]const u8{ "lightpanda", "fetch", "https://example.com" };
        const proc_args: std.process.Args = .{ .vector = &argv };
        const config = try parseArgs(arena.allocator(), proc_args);
        try std.testing.expectEqual(.auto, config.httpVersion());
    }
    {
        const argv = [_][*:0]const u8{ "lightpanda", "serve", "--http-version", "1.1" };
        const proc_args: std.process.Args = .{ .vector = &argv };
        const config = try parseArgs(arena.allocator(), proc_args);
        try std.testing.expectEqual(.@"1.1", config.httpVersion());
    }
    {
        log.expectLog(&.{.app});
        const argv = [_][*:0]const u8{ "lightpanda", "fetch", "--http-version", "3" };
        const proc_args: std.process.Args = .{ .vector = &argv };
        try std.testing.expectError(error.InvalidArgument, parseArgs(std.testing.allocator, proc_args));
    }
}

test "Config: validateLocale" {
    try validateLocale("en");
    try validateLocale("en-US");
    try validateLocale("zh-Hant-TW");
    try validateLocale("es-419");
    try std.testing.expectError(error.InvalidLanguage, validateLocale(""));
    try std.testing.expectError(error.InvalidLanguage, validateLocale("e"));
    try std.testing.expectError(error.InvalidLanguage, validateLocale("en_US"));
    try std.testing.expectError(error.InvalidSubtag, validateLocale("en-"));
    try std.testing.expectError(error.InvalidSubtag, validateLocale("en-U"));
    try std.testing.expectError(error.InvalidSubtag, validateLocale("en-US-x-toolongsub"));
    try std.testing.expectError(error.InvalidSubtag, validateLocale("en-U$"));
    try std.testing.expectError(error.TooLong, validateLocale("en-" ++ "a" ** 40));
}

test "Config: validateTimezone" {
    try validateTimezone("UTC");
    try validateTimezone("Europe/Paris");
    try validateTimezone("America/Argentina/Buenos_Aires");
    try std.testing.expectError(error.Empty, validateTimezone(""));
    try std.testing.expectError(error.InvalidCharacter, validateTimezone("Europe/ Paris"));
    try std.testing.expectError(error.InvalidCharacter, validateTimezone("UTC\n"));
    try std.testing.expectError(error.TooLong, validateTimezone("a" ** 65));
}

test "Config: HttpHeaders.acceptLanguageFor" {
    const cases = [_]struct { tag: []const u8, expected: []const u8 }{
        .{ .tag = "en-US", .expected = "en-US,en;q=0.9" },
        .{ .tag = "en-GB", .expected = "en-GB,en;q=0.9" },
        .{ .tag = "de-DE", .expected = "de-DE,de;q=0.9,en;q=0.8" },
        .{ .tag = "de", .expected = "de,en;q=0.9" },
        .{ .tag = "en", .expected = "en" },
        .{ .tag = "zh-Hant-TW", .expected = "zh-Hant-TW,zh;q=0.9,en;q=0.8" },
    };
    for (cases) |case| {
        var buf: [64]u8 = undefined;
        try std.testing.expectEqualStrings(case.expected, HttpHeaders.acceptLanguageFor(&buf, case.tag));
    }
}

test "Config: HttpHeaders.AcceptLanguage lists the header's tags" {
    const allocator = std.testing.allocator;
    const cases = [_]struct { header: []const u8, tags: []const []const u8 }{
        .{ .header = "en-US,en;q=0.9", .tags = &.{ "en-US", "en" } },
        .{ .header = "de-DE,de;q=0.9, en;q=0.8", .tags = &.{ "de-DE", "de", "en" } },
        .{ .header = "fr-FR", .tags = &.{"fr-FR"} },
        .{ .header = " , ;q=0.5,", .tags = &.{} },
        .{ .header = "", .tags = &.{} },
    };
    for (cases) |case| {
        const al: HttpHeaders.AcceptLanguage = try .init(allocator, case.header);
        defer al.deinit(allocator);
        try std.testing.expectEqualStrings(case.header, al.header);
        try std.testing.expectEqual(case.tags.len, al.languages.len);
        for (case.tags, al.languages) |expected, actual| {
            try std.testing.expectEqualStrings(expected, actual);
        }
    }
}

test "Config: locale drives http_headers" {
    const allocator = std.testing.allocator;
    {
        var config = try Config.init(allocator, "test", .{ .serve = .{ .host = "127.0.0.1" } });
        defer config.deinit(allocator);
        try std.testing.expectEqualStrings("en-US,en;q=0.9", config.http_headers.accept_language.header);
        try std.testing.expectEqual(2, config.http_headers.accept_language.languages.len);
        try std.testing.expectEqualStrings("en", config.http_headers.accept_language.languages[1]);
    }
    {
        var config = try Config.init(allocator, "test", .{ .serve = .{ .host = "127.0.0.1", .locale = "fr" } });
        defer config.deinit(allocator);
        try std.testing.expectEqualStrings("fr,en;q=0.9", config.http_headers.accept_language.header);
        try std.testing.expectEqual(2, config.http_headers.accept_language.languages.len);
        try std.testing.expectEqualStrings("fr", config.http_headers.accept_language.languages[0]);
    }
}

test "Config: parseArgs refuses an invalid --locale and --timezone" {
    {
        log.expectLog(&.{.app});
        const argv = [_][*:0]const u8{ "lightpanda", "fetch", "--locale", "en_US" };
        const proc_args: std.process.Args = .{ .vector = &argv };
        try std.testing.expectError(error.InvalidArgument, parseArgs(std.testing.allocator, proc_args));
    }
    {
        log.expectLog(&.{.app});
        const argv = [_][*:0]const u8{ "lightpanda", "fetch", "--timezone", "Europe/ Paris" };
        const proc_args: std.process.Args = .{ .vector = &argv };
        try std.testing.expectError(error.InvalidArgument, parseArgs(std.testing.allocator, proc_args));
    }
}

test "Config: parseArgs refuses an invalid --http-header" {
    const invalid = [_][*:0]const u8{
        // no colon to split on
        "not-a-header",
        // empty name
        ": value",
        // names that aren't HTTP tokens
        "Foo Bar: value",
        "X(Foo)=a: value",
        // CR/LF in the value would smuggle a second header onto the wire
        "X-A: b\r\nX-B: c",
        "X-A: b\n",
    };

    for (invalid) |header| {
        log.expectLog(&.{.app});
        const argv = [_][*:0]const u8{ "lightpanda", "fetch", "--http-header", header };
        const proc_args: std.process.Args = .{ .vector = &argv };
        try std.testing.expectError(error.InvalidArgument, parseArgs(std.testing.allocator, proc_args));
    }
}

test "Config: parseArgs accumulates repeated list flags" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const argv = [_][*:0]const u8{
        "lightpanda",         "fetch",
        "--adblock-lists",    "easylist.txt",
        "--adblock-lists",    "easyprivacy.txt,annoyances.txt",
        "--block-cidrs",      "10.0.0.0/8",
        "--block-cidrs",      "-10.0.0.42/32",
        "http://example.com",
    };
    const proc_args: std.process.Args = .{ .vector = &argv };
    const config = try parseArgs(arena.allocator(), proc_args);

    var paths = config.adblockLists().?;
    try std.testing.expectEqualStrings("easylist.txt", paths.next().?);
    try std.testing.expectEqualStrings("easyprivacy.txt", paths.next().?);
    try std.testing.expectEqualStrings("annoyances.txt", paths.next().?);
    try std.testing.expectEqual(null, paths.next());

    try std.testing.expectEqualStrings("10.0.0.0/8,-10.0.0.42/32", config.blockCidrs().?);
}

test "Config: parseArgs collects --http-header" {
    // The parsed headers are owned by the allocator for the process lifetime;
    // an arena stands in for main's.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const argv = [_][*:0]const u8{
        "lightpanda",         "fetch",
        "--http-header",      "Accept-Language: fr-FR,fr;q=0.9",
        "--http-header",      " \tX-Empty \t: \t",
        "http://example.com",
    };
    const proc_args: std.process.Args = .{ .vector = &argv };
    const config = try parseArgs(arena.allocator(), proc_args);

    const headers = config.httpHeaders();
    try std.testing.expectEqual(2, headers.len);
    try std.testing.expectEqualStrings("Accept-Language", headers[0].name);
    try std.testing.expectEqualStrings("fr-FR,fr;q=0.9", headers[0].value);
    // Name and value are trimmed; an empty value is legal.
    try std.testing.expectEqualStrings("X-Empty", headers[1].name);
    try std.testing.expectEqualStrings("", headers[1].value);
}

test "Config: httpHeaders accessor" {
    {
        var config = try Config.init(std.testing.allocator, "test", .{ .serve = .{} });
        defer config.deinit(std.testing.allocator);
        try std.testing.expectEqual(0, config.httpHeaders().len);
    }
    {
        var list: std.ArrayList(HttpHeader) = .empty;
        defer list.deinit(std.testing.allocator);
        try list.append(std.testing.allocator, .{ .name = "X-Extra", .value = "1" });

        var config = try Config.init(std.testing.allocator, "test", .{ .serve = .{
            .http_header = list,
        } });
        defer config.deinit(std.testing.allocator);

        const headers = config.httpHeaders();
        try std.testing.expectEqual(1, headers.len);
        try std.testing.expectEqualStrings("X-Extra", headers[0].name);
        try std.testing.expectEqualStrings("1", headers[0].value);
    }
}

/// For comma-separated flags the help documents as repeatable: each
/// occurrence appends to what earlier ones left, so "--x a --x b" equals
/// "--x a,b" instead of the last flag silently winning.
fn accumulateValidator(allocator: Allocator, args: *std.process.Args.Iterator, field: *?[]const u8) !void {
    const str = args.next() orelse return error.MissingArgument;
    const existing = field.* orelse {
        field.* = try allocator.dupe(u8, str);
        return;
    };
    field.* = try std.mem.join(allocator, ",", &.{ existing, str });
}

fn userAgentValidator(allocator: Allocator, args: *std.process.Args.Iterator, ua: *?[]const u8) !void {
    const str = args.next() orelse return error.MissingArgument;
    validateUserAgent(str) catch |err| {
        log.fatal(.app, "invalid user-agent", .{ .err = err, .hint = "must be printable ASCII" });
        return error.InvalidArgument;
    };

    ua.* = try allocator.dupe(u8, str);
}

pub fn validateUserAgent(ua: []const u8) !void {
    for (ua) |c| {
        if (!std.ascii.isPrint(c)) {
            return error.NonPrintable;
        }
    }
}

fn localeValidator(allocator: Allocator, args: *std.process.Args.Iterator, field: *[:0]const u8) !void {
    const str = args.next() orelse return error.MissingArgument;
    validateLocale(str) catch |err| {
        log.fatal(.app, "invalid option value", .{ .arg = "--locale", .value = str, .err = err, .hint = "must be a BCP 47 tag such as en-US, de or zh-Hant-TW" });
        return error.InvalidArgument;
    };
    field.* = try allocator.dupeZ(u8, str);
}

fn timezoneValidator(allocator: Allocator, args: *std.process.Args.Iterator, field: *?[:0]const u8) !void {
    const str = args.next() orelse return error.MissingArgument;
    validateTimezone(str) catch |err| {
        log.fatal(.app, "invalid option value", .{ .arg = "--timezone", .value = str, .err = err, .hint = "must be an IANA time zone such as Europe/Paris or UTC" });
        return error.InvalidArgument;
    };
    field.* = try allocator.dupeZ(u8, str);
}

/// A BCP 47 tag restricted to what ICU and the Accept-Language derivation
/// need: a 2-3 letter language followed by 2-8 character alphanumeric subtags.
pub fn validateLocale(tag: []const u8) !void {
    if (tag.len > 35) {
        return error.TooLong;
    }
    var it = std.mem.splitScalar(u8, tag, '-');
    const language = it.next().?;
    if (language.len < 2 or language.len > 3) {
        return error.InvalidLanguage;
    }
    for (language) |c| {
        if (!std.ascii.isAlphabetic(c)) {
            return error.InvalidLanguage;
        }
    }
    while (it.next()) |subtag| {
        if (subtag.len < 2 or subtag.len > 8) {
            return error.InvalidSubtag;
        }
        for (subtag) |c| {
            if (!std.ascii.isAlphanumeric(c)) {
                return error.InvalidSubtag;
            }
        }
    }
}

/// Only the shape is checked; ICU resolves the id itself and falls back to
/// GMT for names it does not know.
pub fn validateTimezone(id: []const u8) !void {
    if (id.len == 0) {
        return error.Empty;
    }
    if (id.len > 64) {
        return error.TooLong;
    }
    for (id) |c| {
        if (c <= ' ' or c == 0x7f) {
            return error.InvalidCharacter;
        }
    }
}

/// Tag names of a Zig enum, so a command's allowed values can't drift from the
/// enum it sets.
pub const tagNames = cli.tagNames;

/// `<a|b|c>` ghost-text hint built from the same enum's tag names.
pub fn tagHint(comptime E: type) []const u8 {
    var s: []const u8 = "<";
    for (@typeInfo(E).@"enum".fields, 0..) |f, i| {
        s = s ++ (if (i == 0) f.name else "|" ++ f.name);
    }
    return s ++ ">";
}

/// JSON array `["a","b","c"]` representation of the enum tag names.
pub fn tagJsonArray(comptime E: type) []const u8 {
    var s: []const u8 = "[";
    for (@typeInfo(E).@"enum".fields, 0..) |f, i| {
        s = s ++ (if (i == 0) "\"" else ",\"") ++ f.name ++ "\"";
    }
    return s ++ "]";
}
