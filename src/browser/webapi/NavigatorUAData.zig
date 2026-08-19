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

const Config = @import("../../Config.zig");
const claimed_platform = @import("../../claimed_platform.zig");
const js = @import("../js/js.zig");
const Execution = js.Execution;

const NavigatorUAData = @This();

_pad: bool = false,

const Brand = Config.HttpHeaders.Brand;

pub fn getBrands(_: *const NavigatorUAData, exec: *const Execution) []const Brand {
    return brandList(exec);
}

pub fn getMobile(_: *const NavigatorUAData) bool {
    return false;
}

pub fn getPlatform(_: *const NavigatorUAData, exec: *const Execution) []const u8 {
    return uaPlatform(exec);
}

pub fn toJSON(_: *const NavigatorUAData, exec: *const Execution) struct {
    brands: []const Brand,
    mobile: bool,
    platform: []const u8,
} {
    return .{
        .mobile = false,
        .brands = brandList(exec),
        .platform = uaPlatform(exec),
    };
}

// Chrome returns the low-entropy set — brands, mobile, platform — plus only
// the hints the caller asked for. Upstream ignored `hints` and returned
// everything, which is a behavioural difference a page can see in one call:
// asking for nothing and getting formFactor back is not something Chrome does.
pub fn getHighEntropyValues(_: *const NavigatorUAData, hints: []const []const u8, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;
    const values = local.newObject();

    // Always present, whatever was asked for.
    _ = try values.set("brands", brandList(exec), .{});
    _ = try values.set("mobile", false, .{});
    _ = try values.set("platform", uaPlatform(exec), .{});

    for (hints) |hint| {
        if (std.mem.eql(u8, hint, "architecture")) {
            _ = try values.set("architecture", uaArchitecture(), .{});
        } else if (std.mem.eql(u8, hint, "bitness")) {
            _ = try values.set("bitness", uaBitness(), .{});
        } else if (std.mem.eql(u8, hint, "model")) {
            _ = try values.set("model", "", .{});
        } else if (std.mem.eql(u8, hint, "platformVersion")) {
            // The OS version, from the platform claim rather than from a syscall
            // on the host — see claimed_platform.zig. Not a hint we can decline
            // by answering "": that empty string is itself one platform's answer
            // (the Linux Chrome's) and a mismatch under the other's claim.
            _ = try values.set("platformVersion", uaPlatformVersion(), .{});
        } else if (std.mem.eql(u8, hint, "uaFullVersion")) {
            _ = try values.set("uaFullVersion", uaFullVersion(exec), .{});
        } else if (std.mem.eql(u8, hint, "fullVersionList")) {
            _ = try values.set("fullVersionList", fullVersionList(exec), .{});
        } else if (std.mem.eql(u8, hint, "wow64")) {
            _ = try values.set("wow64", false, .{});
        } else if (std.mem.eql(u8, hint, "formFactors")) {
            _ = try values.set("formFactors", [_][]const u8{"Desktop"}, .{});
        }
        // Unknown hints are ignored, as in Chrome.
    }

    return local.resolvePromise(values);
}

// Same list the Sec-Ch-Ua header is built from, so the header and
// navigator.userAgentData.brands cannot drift apart.
fn brandList(exec: *const Execution) []const Brand {
    return exec.session.browser.http_client.httpHeaders().brands;
}

// The four-part versions, resolved next to the brands in Config so the two
// lists can't disagree. Hardcoding "1.0.0.0" here left uaFullVersion
// contradicting the brands beside it, which report 150 by default.
fn fullVersionList(exec: *const Execution) []const Brand {
    return exec.session.browser.http_client.httpHeaders().full_version_brands;
}

// The version of whichever brand names the browser itself — the last entry, as
// in Chrome's own list.
fn uaFullVersion(exec: *const Execution) []const u8 {
    const brands = fullVersionList(exec);
    return if (brands.len == 0) "" else brands[brands.len - 1].version;
}

// Configured via --sec-ch-ua-platform or CDP Emulation.setUserAgentOverride,
// defaulting to the host OS. Same value the Sec-Ch-Ua-Platform header carries.
fn uaPlatform(exec: *const Execution) []const u8 {
    return exec.session.browser.http_client.getPlatform();
}

// The CPU the *claim* names, not the one this was built for. Deriving these
// from builtin.cpu.arch read as the more honest choice and was not: an
// architecture of "arm" sitting beside a user-agent that says Linux x86_64 is a
// contradiction one getHighEntropyValues() call away.
fn uaArchitecture() []const u8 {
    return claimed_platform.architecture;
}

fn uaBitness() []const u8 {
    return claimed_platform.bitness;
}

fn uaPlatformVersion() []const u8 {
    return claimed_platform.platform_version;
}

pub const JsApi = struct {
    pub const bridge = js.Bridge(NavigatorUAData);

    pub const Meta = struct {
        pub const name = "NavigatorUAData";
        pub const prototype_chain = bridge.prototypeChain();
        pub var class_id: bridge.ClassId = undefined;
        pub const empty_with_no_proto = true;
    };

    pub const brands = bridge.accessor(NavigatorUAData.getBrands, null, .{});
    pub const mobile = bridge.accessor(NavigatorUAData.getMobile, null, .{});
    pub const platform = bridge.accessor(NavigatorUAData.getPlatform, null, .{});
    pub const toJSON = bridge.function(NavigatorUAData.toJSON, .{});
    pub const getHighEntropyValues = bridge.function(NavigatorUAData.getHighEntropyValues, .{});
};
