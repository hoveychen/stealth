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
const Observable = @import("observable.zig").Observable;

const Page = @import("../Page.zig");
const reflect = @import("../reflect.zig");
const Factory = @import("../Factory.zig");
const EventManager = @import("../EventManager.zig");

const Node = @import("Node.zig");
const Event = @import("Event.zig");
const Screen = @import("Screen.zig");
const Worker = @import("Worker.zig");
const Window = @import("Window.zig");
const AbortSignal = @import("AbortSignal.zig");
const MessagePort = @import("MessagePort.zig");
const FileReader = @import("FileReader.zig");
const WebSocket = @import("net/WebSocket.zig");
const Navigation = @import("navigation/Navigation.zig");
const Notification = @import("Notification.zig");
const EventSource = @import("net/EventSource.zig");
const CookieStore = @import("storage/CookieStore.zig");
const IDBRequest = @import("storage/idb/IDBRequest.zig");
const SharedWorker = @import("SharedWorker.zig");
const FontFaceSet = @import("css/FontFaceSet.zig");
const IDBDatabase = @import("storage/idb/IDBDatabase.zig");
const TextTrackCue = @import("media/TextTrackCue.zig");
const VisualViewport = @import("VisualViewport.zig");
const MediaQueryList = @import("css/MediaQueryList.zig");
const IDBTransaction = @import("storage/idb/IDBTransaction.zig");
const BroadcastChannel = @import("BroadcastChannel.zig");
const WorkerGlobalScope = @import("WorkerGlobalScope.zig");
const NavigationHistoryEntry = @import("navigation/NavigationHistoryEntry.zig");
const XMLHttpRequestEventTarget = @import("net/XMLHttpRequestEventTarget.zig");

const RegisterOptions = EventManager.RegisterOptions;

const EventTarget = @This();

pub const _prototype_root = true;

// `global_event_handlers.Key` reuses the low 3 bits of an EventTarget pointer,
// so the type has to stay 8-byte aligned even though the tag is a single byte.
// This costs nothing in a chain: EventTarget is always at offset 0 and every
// subtype that follows it is itself 8-aligned.
_type: Type align(8),

// Upstream's bare-enum tag (the subtype's address is derived by pointer
// arithmetic over the factory-allocated chain), extended with every event
// target our fork adds on top of upstream's set.
pub const Type = enum(u8) {
    generic,
    node,
    window,
    worker,
    shared_worker,
    worker_global_scope,
    xhr,
    abort_signal,
    media_query_list,
    animation,
    message_port,
    broadcast_channel,
    text_track_cue,
    navigation,
    navigation_history_entry,
    screen,
    screen_orientation,
    offscreen_canvas,
    performance,
    visual_viewport,
    network_information,
    media_devices,
    battery_manager,
    file_reader,
    font_face_set,
    websocket,
    event_source,
    cookie_store,
    idb_request,
    idb_database,
    idb_transaction,
    notification,
    audio_node,
    base_audio_context,
    speech_synthesis,
    speech_synthesis_utterance,
    speech_recognition,
    file_writer,
    media_stream,
    media_stream_track,
    media_stream_track_generator,
    canvas_capture_media_stream_track,
    remote_playback,
    service_worker,
    service_worker_registration,
    background_fetch_registration,
    payment_request,
    payment_response,
    presentation_request,
    presentation_availability,
    presentation_connection,
    presentation_connection_list,
    media_source,
    media_recorder,
    media_key_session,
    source_buffer,
    source_buffer_list,
    rtc_peer_connection,
    rtc_data_channel,
    window_controls_overlay,
    bluetooth,
    clipboard,
    navigator_managed_data,
    service_worker_container,
    virtual_keyboard,
    device_posture,
    hid,
    serial,
    usb,
    xr_system,
    wake_lock_sentinel,
    sensor,
    permission_status,
    bluetooth_device,
    bluetooth_gatt_characteristic,
    hid_device,
    serial_port,
    text_track,
    text_track_list,
    capture_controller,
    picture_in_picture_window,
    idle_detector,
    edit_context,
    gpu_device,
    video_decoder,
    video_encoder,
    audio_decoder,
    audio_encoder,
    xr_space,
    xr_session,
    xr_layer,
};

// `.generic` maps to EventTarget itself: a standalone `new EventTarget()` has
// no chain member of its own.
pub fn Subtype(comptime tag: Type) type {
    return switch (tag) {
        .generic => EventTarget,
        .node => Node,
        .window => Window,
        .worker => Worker,
        .shared_worker => SharedWorker,
        .worker_global_scope => WorkerGlobalScope,
        .xhr => XMLHttpRequestEventTarget,
        .abort_signal => AbortSignal,
        .media_query_list => MediaQueryList,
        .animation => @import("animation/Animation.zig"),
        .message_port => MessagePort,
        .broadcast_channel => BroadcastChannel,
        .text_track_cue => TextTrackCue,
        .navigation => Navigation,
        .navigation_history_entry => NavigationHistoryEntry,
        .screen => Screen,
        .screen_orientation => Screen.Orientation,
        .offscreen_canvas => @import("canvas/OffscreenCanvas.zig"),
        .performance => @import("Performance.zig"),
        .visual_viewport => VisualViewport,
        .network_information => @import("NetworkInformation.zig"),
        .media_devices => @import("media/MediaDevices.zig"),
        .battery_manager => @import("BatteryManager.zig"),
        .file_reader => FileReader,
        .font_face_set => FontFaceSet,
        .websocket => WebSocket,
        .event_source => EventSource,
        .cookie_store => CookieStore,
        .idb_request => IDBRequest,
        .idb_database => IDBDatabase,
        .idb_transaction => IDBTransaction,
        .notification => Notification,
        .audio_node => @import("audio/AudioNode.zig"),
        .base_audio_context => @import("audio/BaseAudioContext.zig"),
        .speech_synthesis => @import("speech/SpeechSynthesis.zig"),
        .speech_synthesis_utterance => @import("speech/SpeechSynthesisUtterance.zig"),
        .speech_recognition => @import("speech/recognition.zig").SpeechRecognition,
        .file_writer => @import("filesystem.zig").FileWriter,
        .media_stream => @import("media/streams.zig").MediaStream,
        .media_stream_track => @import("media/streams.zig").MediaStreamTrack,
        .media_stream_track_generator => @import("media/breakout_box.zig").MediaStreamTrackGenerator,
        .canvas_capture_media_stream_track => @import("media/image_capture.zig").CanvasCaptureMediaStreamTrack,
        .remote_playback => @import("media/playback.zig").RemotePlayback,
        .service_worker => @import("service_worker.zig").ServiceWorker,
        .service_worker_registration => @import("service_worker.zig").ServiceWorkerRegistration,
        .background_fetch_registration => @import("service_worker.zig").BackgroundFetchRegistration,
        .payment_request => @import("payment.zig").PaymentRequest,
        .payment_response => @import("payment.zig").PaymentResponse,
        .presentation_request => @import("presentation.zig").PresentationRequest,
        .presentation_availability => @import("presentation.zig").PresentationAvailability,
        .presentation_connection => @import("presentation.zig").PresentationConnection,
        .presentation_connection_list => @import("presentation.zig").PresentationConnectionList,
        .media_source => @import("media/MediaSource.zig"),
        .media_recorder => @import("media/MediaRecorder.zig"),
        .media_key_session => @import("media/eme.zig").MediaKeySession,
        .source_buffer => @import("media/MediaSource.zig").SourceBuffer,
        .source_buffer_list => @import("media/MediaSource.zig").SourceBufferList,
        .rtc_peer_connection => @import("webrtc/RTCPeerConnection.zig"),
        .rtc_data_channel => @import("webrtc/RTCDataChannel.zig"),
        .window_controls_overlay => @import("navigator/devices.zig").WindowControlsOverlay,
        .bluetooth => @import("navigator/devices.zig").Bluetooth,
        .clipboard => @import("navigator/devices.zig").Clipboard,
        .navigator_managed_data => @import("navigator/devices.zig").NavigatorManagedData,
        .service_worker_container => @import("navigator/devices.zig").ServiceWorkerContainer,
        .virtual_keyboard => @import("navigator/devices.zig").VirtualKeyboard,
        .device_posture => @import("navigator/devices.zig").DevicePosture,
        .hid => @import("navigator/devices.zig").HID,
        .serial => @import("navigator/devices.zig").Serial,
        .usb => @import("navigator/devices.zig").USB,
        .xr_system => @import("navigator/devices.zig").XRSystem,
        .wake_lock_sentinel => @import("navigator/devices.zig").WakeLockSentinel,
        .sensor => @import("sensor.zig").Sensor,
        .permission_status => @import("Permissions.zig").PermissionStatus,
        .bluetooth_device => @import("navigator/bluetooth.zig").BluetoothDevice,
        .bluetooth_gatt_characteristic => @import("navigator/bluetooth.zig").BluetoothRemoteGATTCharacteristic,
        .hid_device => @import("navigator/hid_serial.zig").HIDDevice,
        .serial_port => @import("navigator/hid_serial.zig").SerialPort,
        .text_track => @import("media/text_tracks.zig").TextTrack,
        .text_track_list => @import("media/text_tracks.zig").TextTrackList,
        .capture_controller => @import("media/capture.zig").CaptureController,
        .picture_in_picture_window => @import("media/PictureInPictureWindow.zig"),
        .idle_detector => @import("IdleDetector.zig"),
        .edit_context => @import("EditContext.zig"),
        .gpu_device => @import("webgpu/device.zig").GPUDevice,
        .video_decoder => @import("webcodecs/codecs.zig").VideoDecoder,
        .video_encoder => @import("webcodecs/codecs.zig").VideoEncoder,
        .audio_decoder => @import("webcodecs/codecs.zig").AudioDecoder,
        .audio_encoder => @import("webcodecs/codecs.zig").AudioEncoder,
        .xr_space => @import("webxr/spaces.zig").XRSpace,
        .xr_session => @import("webxr/session.zig").XRSession,
        .xr_layer => @import("webxr/layers.zig").XRLayer,
    };
}

pub fn subtype(self: *const EventTarget, comptime T: type) *T {
    const offset = comptime Factory.chainOffsetOf(T, T) - Factory.chainOffsetOf(T, EventTarget);
    const sub: *T = @ptrFromInt(@intFromPtr(self) + offset);
    if (comptime lp.IS_DEBUG and reflect.Proto(T) == EventTarget) {
        // This pointer dance only works because the factory allocates the chain
        // in a contiguous block of memory. In debug, we assert this holds via
        // the _proto_canary back pointer -- but only for a direct child of
        // EventTarget: the tag table also names types that sit deeper in a
        // chain, whose own proto is that intermediate rather than this target.
        std.debug.assert(Factory.protoOf(sub) == self);
    }
    return sub;
}

// Returns the target as a more specific type, or null if it isn't a `T`.
pub fn is(self: *EventTarget, comptime T: type) ?*T {
    switch (self._type) {
        .generic => {},
        inline else => |tag| {
            if (Subtype(tag) == T) {
                return self.subtype(T);
            }
        },
    }
    return null;
}

pub fn as(self: *EventTarget, comptime T: type) *T {
    return self.is(T).?;
}

pub fn init(page: *Page) !*EventTarget {
    return page.factory.create(EventTarget{
        ._type = .generic,
    });
}

pub fn dispatchEvent(self: *EventTarget, event: *Event, exec: *js.Execution) !bool {
    if (event._event_phase != .none) {
        return error.InvalidStateError;
    }

    if (!event._initialized) {
        return error.InvalidStateError;
    }
    event._is_trusted = false;

    switch (exec.js.global) {
        .frame => |frame| {
            event.acquireRef();
            defer _ = event.releaseRef(frame._page);
            try frame._event_manager.dispatch(self, event);
        },
        .worker => |wgs| try wgs.dispatch(self, event, null, .{}),
    }
    return !event._cancelable or !event._prevent_default;
}

const AddEventListenerOptions = union(enum) {
    capture: bool,
    options: Options,

    // The signal is kept as a raw js.Value so that an explicit null (or any
    // non-AbortSignal value) can be told apart from an absent or undefined
    // member, and rejected with a TypeError per the dictionary conversion.
    // passive is optional so that an absent (or undefined) member falls back
    // to the type- and target-dependent default passive value.
    const Options = struct {
        // Alphabetical: a dictionary's members are read in that order and a
        // page handing a Proxy in sees the sequence.
        capture: bool = false,
        once: bool = false,
        passive: ?bool = null,
        signal: ?js.Value = null,
    };
};

// The DOM spec's "default passive value": listeners for the scroll-blocking
// event types are passive by default on the window, the document, and the
// html and body elements.
fn defaultPassiveValue(self: *EventTarget, typ: []const u8) bool {
    const scroll_blocking_event_types = std.StaticStringMap(void).initComptime(.{
        .{ "touchstart", {} },
        .{ "touchmove", {} },
        .{ "wheel", {} },
        .{ "mousewheel", {} },
    });
    if (scroll_blocking_event_types.has(typ) == false) {
        return false;
    }

    switch (self._type) {
        .window => return true,
        .node => {
            const Element = @import("Element.zig");
            const n = self.subtype(Node);
            if (n._type == .document) {
                return true;
            }
            const element = n.is(Element) orelse return false;
            return switch (element.getTag()) {
                .html, .body => true,
                else => false,
            };
        },
        else => return false,
    }
}

pub const EventListenerCallback = union(enum) {
    function: js.Function,
    object: js.Object,
};
/// `EventTarget.when(type)` -- an Observable of that event type. The
/// subscription's signal is what removes the listener, so
/// `subscribe(observer, {signal})` followed by `abort()` stops delivery
/// (measured on Chrome 151; see webapi/observable.zig).
pub fn when(self: *EventTarget, typ: []const u8, exec: *const js.Execution) !*Observable {
    return Observable.forEvents(self, typ, exec);
}

pub fn addEventListener(self: *EventTarget, typ: []const u8, callback_: js.Nullable(EventListenerCallback), opts_: ?AddEventListenerOptions, exec: *js.Execution) !void {
    // Convert the options before the null-callback early return: per spec,
    // the dictionary conversion throws even when the callback is null.
    const options = blk: {
        const o = opts_ orelse break :blk RegisterOptions{ .passive = self.defaultPassiveValue(typ) };
        break :blk switch (o) {
            .options => |opts| RegisterOptions{
                .once = opts.once,
                .capture = opts.capture,
                .passive = opts.passive orelse self.defaultPassiveValue(typ),
                .signal = signal: {
                    const signal = opts.signal orelse break :signal null;
                    if (signal.isUndefined()) {
                        break :signal null;
                    }
                    break :signal try signal.toZig(*AbortSignal);
                },
            },
            .capture => |capture| RegisterOptions{ .capture = capture, .passive = self.defaultPassiveValue(typ) },
        };
    };

    const callback = callback_.value orelse return;

    const em_callback: EventManager.Callback = switch (callback) {
        .object => |obj| .{ .object = obj },
        .function => |func| .{ .function = func },
    };

    switch (exec.js.global) {
        inline else => |g| _ = try g._event_manager.register(self, typ, em_callback, options),
    }
}

const RemoveEventListenerOptions = union(enum) {
    capture: bool,
    options: Options,

    const Options = struct {
        capture: bool = false,
    };
};
pub fn removeEventListener(self: *EventTarget, typ: []const u8, callback_: js.Nullable(EventListenerCallback), opts_: ?RemoveEventListenerOptions, exec: *js.Execution) !void {
    const callback = callback_.value orelse return;

    // For object callbacks, check if handleEvent exists
    if (callback == .object) {
        if (try callback.object.getFunction("handleEvent") == null) {
            return;
        }
    }

    const em_callback: EventManager.Callback = switch (callback) {
        .function => |func| .{ .function = func },
        .object => |obj| .{ .object = obj },
    };

    const use_capture = blk: {
        const o = opts_ orelse break :blk false;
        break :blk switch (o) {
            .capture => |capture| capture,
            .options => |opts| opts.capture,
        };
    };

    switch (exec.js.global) {
        inline else => |g| g._event_manager.remove(self, typ, em_callback, use_capture),
    }
}

pub fn format(self: *EventTarget, writer: *std.Io.Writer) !void {
    return switch (self._type) {
        .node => self.subtype(Node).format(writer),
        .generic => writer.writeAll("<EventTarget>"),
        .window => writer.writeAll("<Window>"),
        .worker => writer.writeAll("<Worker>"),
        .shared_worker => writer.writeAll("<SharedWorker>"),
        .worker_global_scope => writer.writeAll("<WorkerGlobalScope>"),
        .xhr => writer.writeAll("<XMLHttpRequestEventTarget>"),
        .abort_signal => writer.writeAll("<AbortSignal>"),
        .media_query_list => writer.writeAll("<MediaQueryList>"),
        .animation => writer.writeAll("<Animation>"),
        .message_port => writer.writeAll("<MessagePort>"),
        .broadcast_channel => writer.writeAll("<BroadcastChannel>"),
        .text_track_cue => writer.writeAll("<TextTrackCue>"),
        .navigation => writer.writeAll("<Navigation>"),
        .screen => writer.writeAll("<Screen>"),
        .screen_orientation => writer.writeAll("<ScreenOrientation>"),
        .offscreen_canvas => writer.writeAll("<OffscreenCanvas>"),
        .performance => writer.writeAll("<Performance>"),
        .visual_viewport => writer.writeAll("<VisualViewport>"),
        .network_information => writer.writeAll("<NetworkInformation>"),
        .media_devices => writer.writeAll("<MediaDevices>"),
        .battery_manager => writer.writeAll("<BatteryManager>"),
        .file_reader => writer.writeAll("<FileReader>"),
        .font_face_set => writer.writeAll("<FontFaceSet>"),
        .websocket => writer.writeAll("<WebSocket>"),
        .event_source => writer.writeAll("<EventSource>"),
        .cookie_store => writer.writeAll("<CookieStore>"),
        .idb_request => writer.writeAll("<IDBRequest>"),
        .idb_database => writer.writeAll("<IDBDatabase>"),
        .idb_transaction => writer.writeAll("<IDBTransaction>"),
        .notification => writer.writeAll("<Notification>"),
        .navigation_history_entry => writer.writeAll("<NavigationHistoryEntry>"),
        .xr_space => writer.writeAll("<XRSpace>"),
        .xr_session => writer.writeAll("<XRSession>"),
        .xr_layer => writer.writeAll("<XRLayer>"),
        .audio_node => writer.writeAll("<AudioNode>"),
        .base_audio_context => writer.writeAll("<BaseAudioContext>"),
        .speech_synthesis => writer.writeAll("<SpeechSynthesis>"),
        .speech_synthesis_utterance => writer.writeAll("<SpeechSynthesisUtterance>"),
        .speech_recognition => writer.writeAll("<SpeechRecognition>"),
        .file_writer => writer.writeAll("<FileWriter>"),
        .media_source => writer.writeAll("<MediaSource>"),
        .media_recorder => writer.writeAll("<MediaRecorder>"),
        .media_key_session => writer.writeAll("<MediaKeySession>"),
        .source_buffer => writer.writeAll("<SourceBuffer>"),
        .source_buffer_list => writer.writeAll("<SourceBufferList>"),
        .rtc_peer_connection => writer.writeAll("<RTCPeerConnection>"),
        .rtc_data_channel => writer.writeAll("<RTCDataChannel>"),
        .window_controls_overlay => writer.writeAll("<WindowControlsOverlay>"),
        .bluetooth => writer.writeAll("<Bluetooth>"),
        .clipboard => writer.writeAll("<Clipboard>"),
        .navigator_managed_data => writer.writeAll("<NavigatorManagedData>"),
        .service_worker_container => writer.writeAll("<ServiceWorkerContainer>"),
        .virtual_keyboard => writer.writeAll("<VirtualKeyboard>"),
        .device_posture => writer.writeAll("<DevicePosture>"),
        .hid => writer.writeAll("<HID>"),
        .serial => writer.writeAll("<Serial>"),
        .usb => writer.writeAll("<USB>"),
        .xr_system => writer.writeAll("<XRSystem>"),
        .wake_lock_sentinel => writer.writeAll("<WakeLockSentinel>"),
        .sensor => writer.writeAll("<Sensor>"),
        .permission_status => writer.writeAll("<PermissionStatus>"),
        .bluetooth_device => writer.writeAll("<BluetoothDevice>"),
        .bluetooth_gatt_characteristic => writer.writeAll("<BluetoothRemoteGATTCharacteristic>"),
        .hid_device => writer.writeAll("<HIDDevice>"),
        .serial_port => writer.writeAll("<SerialPort>"),
        .media_stream => writer.writeAll("<MediaStream>"),
        .media_stream_track => writer.writeAll("<MediaStreamTrack>"),
        .media_stream_track_generator => writer.writeAll("<MediaStreamTrackGenerator>"),
        .canvas_capture_media_stream_track => writer.writeAll("<CanvasCaptureMediaStreamTrack>"),
        .remote_playback => writer.writeAll("<RemotePlayback>"),
        .service_worker => writer.writeAll("<ServiceWorker>"),
        .service_worker_registration => writer.writeAll("<ServiceWorkerRegistration>"),
        .background_fetch_registration => writer.writeAll("<BackgroundFetchRegistration>"),
        .payment_request => writer.writeAll("<PaymentRequest>"),
        .payment_response => writer.writeAll("<PaymentResponse>"),
        .presentation_request => writer.writeAll("<PresentationRequest>"),
        .presentation_availability => writer.writeAll("<PresentationAvailability>"),
        .presentation_connection => writer.writeAll("<PresentationConnection>"),
        .presentation_connection_list => writer.writeAll("<PresentationConnectionList>"),
        .text_track => writer.writeAll("<TextTrack>"),
        .text_track_list => writer.writeAll("<TextTrackList>"),
        .capture_controller => writer.writeAll("<CaptureController>"),
        .picture_in_picture_window => writer.writeAll("<PictureInPictureWindow>"),
        .idle_detector => writer.writeAll("<IdleDetector>"),
        .edit_context => writer.writeAll("<EditContext>"),
        .gpu_device => writer.writeAll("<GPUDevice>"),
        .video_decoder => writer.writeAll("<VideoDecoder>"),
        .video_encoder => writer.writeAll("<VideoEncoder>"),
        .audio_decoder => writer.writeAll("<AudioDecoder>"),
        .audio_encoder => writer.writeAll("<AudioEncoder>"),
    };
}

pub fn toString(self: *EventTarget) []const u8 {
    return switch (self._type) {
        .node => return "[object Node]",
        .generic => return "[object EventTarget]",
        .window => return "[object Window]",
        .worker => return "[object Worker]",
        .shared_worker => return "[object SharedWorker]",
        .worker_global_scope => return "[object WorkerGlobalScope]",
        .xhr => return "[object XMLHttpRequestEventTarget]",
        .abort_signal => return "[object AbortSignal]",
        .media_query_list => return "[object MediaQueryList]",
        .animation => return "[object Animation]",
        .message_port => return "[object MessagePort]",
        .broadcast_channel => return "[object BroadcastChannel]",
        .text_track_cue => return "[object TextTrackCue]",
        .navigation => return "[object Navigation]",
        .screen => return "[object Screen]",
        .screen_orientation => return "[object ScreenOrientation]",
        .offscreen_canvas => return "[object OffscreenCanvas]",
        .performance => return "[object Performance]",
        .visual_viewport => return "[object VisualViewport]",
        .network_information => return "[object NetworkInformation]",
        .media_devices => return "[object MediaDevices]",
        .battery_manager => return "[object BatteryManager]",
        .file_reader => return "[object FileReader]",
        .font_face_set => return "[object FontFaceSet]",
        .websocket => return "[object WebSocket]",
        .event_source => return "[object EventSource]",
        .cookie_store => return "[object CookieStore]",
        .idb_request => return "[object IDBRequest]",
        .idb_database => return "[object IDBDatabase]",
        .idb_transaction => return "[object IDBTransaction]",
        .notification => return "[object Notification]",
        .navigation_history_entry => return "[object NavigationHistoryEntry]",
        .xr_space => return "[object XRSpace]",
        .xr_session => return "[object XRSession]",
        .xr_layer => return "[object XRLayer]",
        .audio_node => return "[object AudioNode]",
        .base_audio_context => return "[object BaseAudioContext]",
        .speech_synthesis => return "[object SpeechSynthesis]",
        .speech_synthesis_utterance => return "[object SpeechSynthesisUtterance]",
        .speech_recognition => return "[object SpeechRecognition]",
        .file_writer => return "[object FileWriter]",
        .media_source => return "[object MediaSource]",
        .media_recorder => return "[object MediaRecorder]",
        .media_key_session => return "[object MediaKeySession]",
        .source_buffer => return "[object SourceBuffer]",
        .source_buffer_list => return "[object SourceBufferList]",
        .rtc_peer_connection => return "[object RTCPeerConnection]",
        .rtc_data_channel => return "[object RTCDataChannel]",
        .window_controls_overlay => return "[object WindowControlsOverlay]",
        .bluetooth => return "[object Bluetooth]",
        .clipboard => return "[object Clipboard]",
        .navigator_managed_data => return "[object NavigatorManagedData]",
        .service_worker_container => return "[object ServiceWorkerContainer]",
        .virtual_keyboard => return "[object VirtualKeyboard]",
        .device_posture => return "[object DevicePosture]",
        .hid => return "[object HID]",
        .serial => return "[object Serial]",
        .usb => return "[object USB]",
        .xr_system => return "[object XRSystem]",
        .wake_lock_sentinel => return "[object WakeLockSentinel]",
        .sensor => return "[object Sensor]",
        .permission_status => return "[object PermissionStatus]",
        .bluetooth_device => return "[object BluetoothDevice]",
        .bluetooth_gatt_characteristic => return "[object BluetoothRemoteGATTCharacteristic]",
        .hid_device => return "[object HIDDevice]",
        .serial_port => return "[object SerialPort]",
        .media_stream => return "[object MediaStream]",
        .media_stream_track => return "[object MediaStreamTrack]",
        .media_stream_track_generator => return "[object MediaStreamTrackGenerator]",
        .canvas_capture_media_stream_track => return "[object CanvasCaptureMediaStreamTrack]",
        .remote_playback => return "[object RemotePlayback]",
        .service_worker => return "[object ServiceWorker]",
        .service_worker_registration => return "[object ServiceWorkerRegistration]",
        .background_fetch_registration => return "[object BackgroundFetchRegistration]",
        .payment_request => return "[object PaymentRequest]",
        .payment_response => return "[object PaymentResponse]",
        .presentation_request => return "[object PresentationRequest]",
        .presentation_availability => return "[object PresentationAvailability]",
        .presentation_connection => return "[object PresentationConnection]",
        .presentation_connection_list => return "[object PresentationConnectionList]",
        .text_track => return "[object TextTrack]",
        .text_track_list => return "[object TextTrackList]",
        .capture_controller => return "[object CaptureController]",
        .picture_in_picture_window => return "[object PictureInPictureWindow]",
        .idle_detector => return "[object IdleDetector]",
        .edit_context => return "[object EditContext]",
        .gpu_device => return "[object GPUDevice]",
        .video_decoder => return "[object VideoDecoder]",
        .video_encoder => return "[object VideoEncoder]",
        .audio_decoder => return "[object AudioDecoder]",
        .audio_encoder => return "[object AudioEncoder]",
    };
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(EventTarget);

    pub const Meta = struct {
        pub const name = "EventTarget";

        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
    };

    // Chrome's own-property order, in both the window realm and a worker's:
    // addEventListener, dispatchEvent, removeEventListener, when. This is IDL
    // order, not the declaration order the file used to carry, and it is on the
    // most walked prototype in the realm. `when` comes last because the
    // Observable spec appends it to the interface rather than sorting it in.
    pub const constructor = bridge.constructor(EventTarget.init, .{});
    pub const addEventListener = bridge.function(EventTarget.addEventListener, .{});
    pub const dispatchEvent = bridge.function(EventTarget.dispatchEvent, .{});
    pub const removeEventListener = bridge.function(EventTarget.removeEventListener, .{});
    pub const when = bridge.function(EventTarget.when, .{});
};

const testing = @import("../../testing.zig");
test "WebApi: EventTarget" {
    testing.silenceLog(&.{ .js, .event });

    // we create thousands of these per frame. Nothing should bloat it.
    // The tag is 1 byte; the rest is the align(8) that `Key.fuse` depends on.
    try testing.expectEqual(8, @sizeOf(EventTarget));
    try testing.expectEqual(8, @alignOf(EventTarget));
    try testing.htmlRunner("events.html", .{});
}

test "WebApi: EventTarget handler order" {
    testing.silenceLog(&.{.event});
    try testing.htmlRunner("event/handler_order.html", .{});
}

test "WebApi: EventTarget handler order on stub targets" {
    testing.silenceLog(&.{.event});
    try testing.htmlRunner("event/handler_order_stubs.html", .{});
}
