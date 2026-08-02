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

//! Trusted Types: window.trustedTypes and the five interfaces behind it.
//!
//! Nothing here enforces anything -- this engine has no CSP require-trusted-types
//! sink to guard, so a TrustedHTML is just a branded box around the string the
//! page's own policy produced. That is exactly what an unenforced Chrome does
//! too: without the CSP directive, createHTML() hands back a TrustedHTML and no
//! sink ever checks it. What matters for parity is the surface -- five globals,
//! their prototypes, the factory's answers, and the type mapping -- all measured
//! on a headed Chrome 150 over http://localhost.

const std = @import("std");

const js = @import("../js/js.zig");
const Frame = @import("../Frame.zig");
const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        TrustedTypePolicyFactory,
        TrustedTypePolicy,
        TrustedHTML,
        TrustedScript,
        TrustedScriptURL,
    };
}

// The three value types differ only in their brand, so they share a body.
fn TrustedValue(comptime type_name: [:0]const u8) type {
    return struct {
        const Self = @This();

        _value: []const u8,

        // Chrome's toString and toJSON both give back the raw string.
        pub fn toString(self: *const Self) []const u8 {
            return self._value;
        }

        pub fn toJSON(self: *const Self) []const u8 {
            return self._value;
        }

        pub const JsApi = struct {
            pub const bridge = js.Bridge(Self);

            pub const Meta = struct {
                pub const name = type_name;
                pub const prototype_chain = bridge.prototypeChain();
                pub var class_id: bridge.ClassId = undefined;
            };

            pub const toJSON = bridge.function(Self.toJSON, .{});
            pub const toString = bridge.function(Self.toString, .{});
        };
    };
}

pub const TrustedHTML = TrustedValue("TrustedHTML");
pub const TrustedScript = TrustedValue("TrustedScript");
pub const TrustedScriptURL = TrustedValue("TrustedScriptURL");

// Which of the three types a given attribute or property is a sink for. Blink
// keeps one table for both questions; getTypeMapping() returns it whole.
const Sink = enum {
    html,
    script,
    script_url,

    fn typeName(self: Sink) []const u8 {
        return switch (self) {
            .html => "TrustedHTML",
            .script => "TrustedScript",
            .script_url => "TrustedScriptURL",
        };
    }
};

const Entry = struct { []const u8, Sink };

const Element = struct {
    tag: []const u8,
    attributes: []const Entry,
    properties: []const Entry,
};

// getTypeMapping()'s table, transcribed from the measurement. The four element
// rows are short; the wildcard row's attribute list is every event-handler
// content attribute Blink knows -- 321 of them, more than this engine
// dispatches, so it is a list of names rather than something derived from
// global_event_handlers.Handler.
const ELEMENTS = [_]Element{
    .{
        .tag = "embed",
        .attributes = &.{.{ "src", .script_url }},
        .properties = &.{.{ "src", .script_url }},
    },
    .{
        .tag = "iframe",
        .attributes = &.{.{ "srcdoc", .html }},
        .properties = &.{.{ "srcdoc", .html }},
    },
    .{
        .tag = "object",
        .attributes = &.{ .{ "codebase", .script_url }, .{ "data", .script_url } },
        .properties = &.{ .{ "codeBase", .script_url }, .{ "data", .script_url } },
    },
    .{
        .tag = "script",
        .attributes = &.{ .{ "src", .script_url }, .{ "href", .script_url } },
        .properties = &.{
            .{ "innerText", .script },
            .{ "src", .script_url },
            .{ "text", .script },
            .{ "textContent", .script },
            .{ "href", .script_url },
        },
    },
};

const WILDCARD_PROPERTIES = [_]Entry{ .{ "innerHTML", .html }, .{ "outerHTML", .html } };

const WILDCARD_ATTRIBUTES = [_][]const u8{
    "onabort",                      "onabortpayment",             "onactivate",               "onactive",                      "onaddsourcebuffer",                  "onaddstream",
    "onaddtrack",                   "onadvertisementreceived",    "onafterprint",             "onanimationcancel",             "onanimationend",                     "onanimationiteration",
    "onanimationstart",             "onappinstalled",             "onaudioend",               "onaudioprocess",                "onaudiostart",                       "onautofill",
    "onauxclick",                   "onbackgroundfetchabort",     "onbackgroundfetchclick",   "onbackgroundfetchfail",         "onbackgroundfetchsuccess",           "onbeforecopy",
    "onbeforecut",                  "onbeforefilter",             "onbeforeinput",            "onbeforeinstallprompt",         "onbeforematch",                      "onbeforepaste",
    "onbeforeprint",                "onbeforetoggle",             "onbeforeunload",           "onbeforexrselect",              "onbegin",                            "onblocked",
    "onblur",                       "onboundary",                 "onbufferedamountlow",      "oncancel",                      "oncanmakepayment",                   "oncanplay",
    "oncanplaythrough",             "oncapturedmousechange",      "oncapturehandlechange",    "onchange",                      "oncharacterboundsupdate",            "oncharacteristicvaluechanged",
    "onchargingchange",             "onchargingtimechange",       "onclick",                  "onclipboardchange",             "onclose",                            "onclosing",
    "oncommand",                    "oncomplete",                 "oncompositionend",         "oncompositionstart",            "onconfigurationchange",              "onconnect",
    "onconnecting",                 "onconnectionavailable",      "onconnectionstatechange",  "oncontentdelete",               "oncontentvisibilityautostatechange", "oncontextlost",
    "oncontextmenu",                "oncontextoverflow",          "oncontextrestored",        "oncontrollerchange",            "oncookiechange",                     "oncopy",
    "oncuechange",                  "oncurrententrychange",       "oncurrentscreenchange",    "oncut",                         "ondataavailable",                    "ondatachannel",
    "ondblclick",                   "ondequeue",                  "ondevicechange",           "ondevicemotion",                "ondeviceorientation",                "ondeviceorientationabsolute",
    "ondischargingtimechange",      "ondisconnect",               "ondispose",                "ondownloadprogress",            "ondrag",                             "ondragend",
    "ondragenter",                  "ondragleave",                "ondragover",               "ondragstart",                   "ondrop",                             "ondurationchange",
    "onemptied",                    "onencrypted",                "onend",                    "onended",                       "onenter",                            "onenterpictureinpicture",
    "onerror",                      "onexit",                     "onfetch",                  "onfinish",                      "onfocus",                            "onformdata",
    "onframeratechange",            "onfreeze",                   "onfullscreenchange",       "onfullscreenerror",             "ongamepadconnected",                 "ongamepaddisconnected",
    "ongamepadrawinputchanged",     "ongatheringstatechange",     "ongattserverdisconnected", "ongeometrychange",              "ongotpointercapture",                "onhashchange",
    "onhdrheadroomchange",          "onicecandidate",             "onicecandidateerror",      "oniceconnectionstatechange",    "onicegatheringstatechange",          "oninactive",
    "oninput",                      "oninputreport",              "oninputsourceschange",     "oninstall",                     "oninterfacerequest",                 "oninvalid",
    "onjobstatechange",             "onkeydown",                  "onkeypress",               "onkeystatuseschange",           "onkeyup",                            "onlanguagechange",
    "onleavepictureinpicture",      "onlevelchange",              "onload",                   "onloadeddata",                  "onloadedmetadata",                   "onloadend",
    "onloading",                    "onloadingdone",              "onloadingerror",           "onloadstart",                   "onlocation",                         "onlostpointercapture",
    "onmanagedconfigurationchange", "onmark",                     "onmessage",                "onmessageerror",                "onmidimessage",                      "onmousedown",
    "onmouseenter",                 "onmouseleave",               "onmousemove",              "onmouseout",                    "onmouseover",                        "onmouseup",
    "onmousewheel",                 "onmove",                     "onmute",                   "onnavigate",                    "onnavigateerror",                    "onnavigatesuccess",
    "onnegotiationneeded",          "onnomatch",                  "onnotificationclick",      "onnotificationclose",           "onoffline",                          "ononline",
    "onopen",                       "onorientationchange",        "onoverscrollcancel",       "onoverscrollchanging",          "onoverscrollend",                    "onoverscrollstart",
    "onpagehide",                   "onpagereveal",               "onpageshow",               "onpageswap",                    "onpaint",                            "onpaste",
    "onpause",                      "onpayerdetailchange",        "onpaymentmethodchange",    "onpaymentrequest",              "onperiodicsync",                     "onplay",
    "onplaying",                    "onpointercancel",            "onpointerdown",            "onpointerenter",                "onpointerleave",                     "onpointerlockchange",
    "onpointerlockerror",           "onpointermove",              "onpointerout",             "onpointerover",                 "onpointerrawupdate",                 "onpointerup",
    "onpopstate",                   "onprerenderingchange",       "onprioritychange",         "onprocessorerror",              "onprogress",                         "onpromptaction",
    "onpromptdismiss",              "onpush",                     "onpushsubscriptionchange", "onquotaoverflow",               "onratechange",                       "onreading",
    "onreadingerror",               "onreadystatechange",         "onredraw",                 "onreflectionchange",            "onrejectionhandled",                 "onrelease",
    "onremove",                     "onremovesourcebuffer",       "onremovestream",           "onremovetrack",                 "onrepeat",                           "onreset",
    "onresize",                     "onresourcetimingbufferfull", "onresult",                 "onresume",                      "onrtctransform",                     "onscreenschange",
    "onscroll",                     "onscrollend",                "onscrollsnapchange",       "onscrollsnapchanging",          "onsearch",                           "onsecuritypolicyviolation",
    "onseeked",                     "onseeking",                  "onselect",                 "onselectedcandidatepairchange", "onselectend",                        "onselectionchange",
    "onselectstart",                "onshippingaddresschange",    "onshippingoptionchange",   "onshow",                        "onsignalingstatechange",             "onsinkchange",
    "onslotchange",                 "onsoundend",                 "onsoundstart",             "onsourceclose",                 "onsourceended",                      "onsourceopen",
    "onspeechend",                  "onspeechstart",              "onsqueeze",                "onsqueezeend",                  "onsqueezestart",                     "onstalled",
    "onstart",                      "onstatechange",              "onstop",                   "onstorage",                     "onstream",                           "onsubmit",
    "onsuccess",                    "onsuspend",                  "onsync",                   "onterminate",                   "ontextformatupdate",                 "ontextupdate",
    "ontimeout",                    "ontimeupdate",               "ontimezonechange",         "ontoggle",                      "ontonechange",                       "ontoolchange",
    "ontouchcancel",                "ontouchend",                 "ontouchmove",              "ontouchstart",                  "ontrack",                            "ontransitioncancel",
    "ontransitionend",              "ontransitionrun",            "ontransitionstart",        "ontypechange",                  "onuncapturederror",                  "onunhandledrejection",
    "onunload",                     "onunmute",                   "onupdate",                 "onupdateend",                   "onupdatefound",                      "onupdatestart",
    "onupgradeneeded",              "onvalidationstatuschange",   "onversionchange",          "onvisibilitychange",            "onvisibilitymaskchange",             "onvoiceschanged",
    "onvolumechange",               "onwaiting",                  "onwaitingforkey",          "onwebkitanimationend",          "onwebkitanimationiteration",         "onwebkitanimationstart",
    "onwebkitfullscreenchange",     "onwebkitfullscreenerror",    "onwebkittransitionend",    "onwheel",                       "onwritablechange",                   "onwrite",
    "onwriteend",                   "onwritestart",               "onzoomlevelchange",
};

fn lookupElement(tag: []const u8) ?*const Element {
    for (&ELEMENTS) |*element| {
        if (std.mem.eql(u8, element.tag, tag)) return element;
    }
    return null;
}

fn lookupEntry(entries: []const Entry, name: []const u8) ?Sink {
    for (entries) |entry| {
        if (std.mem.eql(u8, entry[0], name)) return entry[1];
    }
    return null;
}

fn isWildcardAttribute(name: []const u8) bool {
    for (WILDCARD_ATTRIBUTES) |candidate| {
        if (std.mem.eql(u8, candidate, name)) return true;
    }
    return false;
}

pub const TrustedTypePolicy = struct {
    _name: []const u8,
    // The three options callbacks. Absent ones stay null and make the matching
    // create* throw, which is what Chrome does.
    _create_html: ?js.Function.Global = null,
    _create_script: ?js.Function.Global = null,
    _create_script_url: ?js.Function.Global = null,

    pub const Options = struct {
        createHTML: ?js.Function = null,
        createScript: ?js.Function = null,
        createScriptURL: ?js.Function = null,
    };

    pub fn getName(self: *const TrustedTypePolicy) []const u8 {
        return self._name;
    }

    // Chrome's wording, measured:
    //   Failed to execute 'createHTML' on 'TrustedTypePolicy': Policy <name>'s
    //   TrustedTypePolicyOptions did not specify a 'createHTML' member.
    // Thrown straight onto the isolate rather than mapped from a Zig error,
    // because the bridge's error mapping has no way to carry a message.
    // error.JsException tells Caller an exception is already pending.
    fn missingMember(
        self: *const TrustedTypePolicy,
        comptime member: []const u8,
        frame: *Frame,
    ) anyerror {
        const message = std.fmt.allocPrint(
            frame.call_arena,
            "Failed to execute '" ++ member ++ "' on 'TrustedTypePolicy': Policy {s}'s " ++
                "TrustedTypePolicyOptions did not specify a '" ++ member ++ "' member.",
            .{self._name},
        ) catch return error.TypeError;
        const isolate = frame.js.isolate;
        _ = isolate.throwException(isolate.createTypeError(message));
        return error.JsException;
    }

    fn apply(
        callback: ?js.Function.Global,
        input: ?[]const u8,
        frame: *Frame,
    ) ![]const u8 {
        const local = frame.js.local.?;
        const result = try callback.?.local(local).call([]const u8, .{input orelse ""});
        return frame.dupeString(result);
    }

    pub fn createHTML(
        self: *TrustedTypePolicy,
        input: ?[]const u8,
        frame: *Frame,
    ) !*TrustedHTML {
        if (self._create_html == null) return self.missingMember("createHTML", frame);
        return frame._factory.create(TrustedHTML{ ._value = try apply(self._create_html, input, frame) });
    }

    pub fn createScript(
        self: *TrustedTypePolicy,
        input: ?[]const u8,
        frame: *Frame,
    ) !*TrustedScript {
        if (self._create_script == null) return self.missingMember("createScript", frame);
        return frame._factory.create(TrustedScript{ ._value = try apply(self._create_script, input, frame) });
    }

    pub fn createScriptURL(
        self: *TrustedTypePolicy,
        input: ?[]const u8,
        frame: *Frame,
    ) !*TrustedScriptURL {
        if (self._create_script_url == null) return self.missingMember("createScriptURL", frame);
        return frame._factory.create(TrustedScriptURL{ ._value = try apply(self._create_script_url, input, frame) });
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(TrustedTypePolicy);

        pub const Meta = struct {
            pub const name = "TrustedTypePolicy";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const name = bridge.accessor(TrustedTypePolicy.getName, null, .{});
        pub const createHTML = bridge.function(TrustedTypePolicy.createHTML, .{ .arity = 1 });
        pub const createScript = bridge.function(TrustedTypePolicy.createScript, .{ .arity = 1 });
        pub const createScriptURL = bridge.function(TrustedTypePolicy.createScriptURL, .{ .arity = 1 });
    };
};

pub const TrustedTypePolicyFactory = struct {
    // emptyHTML and emptyScript keep their identity across reads (measured:
    // trustedTypes.emptyHTML === trustedTypes.emptyHTML), so they are built
    // once and cached.
    _empty_html: ?*TrustedHTML = null,
    _empty_script: ?*TrustedScript = null,

    pub const init: TrustedTypePolicyFactory = .{};

    pub fn getEmptyHTML(self: *TrustedTypePolicyFactory, frame: *Frame) !*TrustedHTML {
        if (self._empty_html) |empty| return empty;
        const created = try frame._factory.create(TrustedHTML{ ._value = "" });
        self._empty_html = created;
        return created;
    }

    pub fn getEmptyScript(self: *TrustedTypePolicyFactory, frame: *Frame) !*TrustedScript {
        if (self._empty_script) |empty| return empty;
        const created = try frame._factory.create(TrustedScript{ ._value = "" });
        self._empty_script = created;
        return created;
    }

    // Only a policy named "default" installed under an enforcing CSP becomes
    // the default one, and nothing here enforces, so this stays null the way it
    // does on an ordinary Chrome page.
    pub fn getDefaultPolicy(_: *const TrustedTypePolicyFactory) ?*TrustedTypePolicy {
        return null;
    }

    // Chrome does not reject a duplicate name outside an enforcing CSP
    // (measured: createPolicy('x', {}) twice, no throw), so neither do we, and
    // no registry of created policies is kept.
    pub fn createPolicy(
        _: *TrustedTypePolicyFactory,
        policy_name: []const u8,
        options: ?TrustedTypePolicy.Options,
        frame: *Frame,
    ) !*TrustedTypePolicy {
        const opts = options orelse TrustedTypePolicy.Options{};
        return frame._factory.create(TrustedTypePolicy{
            ._name = try frame.dupeString(policy_name),
            ._create_html = if (opts.createHTML) |cb| try cb.persist() else null,
            ._create_script = if (opts.createScript) |cb| try cb.persist() else null,
            ._create_script_url = if (opts.createScriptURL) |cb| try cb.persist() else null,
        });
    }

    pub fn getAttributeType(
        _: *const TrustedTypePolicyFactory,
        tag: []const u8,
        attribute: []const u8,
    ) ?[]const u8 {
        if (lookupElement(tag)) |element| {
            if (lookupEntry(element.attributes, attribute)) |sink| return sink.typeName();
        }
        // The wildcard row applies to every element, which is why
        // getAttributeType('div', 'onclick') is TrustedScript.
        if (isWildcardAttribute(attribute)) return Sink.script.typeName();
        return null;
    }

    pub fn getPropertyType(
        _: *const TrustedTypePolicyFactory,
        tag: []const u8,
        property: []const u8,
    ) ?[]const u8 {
        if (lookupElement(tag)) |element| {
            if (lookupEntry(element.properties, property)) |sink| return sink.typeName();
        }
        if (lookupEntry(&WILDCARD_PROPERTIES, property)) |sink| return sink.typeName();
        return null;
    }

    // A fresh object each call, as in Chrome. Built by hand rather than
    // returned as a Zig value so the nesting and key order come out exactly the
    // way getTypeMapping() reports them.
    pub fn getTypeMapping(_: *const TrustedTypePolicyFactory, exec: *const Execution) !js.Object {
        const local = exec.js.local.?;
        const mapping = local.newObject();

        for (&ELEMENTS) |*element| {
            const row = local.newObject();
            _ = try row.set("attributes", try buildEntries(local, element.attributes), .{});
            _ = try row.set("properties", try buildEntries(local, element.properties), .{});
            _ = try mapping.set(element.tag, row, .{});
        }

        const wildcard = local.newObject();
        const attributes = local.newObject();
        for (WILDCARD_ATTRIBUTES) |attribute| {
            _ = try attributes.set(attribute, Sink.script.typeName(), .{});
        }
        _ = try wildcard.set("attributes", attributes, .{});
        _ = try wildcard.set("properties", try buildEntries(local, &WILDCARD_PROPERTIES), .{});
        _ = try mapping.set("*", wildcard, .{});

        return mapping;
    }

    fn buildEntries(local: *const js.Local, entries: []const Entry) !js.Object {
        const object = local.newObject();
        for (entries) |entry| {
            _ = try object.set(entry[0], entry[1].typeName(), .{});
        }
        return object;
    }

    // The three brand checks. `value` is whatever the page passed, so anything
    // that isn't the matching platform object answers false.
    pub fn isHTML(_: *const TrustedTypePolicyFactory, value: js.Value) bool {
        return value.toZig(*TrustedHTML) != error.InvalidArgument;
    }

    pub fn isScript(_: *const TrustedTypePolicyFactory, value: js.Value) bool {
        return value.toZig(*TrustedScript) != error.InvalidArgument;
    }

    pub fn isScriptURL(_: *const TrustedTypePolicyFactory, value: js.Value) bool {
        return value.toZig(*TrustedScriptURL) != error.InvalidArgument;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(TrustedTypePolicyFactory);

        pub const Meta = struct {
            pub const name = "TrustedTypePolicyFactory";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        // Chrome's own prototype order.
        pub const emptyHTML = bridge.accessor(TrustedTypePolicyFactory.getEmptyHTML, null, .{});
        pub const emptyScript = bridge.accessor(TrustedTypePolicyFactory.getEmptyScript, null, .{});
        pub const defaultPolicy = bridge.accessor(TrustedTypePolicyFactory.getDefaultPolicy, null, .{});
        pub const createPolicy = bridge.function(TrustedTypePolicyFactory.createPolicy, .{ .arity = 1 });
        pub const getAttributeType = bridge.function(TrustedTypePolicyFactory.getAttributeType, .{});
        pub const getPropertyType = bridge.function(TrustedTypePolicyFactory.getPropertyType, .{});
        pub const getTypeMapping = bridge.function(TrustedTypePolicyFactory.getTypeMapping, .{});
        pub const isHTML = bridge.function(TrustedTypePolicyFactory.isHTML, .{});
        pub const isScript = bridge.function(TrustedTypePolicyFactory.isScript, .{});
        pub const isScriptURL = bridge.function(TrustedTypePolicyFactory.isScriptURL, .{});
    };
};
