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

// The twelve leftover Event subclasses a Chrome window carries. None of them is
// ever dispatched here -- there is no animation timeline, no install prompt, no
// media recorder, no clipboard paste, no content-visibility pass, no
// picture-in-picture, no CSP report, no track change, no lost GL context, no
// virtual keyboard, no window-controls overlay and no intercepted navigation --
// but every one is constructible from script, so the dictionary each one reads
// is reachable and its errors are part of the surface.
//
// Every constructor here reads its dictionary by hand. The bridge's typed
// dictionaries cannot produce the three messages Chrome gives ("Required member
// is undefined.", "Failed to convert value to 'X'.", "The provided value is not
// of type 'XInit'."), and those messages are exactly what a detector reads back
// when it feeds a constructor the wrong thing.
//
// Measured on a headed Chrome 150; see
// tools/fingerprint/scratch/win-batch/probe-win29.js and
// probe-win30.js for the captures each default below comes from.

const std = @import("std");
const lp = @import("lightpanda");

const js = @import("../../js/js.zig");
const Blob = @import("../Blob.zig");
const Event = @import("../Event.zig");
const DOMRect = @import("../DOMRect.zig");
const DOMException = @import("../DOMException.zig");
const DataTransfer = @import("../DataTransfer.zig");
const dictionary = @import("../dictionary.zig");
const TextTrack = @import("../media/text_tracks.zig").TextTrack;
const PictureInPictureWindow = @import("../media/PictureInPictureWindow.zig");

const String = lp.String;
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        AnimationPlaybackEvent,
        BeforeInstallPromptEvent,
        BlobEvent,
        ClipboardEvent,
        ContentVisibilityAutoStateChangeEvent,
        NavigateEvent,
        PictureInPictureEvent,
        SecurityPolicyViolationEvent,
        TrackEvent,
        VirtualKeyboardGeometryChangeEvent,
        WebGLContextEvent,
        WindowControlsOverlayGeometryChangeEvent,
    };
}

const throwTypeError = dictionary.throwTypeError;
const Init = dictionary.Init;

fn rejectDom(comptime name: []const u8, message: []const u8, exec: *const Execution) js.Promise {
    var resolver = exec.js.local.?.createPromiseResolver();
    resolver.reject("misc_events", DOMException.init(message, name));
    return resolver.promise();
}

/// Reads the type argument, with Chrome's count message when it is missing.
/// Every constructor in this file declares its arity, so the bridge has already
/// rejected a call with too few arguments by the time this runs -- this is the
/// conversion, not the check.
fn eventType(value_: ?js.Value, allocator: std.mem.Allocator) !String {
    const value = value_ orelse return String.init(allocator, "undefined", .{});
    const slice = try value.toStringSlice();
    return String.init(allocator, slice, .{});
}

// ---------------------------------------------------------------------------
// AnimationPlaybackEvent

/// `animation.onfinish`'s payload. Both members are nullable doubles that
/// default to null even on an event a page fills in (measured).
pub const AnimationPlaybackEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _current_time: ?f64 = null,
    _timeline_time: ?f64 = null,

    const Reader = Init("AnimationPlaybackEvent", "AnimationPlaybackEventInit");

    pub fn constructor(type_: ?js.Value, options_: ?js.Value, exec: *const Execution) !*AnimationPlaybackEvent {
        const init = try Reader.read(options_, exec);
        const current_time = try init.nullableDouble("currentTime", exec);
        const timeline_time = try init.nullableDouble("timelineTime", exec);

        const arena = try exec.getArena(.tiny, "AnimationPlaybackEvent");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try eventType(type_, arena.allocator()),
            AnimationPlaybackEvent{
                ._proto = undefined,
                ._current_time = current_time,
                ._timeline_time = timeline_time,
            },
        );
        Event.populatePrototypes(event, init.event, false);
        return event;
    }

    pub fn asEvent(self: *AnimationPlaybackEvent) *Event {
        return self._proto;
    }

    pub fn getCurrentTime(self: *const AnimationPlaybackEvent) ?f64 {
        return self._current_time;
    }

    pub fn getTimelineTime(self: *const AnimationPlaybackEvent) ?f64 {
        return self._timeline_time;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(AnimationPlaybackEvent);

        pub const Meta = struct {
            pub const name = "AnimationPlaybackEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(AnimationPlaybackEvent.constructor, .{ .arity = 1 });
        pub const currentTime = bridge.accessor(AnimationPlaybackEvent.getCurrentTime, null, .{});
        pub const timelineTime = bridge.accessor(AnimationPlaybackEvent.getTimelineTime, null, .{});
    };
};

// ---------------------------------------------------------------------------
// BeforeInstallPromptEvent

/// The install prompt. Its two members are the odd ones out: `platforms` is a
/// fresh array on every read and `userChoice` is a fresh *rejected* promise,
/// because only the event the browser itself fires can answer them (measured:
/// both `e.platforms === e.platforms` and `e.userChoice === e.userChoice` are
/// false, and awaiting userChoice is an InvalidStateError).
pub const BeforeInstallPromptEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _platforms: []const []const u8 = &.{},

    const Reader = Init("BeforeInstallPromptEvent", "BeforeInstallPromptEventInit");

    pub fn constructor(type_: ?js.Value, options_: ?js.Value, exec: *const Execution) !*BeforeInstallPromptEvent {
        const init = try Reader.read(options_, exec);

        const arena = try exec.getArena(.tiny, "BeforeInstallPromptEvent");
        errdefer arena.release();
        const allocator = arena.allocator();

        var platforms: []const []const u8 = &.{};
        if (try init.present("platforms")) |member| {
            if (member.isArray()) {
                const array = member.toArray();
                const len: u32 = @intCast(array.len());
                const list = try allocator.alloc([]const u8, len);
                for (list, 0..) |*entry, i| {
                    const item = try array.get(@intCast(i));
                    entry.* = try item.toStringSliceWithAlloc(allocator);
                }
                platforms = list;
            }
        }

        const event = try exec._factory.event(
            arena,
            try eventType(type_, allocator),
            BeforeInstallPromptEvent{ ._proto = undefined, ._platforms = platforms },
        );
        Event.populatePrototypes(event, init.event, false);
        return event;
    }

    pub fn asEvent(self: *BeforeInstallPromptEvent) *Event {
        return self._proto;
    }

    pub fn getPlatforms(self: *const BeforeInstallPromptEvent) []const []const u8 {
        return self._platforms;
    }

    pub fn getUserChoice(_: *const BeforeInstallPromptEvent, exec: *const Execution) js.Promise {
        return rejectDom(
            "InvalidStateError",
            "Failed to read the 'userChoice' property from 'BeforeInstallPromptEvent': " ++
                "userChoice cannot be accessed on this event.",
            exec,
        );
    }

    pub fn prompt(_: *BeforeInstallPromptEvent, exec: *const Execution) js.Promise {
        return rejectDom(
            "InvalidStateError",
            "Failed to execute 'prompt' on 'BeforeInstallPromptEvent': The prompt() method cannot be called.",
            exec,
        );
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(BeforeInstallPromptEvent);

        pub const Meta = struct {
            pub const name = "BeforeInstallPromptEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(BeforeInstallPromptEvent.constructor, .{ .arity = 1 });
        pub const platforms = bridge.accessor(BeforeInstallPromptEvent.getPlatforms, null, .{});
        pub const userChoice = bridge.accessor(BeforeInstallPromptEvent.getUserChoice, null, .{});
        pub const prompt = bridge.function(BeforeInstallPromptEvent.prompt, .{});
    };
};

// ---------------------------------------------------------------------------
// BlobEvent

/// MediaRecorder's `ondataavailable` payload. `data` is required and must be a
/// Blob, so this is one of the few events in this file a page can build in full.
pub const BlobEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _data: *Blob,
    _timecode: f64 = 0,

    const Reader = Init("BlobEvent", "BlobEventInit");

    pub fn constructor(type_: ?js.Value, options_: ?js.Value, exec: *const Execution) !*BlobEvent {
        const init = try Reader.read(options_, exec);
        const data = try init.interfaceMember("data", Blob, "Blob", exec);
        const timecode = try init.double("timecode", 0, exec);

        const arena = try exec.getArena(.tiny, "BlobEvent");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try eventType(type_, arena.allocator()),
            BlobEvent{ ._proto = undefined, ._data = data, ._timecode = timecode },
        );
        Event.populatePrototypes(event, init.event, false);
        return event;
    }

    pub fn asEvent(self: *BlobEvent) *Event {
        return self._proto;
    }

    pub fn getData(self: *const BlobEvent) *Blob {
        return self._data;
    }

    pub fn getTimecode(self: *const BlobEvent) f64 {
        return self._timecode;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(BlobEvent);

        pub const Meta = struct {
            pub const name = "BlobEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(BlobEvent.constructor, .{ .arity = 2 });
        pub const data = bridge.accessor(BlobEvent.getData, null, .{});
        pub const timecode = bridge.accessor(BlobEvent.getTimecode, null, .{});
    };
};

// ---------------------------------------------------------------------------
// ClipboardEvent

/// cut / copy / paste. `clipboardData` is nullable and defaults to null, and a
/// page can hand in a DataTransfer it built itself -- the event keeps that very
/// object (measured: `e.clipboardData === dt`).
pub const ClipboardEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _clipboard_data: ?*DataTransfer = null,

    const Reader = Init("ClipboardEvent", "ClipboardEventInit");

    pub fn constructor(type_: ?js.Value, options_: ?js.Value, exec: *const Execution) !*ClipboardEvent {
        const init = try Reader.read(options_, exec);
        const data = try init.nullableInterface("clipboardData", DataTransfer, "DataTransfer", exec);

        const arena = try exec.getArena(.tiny, "ClipboardEvent");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try eventType(type_, arena.allocator()),
            ClipboardEvent{ ._proto = undefined, ._clipboard_data = data },
        );
        Event.populatePrototypes(event, init.event, false);
        return event;
    }

    pub fn asEvent(self: *ClipboardEvent) *Event {
        return self._proto;
    }

    pub fn getClipboardData(self: *const ClipboardEvent) ?*DataTransfer {
        return self._clipboard_data;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ClipboardEvent);

        pub const Meta = struct {
            pub const name = "ClipboardEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(ClipboardEvent.constructor, .{ .arity = 1 });
        pub const clipboardData = bridge.accessor(ClipboardEvent.getClipboardData, null, .{});
    };
};

// ---------------------------------------------------------------------------
// ContentVisibilityAutoStateChangeEvent

/// `content-visibility: auto` skipping or unskipping a subtree. No layout here,
/// so nothing fires it; `skipped` is a plain boolean member.
pub const ContentVisibilityAutoStateChangeEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _skipped: bool = false,

    const Reader = Init(
        "ContentVisibilityAutoStateChangeEvent",
        "ContentVisibilityAutoStateChangeEventInit",
    );

    pub fn constructor(
        type_: ?js.Value,
        options_: ?js.Value,
        exec: *const Execution,
    ) !*ContentVisibilityAutoStateChangeEvent {
        const init = try Reader.read(options_, exec);
        const skipped = try init.boolean("skipped", false);

        const arena = try exec.getArena(.tiny, "ContentVisibilityAutoStateChangeEvent");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try eventType(type_, arena.allocator()),
            ContentVisibilityAutoStateChangeEvent{ ._proto = undefined, ._skipped = skipped },
        );
        Event.populatePrototypes(event, init.event, false);
        return event;
    }

    pub fn asEvent(self: *ContentVisibilityAutoStateChangeEvent) *Event {
        return self._proto;
    }

    pub fn getSkipped(self: *const ContentVisibilityAutoStateChangeEvent) bool {
        return self._skipped;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ContentVisibilityAutoStateChangeEvent);

        pub const Meta = struct {
            pub const name = "ContentVisibilityAutoStateChangeEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(
            ContentVisibilityAutoStateChangeEvent.constructor,
            .{ .arity = 1 },
        );
        pub const skipped = bridge.accessor(ContentVisibilityAutoStateChangeEvent.getSkipped, null, .{});
    };
};

// ---------------------------------------------------------------------------
// NavigateEvent

/// `navigation.onnavigate`. Its `destination` is a required, non-nullable
/// NavigationDestination, and nothing a page can hold is one -- the interface
/// has an Illegal constructor and the only instances come from an event the
/// browser fires. So every page-side construction ends in one of the two
/// messages below, which is exactly what Chrome does (measured: `{destination:
/// null}` is the conversion failure, an empty dictionary the missing member).
/// The accessors are therefore unreachable; they answer the IDL defaults.
pub const NavigateEvent = struct {
    pub const Proto = Event;

    _proto: *Event,

    const Reader = Init("NavigateEvent", "NavigateEventInit");

    pub fn constructor(_: ?js.Value, options_: ?js.Value, exec: *const Execution) !*NavigateEvent {
        const init = try Reader.read(options_, exec);
        _ = try init.required("destination", exec);
        return Reader.convertFailed("destination", "NavigationDestination", exec);
    }

    pub fn asEvent(self: *NavigateEvent) *Event {
        return self._proto;
    }

    pub fn getNavigationType(_: *const NavigateEvent) []const u8 {
        return "push";
    }

    pub fn getDestination(_: *const NavigateEvent) ?js.Value {
        return null;
    }

    pub fn getCanIntercept(_: *const NavigateEvent) bool {
        return false;
    }

    pub fn getUserInitiated(_: *const NavigateEvent) bool {
        return false;
    }

    pub fn getHashChange(_: *const NavigateEvent) bool {
        return false;
    }

    pub fn getSignal(_: *const NavigateEvent) ?js.Value {
        return null;
    }

    pub fn getFormData(_: *const NavigateEvent) ?js.Value {
        return null;
    }

    pub fn getDownloadRequest(_: *const NavigateEvent) ?[]const u8 {
        return null;
    }

    pub fn getInfo(_: *const NavigateEvent) ?js.Value {
        return null;
    }

    pub fn getSourceElement(_: *const NavigateEvent) ?js.Value {
        return null;
    }

    pub fn getHasUAVisualTransition(_: *const NavigateEvent) bool {
        return false;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(NavigateEvent);

        pub const Meta = struct {
            pub const name = "NavigateEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        fn unreachableMethod(_: *NavigateEvent, _: ?js.Value) void {}

        pub const constructor = bridge.constructor(NavigateEvent.constructor, .{ .arity = 2 });
        pub const navigationType = bridge.accessor(NavigateEvent.getNavigationType, null, .{});
        pub const destination = bridge.accessor(NavigateEvent.getDestination, null, .{});
        pub const canIntercept = bridge.accessor(NavigateEvent.getCanIntercept, null, .{});
        pub const userInitiated = bridge.accessor(NavigateEvent.getUserInitiated, null, .{});
        pub const hashChange = bridge.accessor(NavigateEvent.getHashChange, null, .{});
        pub const signal = bridge.accessor(NavigateEvent.getSignal, null, .{});
        pub const formData = bridge.accessor(NavigateEvent.getFormData, null, .{});
        pub const downloadRequest = bridge.accessor(NavigateEvent.getDownloadRequest, null, .{});
        pub const info = bridge.accessor(NavigateEvent.getInfo, null, .{});
        pub const sourceElement = bridge.accessor(NavigateEvent.getSourceElement, null, .{});
        pub const intercept = bridge.function(unreachableMethod, .{ .noop = true, .arity = 0 });
        pub const scroll = bridge.function(unreachableMethod, .{ .noop = true, .arity = 0 });
        pub const hasUAVisualTransition = bridge.accessor(NavigateEvent.getHasUAVisualTransition, null, .{});
    };
};

// ---------------------------------------------------------------------------
// PictureInPictureEvent

/// `onenterpictureinpicture`. Like NavigateEvent, its required member is an
/// interface a page cannot hold, so both arms of the dictionary check are all
/// that is observable.
pub const PictureInPictureEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _window: ?*PictureInPictureWindow = null,

    const Reader = Init("PictureInPictureEvent", "PictureInPictureEventInit");

    pub fn constructor(type_: ?js.Value, options_: ?js.Value, exec: *const Execution) !*PictureInPictureEvent {
        const init = try Reader.read(options_, exec);
        const window = try init.interfaceMember(
            "pictureInPictureWindow",
            PictureInPictureWindow,
            "PictureInPictureWindow",
            exec,
        );

        const arena = try exec.getArena(.tiny, "PictureInPictureEvent");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try eventType(type_, arena.allocator()),
            PictureInPictureEvent{ ._proto = undefined, ._window = window },
        );
        Event.populatePrototypes(event, init.event, false);
        return event;
    }

    pub fn asEvent(self: *PictureInPictureEvent) *Event {
        return self._proto;
    }

    pub fn getPictureInPictureWindow(self: *const PictureInPictureEvent) ?*PictureInPictureWindow {
        return self._window;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PictureInPictureEvent);

        pub const Meta = struct {
            pub const name = "PictureInPictureEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(PictureInPictureEvent.constructor, .{ .arity = 2 });
        pub const pictureInPictureWindow = bridge.accessor(
            PictureInPictureEvent.getPictureInPictureWindow,
            null,
            .{},
        );
    };
};

// ---------------------------------------------------------------------------
// SecurityPolicyViolationEvent

/// The CSP report event. The engine enforces page CSP but does not fire this
/// yet; a page can build one, and when it does, bubbles and composed are true
/// and cancelable false *whatever the dictionary says* -- measured with
/// `{bubbles: false, composed: false, cancelable: true}`, which changed none of
/// the three. Chrome hard-codes them, so the EventInit members are read and
/// dropped here too.
pub const SecurityPolicyViolationEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _document_uri: []const u8 = "",
    _referrer: []const u8 = "",
    _blocked_uri: []const u8 = "",
    _violated_directive: []const u8 = "",
    _effective_directive: []const u8 = "",
    _original_policy: []const u8 = "",
    _disposition: Disposition = .enforce,
    _source_file: []const u8 = "",
    _sample: []const u8 = "",
    _status_code: u16 = 0,
    _line_number: i32 = 0,
    _column_number: i32 = 0,

    pub const Disposition = enum { enforce, report };

    const Reader = Init("SecurityPolicyViolationEvent", "SecurityPolicyViolationEventInit");

    pub fn constructor(
        type_: ?js.Value,
        options_: ?js.Value,
        exec: *const Execution,
    ) !*SecurityPolicyViolationEvent {
        const init = try Reader.read(options_, exec);

        var disposition: Disposition = .enforce;
        if (try init.present("disposition")) |member| {
            const slice = try member.toStringSlice();
            disposition = std.meta.stringToEnum(Disposition, slice) orelse {
                const message = try std.fmt.allocPrint(
                    exec.call_arena,
                    "Failed to construct 'SecurityPolicyViolationEvent': Failed to read the " ++
                        "'disposition' property from 'SecurityPolicyViolationEventInit': The provided " ++
                        "value '{s}' is not a valid enum value of type SecurityPolicyViolationEventDisposition.",
                    .{slice},
                );
                return throwTypeError(message, exec);
            };
        }

        const status_code = try init.long("statusCode", 0);
        const line_number = try init.long("lineNumber", 0);
        const column_number = try init.long("columnNumber", 0);

        const arena = try exec.getArena(.tiny, "SecurityPolicyViolationEvent");
        errdefer arena.release();
        const allocator = arena.allocator();

        const event = try exec._factory.event(
            arena,
            try eventType(type_, allocator),
            SecurityPolicyViolationEvent{
                ._proto = undefined,
                ._document_uri = try init.string("documentURI", "", allocator),
                ._referrer = try init.string("referrer", "", allocator),
                ._blocked_uri = try init.string("blockedURI", "", allocator),
                ._violated_directive = try init.string("violatedDirective", "", allocator),
                ._effective_directive = try init.string("effectiveDirective", "", allocator),
                ._original_policy = try init.string("originalPolicy", "", allocator),
                ._disposition = disposition,
                ._source_file = try init.string("sourceFile", "", allocator),
                ._sample = try init.string("sample", "", allocator),
                ._status_code = @truncate(@as(u32, @bitCast(status_code))),
                ._line_number = line_number,
                ._column_number = column_number,
            },
        );

        // Not init.event: Chrome ignores the EventInit members here.
        Event.populatePrototypes(event, Event.Options{
            .bubbles = true,
            .cancelable = false,
            .composed = true,
        }, false);
        return event;
    }

    pub fn asEvent(self: *SecurityPolicyViolationEvent) *Event {
        return self._proto;
    }

    pub fn getDocumentURI(self: *const SecurityPolicyViolationEvent) []const u8 {
        return self._document_uri;
    }

    pub fn getReferrer(self: *const SecurityPolicyViolationEvent) []const u8 {
        return self._referrer;
    }

    pub fn getBlockedURI(self: *const SecurityPolicyViolationEvent) []const u8 {
        return self._blocked_uri;
    }

    pub fn getViolatedDirective(self: *const SecurityPolicyViolationEvent) []const u8 {
        return self._violated_directive;
    }

    pub fn getEffectiveDirective(self: *const SecurityPolicyViolationEvent) []const u8 {
        return self._effective_directive;
    }

    pub fn getOriginalPolicy(self: *const SecurityPolicyViolationEvent) []const u8 {
        return self._original_policy;
    }

    pub fn getDisposition(self: *const SecurityPolicyViolationEvent) []const u8 {
        return @tagName(self._disposition);
    }

    pub fn getSourceFile(self: *const SecurityPolicyViolationEvent) []const u8 {
        return self._source_file;
    }

    pub fn getStatusCode(self: *const SecurityPolicyViolationEvent) u16 {
        return self._status_code;
    }

    pub fn getLineNumber(self: *const SecurityPolicyViolationEvent) i32 {
        return self._line_number;
    }

    pub fn getColumnNumber(self: *const SecurityPolicyViolationEvent) i32 {
        return self._column_number;
    }

    pub fn getSample(self: *const SecurityPolicyViolationEvent) []const u8 {
        return self._sample;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(SecurityPolicyViolationEvent);

        pub const Meta = struct {
            pub const name = "SecurityPolicyViolationEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(SecurityPolicyViolationEvent.constructor, .{ .arity = 1 });
        pub const documentURI = bridge.accessor(SecurityPolicyViolationEvent.getDocumentURI, null, .{});
        pub const referrer = bridge.accessor(SecurityPolicyViolationEvent.getReferrer, null, .{});
        pub const blockedURI = bridge.accessor(SecurityPolicyViolationEvent.getBlockedURI, null, .{});
        pub const violatedDirective = bridge.accessor(SecurityPolicyViolationEvent.getViolatedDirective, null, .{});
        pub const effectiveDirective = bridge.accessor(SecurityPolicyViolationEvent.getEffectiveDirective, null, .{});
        pub const originalPolicy = bridge.accessor(SecurityPolicyViolationEvent.getOriginalPolicy, null, .{});
        pub const disposition = bridge.accessor(SecurityPolicyViolationEvent.getDisposition, null, .{});
        pub const sourceFile = bridge.accessor(SecurityPolicyViolationEvent.getSourceFile, null, .{});
        pub const statusCode = bridge.accessor(SecurityPolicyViolationEvent.getStatusCode, null, .{});
        pub const lineNumber = bridge.accessor(SecurityPolicyViolationEvent.getLineNumber, null, .{});
        pub const columnNumber = bridge.accessor(SecurityPolicyViolationEvent.getColumnNumber, null, .{});
        pub const sample = bridge.accessor(SecurityPolicyViolationEvent.getSample, null, .{});
    };
};

// ---------------------------------------------------------------------------
// TrackEvent

/// `textTracks.onaddtrack`. Chrome's `track` is a nullable union of the three
/// track interfaces; TextTrack is the only one this engine has, and it is the
/// only one a page can hold, so a value that is neither null nor a TextTrack
/// gets the union's own message.
pub const TrackEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _track: ?*TextTrack = null,

    const Reader = Init("TrackEvent", "TrackEventInit");

    pub fn constructor(type_: ?js.Value, options_: ?js.Value, exec: *const Execution) !*TrackEvent {
        const init = try Reader.read(options_, exec);
        const track = try init.unionMember(
            "track",
            TextTrack,
            "(AudioTrack or TextTrack or VideoTrack)",
            exec,
        );

        const arena = try exec.getArena(.tiny, "TrackEvent");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try eventType(type_, arena.allocator()),
            TrackEvent{ ._proto = undefined, ._track = track },
        );
        Event.populatePrototypes(event, init.event, false);
        return event;
    }

    /// The one the engine fires itself, when addTextTrack appends to a list.
    pub fn initTrusted(typ: []const u8, track: *TextTrack, exec: *const Execution) !*TrackEvent {
        const arena = try exec.getArena(.tiny, "TrackEvent.trusted");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try String.init(arena.allocator(), typ, .{}),
            TrackEvent{ ._proto = undefined, ._track = track },
        );
        Event.populatePrototypes(event, Event.Options{}, true);
        return event;
    }

    pub fn asEvent(self: *TrackEvent) *Event {
        return self._proto;
    }

    pub fn getTrack(self: *const TrackEvent) ?*TextTrack {
        return self._track;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(TrackEvent);

        pub const Meta = struct {
            pub const name = "TrackEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(TrackEvent.constructor, .{ .arity = 1 });
        pub const track = bridge.accessor(TrackEvent.getTrack, null, .{});
    };
};

// ---------------------------------------------------------------------------
// VirtualKeyboardGeometryChangeEvent

/// `navigator.virtualKeyboard.ongeometrychange`. The only event in this file
/// with no members of its own, and the only one whose dictionary is plain
/// EventInit -- which is why a non-object second argument is accepted here
/// rather than a TypeError (measured: `new VirtualKeyboardGeometryChangeEvent
/// ('x', 5).type` is "x", while the same call on an event with its own
/// dictionary throws).
pub const VirtualKeyboardGeometryChangeEvent = struct {
    pub const Proto = Event;

    _proto: *Event,

    /// The dictionary goes through Event.optionsFromJs, which reads the three
    /// EventInit members off an object and shrugs at anything else. A typed
    /// dictionary would have made `new VirtualKeyboardGeometryChangeEvent('x',
    /// 5)` a TypeError, and Chrome accepts it.
    pub fn constructor(
        type_: ?js.Value,
        options_: ?js.Value,
        exec: *const Execution,
    ) !*VirtualKeyboardGeometryChangeEvent {
        const options = try Event.optionsFromJs(options_);

        const arena = try exec.getArena(.tiny, "VirtualKeyboardGeometryChangeEvent");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try eventType(type_, arena.allocator()),
            VirtualKeyboardGeometryChangeEvent{ ._proto = undefined },
        );
        Event.populatePrototypes(event, options, false);
        return event;
    }

    pub fn asEvent(self: *VirtualKeyboardGeometryChangeEvent) *Event {
        return self._proto;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(VirtualKeyboardGeometryChangeEvent);

        pub const Meta = struct {
            pub const name = "VirtualKeyboardGeometryChangeEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(VirtualKeyboardGeometryChangeEvent.constructor, .{ .arity = 1 });
    };
};

// ---------------------------------------------------------------------------
// WebGLContextEvent

/// webglcontextlost / restored / creationerror. The context here is never lost,
/// so only a page-built one exists; `statusMessage` is a plain string member
/// that coerces whatever it is given (measured: 7 reads back as "7").
pub const WebGLContextEvent = struct {
    pub const Proto = Event;

    _proto: *Event,
    _status_message: []const u8 = "",

    const Reader = Init("WebGLContextEvent", "WebGLContextEventInit");

    pub fn constructor(type_: ?js.Value, options_: ?js.Value, exec: *const Execution) !*WebGLContextEvent {
        const init = try Reader.read(options_, exec);

        const arena = try exec.getArena(.tiny, "WebGLContextEvent");
        errdefer arena.release();
        const allocator = arena.allocator();

        const event = try exec._factory.event(
            arena,
            try eventType(type_, allocator),
            WebGLContextEvent{
                ._proto = undefined,
                ._status_message = try init.string("statusMessage", "", allocator),
            },
        );
        Event.populatePrototypes(event, init.event, false);
        return event;
    }

    pub fn asEvent(self: *WebGLContextEvent) *Event {
        return self._proto;
    }

    pub fn getStatusMessage(self: *const WebGLContextEvent) []const u8 {
        return self._status_message;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(WebGLContextEvent);

        pub const Meta = struct {
            pub const name = "WebGLContextEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(WebGLContextEvent.constructor, .{ .arity = 1 });
        pub const statusMessage = bridge.accessor(WebGLContextEvent.getStatusMessage, null, .{});
    };
};

// ---------------------------------------------------------------------------
// WindowControlsOverlayGeometryChangeEvent

/// The installed-app title-bar overlay moving. Its dictionary requires
/// `titlebarAreaRect`, and then Chrome ignores both members: an event built with
/// `{titlebarAreaRect: new DOMRect(1, 2, 3, 4), visible: true}` answers null and
/// false (measured). Only the browser's own event carries the geometry, so the
/// required member is a gate rather than a value.
pub const WindowControlsOverlayGeometryChangeEvent = struct {
    pub const Proto = Event;

    _proto: *Event,

    const Reader = Init(
        "WindowControlsOverlayGeometryChangeEvent",
        "WindowControlsOverlayGeometryChangeEventInit",
    );

    pub fn constructor(
        type_: ?js.Value,
        options_: ?js.Value,
        exec: *const Execution,
    ) !*WindowControlsOverlayGeometryChangeEvent {
        const init = try Reader.read(options_, exec);
        _ = try init.required("titlebarAreaRect", exec);

        const arena = try exec.getArena(.tiny, "WindowControlsOverlayGeometryChangeEvent");
        errdefer arena.release();

        const event = try exec._factory.event(
            arena,
            try eventType(type_, arena.allocator()),
            WindowControlsOverlayGeometryChangeEvent{ ._proto = undefined },
        );
        Event.populatePrototypes(event, init.event, false);
        return event;
    }

    pub fn asEvent(self: *WindowControlsOverlayGeometryChangeEvent) *Event {
        return self._proto;
    }

    pub fn getTitlebarAreaRect(_: *const WindowControlsOverlayGeometryChangeEvent) ?*DOMRect {
        return null;
    }

    pub fn getVisible(_: *const WindowControlsOverlayGeometryChangeEvent) bool {
        return false;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(WindowControlsOverlayGeometryChangeEvent);

        pub const Meta = struct {
            pub const name = "WindowControlsOverlayGeometryChangeEvent";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const constructor = bridge.constructor(
            WindowControlsOverlayGeometryChangeEvent.constructor,
            .{ .arity = 2 },
        );
        pub const titlebarAreaRect = bridge.accessor(
            WindowControlsOverlayGeometryChangeEvent.getTitlebarAreaRect,
            null,
            .{},
        );
        pub const visible = bridge.accessor(WindowControlsOverlayGeometryChangeEvent.getVisible, null, .{});
    };
};

const testing = @import("../../../testing.zig");
test "WebApi: MiscEvents" {
    try testing.htmlRunner("event/misc_events.html", .{});
}
