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

//! Web Bluetooth's device side: the six interfaces a granted chooser would
//! hand back, plus BluetoothUUID.
//!
//! navigator.bluetooth.requestDevice rejects -- Chrome will not open the
//! chooser without a user gesture and nothing here ever has one -- so no
//! BluetoothDevice is ever handed out, and with it no GATT server, service,
//! characteristic or descriptor. That is the answer rather than a gap:
//! resolving one would mean inventing a paired radio this engine does not
//! have. What a script can see is the interface, shaped as Chrome shapes it
//! (win13-chrome.json).
//!
//! BluetoothUUID is the exception. Its four statics are pure string functions
//! that need no device, so they work, and they work on Chrome's own tables:
//! every name below was accepted by a headed Chrome 150 and mapped to the
//! alias it is paired with here (win13c-chrome.json). Names Chrome rejects are
//! absent by construction -- the candidate list was filtered by what Chrome
//! answered, not by what a spec says it should.

const std = @import("std");

const js = @import("../../js/js.zig");
const EventTarget = @import("../EventTarget.zig");
const handler_property = @import("../handler_property.zig");

/// The getter/setter pair for one of `T`'s `on*` properties. Per DOM the
/// function is a listener like any other, so it lives in the event manager's
/// handler store -- where the listener list can put it in dispatch order --
/// rather than in a field here.
fn handlerProperty(comptime T: type, comptime which: handler_property.Handler) type {
    return handler_property.accessors(T, which);
}
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        BluetoothUUID,
        BluetoothCharacteristicProperties,
        BluetoothDevice,
        BluetoothRemoteGATTServer,
        BluetoothRemoteGATTService,
        BluetoothRemoteGATTCharacteristic,
        BluetoothRemoteGATTDescriptor,
    };
}

fn throwTypeError(message: []const u8, exec: *const Execution) anyerror {
    const isolate = exec.js.isolate;
    _ = isolate.throwException(isolate.createTypeError(message));
    return error.JsException;
}

// 39 names, each measured against a headed Chrome 150.
const service_names = std.StaticStringMap(u16).initComptime(.{
    .{ "alert_notification", 0x1811 },
    .{ "automation_io", 0x1815 },
    .{ "battery_service", 0x180f },
    .{ "blood_pressure", 0x1810 },
    .{ "body_composition", 0x181b },
    .{ "bond_management", 0x181e },
    .{ "continuous_glucose_monitoring", 0x181f },
    .{ "current_time", 0x1805 },
    .{ "cycling_power", 0x1818 },
    .{ "cycling_speed_and_cadence", 0x1816 },
    .{ "device_information", 0x180a },
    .{ "environmental_sensing", 0x181a },
    .{ "fitness_machine", 0x1826 },
    .{ "generic_access", 0x1800 },
    .{ "generic_attribute", 0x1801 },
    .{ "glucose", 0x1808 },
    .{ "health_thermometer", 0x1809 },
    .{ "heart_rate", 0x180d },
    .{ "http_proxy", 0x1823 },
    .{ "human_interface_device", 0x1812 },
    .{ "immediate_alert", 0x1802 },
    .{ "indoor_positioning", 0x1821 },
    .{ "internet_protocol_support", 0x1820 },
    .{ "link_loss", 0x1803 },
    .{ "location_and_navigation", 0x1819 },
    .{ "mesh_provisioning", 0x1827 },
    .{ "mesh_proxy", 0x1828 },
    .{ "next_dst_change", 0x1807 },
    .{ "object_transfer", 0x1825 },
    .{ "phone_alert_status", 0x180e },
    .{ "pulse_oximeter", 0x1822 },
    .{ "reconnection_configuration", 0x1829 },
    .{ "reference_time_update", 0x1806 },
    .{ "running_speed_and_cadence", 0x1814 },
    .{ "scan_parameters", 0x1813 },
    .{ "transport_discovery", 0x1824 },
    .{ "tx_power", 0x1804 },
    .{ "user_data", 0x181c },
    .{ "weight_scale", 0x181d },
});

// 186 names, each measured against a headed Chrome 150.
const characteristic_names = std.StaticStringMap(u16).initComptime(.{
    .{ "aerobic_heart_rate_lower_limit", 0x2a7e },
    .{ "aerobic_heart_rate_upper_limit", 0x2a84 },
    .{ "aerobic_threshold", 0x2a7f },
    .{ "age", 0x2a80 },
    .{ "aggregate", 0x2a5a },
    .{ "alert_category_id", 0x2a43 },
    .{ "alert_category_id_bit_mask", 0x2a42 },
    .{ "alert_level", 0x2a06 },
    .{ "alert_notification_control_point", 0x2a44 },
    .{ "alert_status", 0x2a3f },
    .{ "altitude", 0x2ab3 },
    .{ "anaerobic_heart_rate_lower_limit", 0x2a81 },
    .{ "anaerobic_heart_rate_upper_limit", 0x2a82 },
    .{ "anaerobic_threshold", 0x2a83 },
    .{ "analog", 0x2a58 },
    .{ "analog_output", 0x2a59 },
    .{ "apparent_wind_direction", 0x2a73 },
    .{ "apparent_wind_speed", 0x2a72 },
    .{ "gap.appearance", 0x2a01 },
    .{ "barometric_pressure_trend", 0x2aa3 },
    .{ "battery_level", 0x2a19 },
    .{ "battery_level_state", 0x2a1b },
    .{ "battery_power_state", 0x2a1a },
    .{ "blood_pressure_feature", 0x2a49 },
    .{ "blood_pressure_measurement", 0x2a35 },
    .{ "body_composition_feature", 0x2a9b },
    .{ "body_composition_measurement", 0x2a9c },
    .{ "body_sensor_location", 0x2a38 },
    .{ "bond_management_control_point", 0x2aa4 },
    .{ "bond_management_feature", 0x2aa5 },
    .{ "boot_keyboard_input_report", 0x2a22 },
    .{ "boot_keyboard_output_report", 0x2a32 },
    .{ "boot_mouse_input_report", 0x2a33 },
    .{ "gap.central_address_resolution_support", 0x2aa6 },
    .{ "cgm_feature", 0x2aa8 },
    .{ "cgm_measurement", 0x2aa7 },
    .{ "cgm_session_run_time", 0x2aab },
    .{ "cgm_session_start_time", 0x2aaa },
    .{ "cgm_specific_ops_control_point", 0x2aac },
    .{ "cgm_status", 0x2aa9 },
    .{ "cross_trainer_data", 0x2ace },
    .{ "csc_feature", 0x2a5c },
    .{ "csc_measurement", 0x2a5b },
    .{ "current_time", 0x2a2b },
    .{ "cycling_power_control_point", 0x2a66 },
    .{ "cycling_power_feature", 0x2a65 },
    .{ "cycling_power_measurement", 0x2a63 },
    .{ "cycling_power_vector", 0x2a64 },
    .{ "database_change_increment", 0x2a99 },
    .{ "date_of_birth", 0x2a85 },
    .{ "date_of_threshold_assessment", 0x2a86 },
    .{ "date_time", 0x2a08 },
    .{ "date_utc", 0x2aed },
    .{ "day_date_time", 0x2a0a },
    .{ "day_of_week", 0x2a09 },
    .{ "descriptor_value_changed", 0x2a7d },
    .{ "dew_point", 0x2a7b },
    .{ "digital", 0x2a56 },
    .{ "digital_output", 0x2a57 },
    .{ "dst_offset", 0x2a0d },
    .{ "elevation", 0x2a6c },
    .{ "email_address", 0x2a87 },
    .{ "exact_time_100", 0x2a0b },
    .{ "exact_time_256", 0x2a0c },
    .{ "fat_burn_heart_rate_lower_limit", 0x2a88 },
    .{ "fat_burn_heart_rate_upper_limit", 0x2a89 },
    .{ "firmware_revision_string", 0x2a26 },
    .{ "first_name", 0x2a8a },
    .{ "fitness_machine_control_point", 0x2ad9 },
    .{ "fitness_machine_feature", 0x2acc },
    .{ "fitness_machine_status", 0x2ada },
    .{ "five_zone_heart_rate_limits", 0x2a8b },
    .{ "floor_number", 0x2ab2 },
    .{ "gender", 0x2a8c },
    .{ "glucose_feature", 0x2a51 },
    .{ "glucose_measurement", 0x2a18 },
    .{ "glucose_measurement_context", 0x2a34 },
    .{ "gust_factor", 0x2a74 },
    .{ "hardware_revision_string", 0x2a27 },
    .{ "heart_rate_control_point", 0x2a39 },
    .{ "heart_rate_max", 0x2a8d },
    .{ "heart_rate_measurement", 0x2a37 },
    .{ "heat_index", 0x2a7a },
    .{ "height", 0x2a8e },
    .{ "hid_control_point", 0x2a4c },
    .{ "hid_information", 0x2a4a },
    .{ "hip_circumference", 0x2a8f },
    .{ "humidity", 0x2a6f },
    .{ "ieee_11073-20601_regulatory_certification_data_list", 0x2a2a },
    .{ "indoor_bike_data", 0x2ad2 },
    .{ "indoor_positioning_configuration", 0x2aad },
    .{ "intermediate_cuff_pressure", 0x2a36 },
    .{ "intermediate_temperature", 0x2a1e },
    .{ "irradiance", 0x2a77 },
    .{ "language", 0x2aa2 },
    .{ "last_name", 0x2a90 },
    .{ "latitude", 0x2aae },
    .{ "ln_control_point", 0x2a6b },
    .{ "ln_feature", 0x2a6a },
    .{ "local_east_coordinate", 0x2ab1 },
    .{ "local_north_coordinate", 0x2ab0 },
    .{ "local_time_information", 0x2a0f },
    .{ "location_and_speed", 0x2a67 },
    .{ "location_name", 0x2ab5 },
    .{ "longitude", 0x2aaf },
    .{ "magnetic_declination", 0x2a2c },
    .{ "magnetic_flux_density_2D", 0x2aa0 },
    .{ "magnetic_flux_density_3D", 0x2aa1 },
    .{ "manufacturer_name_string", 0x2a29 },
    .{ "maximum_recommended_heart_rate", 0x2a91 },
    .{ "measurement_interval", 0x2a21 },
    .{ "model_number_string", 0x2a24 },
    .{ "navigation", 0x2a68 },
    .{ "new_alert", 0x2a46 },
    .{ "gap.peripheral_preferred_connection_parameters", 0x2a04 },
    .{ "gap.peripheral_privacy_flag", 0x2a02 },
    .{ "plx_continuous_measurement", 0x2a5f },
    .{ "plx_features", 0x2a60 },
    .{ "plx_spot_check_measurement", 0x2a5e },
    .{ "pnp_id", 0x2a50 },
    .{ "pollen_concentration", 0x2a75 },
    .{ "position_2d", 0x2a2f },
    .{ "position_3d", 0x2a30 },
    .{ "position_quality", 0x2a69 },
    .{ "pressure", 0x2a6d },
    .{ "protocol_mode", 0x2a4e },
    .{ "rainfall", 0x2a78 },
    .{ "gap.reconnection_address", 0x2a03 },
    .{ "record_access_control_point", 0x2a52 },
    .{ "reference_time_information", 0x2a14 },
    .{ "report", 0x2a4d },
    .{ "report_map", 0x2a4b },
    .{ "resolvable_private_address_only", 0x2ac9 },
    .{ "resting_heart_rate", 0x2a92 },
    .{ "ringer_control_point", 0x2a40 },
    .{ "ringer_setting", 0x2a41 },
    .{ "rower_data", 0x2ad1 },
    .{ "rsc_feature", 0x2a54 },
    .{ "rsc_measurement", 0x2a53 },
    .{ "sc_control_point", 0x2a55 },
    .{ "scan_interval_window", 0x2a4f },
    .{ "scan_refresh", 0x2a31 },
    .{ "sensor_location", 0x2a5d },
    .{ "serial_number_string", 0x2a25 },
    .{ "gap.device_name", 0x2a00 },
    .{ "software_revision_string", 0x2a28 },
    .{ "sport_type_for_aerobic_and_anaerobic_thresholds", 0x2a93 },
    .{ "stair_climber_data", 0x2ad0 },
    .{ "step_climber_data", 0x2acf },
    .{ "string", 0x2a3d },
    .{ "supported_heart_rate_range", 0x2ad7 },
    .{ "supported_inclination_range", 0x2ad5 },
    .{ "supported_new_alert_category", 0x2a47 },
    .{ "supported_power_range", 0x2ad8 },
    .{ "supported_resistance_level_range", 0x2ad6 },
    .{ "supported_speed_range", 0x2ad4 },
    .{ "supported_unread_alert_category", 0x2a48 },
    .{ "system_id", 0x2a23 },
    .{ "temperature", 0x2a6e },
    .{ "temperature_measurement", 0x2a1c },
    .{ "temperature_type", 0x2a1d },
    .{ "three_zone_heart_rate_limits", 0x2a94 },
    .{ "time_accuracy", 0x2a12 },
    .{ "time_broadcast", 0x2a15 },
    .{ "time_source", 0x2a13 },
    .{ "time_update_control_point", 0x2a16 },
    .{ "time_update_state", 0x2a17 },
    .{ "time_with_dst", 0x2a11 },
    .{ "time_zone", 0x2a0e },
    .{ "training_status", 0x2ad3 },
    .{ "treadmill_data", 0x2acd },
    .{ "true_wind_direction", 0x2a71 },
    .{ "true_wind_speed", 0x2a70 },
    .{ "two_zone_heart_rate_limit", 0x2a95 },
    .{ "tx_power_level", 0x2a07 },
    .{ "uncertainty", 0x2ab4 },
    .{ "unread_alert_status", 0x2a45 },
    .{ "user_control_point", 0x2a9f },
    .{ "user_index", 0x2a9a },
    .{ "uv_index", 0x2a76 },
    .{ "vo2_max", 0x2a96 },
    .{ "waist_circumference", 0x2a97 },
    .{ "weight", 0x2a98 },
    .{ "weight_measurement", 0x2a9d },
    .{ "weight_scale_feature", 0x2a9e },
    .{ "wind_chill", 0x2a79 },
});

// 6 names, each measured against a headed Chrome 150.
const descriptor_names = std.StaticStringMap(u16).initComptime(.{
    .{ "gatt.characteristic_extended_properties", 0x2900 },
    .{ "gatt.characteristic_user_description", 0x2901 },
    .{ "gatt.client_characteristic_configuration", 0x2902 },
    .{ "gatt.server_characteristic_configuration", 0x2903 },
    .{ "gatt.characteristic_presentation_format", 0x2904 },
    .{ "gatt.characteristic_aggregate_format", 0x2905 },
});

const SUFFIX = "-0000-1000-8000-00805f9b34fb";

// Chrome's canonical form, verified against every alias from 0x0000 to 0xffff
// and sampled up to 0xffffffff: the value as eight lowercase hex digits, then
// the Bluetooth base UUID.
fn canonical(alias: u32, exec: *const Execution) ![]const u8 {
    return std.fmt.allocPrint(exec.call_arena, "{x:0>8}" ++ SUFFIX, .{alias});
}

// A custom UUID is handed straight back, but only in the lowercase canonical
// form: Chrome rejects '0000180F-...' and '0x180f' and '180f' alike (measured).
fn isCanonicalUuid(text: []const u8) bool {
    if (text.len != 36) return false;
    for (text, 0..) |c, i| {
        switch (i) {
            8, 13, 18, 23 => if (c != '-') return false,
            else => if (!std.ascii.isDigit(c) and !(c >= 'a' and c <= 'f')) return false,
        }
    }
    return true;
}

/// The four static string functions. No device is involved, so these are the
/// one part of Web Bluetooth that works here exactly as it does on Chrome.
pub const BluetoothUUID = struct {
    _pad: bool = false,

    // `[EnforceRange] unsigned long`: a value that is not a number at all and a
    // number outside the range carry different messages, both measured.
    pub fn canonicalUUID(alias_: ?js.Value, exec: *const Execution) ![]const u8 {
        const value = alias_ orelse return throwTypeError(
            "Failed to execute 'canonicalUUID' on 'BluetoothUUID': 1 argument required, but only 0 present.",
            exec,
        );
        const number = value.toZig(f64) catch std.math.nan(f64);
        if (std.math.isNan(number)) return throwTypeError(
            "Failed to execute 'canonicalUUID' on 'BluetoothUUID': Value is not of type 'unsigned long'.",
            exec,
        );
        // An infinity gets its own wording, distinct from a finite out-of-range
        // value (measured).
        if (std.math.isInf(number)) return throwTypeError(
            "Failed to execute 'canonicalUUID' on 'BluetoothUUID': " ++
                "Value is infinite and not of type 'unsigned long'.",
            exec,
        );
        if (number < 0 or number > 4294967295) return throwTypeError(
            "Failed to execute 'canonicalUUID' on 'BluetoothUUID': Value is outside the 'unsigned long' value range.",
            exec,
        );
        return canonical(@intFromFloat(@trunc(number)), exec);
    }

    // The three name lookups share one rule, which differs from canonicalUUID's
    // in two measured ways: the argument is a `(DOMString or unsigned long)`
    // union, so dispatch is on the JS type rather than by coercion (null
    // becomes the string "null" and is rejected, not zero); and the numeric arm
    // wraps instead of enforcing a range, so getService(-1) answers
    // ffffffff-... where canonicalUUID(-1) throws.
    fn resolve(
        comptime kind: []const u8,
        comptime plural: []const u8,
        comptime example: []const u8,
        names: std.StaticStringMap(u16),
        name_: ?js.Value,
        exec: *const Execution,
    ) ![]const u8 {
        const value = name_ orelse return throwTypeError(
            "Failed to execute 'get" ++ kind ++ "' on 'BluetoothUUID': 1 argument required, but only 0 present.",
            exec,
        );
        if (value.isNumber()) {
            // ToUint32: wrap into [0, 2^32), and NaN or an infinity becomes 0.
            const number = try value.toZig(f64);
            const wrapped = if (std.math.isNan(number) or std.math.isInf(number))
                0
            else
                @mod(@trunc(number), 4294967296);
            return canonical(@intFromFloat(wrapped), exec);
        }

        const text = try value.toStringSlice();
        if (names.get(text)) |alias| return canonical(alias, exec);
        if (isCanonicalUuid(text)) return exec.call_arena.dupe(u8, text);

        return throwTypeError(try std.fmt.allocPrint(
            exec.call_arena,
            "Failed to execute 'get" ++ kind ++ "' on 'BluetoothUUID': Invalid " ++ kind ++
                " name: '{s}'. It must be a valid UUID alias (e.g. 0x1234), UUID (lowercase hex " ++
                "characters e.g. '00001234" ++ SUFFIX ++ "'), or recognized standard name from " ++
                "https://www.bluetooth.com/specifications/gatt/" ++ plural ++ " e.g. '" ++ example ++ "'.",
            .{text},
        ), exec);
    }

    pub fn getService(name: ?js.Value, exec: *const Execution) ![]const u8 {
        return resolve("Service", "services", "alert_notification", service_names, name, exec);
    }

    pub fn getCharacteristic(name: ?js.Value, exec: *const Execution) ![]const u8 {
        return resolve("Characteristic", "characteristics", "aerobic_heart_rate_lower_limit", characteristic_names, name, exec);
    }

    pub fn getDescriptor(name: ?js.Value, exec: *const Execution) ![]const u8 {
        return resolve("Descriptor", "descriptors", "gatt.characteristic_presentation_format", descriptor_names, name, exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(BluetoothUUID);

        pub const Meta = struct {
            pub const name = "BluetoothUUID";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        // Chrome's own static order.
        pub const canonicalUUID = bridge.function(BluetoothUUID.canonicalUUID, .{ .static = true, .arity = 1 });
        pub const getCharacteristic = bridge.function(BluetoothUUID.getCharacteristic, .{ .static = true, .arity = 1 });
        pub const getDescriptor = bridge.function(BluetoothUUID.getDescriptor, .{ .static = true, .arity = 1 });
        pub const getService = bridge.function(BluetoothUUID.getService, .{ .static = true, .arity = 1 });
    };
};

// Everything below describes an object no script can obtain, so the members
// answer for a device that was never paired: no name, no services, and a GATT
// server that is not connected. See the module comment.

fn notConnected(exec: *const Execution) js.Promise {
    return exec.js.local.?.rejectPromise(.{ .dom_exception = .{ .err = error.NetworkError } });
}

pub const BluetoothCharacteristicProperties = struct {
    _pad: bool = false,

    fn no(_: *const BluetoothCharacteristicProperties) bool {
        return false;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(BluetoothCharacteristicProperties);

        pub const Meta = struct {
            pub const name = "BluetoothCharacteristicProperties";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const off = BluetoothCharacteristicProperties.no;

        // Chrome's own prototype order.
        pub const broadcast = bridge.accessor(off, null, .{});
        pub const read = bridge.accessor(off, null, .{});
        pub const writeWithoutResponse = bridge.accessor(off, null, .{});
        pub const write = bridge.accessor(off, null, .{});
        pub const notify = bridge.accessor(off, null, .{});
        pub const indicate = bridge.accessor(off, null, .{});
        pub const authenticatedSignedWrites = bridge.accessor(off, null, .{});
        pub const reliableWrite = bridge.accessor(off, null, .{});
        pub const writableAuxiliaries = bridge.accessor(off, null, .{});
    };
};

pub const BluetoothDevice = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    pub fn asEventTarget(self: *BluetoothDevice) *EventTarget {
        return self._proto;
    }

    pub fn getId(_: *const BluetoothDevice) []const u8 {
        return "";
    }

    pub fn getName(_: *const BluetoothDevice) ?[]const u8 {
        return null;
    }

    pub fn getGatt(_: *const BluetoothDevice) ?*BluetoothRemoteGATTServer {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(BluetoothDevice);

        pub const Meta = struct {
            pub const name = "BluetoothDevice";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = EventTarget;

        pub const id = bridge.accessor(BluetoothDevice.getId, null, .{});
        pub const name = bridge.accessor(BluetoothDevice.getName, null, .{});
        pub const gatt = bridge.accessor(BluetoothDevice.getGatt, null, .{});
        pub const ongattserverdisconnected = bridge.accessor(handlerProperty(BluetoothDevice, .ongattserverdisconnected).get, handlerProperty(BluetoothDevice, .ongattserverdisconnected).set, .{});
    };
};

pub const BluetoothRemoteGATTServer = struct {
    _pad: bool = false,

    pub fn getDevice(_: *const BluetoothRemoteGATTServer) ?*BluetoothDevice {
        return null;
    }

    pub fn getConnected(_: *const BluetoothRemoteGATTServer) bool {
        return false;
    }

    pub fn connect(_: *const BluetoothRemoteGATTServer, exec: *const Execution) js.Promise {
        return notConnected(exec);
    }

    pub fn disconnect(_: *const BluetoothRemoteGATTServer) void {}

    pub fn getPrimaryService(_: *const BluetoothRemoteGATTServer, _: ?js.Value, exec: *const Execution) js.Promise {
        return notConnected(exec);
    }

    pub fn getPrimaryServices(_: *const BluetoothRemoteGATTServer, _: ?js.Value, exec: *const Execution) js.Promise {
        return notConnected(exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(BluetoothRemoteGATTServer);

        pub const Meta = struct {
            pub const name = "BluetoothRemoteGATTServer";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const device = bridge.accessor(BluetoothRemoteGATTServer.getDevice, null, .{});
        pub const connected = bridge.accessor(BluetoothRemoteGATTServer.getConnected, null, .{});
        pub const connect = bridge.function(BluetoothRemoteGATTServer.connect, .{});
        pub const disconnect = bridge.function(BluetoothRemoteGATTServer.disconnect, .{});
        pub const getPrimaryService = bridge.function(BluetoothRemoteGATTServer.getPrimaryService, .{ .arity = 1 });
        pub const getPrimaryServices = bridge.function(BluetoothRemoteGATTServer.getPrimaryServices, .{ .arity = 0 });
    };
};

pub const BluetoothRemoteGATTService = struct {
    _pad: bool = false,

    pub fn getDevice(_: *const BluetoothRemoteGATTService) ?*BluetoothDevice {
        return null;
    }

    pub fn getUuid(_: *const BluetoothRemoteGATTService) []const u8 {
        return "";
    }

    pub fn getIsPrimary(_: *const BluetoothRemoteGATTService) bool {
        return false;
    }

    pub fn getCharacteristic(_: *const BluetoothRemoteGATTService, _: ?js.Value, exec: *const Execution) js.Promise {
        return notConnected(exec);
    }

    pub fn getCharacteristics(_: *const BluetoothRemoteGATTService, _: ?js.Value, exec: *const Execution) js.Promise {
        return notConnected(exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(BluetoothRemoteGATTService);

        pub const Meta = struct {
            pub const name = "BluetoothRemoteGATTService";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const device = bridge.accessor(BluetoothRemoteGATTService.getDevice, null, .{});
        pub const uuid = bridge.accessor(BluetoothRemoteGATTService.getUuid, null, .{});
        pub const isPrimary = bridge.accessor(BluetoothRemoteGATTService.getIsPrimary, null, .{});
        pub const getCharacteristic = bridge.function(BluetoothRemoteGATTService.getCharacteristic, .{ .arity = 1 });
        pub const getCharacteristics = bridge.function(BluetoothRemoteGATTService.getCharacteristics, .{ .arity = 0 });
    };
};

pub const BluetoothRemoteGATTCharacteristic = struct {
    pub const Proto = EventTarget;

    _proto: *EventTarget,

    pub fn asEventTarget(self: *BluetoothRemoteGATTCharacteristic) *EventTarget {
        return self._proto;
    }

    pub fn getService(_: *const BluetoothRemoteGATTCharacteristic) ?*BluetoothRemoteGATTService {
        return null;
    }

    pub fn getUuid(_: *const BluetoothRemoteGATTCharacteristic) []const u8 {
        return "";
    }

    pub fn getProperties(_: *const BluetoothRemoteGATTCharacteristic) ?*BluetoothCharacteristicProperties {
        return null;
    }

    pub fn getValue(_: *const BluetoothRemoteGATTCharacteristic) ?[]const u8 {
        return null;
    }

    pub fn getDescriptor(_: *const BluetoothRemoteGATTCharacteristic, _: ?js.Value, exec: *const Execution) js.Promise {
        return notConnected(exec);
    }

    pub fn getDescriptors(_: *const BluetoothRemoteGATTCharacteristic, _: ?js.Value, exec: *const Execution) js.Promise {
        return notConnected(exec);
    }

    pub fn readValue(_: *const BluetoothRemoteGATTCharacteristic, exec: *const Execution) js.Promise {
        return notConnected(exec);
    }

    pub fn startNotifications(_: *const BluetoothRemoteGATTCharacteristic, exec: *const Execution) js.Promise {
        return notConnected(exec);
    }

    pub fn stopNotifications(_: *const BluetoothRemoteGATTCharacteristic, exec: *const Execution) js.Promise {
        return notConnected(exec);
    }

    pub fn writeValue(_: *const BluetoothRemoteGATTCharacteristic, _: ?js.Value, exec: *const Execution) js.Promise {
        return notConnected(exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(BluetoothRemoteGATTCharacteristic);

        pub const Meta = struct {
            pub const name = "BluetoothRemoteGATTCharacteristic";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = EventTarget;

        const C = BluetoothRemoteGATTCharacteristic;

        pub const service = bridge.accessor(C.getService, null, .{});
        pub const uuid = bridge.accessor(C.getUuid, null, .{});
        pub const properties = bridge.accessor(C.getProperties, null, .{});
        pub const value = bridge.accessor(C.getValue, null, .{});
        pub const oncharacteristicvaluechanged = bridge.accessor(handlerProperty(BluetoothRemoteGATTCharacteristic, .oncharacteristicvaluechanged).get, handlerProperty(BluetoothRemoteGATTCharacteristic, .oncharacteristicvaluechanged).set, .{});
        pub const getDescriptor = bridge.function(C.getDescriptor, .{ .arity = 1 });
        pub const getDescriptors = bridge.function(C.getDescriptors, .{ .arity = 0 });
        pub const readValue = bridge.function(C.readValue, .{});
        pub const startNotifications = bridge.function(C.startNotifications, .{});
        pub const stopNotifications = bridge.function(C.stopNotifications, .{});
        pub const writeValue = bridge.function(C.writeValue, .{ .arity = 1 });
        pub const writeValueWithResponse = bridge.function(C.writeValue, .{ .arity = 1 });
        pub const writeValueWithoutResponse = bridge.function(C.writeValue, .{ .arity = 1 });
    };
};

pub const BluetoothRemoteGATTDescriptor = struct {
    _pad: bool = false,

    pub fn getCharacteristic(_: *const BluetoothRemoteGATTDescriptor) ?*BluetoothRemoteGATTCharacteristic {
        return null;
    }

    pub fn getUuid(_: *const BluetoothRemoteGATTDescriptor) []const u8 {
        return "";
    }

    pub fn getValue(_: *const BluetoothRemoteGATTDescriptor) ?[]const u8 {
        return null;
    }

    pub fn readValue(_: *const BluetoothRemoteGATTDescriptor, exec: *const Execution) js.Promise {
        return notConnected(exec);
    }

    pub fn writeValue(_: *const BluetoothRemoteGATTDescriptor, _: ?js.Value, exec: *const Execution) js.Promise {
        return notConnected(exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(BluetoothRemoteGATTDescriptor);

        pub const Meta = struct {
            pub const name = "BluetoothRemoteGATTDescriptor";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const D = BluetoothRemoteGATTDescriptor;

        pub const characteristic = bridge.accessor(D.getCharacteristic, null, .{});
        pub const uuid = bridge.accessor(D.getUuid, null, .{});
        pub const value = bridge.accessor(D.getValue, null, .{});
        pub const readValue = bridge.function(D.readValue, .{});
        pub const writeValue = bridge.function(D.writeValue, .{ .arity = 1 });
    };
};
