// Copyright (C) 2023-2025  Lightpanda (Selecy SAS)
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
const lp = @import("lightpanda");

const js = @import("../js/js.zig");
const Page = @import("../Page.zig");

const Node = @import("Node.zig");
const EventTarget = @import("EventTarget.zig");

const String = lp.String;
const Execution = js.Execution;

pub const Event = @This();

pub const _prototype_root = true;
_type: Type,
_arena: *lp.Arena,
_bubbles: bool = false,
_cancelable: bool = false,
_composed: bool = false,
_type_string: String,
_target: ?*EventTarget = null,
_current_target: ?*EventTarget = null,
_dispatch_target: ?*EventTarget = null, // Original target for composedPath()
_prevent_default: bool = false,
_stop_propagation: bool = false,
_stop_immediate_propagation: bool = false,
_event_phase: EventPhase = .none,
_time_stamp: u64,
_needs_retargeting: bool = false,
_is_trusted: bool = false,
_in_passive_listener: bool = false,
_listeners_did_throw: bool = false, // IndexedDB needs to abort on callback throw
// Per spec, events created via document.createEvent are not initialized
// until one of the init*Event methods runs; dispatching one throws an
// InvalidStateError. Events created any other way start initialized.
_initialized: bool = true,
// Time origin of the event's relevant global, captured at creation when
// known; 0 means "use the accessing realm's origin" (see getTimeStamp).
_time_origin: u64 = 0,

// There's a period of time between creating an event and handing it off to v8
// where things can fail. If it does fail, we need to deinit the event. The timing
// window can be difficult to capture, so we use a reference count.
// should be 0, 1, or 2. 0
// - 0: no reference, always a transient state going to either 1 or about to be deinit'd
// - 1: either zig or v8 have a reference
// - 2: both zig and v8 have a reference
_rc: lp.RC = .{},

pub const EventPhase = enum(u8) {
    none = 0,
    capturing_phase = 1,
    at_target = 2,
    bubbling_phase = 3,
};

pub const Type = union(enum) {
    generic,
    error_event: *@import("event/ErrorEvent.zig"),
    custom_event: *@import("event/CustomEvent.zig"),
    message_event: *@import("event/MessageEvent.zig"),
    progress_event: *@import("event/ProgressEvent.zig"),
    navigation_current_entry_change_event: *@import("event/NavigationCurrentEntryChangeEvent.zig"),
    page_transition_event: *@import("event/PageTransitionEvent.zig"),
    pop_state_event: *@import("event/PopStateEvent.zig"),
    hash_change_event: *@import("event/HashChangeEvent.zig"),
    before_unload_event: *@import("event/BeforeUnloadEvent.zig"),
    storage_event: *@import("event/StorageEvent.zig"),
    device_motion_event: *@import("event/DeviceMotionEvent.zig"),
    gamepad_event: *@import("event/GamepadEvent.zig"),
    device_orientation_event: *@import("event/DeviceOrientationEvent.zig"),
    ui_event: *@import("event/UIEvent.zig"),
    promise_rejection_event: *@import("event/PromiseRejectionEvent.zig"),
    submit_event: *@import("event/SubmitEvent.zig"),
    form_data_event: *@import("event/FormDataEvent.zig"),
    close_event: *@import("event/CloseEvent.zig"),
    cookie_change_event: *@import("event/CookieChangeEvent.zig"),
    idb_version_change_event: *@import("storage/idb/IDBVersionChangeEvent.zig"),
    toggle_event: *@import("event/ToggleEvent.zig"),
    speech_synthesis_event: *@import("speech/SpeechSynthesisEvent.zig"),
    rtc_peer_connection_ice_event: *@import("webrtc/RTCPeerConnectionIceEvent.zig"),
    rtc_peer_connection_ice_error_event: *@import("webrtc/events.zig").RTCPeerConnectionIceErrorEvent,
    rtc_error_event: *@import("webrtc/events.zig").RTCErrorEvent,
    rtc_data_channel_event: *@import("webrtc/events.zig").RTCDataChannelEvent,
    rtc_dtmf_tone_change_event: *@import("webrtc/events.zig").RTCDTMFToneChangeEvent,
    transition_event: *@import("event/css_events.zig").TransitionEvent,
    animation_event: *@import("event/css_events.zig").AnimationEvent,
    media_query_list_event: *@import("event/css_events.zig").MediaQueryListEvent,
    font_face_set_load_event: *@import("event/css_events.zig").FontFaceSetLoadEvent,
    task_priority_change_event: *@import("scheduler.zig").TaskPriorityChangeEvent,
    sensor_error_event: *@import("sensor.zig").SensorErrorEvent,
    midi_message_event: *@import("midi.zig").MIDIMessageEvent,
    midi_connection_event: *@import("midi.zig").MIDIConnectionEvent,
    usb_connection_event: *@import("navigator/usb.zig").USBConnectionEvent,
    hid_connection_event: *@import("navigator/hid_serial.zig").HIDConnectionEvent,
    hid_input_report_event: *@import("navigator/hid_serial.zig").HIDInputReportEvent,
    media_stream_track_event: *@import("media/streams.zig").MediaStreamTrackEvent,
    media_stream_event: *@import("media/streams.zig").MediaStreamEvent,
    offline_audio_completion_event: *@import("audio/events.zig").OfflineAudioCompletionEvent,
    audio_processing_event: *@import("audio/events.zig").AudioProcessingEvent,
    payment_request_update_event: *@import("payment.zig").PaymentRequestUpdateEvent,
    presentation_connection_available_event: *@import("presentation.zig").PresentationConnectionAvailableEvent,
    presentation_connection_close_event: *@import("presentation.zig").PresentationConnectionCloseEvent,
    animation_playback_event: *@import("event/misc_events.zig").AnimationPlaybackEvent,
    before_install_prompt_event: *@import("event/misc_events.zig").BeforeInstallPromptEvent,
    blob_event: *@import("event/misc_events.zig").BlobEvent,
    clipboard_event: *@import("event/misc_events.zig").ClipboardEvent,
    content_visibility_auto_state_change_event: *@import("event/misc_events.zig").ContentVisibilityAutoStateChangeEvent,
    navigate_event: *@import("event/misc_events.zig").NavigateEvent,
    picture_in_picture_event: *@import("event/misc_events.zig").PictureInPictureEvent,
    security_policy_violation_event: *@import("event/misc_events.zig").SecurityPolicyViolationEvent,
    track_event: *@import("event/misc_events.zig").TrackEvent,
    virtual_keyboard_geometry_change_event: *@import("event/misc_events.zig").VirtualKeyboardGeometryChangeEvent,
    webgl_context_event: *@import("event/misc_events.zig").WebGLContextEvent,
    gpu_uncaptured_error_event: *@import("webgpu/errors.zig").GPUUncapturedErrorEvent,
    window_controls_overlay_geometry_change_event: *@import("event/misc_events.zig").WindowControlsOverlayGeometryChangeEvent,
};

pub const Options = struct {
    bubbles: bool = false,
    cancelable: bool = false,
    composed: bool = false,
};

/// EventInit's three members, read by hand. For the constructors that read
/// their whole dictionary themselves because one of their own members needs a
/// message the bridge cannot produce.
pub fn optionsFromJs(value_: ?js.Value) !Options {
    const value = value_ orelse return .{};
    if (!value.isObject()) {
        return .{};
    }
    const object = value.toObject();

    var options: Options = .{};
    inline for (@typeInfo(Options).@"struct".fields) |field| {
        const member = try object.get(field.name);
        if (!member.isUndefined()) {
            @field(options, field.name) = member.toBool();
        }
    }
    return options;
}

pub fn init(typ: []const u8, opts_: ?Options, page: *Page) !*Event {
    const arena = try page.getArena(.tiny, "Event");
    errdefer arena.release();
    const str = try String.init(arena.allocator(), typ, .{});
    return initWithTrusted(arena, str, opts_, false);
}

pub fn initTrusted(typ: String, opts_: ?Options, page: *Page) !*Event {
    const arena = try page.getArena(.tiny, "Event.trusted");
    errdefer arena.release();
    return initWithTrusted(arena, typ, opts_, true);
}

fn initWithTrusted(arena: *lp.Arena, typ: String, opts_: ?Options, comptime trusted: bool) !*Event {
    const opts = opts_ orelse Options{};

    // Same (already coarsened) clock as the performance time origin, so the
    // timeStamp getter can report it relative to that origin.
    const time_stamp = @import("Performance.zig").highResTimestamp();

    const event = try arena.create(Event);
    event.* = .{
        ._arena = arena,
        ._type = .generic,
        ._bubbles = opts.bubbles,
        ._time_stamp = time_stamp,
        ._cancelable = opts.cancelable,
        ._composed = opts.composed,
        ._type_string = typ,
        ._is_trusted = trusted,
    };
    return event;
}

pub fn initEvent(
    self: *Event,
    event_string: []const u8,
    bubbles: ?bool,
    cancelable: ?bool,
) !void {
    if (self._event_phase != .none) {
        return;
    }

    self._initialized = true;
    self._type_string = try String.init(self._arena.allocator(), event_string, .{});
    self._bubbles = bubbles orelse false;
    self._cancelable = cancelable orelse false;
    self._stop_propagation = false;
    self._stop_immediate_propagation = false;
    self._prevent_default = false;
}

pub fn acquireRef(self: *Event) void {
    self._rc.acquire();
}

pub fn deinit(self: *Event, _: *Page) void {
    self._arena.release();
}

pub fn releaseRef(self: *Event, page: *Page) void {
    self._rc.release(self, page);
}

pub fn as(self: *Event, comptime T: type) *T {
    return self.is(T).?;
}

// Storage of the subtype's relatedTarget, for event types that have one.
// Used by dispatch for retargeting and shadow-tree resets.
pub fn relatedTargetPtr(self: *Event) ?*?*EventTarget {
    switch (self._type) {
        .ui_event => |ui| switch (ui._type) {
            .mouse_event => |me| return &me._related_target,
            .focus_event => |fe| return &fe._related_target,
            else => return null,
        },
        else => return null,
    }
}

pub fn is(self: *Event, comptime T: type) ?*T {
    switch (self._type) {
        .generic => return if (T == Event) self else null,
        .error_event => |e| return if (T == @import("event/ErrorEvent.zig")) e else null,
        .custom_event => |e| return if (T == @import("event/CustomEvent.zig")) e else null,
        .message_event => |e| return if (T == @import("event/MessageEvent.zig")) e else null,
        .progress_event => |e| return if (T == @import("event/ProgressEvent.zig")) e else null,
        .navigation_current_entry_change_event => |e| return if (T == @import("event/NavigationCurrentEntryChangeEvent.zig")) e else null,
        .page_transition_event => |e| return if (T == @import("event/PageTransitionEvent.zig")) e else null,
        .pop_state_event => |e| return if (T == @import("event/PopStateEvent.zig")) e else null,
        .hash_change_event => |e| return if (T == @import("event/HashChangeEvent.zig")) e else null,
        .before_unload_event => |e| return if (T == @import("event/BeforeUnloadEvent.zig")) e else null,
        .storage_event => |e| return if (T == @import("event/StorageEvent.zig")) e else null,
        .device_motion_event => |e| return if (T == @import("event/DeviceMotionEvent.zig")) e else null,
        .gamepad_event => |e| return if (T == @import("event/GamepadEvent.zig")) e else null,
        .device_orientation_event => |e| return if (T == @import("event/DeviceOrientationEvent.zig")) e else null,
        .promise_rejection_event => |e| return if (T == @import("event/PromiseRejectionEvent.zig")) e else null,
        .submit_event => |e| return if (T == @import("event/SubmitEvent.zig")) e else null,
        .form_data_event => |e| return if (T == @import("event/FormDataEvent.zig")) e else null,
        .close_event => |e| return if (T == @import("event/CloseEvent.zig")) e else null,
        .cookie_change_event => |e| return if (T == @import("event/CookieChangeEvent.zig")) e else null,
        .idb_version_change_event => |e| return if (T == @import("storage/idb/IDBVersionChangeEvent.zig")) e else null,
        .toggle_event => |e| return if (T == @import("event/ToggleEvent.zig")) e else null,
        .ui_event => |e| {
            if (T == @import("event/UIEvent.zig")) {
                return e;
            }
            return e.is(T);
        },
        .speech_synthesis_event => |e| {
            if (T == @import("speech/SpeechSynthesisEvent.zig")) {
                return e;
            }
            return e.is(T);
        },
        .rtc_peer_connection_ice_event => |e| return if (T == @import("webrtc/RTCPeerConnectionIceEvent.zig")) e else null,
        .rtc_peer_connection_ice_error_event => |e| return if (T == @import("webrtc/events.zig").RTCPeerConnectionIceErrorEvent) e else null,
        .rtc_error_event => |e| return if (T == @import("webrtc/events.zig").RTCErrorEvent) e else null,
        .rtc_data_channel_event => |e| return if (T == @import("webrtc/events.zig").RTCDataChannelEvent) e else null,
        .rtc_dtmf_tone_change_event => |e| return if (T == @import("webrtc/events.zig").RTCDTMFToneChangeEvent) e else null,
        .transition_event => |e| return if (T == @import("event/css_events.zig").TransitionEvent) e else null,
        .animation_event => |e| return if (T == @import("event/css_events.zig").AnimationEvent) e else null,
        .media_query_list_event => |e| return if (T == @import("event/css_events.zig").MediaQueryListEvent) e else null,
        .font_face_set_load_event => |e| return if (T == @import("event/css_events.zig").FontFaceSetLoadEvent) e else null,
        .task_priority_change_event => |e| return if (T == @import("scheduler.zig").TaskPriorityChangeEvent) e else null,
        .sensor_error_event => |e| return if (T == @import("sensor.zig").SensorErrorEvent) e else null,
        .midi_message_event => |e| return if (T == @import("midi.zig").MIDIMessageEvent) e else null,
        .midi_connection_event => |e| return if (T == @import("midi.zig").MIDIConnectionEvent) e else null,
        .usb_connection_event => |e| return if (T == @import("navigator/usb.zig").USBConnectionEvent) e else null,
        .hid_connection_event => |e| return if (T == @import("navigator/hid_serial.zig").HIDConnectionEvent) e else null,
        .hid_input_report_event => |e| return if (T == @import("navigator/hid_serial.zig").HIDInputReportEvent) e else null,
        .media_stream_track_event => |e| return if (T == @import("media/streams.zig").MediaStreamTrackEvent) e else null,
        .payment_request_update_event => |e| return if (T == @import("payment.zig").PaymentRequestUpdateEvent) e else null,
        .presentation_connection_available_event => |e| return if (T == @import("presentation.zig").PresentationConnectionAvailableEvent) e else null,
        .presentation_connection_close_event => |e| return if (T == @import("presentation.zig").PresentationConnectionCloseEvent) e else null,
        .media_stream_event => |e| return if (T == @import("media/streams.zig").MediaStreamEvent) e else null,
        .offline_audio_completion_event => |e| return if (T == @import("audio/events.zig").OfflineAudioCompletionEvent) e else null,
        .audio_processing_event => |e| return if (T == @import("audio/events.zig").AudioProcessingEvent) e else null,
        .animation_playback_event => |e| return if (T == @import("event/misc_events.zig").AnimationPlaybackEvent) e else null,
        .before_install_prompt_event => |e| return if (T == @import("event/misc_events.zig").BeforeInstallPromptEvent) e else null,
        .blob_event => |e| return if (T == @import("event/misc_events.zig").BlobEvent) e else null,
        .clipboard_event => |e| return if (T == @import("event/misc_events.zig").ClipboardEvent) e else null,
        .content_visibility_auto_state_change_event => |e| return if (T == @import("event/misc_events.zig").ContentVisibilityAutoStateChangeEvent) e else null,
        .navigate_event => |e| return if (T == @import("event/misc_events.zig").NavigateEvent) e else null,
        .picture_in_picture_event => |e| return if (T == @import("event/misc_events.zig").PictureInPictureEvent) e else null,
        .security_policy_violation_event => |e| return if (T == @import("event/misc_events.zig").SecurityPolicyViolationEvent) e else null,
        .track_event => |e| return if (T == @import("event/misc_events.zig").TrackEvent) e else null,
        .virtual_keyboard_geometry_change_event => |e| return if (T == @import("event/misc_events.zig").VirtualKeyboardGeometryChangeEvent) e else null,
        .webgl_context_event => |e| return if (T == @import("event/misc_events.zig").WebGLContextEvent) e else null,
        .gpu_uncaptured_error_event => |e| return if (T == @import("webgpu/errors.zig").GPUUncapturedErrorEvent) e else null,
        .window_controls_overlay_geometry_change_event => |e| return if (T == @import("event/misc_events.zig").WindowControlsOverlayGeometryChangeEvent) e else null,
    }
    return null;
}

pub fn getType(self: *const Event) []const u8 {
    return self._type_string.str();
}

pub fn getBubbles(self: *const Event) bool {
    return self._bubbles;
}

pub fn getCancelable(self: *const Event) bool {
    return self._cancelable;
}

pub fn getComposed(self: *const Event) bool {
    return self._composed;
}

pub fn getTarget(self: *const Event) ?*EventTarget {
    return self._target;
}

pub fn getCurrentTarget(self: *const Event) ?*EventTarget {
    return self._current_target;
}

pub fn preventDefault(self: *Event) void {
    if (self._cancelable and !self._in_passive_listener) {
        self._prevent_default = true;
    }
}

pub fn stopPropagation(self: *Event) void {
    self._stop_propagation = true;
}

pub fn stopImmediatePropagation(self: *Event) void {
    self._stop_immediate_propagation = true;
    self._stop_propagation = true;
}

pub fn getDefaultPrevented(self: *const Event) bool {
    return self._prevent_default;
}

pub fn getReturnValue(self: *const Event) bool {
    return !self._prevent_default;
}

pub fn setReturnValue(self: *Event, v: bool) void {
    if (!v) {
        // Setting returnValue=false is equivalent to preventDefault()
        if (self._cancelable and !self._in_passive_listener) {
            self._prevent_default = true;
        }
    }
}

pub fn getCancelBubble(self: *const Event) bool {
    return self._stop_propagation;
}

pub fn setCancelBubble(self: *Event) void {
    self.stopPropagation();
}

pub fn getEventPhase(self: *const Event) u8 {
    return @intFromEnum(self._event_phase);
}

pub fn getTimeStamp(self: *const Event, exec: *js.Execution) f64 {
    const origin = if (self._time_origin != 0) self._time_origin else exec.performance()._time_origin;
    if (self._time_stamp <= origin) {
        return 0.0;
    }
    return @as(f64, @floatFromInt(self._time_stamp - origin)) / 1000.0;
}

pub fn setTrusted(self: *Event) void {
    self._is_trusted = true;
}

pub fn setUntrusted(self: *Event) void {
    self._is_trusted = false;
}

pub fn getIsTrusted(self: *const Event) bool {
    return self._is_trusted;
}

pub fn composedPath(self: *Event, exec: *Execution) ![]const *EventTarget {
    // Return empty array if event is not being dispatched
    if (self._event_phase == .none) {
        return &.{};
    }

    // Use dispatch_target (original target) if available, otherwise fall back to target
    // This is important because _target gets retargeted during event dispatch
    const target = self._dispatch_target orelse self._target orelse return &.{};

    // Only nodes have a propagation path
    const target_node = switch (target._type) {
        .node => |n| n,
        else => return &.{},
    };

    // Build the path by walking up from target
    var path_len: usize = 0;
    var path_buffer: [128]*EventTarget = undefined;
    var stopped_at_shadow_boundary = false;

    // Track closed shadow boundaries (position in path and host position)
    var closed_shadow_boundary: ?struct { shadow_end: usize, host_start: usize } = null;

    const frame_ = switch (exec.js.global) {
        .frame => |frame| frame,
        else => null,
    };

    const target_root = target_node.getRootNode(.{});
    var node: ?*Node = target_node;
    while (node) |n| {
        if (path_len >= path_buffer.len) {
            break;
        }
        path_buffer[path_len] = n.asEventTarget();
        path_len += 1;

        // Check if this node is a shadow root
        if (n._type == .document_fragment) {
            if (n._type.document_fragment._type == .shadow_root) {
                const shadow = n._type.document_fragment._type.shadow_root;

                if (!self._composed and n == target_root) {
                    stopped_at_shadow_boundary = true;
                    break;
                }

                // Track the first closed shadow boundary we encounter
                if (shadow._mode == .closed and closed_shadow_boundary == null) {
                    // Mark where the shadow root is in the path
                    // The next element will be the host
                    closed_shadow_boundary = .{
                        .shadow_end = path_len - 1, // index of shadow root
                        .host_start = path_len, // index where host will be
                    };
                }

                // Jump to the shadow host and continue
                node = shadow._host.asNode();
                continue;
            }
        }

        // an assigned slottable's event-path parent is its assigned slot,
        // routing the event into the slot's shadow tree
        if (frame_) |frame| {
            if (frame._assigned_slots.get(n)) |slot| {
                node = slot.asNode();
                continue;
            }
        }

        node = n._parent;
    }

    // Add window at the end. It only participates when propagation did not stop
    // at a shadow boundary...
    if (stopped_at_shadow_boundary == false) {
        // ... AND when the tree's root is a document
        const root_is_document = path_len > 0 and switch (path_buffer[path_len - 1]._type) {
            .node => |n| n._type == .document,
            else => false,
        };
        if (root_is_document) {
            if (path_len < path_buffer.len) {
                switch (exec.js.global) {
                    .worker => {},
                    .frame => |frame| {
                        path_buffer[path_len] = frame.window.asEventTarget();
                        path_len += 1;
                    },
                }
            }
        }
    }

    // Determine visible path based on current_target and closed shadow boundaries
    var visible_start_index: usize = 0;

    if (closed_shadow_boundary) |boundary| {
        // Check if current_target is outside the closed shadow
        // If current_target is null or is at/after the host position, hide shadow internals
        const current_target = self._current_target;

        if (current_target) |ct| {
            // Find current_target in the path
            var ct_index: ?usize = null;
            for (path_buffer[0..path_len], 0..) |elem, i| {
                if (elem == ct) {
                    ct_index = i;
                    break;
                }
            }

            // If current_target is at or after the host (outside the closed shadow),
            // hide everything from target up to the host
            if (ct_index) |idx| {
                if (idx >= boundary.host_start) {
                    visible_start_index = boundary.host_start;
                }
            }
        }
    }

    // Calculate the visible portion of the path
    const visible_path_len = if (path_len > visible_start_index) path_len - visible_start_index else 0;

    // Allocate and return the visible path using call_arena (short-lived)
    const path = try exec.local_arena.alloc(*EventTarget, visible_path_len);
    @memcpy(path, path_buffer[visible_start_index..path_len]);
    return path;
}

pub fn populateFromOptions(self: *Event, opts: anytype) void {
    self._bubbles = opts.bubbles;
    self._cancelable = opts.cancelable;
    self._composed = opts.composed;
}

pub fn inheritOptions(comptime T: type, comptime additions: anytype) type {
    var all_fields: []const std.builtin.Type.StructField = &.{};

    if (@hasField(T, "_proto")) {
        const t_fields = @typeInfo(T).@"struct".fields;

        inline for (t_fields) |field| {
            if (std.mem.eql(u8, field.name, "_proto")) {
                const ProtoType = @typeInfo(field.type).pointer.child;
                if (@hasDecl(ProtoType, "Options")) {
                    const parent_options = @typeInfo(ProtoType.Options);
                    all_fields = all_fields ++ parent_options.@"struct".fields;
                }
            }
        }
    }

    const additions_info = @typeInfo(additions);
    all_fields = all_fields ++ additions_info.@"struct".fields;

    var names: [all_fields.len][:0]const u8 = undefined;
    var types: [all_fields.len]type = undefined;
    var attrs: [all_fields.len]std.builtin.Type.StructField.Attributes = undefined;
    for (all_fields, 0..) |f, i| {
        names[i] = f.name;
        types[i] = f.type;
        attrs[i] = .{ .@"comptime" = f.is_comptime, .@"align" = f.alignment, .default_value_ptr = f.default_value_ptr };
    }
    return @Struct(.auto, null, &names, &types, &attrs);
}

pub fn populatePrototypes(self: anytype, opts: anytype, trusted: bool) void {
    const T = @TypeOf(self.*);

    if (@hasField(T, "_proto")) {
        populatePrototypes(self._proto, opts, trusted);
    }

    if (@hasDecl(T, "populateFromOptions")) {
        T.populateFromOptions(self, opts);
    }

    // Set isTrusted at the Event level (base of prototype chain)
    if (T == Event or @hasField(T, "is_trusted")) {
        self._is_trusted = trusted;
    }
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(Event);

    pub const Meta = struct {
        pub const name = "Event";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    pub const constructor = bridge.constructor(struct {
        fn wrap(typ: []const u8, opts_: ?Options, exec: *js.Execution) !*Event {
            const event = try Event.init(typ, opts_, exec.page);
            // capture the realm's time
            event._time_origin = exec.performance()._time_origin;
            return event;
        }
    }.wrap, .{});
    pub const @"type" = bridge.accessor(Event.getType, null, .{});
    pub const bubbles = bridge.accessor(Event.getBubbles, null, .{});
    pub const cancelable = bridge.accessor(Event.getCancelable, null, .{});
    pub const composed = bridge.accessor(Event.getComposed, null, .{});
    pub const target = bridge.accessor(Event.getTarget, null, .{});
    pub const srcElement = bridge.accessor(Event.getTarget, null, .{});
    pub const currentTarget = bridge.accessor(Event.getCurrentTarget, null, .{});
    pub const eventPhase = bridge.accessor(Event.getEventPhase, null, .{});
    pub const defaultPrevented = bridge.accessor(Event.getDefaultPrevented, null, .{});
    pub const timeStamp = bridge.accessor(Event.getTimeStamp, null, .{});
    pub const isTrusted = bridge.accessor(Event.getIsTrusted, null, .{ .unforgeable = true, .deletable = false });
    pub const preventDefault = bridge.function(Event.preventDefault, .{});
    pub const stopPropagation = bridge.function(Event.stopPropagation, .{});
    pub const stopImmediatePropagation = bridge.function(Event.stopImmediatePropagation, .{});
    pub const composedPath = bridge.function(Event.composedPath, .{});
    pub const initEvent = bridge.function(Event.initEvent, .{});
    // deprecated
    pub const returnValue = bridge.accessor(Event.getReturnValue, Event.setReturnValue, .{});
    // deprecated
    pub const cancelBubble = bridge.accessor(Event.getCancelBubble, Event.setCancelBubble, .{});

    // Event phase constants
    pub const NONE = bridge.property(@intFromEnum(EventPhase.none), .{ .template = true });
    pub const CAPTURING_PHASE = bridge.property(@intFromEnum(EventPhase.capturing_phase), .{ .template = true });
    pub const AT_TARGET = bridge.property(@intFromEnum(EventPhase.at_target), .{ .template = true });
    pub const BUBBLING_PHASE = bridge.property(@intFromEnum(EventPhase.bubbling_phase), .{ .template = true });
};

// tested in event_target
