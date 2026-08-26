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

//! Encrypted Media Extensions: the six interfaces plus the acceptance rules
//! behind navigator.requestMediaKeySystemAccess.
//!
//! The interfaces were the reason this file exists -- they are six of the
//! window keys CreepJS counts -- but the rules are the part a detector reads.
//! `requestMediaKeySystemAccess` used to reject NotSupportedError for every key
//! system, which says "no CDM at all", and a desktop Chrome has two: Clear Key
//! and Widevine. So the negotiation is real here: a candidate configuration is
//! converted, normalised and then either matched or refused exactly as Chrome
//! 150 does it, and `getConfiguration()` echoes back the dictionary Chrome
//! echoes -- alphabetically ordered, every omitted member filled in.
//!
//! Everything past the negotiation is a CDM's job and there is no CDM, so a
//! session is created but never initialised: `generateRequest` marks it
//! initialised and then refuses the init data type, `update`/`remove`/`close`
//! answer "The session is not callable", `keyStatuses` stays empty and `closed`
//! stays pending. All of that is Chrome's own behaviour for a session that
//! never got a license -- measured, not guessed -- so the shallow part is
//! shallow in the same shape as the deep one.
//!
//! Measured on a headed Chrome 150 over http://localhost: win57-chrome.json,
//! win58-chrome.json, win59-chrome.json.
//!
//! Two deliberate divergences, both pre-existing engine conventions rather than
//! decisions taken here:
//!
//!   * A `sequence<T>` is read with `isArray()`, so a generator or any other
//!     non-array iterable is refused where Chrome accepts it. Every other
//!     sequence in this engine reads the same way (see navigator/usb.zig).
//!   * Content types go through media/mime.zig, the single table the three
//!     `isTypeSupported` APIs already share. Agreeing with ourselves matters
//!     more than agreeing with Chrome on an exotic codec string: a page that
//!     found `MediaSource.isTypeSupported(x)` true and EME refusing x would
//!     have a louder signal than either answer being slightly off.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");

const Event = @import("../Event.zig");
const EventTarget = @import("../EventTarget.zig");
const DOMException = @import("../DOMException.zig");
const Frame = @import("../../Frame.zig");
const dictionary = @import("../dictionary.zig");
const mime = @import("mime.zig");
const handler_property = @import("../handler_property.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}

const String = lp.String;
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        MediaKeySystemAccess,
        MediaKeys,
        MediaKeySession,
        MediaKeyStatusMap,
        MediaKeyStatusMap.KeyIterator,
        MediaKeyStatusMap.ValueIterator,
        MediaKeyStatusMap.EntryIterator,
        MediaKeyMessageEvent,
        MediaEncryptedEvent,
    };
}

fn throwTypeError(message: []const u8, exec: *const Execution) anyerror {
    return dictionary.throwTypeError(message, exec);
}

fn rejectDom(comptime name: []const u8, message: []const u8, exec: *const Execution) js.Promise {
    var resolver = exec.js.local.?.createPromiseResolver();
    resolver.reject("eme", DOMException.init(message, name));
    return resolver.promise();
}

fn rejectType(message: []const u8, exec: *const Execution) js.Promise {
    return exec.js.local.?.rejectPromise(.{ .type_error = message });
}

/// A WebIDL `BufferSource` argument: an ArrayBuffer or any view over one. A
/// DataView and a subarray both count (measured).
fn bufferSource(value: js.Value) ?[]const u8 {
    if (!value.isArrayBuffer() and !value.isArrayBufferView() and !value.isTypedArray()) {
        return null;
    }
    return value.toStringSmart() catch null;
}

/// Chrome's wording when a BufferSource parameter is anything else -- and it
/// really does name the union rather than "BufferSource" (measured on
/// setServerCertificate, generateRequest and update alike).
fn notBufferSource(comptime member: []const u8, comptime interface: []const u8) []const u8 {
    return "Failed to execute '" ++ member ++ "' on '" ++ interface ++
        "': The provided value is not of type '(ArrayBuffer or ArrayBufferView)'.";
}

// == The negotiation ==

/// One entry of `audioCapabilities` / `videoCapabilities`, normalised. The
/// field order is the key order Chrome serialises: alphabetical.
pub const Capability = struct {
    contentType: []const u8,
    encryptionScheme: ?[]const u8,
    robustness: []const u8,
};

/// What `getConfiguration()` hands back. Alphabetical, again, and complete:
/// Chrome fills in every member the page left out.
pub const Configuration = struct {
    audioCapabilities: []const Capability,
    distinctiveIdentifier: []const u8,
    initDataTypes: []const []const u8,
    label: []const u8,
    persistentState: []const u8,
    sessionTypes: []const []const u8,
    videoCapabilities: []const Capability,
};

/// The two key systems a plain desktop Chrome answers for, and the three ways
/// their policies differ. Measured side by side (win59-chrome.json): Widevine
/// takes a robustness level and echoes it verbatim and accepts a required
/// persistent state, while Clear Key takes neither; Clear Key decodes HEVC
/// under EME and Widevine does not. Neither offers a distinctive identifier,
/// and neither offers a persistent-license session.
const KeySystem = struct {
    name: []const u8,
    /// Widevine names robustness levels; Clear Key has none, so only the
    /// empty string matches.
    robustness_levels: bool,
    /// Whether `persistentState: "required"` is on offer.
    persistent_state: bool,
    /// Whether HEVC is among the decoders reachable through this CDM.
    hevc: bool,

    const all = [_]KeySystem{
        .{ .name = "org.w3.clearkey", .robustness_levels = false, .persistent_state = false, .hevc = true },
        .{ .name = "com.widevine.alpha", .robustness_levels = true, .persistent_state = true, .hevc = false },
    };

    /// Exact match: no case folding, no trimming, no prefix match (measured --
    /// "ORG.W3.CLEARKEY", "org.w3.clearkey " and "org.w3.clearkey.foo" are all
    /// refused).
    fn find(name: []const u8) ?*const KeySystem {
        for (&all) |*entry| {
            if (std.mem.eql(u8, entry.name, name)) {
                return entry;
            }
        }
        return null;
    }
};

/// The init data types every CDM here understands. An unrecognised one is
/// filtered out rather than refused, but a candidate whose list is entirely
/// unrecognised has nothing left and is refused.
const init_data_types = [_][]const u8{ "cenc", "keyids", "webm" };

/// The only session type on offer. `persistent-license` needs storage no CDM
/// here has.
const session_types = [_][]const u8{"temporary"};

const encryption_schemes = [_][]const u8{ "cenc", "cbcs" };

const requirements = [_][]const u8{ "required", "optional", "not-allowed" };

const method_prefix = "Failed to execute 'requestMediaKeySystemAccess' on 'Navigator': ";

const Config = dictionary.MethodReader("Navigator", "requestMediaKeySystemAccess", "MediaKeySystemConfiguration");

/// A candidate configuration after WebIDL conversion but before the support
/// check. Chrome converts *every* candidate up front -- a bad enum in the
/// second candidate is a TypeError even when the first one would have matched
/// (measured) -- so conversion and matching are two passes here too.
const Candidate = struct {
    label: []const u8,
    init_data_types: []const []const u8,
    audio: []const RawCapability,
    video: []const RawCapability,
    distinctive_identifier: []const u8,
    persistent_state: []const u8,
    /// Null when the member was absent, which defaults to ["temporary"]. An
    /// explicitly empty array is kept empty (measured).
    session_types: ?[]const []const u8,
};

const RawCapability = struct {
    content_type: []const u8,
    encryption_scheme: ?[]const u8,
    robustness: []const u8,
};

fn sequence(
    comptime member: []const u8,
    value: js.Value,
    exec: *const Execution,
) !js.Array {
    // A primitive cannot be a sequence at all; an object without @@iterator is
    // named as such. A string counts as a primitive here, not as the iterable
    // JS makes it (measured: `initDataTypes: 'cenc'` is the primitive message).
    if (!value.isObject()) {
        return Config.notASequence(member, exec);
    }
    if (!value.isArray()) {
        return throwTypeError(
            Config.message_prefix ++ "Failed to read the '" ++ member ++ "' property from " ++
                "'MediaKeySystemConfiguration': The object must have a callable @@iterator property.",
            exec,
        );
    }
    return value.toArray();
}

fn readStrings(
    comptime member: []const u8,
    config: Config,
    exec: *const Execution,
) !?[]const []const u8 {
    const value = (try config.present(member)) orelse return null;
    const array = try sequence(member, value, exec);
    const out = try exec.arena.alloc([]const u8, array.len());
    for (out, 0..) |*slot, i| {
        slot.* = try (try array.get(@intCast(i))).toStringSliceWithAlloc(exec.arena);
    }
    return out;
}

fn readCapabilities(
    comptime member: []const u8,
    config: Config,
    exec: *const Execution,
) ![]const RawCapability {
    const value = (try config.present(member)) orelse return &.{};
    const array = try sequence(member, value, exec);
    const out = try exec.arena.alloc(RawCapability, array.len());

    const Cap = dictionary.Nested(Config, member, "MediaKeySystemMediaCapability");
    for (out, 0..) |*slot, i| {
        const entry = try array.get(@intCast(i));
        // A non-object element is blamed on the member that holds it, and
        // named as the capability dictionary it failed to be.
        if (!entry.isNullOrUndefined() and !entry.isObject()) {
            return Config.notOfType(member, "MediaKeySystemMediaCapability", exec);
        }
        const cap = try Cap.read(entry, exec);
        slot.* = .{
            .content_type = try cap.string("contentType", "", exec.arena),
            // `encryptionScheme` is nullable, and an explicit null is kept
            // rather than defaulted (measured: it echoes back null).
            .encryption_scheme = blk: {
                const scheme = (try cap.present("encryptionScheme")) orelse break :blk null;
                if (scheme.isNull()) break :blk null;
                break :blk try scheme.toStringSliceWithAlloc(exec.arena);
            },
            .robustness = try cap.string("robustness", "", exec.arena),
        };
    }
    return out;
}

fn readCandidate(value: js.Value, exec: *const Execution) !Candidate {
    // A non-object element is refused before any member is read; null and
    // undefined read as an empty dictionary, which then has no capability to
    // match and fails the support check instead (measured: `[5]` is a
    // TypeError, `[null]` is NotSupportedError).
    if (!value.isNullOrUndefined() and !value.isObject()) {
        return throwTypeError(
            method_prefix ++ "The provided value is not of type 'MediaKeySystemConfiguration'.",
            exec,
        );
    }
    const config = try Config.read(value, exec);
    return .{
        .label = try config.string("label", "", exec.arena),
        .init_data_types = (try readStrings("initDataTypes", config, exec)) orelse &.{},
        .audio = try readCapabilities("audioCapabilities", config, exec),
        .video = try readCapabilities("videoCapabilities", config, exec),
        .distinctive_identifier = (try config.enumMember(
            "distinctiveIdentifier",
            "MediaKeysRequirement",
            &requirements,
            "optional",
            exec,
        )).?,
        .persistent_state = (try config.enumMember(
            "persistentState",
            "MediaKeysRequirement",
            &requirements,
            "optional",
            exec,
        )).?,
        // `sessionTypes` is a sequence of plain DOMStrings, not an enum: an
        // unrecognised member is a refusal, not a TypeError (measured -- ['nope']
        // is NotSupportedError while distinctiveIdentifier: 'nope' is a TypeError).
        .session_types = try readStrings("sessionTypes", config, exec),
    };
}

fn known(list: []const []const u8, value: []const u8) bool {
    for (list) |candidate| {
        if (std.mem.eql(u8, candidate, value)) {
            return true;
        }
    }
    return false;
}

fn hasCodecs(content_type: []const u8) bool {
    const semi = std.mem.indexOfScalar(u8, content_type, ';') orelse return false;
    const rest = std.mem.trimStart(u8, content_type[semi + 1 ..], &std.ascii.whitespace);
    return rest.len >= "codecs".len and std.ascii.eqlIgnoreCase(rest[0.."codecs".len], "codecs");
}

fn isHevc(content_type: []const u8) bool {
    return std.ascii.indexOfIgnoreCase(content_type, "hvc1.") != null or
        std.ascii.indexOfIgnoreCase(content_type, "hev1.") != null;
}

/// Whether one capability survives. A bare container is refused even where
/// MediaSource takes it: EME needs the codecs named (measured -- "video/mp4"
/// alone is NotSupportedError while `video/mp4; codecs="avc1.42E01E"` matches).
fn capabilityMatches(
    system: *const KeySystem,
    comptime kind: []const u8,
    cap: RawCapability,
) bool {
    if (!std.ascii.startsWithIgnoreCase(cap.content_type, kind ++ "/")) {
        return false;
    }
    if (!hasCodecs(cap.content_type)) {
        return false;
    }
    if (!mime.isTypeSupported(.media_source, cap.content_type)) {
        return false;
    }
    if (!system.hevc and isHevc(cap.content_type)) {
        return false;
    }
    if (!system.robustness_levels and cap.robustness.len != 0) {
        return false;
    }
    if (cap.encryption_scheme) |scheme| {
        if (!known(&encryption_schemes, scheme)) {
            return false;
        }
    }
    return true;
}

/// "Get Supported Capabilities": the unsupported entries are dropped, and a
/// list that started non-empty and ended empty sinks the whole candidate
/// (measured -- a good audio list does not rescue an all-bad video one, while a
/// video list with one good and one bad entry keeps the good one).
fn matchCapabilities(
    system: *const KeySystem,
    comptime kind: []const u8,
    raw: []const RawCapability,
    exec: *const Execution,
) !?[]const Capability {
    const out = try exec.arena.alloc(Capability, raw.len);
    var count: usize = 0;
    for (raw) |cap| {
        if (!capabilityMatches(system, kind, cap)) {
            continue;
        }
        out[count] = .{
            .contentType = cap.content_type,
            .encryptionScheme = cap.encryption_scheme,
            // Clear Key only ever reaches here with the empty string; Widevine
            // echoes back whatever level it was asked for.
            .robustness = cap.robustness,
        };
        count += 1;
    }
    if (raw.len != 0 and count == 0) {
        return null;
    }
    return out[0..count];
}

fn matchCandidate(
    system: *const KeySystem,
    candidate: Candidate,
    exec: *const Execution,
) !?Configuration {
    // No CDM here offers a distinctive identifier, so asking for one is the
    // end of the candidate -- for both key systems (measured).
    if (std.mem.eql(u8, candidate.distinctive_identifier, "required")) {
        return null;
    }
    const persistent_state = if (std.mem.eql(u8, candidate.persistent_state, "required")) blk: {
        if (!system.persistent_state) return null;
        break :blk "required";
    } else "not-allowed";

    const audio = (try matchCapabilities(system, "audio", candidate.audio, exec)) orelse return null;
    const video = (try matchCapabilities(system, "video", candidate.video, exec)) orelse return null;
    if (audio.len == 0 and video.len == 0) {
        return null;
    }

    const types = try exec.arena.alloc([]const u8, candidate.init_data_types.len);
    var type_count: usize = 0;
    for (candidate.init_data_types) |name| {
        if (known(&init_data_types, name)) {
            types[type_count] = name;
            type_count += 1;
        }
    }
    if (candidate.init_data_types.len != 0 and type_count == 0) {
        return null;
    }

    const sessions = candidate.session_types orelse &session_types;
    for (sessions) |name| {
        if (!known(&session_types, name)) {
            return null;
        }
    }

    return .{
        .audioCapabilities = audio,
        // Never on offer, so the answer is the same whatever was asked.
        .distinctiveIdentifier = "not-allowed",
        .initDataTypes = types[0..type_count],
        .label = candidate.label,
        .persistentState = persistent_state,
        .sessionTypes = sessions,
        .videoCapabilities = video,
    };
}

/// navigator.requestMediaKeySystemAccess, moved here so the rules live next to
/// the objects they hand out.
pub fn requestMediaKeySystemAccess(
    key_system_: ?js.Value,
    configurations_: ?js.Value,
    exec: *const Execution,
) js.Promise {
    const local = exec.js.local.?;

    // The dictionary readers throw, because that is what they do everywhere
    // else in this engine. EME wants the same refusals as *rejections* -- the
    // method always answers with a promise, even for a missing argument
    // (measured: `requestMediaKeySystemAccess()` is a Promise) -- so the throw
    // is caught here and handed to a resolver instead of the caller.
    var try_catch: js.TryCatch = undefined;
    try_catch.init(local);
    defer try_catch.deinit();

    return request(key_system_, configurations_, exec) catch {
        var resolver = local.createPromiseResolver();
        if (try_catch.exceptionValue()) |value| {
            resolver.reject("eme", value);
        } else {
            resolver.rejectError("eme", .{ .type_error = method_prefix ++ "Failed to read the arguments." });
        }
        return resolver.promise();
    };
}

fn request(
    key_system_: ?js.Value,
    configurations_: ?js.Value,
    exec: *const Execution,
) !js.Promise {
    const key_system_value = key_system_ orelse return rejectType(
        method_prefix ++ "2 arguments required, but only 0 present.",
        exec,
    );
    const configurations = configurations_ orelse return rejectType(
        method_prefix ++ "2 arguments required, but only 1 present.",
        exec,
    );

    const key_system = try key_system_value.toStringSliceWithAlloc(exec.call_arena);
    if (key_system.len == 0) {
        return rejectType(method_prefix ++ "The keySystem parameter is empty.", exec);
    }

    if (!configurations.isObject()) {
        return rejectType(method_prefix ++ "The provided value cannot be converted to a sequence.", exec);
    }
    if (!configurations.isArray()) {
        return rejectType(method_prefix ++ "The object must have a callable @@iterator property.", exec);
    }
    const array = configurations.toArray();
    if (array.len() == 0) {
        return rejectType(method_prefix ++ "The supportedConfigurations parameter is empty.", exec);
    }

    // Pass one: convert everything. A bad member anywhere is a TypeError even
    // when an earlier candidate would have matched.
    const candidates = try exec.call_arena.alloc(Candidate, array.len());
    for (candidates, 0..) |*slot, i| {
        slot.* = try readCandidate(try array.get(@intCast(i)), exec);
    }

    const unsupported = "Unsupported keySystem or supportedConfigurations.";
    const system = KeySystem.find(key_system) orelse
        return rejectDom("NotSupportedError", unsupported, exec);

    // Pass two: the first candidate that matches wins.
    for (candidates) |candidate| {
        const configuration = (try matchCandidate(system, candidate, exec)) orelse continue;
        const access = try exec._factory.create(MediaKeySystemAccess{
            ._key_system = system,
            ._configuration = configuration,
        });
        return exec.js.local.?.resolvePromise(access);
    }
    return rejectDom("NotSupportedError", unsupported, exec);
}

// == The interfaces ==

/// The negotiated outcome. It carries the key system it matched and the
/// normalised configuration, and mints MediaKeys.
pub const MediaKeySystemAccess = struct {
    _key_system: *const KeySystem,
    _configuration: Configuration,

    pub fn getKeySystem(self: *const MediaKeySystemAccess) []const u8 {
        return self._key_system.name;
    }

    /// A fresh object on every call, which is what Chrome does (measured:
    /// `access.getConfiguration() !== access.getConfiguration()`).
    pub fn getConfiguration(self: *const MediaKeySystemAccess) Configuration {
        return self._configuration;
    }

    pub fn createMediaKeys(self: *MediaKeySystemAccess, exec: *const Execution) !js.Promise {
        // Distinct on every call (measured).
        const keys = try exec._factory.create(MediaKeys{ ._key_system = self._key_system });
        return exec.js.local.?.resolvePromise(keys);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaKeySystemAccess);

        pub const Meta = struct {
            pub const name = "MediaKeySystemAccess";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        // Chrome's own prototype order.
        pub const keySystem = bridge.accessor(MediaKeySystemAccess.getKeySystem, null, .{});
        pub const createMediaKeys = bridge.function(MediaKeySystemAccess.createMediaKeys, .{});
        pub const getConfiguration = bridge.function(MediaKeySystemAccess.getConfiguration, .{});
    };
};

/// The CDM handle. It creates sessions and takes a server certificate, and
/// both do as much as they can without a CDM behind them: a session is a real
/// object that can never be initialised, and a certificate is accepted and
/// answered "false" -- Chrome's own answer for a CDM with no use for one.
pub const MediaKeys = struct {
    _key_system: *const KeySystem,

    const session_type_names = [_][]const u8{ "temporary", "persistent-usage-record", "persistent-license" };

    pub fn createSession(
        self: *MediaKeys,
        session_type_: ?[]const u8,
        exec: *const Execution,
    ) !*MediaKeySession {
        const session_type = session_type_ orelse "temporary";
        if (!known(&session_type_names, session_type)) {
            return throwTypeError(try std.fmt.allocPrint(
                exec.call_arena,
                "Failed to execute 'createSession' on 'MediaKeys': The provided value '{s}' is not " ++
                    "a valid enum value of type MediaKeySessionType.",
                .{session_type},
            ), exec);
        }
        // A valid enum value that is nonetheless not on offer: the refusal
        // moves from a TypeError to a DOMException (measured).
        if (!std.mem.eql(u8, session_type, "temporary")) {
            return dictionary.throwDom(
                "NotSupportedError",
                "Failed to execute 'createSession' on 'MediaKeys': Unsupported session type.",
                exec,
            );
        }
        _ = self;
        const session = try exec._factory.eventTarget(MediaKeySession{ ._proto = undefined });
        session._proto._type = .media_key_session;
        return session;
    }

    pub fn setServerCertificate(_: *MediaKeys, certificate_: ?js.Value, exec: *const Execution) js.Promise {
        const certificate = certificate_ orelse return rejectType(
            "Failed to execute 'setServerCertificate' on 'MediaKeys': 1 argument required, but only 0 present.",
            exec,
        );
        const bytes = bufferSource(certificate) orelse return rejectType(
            notBufferSource("setServerCertificate", "MediaKeys"),
            exec,
        );
        if (bytes.len == 0) {
            return rejectType(
                "Failed to execute 'setServerCertificate' on 'MediaKeys': The serverCertificate parameter is empty.",
                exec,
            );
        }
        // Resolves, and resolves *false*: the promise says "the certificate
        // was processed", the value says "this CDM had no use for it".
        return exec.js.local.?.resolvePromise(false) catch
            rejectType("Failed to execute 'setServerCertificate' on 'MediaKeys'.", exec);
    }

    /// Chrome answers "usable" for any policy, including no argument at all
    /// (measured on both key systems).
    pub fn getStatusForPolicy(_: *MediaKeys, _: ?js.Value, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise("usable");
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaKeys);

        pub const Meta = struct {
            pub const name = "MediaKeys";
            // Chrome's `constructor` sits here rather than last; the members
            // below it are the ones Blink installs per context. See
            // Snapshot.moveConstructorSlots.
            pub const constructor_after = "setServerCertificate";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        // Chrome puts `getStatusForPolicy` *after* `constructor`, because it
        // arrives on a separate partial interface. V8 can only put
        // `constructor` last, so it sits before it here.
        pub const createSession = bridge.function(MediaKeys.createSession, .{});
        pub const setServerCertificate = bridge.function(MediaKeys.setServerCertificate, .{ .arity = 1 });
        // Arity 0: the policy dictionary is optional (measured).
        pub const getStatusForPolicy = bridge.function(MediaKeys.getStatusForPolicy, .{});
    };
};

/// A session that was created and can never be initialised. Every operation
/// past `generateRequest` needs a license, and there is none, so they answer
/// the way Chrome answers a session that never got one.
pub const MediaKeySession = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,
    /// Set by the first `generateRequest`, whether or not it went on to
    /// succeed. Chrome marks the session initialised before it validates the
    /// init data type, so a refused type still burns the session (measured).
    _initialized: bool = false,
    _key_statuses: MediaKeyStatusMap = .{},
    /// Created once and kept: Chrome hands back the same promise every time.
    _closed: ?js.Promise.Global = null,

    pub fn asEventTarget(self: *MediaKeySession) *EventTarget {
        return self._proto;
    }

    /// Empty until a license arrives (measured on a fresh session).
    pub fn getSessionId(_: *const MediaKeySession) []const u8 {
        return "";
    }

    pub fn getExpiration(_: *const MediaKeySession) f64 {
        return std.math.nan(f64);
    }

    pub fn getClosed(self: *MediaKeySession, exec: *const Execution) !js.Promise {
        const local = exec.js.local.?;
        if (self._closed) |closed| {
            return closed.local(local);
        }
        // Never settled: the session is never closed, because it was never
        // opened. Chrome's own `closed` on such a session is still pending
        // after the microtask queue drains (measured).
        const resolver = local.createPromiseResolver();
        const promise = resolver.promise();
        promise.markAsHandled();
        self._closed = try promise.persist();
        return promise;
    }

    pub fn getKeyStatuses(self: *MediaKeySession) *MediaKeyStatusMap {
        return &self._key_statuses;
    }

    /// The one operation that changes anything: it marks the session
    /// initialised. It cannot go further -- there is no CDM to build a licence
    /// request for -- so a recognised init data type lands on the same
    /// "not callable" refusal the others use.
    pub fn generateRequest(
        self: *MediaKeySession,
        init_data_type_: ?[]const u8,
        init_data_: ?js.Value,
        exec: *const Execution,
    ) js.Promise {
        const init_data_type = init_data_type_ orelse return rejectType(
            "Failed to execute 'generateRequest' on 'MediaKeySession': 2 arguments required, but only 0 present.",
            exec,
        );
        const init_data_value = init_data_ orelse return rejectType(
            "Failed to execute 'generateRequest' on 'MediaKeySession': 2 arguments required, but only 1 present.",
            exec,
        );
        // The WebIDL conversion runs before the algorithm, so a bad buffer is
        // refused without touching the session.
        const init_data = bufferSource(init_data_value) orelse return rejectType(
            notBufferSource("generateRequest", "MediaKeySession"),
            exec,
        );
        if (self._initialized) {
            return rejectDom(
                "InvalidStateError",
                "Failed to execute 'generateRequest' on 'MediaKeySession': The session is already initialized.",
                exec,
            );
        }
        // Step 3 of the spec, and Chrome really does it here: the session is
        // burnt even by a call that goes on to be refused (measured -- a second
        // generateRequest after a bad init data type says "already initialized").
        self._initialized = true;
        if (init_data_type.len == 0) {
            return rejectType(
                "Failed to execute 'generateRequest' on 'MediaKeySession': The initDataType parameter is empty.",
                exec,
            );
        }
        if (init_data.len == 0) {
            return rejectType(
                "Failed to execute 'generateRequest' on 'MediaKeySession': The initData parameter is empty.",
                exec,
            );
        }
        if (!known(&init_data_types, init_data_type)) {
            const message = std.fmt.allocPrint(
                exec.call_arena,
                "Failed to execute 'generateRequest' on 'MediaKeySession': The initialization data " ++
                    "type '{s}' is not supported.",
                .{init_data_type},
            ) catch return rejectType("Failed to execute 'generateRequest' on 'MediaKeySession'.", exec);
            return rejectDom("NotSupportedError", message, exec);
        }
        return notCallable("generateRequest", exec);
    }

    pub fn load(_: *MediaKeySession, session_id_: ?[]const u8, exec: *const Execution) js.Promise {
        const session_id = session_id_ orelse return rejectType(
            "Failed to execute 'load' on 'MediaKeySession': 1 argument required, but only 0 present.",
            exec,
        );
        if (session_id.len == 0) {
            return rejectType(
                "Failed to execute 'load' on 'MediaKeySession': The sessionId parameter is empty.",
                exec,
            );
        }
        return notCallable("load", exec);
    }

    pub fn update(_: *MediaKeySession, response_: ?js.Value, exec: *const Execution) js.Promise {
        const response = response_ orelse return rejectType(
            "Failed to execute 'update' on 'MediaKeySession': 1 argument required, but only 0 present.",
            exec,
        );
        _ = bufferSource(response) orelse return rejectType(
            notBufferSource("update", "MediaKeySession"),
            exec,
        );
        return notCallable("update", exec);
    }

    pub fn close(_: *MediaKeySession, exec: *const Execution) js.Promise {
        return notCallable("close", exec);
    }

    pub fn remove(_: *MediaKeySession, exec: *const Execution) js.Promise {
        return notCallable("remove", exec);
    }

    /// Chrome's wording for an operation that needs a session the CDM knows
    /// about, on one it does not.
    fn notCallable(comptime member: []const u8, exec: *const Execution) js.Promise {
        return rejectDom(
            "InvalidStateError",
            "Failed to execute '" ++ member ++ "' on 'MediaKeySession': The session is not callable.",
            exec,
        );
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaKeySession);

        pub const Meta = struct {
            pub const name = "MediaKeySession";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = EventTarget;

        // Chrome's own prototype order.
        pub const sessionId = bridge.accessor(MediaKeySession.getSessionId, null, .{});
        pub const expiration = bridge.accessor(MediaKeySession.getExpiration, null, .{});
        pub const closed = bridge.accessor(MediaKeySession.getClosed, null, .{});
        pub const keyStatuses = bridge.accessor(MediaKeySession.getKeyStatuses, null, .{});
        pub const onkeystatuseschange = bridge.accessor(handlerProperty(MediaKeySession, .onkeystatuseschange).get, handlerProperty(MediaKeySession, .onkeystatuseschange).set, .{});
        pub const onmessage = bridge.accessor(handlerProperty(MediaKeySession, .onmessage).get, handlerProperty(MediaKeySession, .onmessage).set, .{});
        pub const close = bridge.function(MediaKeySession.close, .{});
        pub const generateRequest = bridge.function(MediaKeySession.generateRequest, .{ .arity = 2 });
        pub const load = bridge.function(MediaKeySession.load, .{ .arity = 1 });
        pub const remove = bridge.function(MediaKeySession.remove, .{});
        pub const update = bridge.function(MediaKeySession.update, .{ .arity = 1 });
    };
};

/// A readonly maplike of key id to status. Always empty: a status arrives with
/// a license, and no license ever does.
pub const MediaKeyStatusMap = struct {
    const Pair = struct { []const u8, []const u8 };

    _entries: []const Pair = &.{},

    pub fn getSize(self: *const MediaKeyStatusMap) u32 {
        return @intCast(self._entries.len);
    }

    pub fn get(_: *const MediaKeyStatusMap, key_: ?js.Value, exec: *const Execution) !?[]const u8 {
        if (key_ == null) {
            return throwTypeError(
                "Failed to execute 'get' on 'MediaKeyStatusMap': 1 argument required, but only 0 present.",
                exec,
            );
        }
        return null;
    }

    pub fn has(_: *const MediaKeyStatusMap, key_: ?js.Value, exec: *const Execution) !bool {
        if (key_ == null) {
            return throwTypeError(
                "Failed to execute 'has' on 'MediaKeyStatusMap': 1 argument required, but only 0 present.",
                exec,
            );
        }
        return false;
    }

    pub fn keys(self: *MediaKeyStatusMap, frame: *Frame) !*KeyIterator {
        return .init(.{ .map = self }, frame);
    }

    pub fn values(self: *MediaKeyStatusMap, frame: *Frame) !*ValueIterator {
        return .init(.{ .map = self }, frame);
    }

    pub fn entries(self: *MediaKeyStatusMap, frame: *Frame) !*EntryIterator {
        return .init(.{ .map = self }, frame);
    }

    pub fn forEach(self: *MediaKeyStatusMap, cb_: js.Function, js_this_: ?js.Object) !void {
        const cb = if (js_this_) |js_this| try cb_.withThis(js_this) else cb_;
        for (self._entries) |pair| {
            var caught: js.TryCatch.Caught = .{};
            cb.tryCall(void, .{ pair[1], pair[0], self }, &caught) catch {
                lp.log.debug(.js, "forEach callback", .{ .caught = caught, .source = "MediaKeyStatusMap" });
            };
        }
    }

    pub const Iterator = struct {
        index: u32 = 0,
        map: *MediaKeyStatusMap,

        pub const Entry = Pair;

        pub fn next(self: *Iterator, _: *const Frame) ?Entry {
            const index = self.index;
            if (index >= self.map._entries.len) {
                return null;
            }
            self.index = index + 1;
            return self.map._entries[index];
        }
    };

    const GenericIterator = @import("../collections/iterator.zig").Entry;
    pub const KeyIterator = GenericIterator(Iterator, "0");
    pub const ValueIterator = GenericIterator(Iterator, "1");
    pub const EntryIterator = GenericIterator(Iterator, null);

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaKeyStatusMap);

        pub const Meta = struct {
            pub const name = "MediaKeyStatusMap";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        // Chrome's own prototype order.
        pub const size = bridge.accessor(MediaKeyStatusMap.getSize, null, .{});
        pub const get = bridge.function(MediaKeyStatusMap.get, .{ .arity = 1, .null_as_undefined = true });
        pub const has = bridge.function(MediaKeyStatusMap.has, .{ .arity = 1 });
        pub const entries = bridge.function(MediaKeyStatusMap.entries, .{});
        pub const forEach = bridge.function(MediaKeyStatusMap.forEach, .{ .arity = 1 });
        pub const keys = bridge.function(MediaKeyStatusMap.keys, .{});
        pub const values = bridge.function(MediaKeyStatusMap.values, .{});
        pub const symbol_iterator = bridge.iterator(MediaKeyStatusMap.entries, .{});
    };
};

// == The two events ==

fn readEventType(comptime interface: []const u8, type_: ?js.Value, exec: *const Execution) ![]const u8 {
    const value = type_ orelse return throwTypeError(
        "Failed to construct '" ++ interface ++ "': 1 argument required, but only 0 present.",
        exec,
    );
    return value.toStringSlice();
}

fn buildEvent(child: anytype, typ: []const u8, options_: ?js.Value, exec: *const Execution) !*@TypeOf(child) {
    const arena = try exec.getArena(.tiny, @TypeOf(child).JsApi.Meta.name);
    errdefer arena.release();
    return buildEventIn(arena, child, typ, options_, exec);
}

// Same, for a caller that had to acquire the arena first because a member of
// `child` is allocated from it. The event takes the arena over, so the string
// lives exactly as long as the event does -- releasing it before handing it to
// the factory leaves the member dangling.
fn buildEventIn(arena: *lp.Arena, child: anytype, typ: []const u8, options_: ?js.Value, exec: *const Execution) !*@TypeOf(child) {
    const options = try Event.optionsFromJs(options_);
    const event = try exec._factory.event(arena, try String.init(arena.allocator(), typ, .{}), child);
    Event.populatePrototypes(event, options, false);
    return event;
}

/// The licence-request event. Both of its members are required, so the init
/// dictionary is too -- which is why its arity is 2 rather than 1.
pub const MediaKeyMessageEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _message_type: []const u8,
    _message: ?js.Value.Global,

    const message_types = [_][]const u8{
        "license-request",
        "license-renewal",
        "license-release",
        "individualization-request",
    };

    const Init = dictionary.Init("MediaKeyMessageEvent", "MediaKeyMessageEventInit");

    pub fn constructor(
        type_: ?js.Value,
        options_: ?js.Value,
        exec: *const Execution,
    ) !*MediaKeyMessageEvent {
        const typ = try readEventType("MediaKeyMessageEvent", type_, exec);
        // Both members are required, so the init dictionary is too -- and an
        // explicit null or undefined is refused as "not of type" rather than
        // counted as a missing argument (measured).
        const options = options_ orelse return throwTypeError(
            "Failed to construct 'MediaKeyMessageEvent': 2 arguments required, but only 1 present.",
            exec,
        );
        const init = try Init.readRequired(options, exec);

        const message_type = (try init.enumMember(
            "messageType",
            "MediaKeyMessageType",
            &message_types,
            null,
            exec,
        )) orelse return Init.missingMember("messageType", exec);

        // `message` is a plain `ArrayBuffer`, not a BufferSource: a Uint8Array
        // over one is refused (measured).
        const message = try init.required("message", exec);
        if (!message.isArrayBuffer()) {
            return Init.convertFailed("message", "ArrayBuffer", exec);
        }

        return buildEvent(MediaKeyMessageEvent{
            ._proto = undefined,
            ._message_type = message_type,
            ._message = try message.persist(),
        }, typ, options_, exec);
    }

    pub fn getMessageType(self: *const MediaKeyMessageEvent) []const u8 {
        return self._message_type;
    }

    pub fn getMessage(self: *const MediaKeyMessageEvent) ?js.Value.Global {
        return self._message;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaKeyMessageEvent);

        pub const Meta = struct {
            pub const name = "MediaKeyMessageEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = Event;

        pub const constructor = bridge.constructor(MediaKeyMessageEvent.constructor, .{ .arity = 2 });
        pub const messageType = bridge.accessor(MediaKeyMessageEvent.getMessageType, null, .{});
        pub const message = bridge.accessor(MediaKeyMessageEvent.getMessage, null, .{});
    };
};

/// The event a media element fires when it meets encrypted content. Unlike the
/// message event both members have defaults, so `new MediaEncryptedEvent('x')`
/// works and reads back `""` and null.
pub const MediaEncryptedEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _init_data_type: []const u8 = "",
    _init_data: ?js.Value.Global = null,

    const Init = dictionary.Init("MediaEncryptedEvent", "MediaEncryptedEventInit");

    pub fn constructor(
        type_: ?js.Value,
        options_: ?js.Value,
        exec: *const Execution,
    ) !*MediaEncryptedEvent {
        const typ = try readEventType("MediaEncryptedEvent", type_, exec);
        const init = try Init.read(options_, exec);

        // The arena that will own the event, acquired up front: initDataType is
        // a free-form DOMString, so it has to be allocated from the event's own
        // arena rather than from one released before the event is built.
        const arena = try exec.getArena(.tiny, "MediaEncryptedEvent");
        errdefer arena.release();
        const init_data_type = try init.string("initDataType", "", arena.allocator());

        var init_data: ?js.Value.Global = null;
        if (try init.present("initData")) |member| {
            if (!member.isNull()) {
                if (!member.isArrayBuffer()) {
                    // The errdefer above releases the arena; releasing here too
                    // would return it to the pool twice.
                    return Init.convertFailed("initData", "ArrayBuffer", exec);
                }
                init_data = try member.persist();
            }
        }

        return buildEventIn(arena, MediaEncryptedEvent{
            ._proto = undefined,
            ._init_data_type = init_data_type,
            ._init_data = init_data,
        }, typ, options_, exec);
    }

    pub fn getInitDataType(self: *const MediaEncryptedEvent) []const u8 {
        return self._init_data_type;
    }

    pub fn getInitData(self: *const MediaEncryptedEvent) ?js.Value.Global {
        return self._init_data;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(MediaEncryptedEvent);

        pub const Meta = struct {
            pub const name = "MediaEncryptedEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = Event;

        pub const constructor = bridge.constructor(MediaEncryptedEvent.constructor, .{ .arity = 1 });
        pub const initDataType = bridge.accessor(MediaEncryptedEvent.getInitDataType, null, .{});
        pub const initData = bridge.accessor(MediaEncryptedEvent.getInitData, null, .{});
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: EME" {
    try testing.htmlRunner("media/eme.html", .{});
}
