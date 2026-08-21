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

// The reporting family a Chrome window carries beside ReportingObserver:
// ReportBody as a prototype root with two concrete bodies under it, the two
// objects a bfcache miss reports through, and CrashReportContext.
//
// Five of the six are unreachable. Their constructors are illegal and only the
// browser's own report queue or a failed back-forward-cache restore produces an
// instance, so the interface object and the prototype are the whole surface --
// which is the part a detector reads, and the part this engine did not have.
// `ReportingObserver.takeRecords()` here is always empty for the same reason
// (see ReportingObserver.zig), so nothing hands out a body.
//
// CrashReportContext is the exception, because `window.crashReport` *is* a live
// one. Its three methods are reachable, and which failure they answer depends on
// whether initialize() has resolved:
//
//   before  set('a','b')  -> InvalidStateError, "not initialized"
//   after   set('a','b')  -> NotAllowedError, "too large ... requested buffer"
//
// The second is what a normal Chrome tab answers too: a page gets no
// crash-report buffer to write into, so a successful initialize() only changes
// which refusal comes back. Measured on a headed Chrome 151 with
// tools/fingerprint/probes/probe-s3-reporting.js (readings in
// results/probes/probe-s3-reporting.chrome.json); the member lists, arities and
// prototype roots are from probe-shapes.js.
//
// ReportBody is the one name of the group a Chrome DedicatedWorkerGlobalScope
// also carries (measured, probe-shapes-worker), so it -- and only it -- goes on
// the worker list too. None of the six is [SecureContext] (measured against both
// probe-secure-context readings).

const std = @import("std");

const js = @import("../js/js.zig");
const DOMException = @import("DOMException.zig");
const dictionary = @import("dictionary.zig");

const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        ReportBody,
        CSPViolationReportBody,
        IntegrityViolationReportBody,
        CrashReportContext,
        NotRestoredReasons,
        NotRestoredReasonDetails,
    };
}

/// What every `toJSON` in this file answers. None of them is reachable -- there
/// is no instance to call one on -- so the shape only has to exist.
const Empty = struct {};

// ---------------------------------------------------------------------------
// ReportBody

/// The prototype root the concrete report bodies hang off. Abstract in WebIDL
/// and abstract here: no fields, never instantiated, and the only member is the
/// `toJSON` its subclasses each override with their own.
pub const ReportBody = struct {
    pub fn toJSON(_: *const ReportBody) Empty {
        return .{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(ReportBody);

        pub const Meta = struct {
            pub const name = "ReportBody";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const toJSON = bridge.function(ReportBody.toJSON, .{});
    };
};

// ---------------------------------------------------------------------------
// CSPViolationReportBody

/// The body of a `csp-violation` report. Eleven readonly members and its own
/// `toJSON`, which is where it differs from SecurityPolicyViolationEvent: the
/// event names `blockedURI` / `documentURI` and the report body names
/// `blockedURL` / `documentURL`, and the body drops `violatedDirective`.
pub const CSPViolationReportBody = struct {
    pub const Proto = ReportBody;

    _proto: *ReportBody,

    pub fn getString(_: *const CSPViolationReportBody) []const u8 {
        return "";
    }

    /// `sample` and `sourceFile` are nullable where the plain strings are not.
    pub fn getNullableString(_: *const CSPViolationReportBody) ?[]const u8 {
        return null;
    }

    pub fn getNullableLong(_: *const CSPViolationReportBody) ?i32 {
        return null;
    }

    pub fn toJSON(_: *const CSPViolationReportBody) Empty {
        return .{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CSPViolationReportBody);

        pub const Meta = struct {
            pub const name = "CSPViolationReportBody";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const B = CSPViolationReportBody;

        pub const documentURL = bridge.accessor(B.getString, null, .{});
        pub const referrer = bridge.accessor(B.getNullableString, null, .{});
        pub const blockedURL = bridge.accessor(B.getNullableString, null, .{});
        pub const effectiveDirective = bridge.accessor(B.getString, null, .{});
        pub const originalPolicy = bridge.accessor(B.getString, null, .{});
        pub const sourceFile = bridge.accessor(B.getNullableString, null, .{});
        pub const sample = bridge.accessor(B.getNullableString, null, .{});
        pub const disposition = bridge.accessor(B.getString, null, .{});
        pub const statusCode = bridge.accessor(B.getNullableLong, null, .{});
        pub const lineNumber = bridge.accessor(B.getNullableLong, null, .{});
        pub const columnNumber = bridge.accessor(B.getNullableLong, null, .{});
        pub const toJSON = bridge.function(B.toJSON, .{});
    };
};

// ---------------------------------------------------------------------------
// IntegrityViolationReportBody

/// The body of an `integrity-violation` report: a subresource whose
/// `integrity` attribute did not match what a required-SRI policy demanded.
pub const IntegrityViolationReportBody = struct {
    pub const Proto = ReportBody;

    _proto: *ReportBody,

    pub fn getString(_: *const IntegrityViolationReportBody) []const u8 {
        return "";
    }

    pub fn getReportOnly(_: *const IntegrityViolationReportBody) bool {
        return false;
    }

    pub fn toJSON(_: *const IntegrityViolationReportBody) Empty {
        return .{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(IntegrityViolationReportBody);

        pub const Meta = struct {
            pub const name = "IntegrityViolationReportBody";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const B = IntegrityViolationReportBody;

        pub const documentURL = bridge.accessor(B.getString, null, .{});
        pub const blockedURL = bridge.accessor(B.getString, null, .{});
        pub const destination = bridge.accessor(B.getString, null, .{});
        pub const reportOnly = bridge.accessor(B.getReportOnly, null, .{});
        pub const toJSON = bridge.function(B.toJSON, .{});
    };
};

// ---------------------------------------------------------------------------
// NotRestoredReasons / NotRestoredReasonDetails

/// `performance.getEntriesByType('navigation')[0].notRestoredReasons`: the tree
/// of frames that kept a document out of the back-forward cache. Nothing here
/// enters that cache in the first place, so the entry's member is null and no
/// instance exists.
pub const NotRestoredReasons = struct {
    pub fn getNullableString(_: *const NotRestoredReasons) ?[]const u8 {
        return null;
    }

    pub fn getList(_: *const NotRestoredReasons) ?[]const js.Value {
        return null;
    }

    pub fn toJSON(_: *const NotRestoredReasons) Empty {
        return .{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(NotRestoredReasons);

        pub const Meta = struct {
            pub const name = "NotRestoredReasons";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        const R = NotRestoredReasons;

        pub const src = bridge.accessor(R.getNullableString, null, .{});
        pub const id = bridge.accessor(R.getNullableString, null, .{});
        pub const name = bridge.accessor(R.getNullableString, null, .{});
        pub const url = bridge.accessor(R.getNullableString, null, .{});
        pub const reasons = bridge.accessor(R.getList, null, .{});
        pub const children = bridge.accessor(R.getList, null, .{});
        pub const toJSON = bridge.function(R.toJSON, .{});
    };
};

/// One leaf of the tree above: a single reason string.
pub const NotRestoredReasonDetails = struct {
    pub fn getReason(_: *const NotRestoredReasonDetails) []const u8 {
        return "";
    }

    pub fn toJSON(_: *const NotRestoredReasonDetails) Empty {
        return .{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(NotRestoredReasonDetails);

        pub const Meta = struct {
            pub const name = "NotRestoredReasonDetails";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const reason = bridge.accessor(NotRestoredReasonDetails.getReason, null, .{});
        pub const toJSON = bridge.function(NotRestoredReasonDetails.toJSON, .{});
    };
};

// ---------------------------------------------------------------------------
// CrashReportContext

/// `window.crashReport`: the key/value blob a page asks the browser to attach to
/// a crash report, so a renderer that dies takes the page's own breadcrumbs with
/// it. One per window, held by the Window rather than built on demand -- the
/// accessor is enumerable and answers the same object every read (measured).
///
/// The whole observable surface is which refusal each method gives, and that
/// turns on one bit: whether initialize() has resolved. Nothing is ever stored
/// either way, here or in Chrome, so `Object.keys(crashReport)` is empty and
/// `JSON.stringify(crashReport)` is `{}` whatever a page does.
pub const CrashReportContext = struct {
    /// Set by the first initialize(); every later call is refused.
    _initialized: bool = false,

    pub const init: CrashReportContext = .{};

    const PREFIX = "Failed to execute '";

    /// This engine does not count a method's arguments -- only a constructor's
    /// -- so the count Chrome reports is produced here. Both messages are
    /// Chrome's, singular and plural (measured).
    fn tooFewArguments(
        comptime method: []const u8,
        comptime required: usize,
        present: usize,
        exec: *const Execution,
    ) anyerror {
        const plural = if (required == 1) "argument" else "arguments";
        const message = try std.fmt.allocPrint(
            exec.call_arena,
            PREFIX ++ method ++ "' on 'CrashReportContext': " ++
                std.fmt.comptimePrint("{d}", .{required}) ++ " " ++ plural ++
                " required, but only {d} present.",
            .{present},
        );
        return dictionary.throwTypeError(message, exec);
    }

    /// What set() and delete() always end in. Never a success: before
    /// initialize() the context is not ready, and after it there is no buffer to
    /// write into -- which is what Chrome answers on a normal page too.
    fn refuse(
        self: *const CrashReportContext,
        comptime method: []const u8,
        exec: *const Execution,
    ) anyerror {
        if (self._initialized == false) {
            return dictionary.throwDom(
                "InvalidStateError",
                PREFIX ++ method ++ "' on 'CrashReportContext': CrashReportContext is not " ++
                    "initialized. Call initialize() and wait for it to resolve.",
                exec,
            );
        }
        return dictionary.throwDom(
            "NotAllowedError",
            PREFIX ++ method ++ "' on 'CrashReportContext': The crash report data is too " ++
                "large to be stored in the requested buffer.",
            exec,
        );
    }

    pub fn set(
        self: *const CrashReportContext,
        key_: ?js.Value,
        value_: ?js.Value,
        exec: *const Execution,
    ) !void {
        if (key_ == null) {
            return tooFewArguments("set", 2, 0, exec);
        }
        if (value_ == null) {
            return tooFewArguments("set", 2, 1, exec);
        }
        return self.refuse("set", exec);
    }

    pub fn delete(self: *const CrashReportContext, key_: ?js.Value, exec: *const Execution) !void {
        if (key_ == null) {
            return tooFewArguments("delete", 1, 0, exec);
        }
        return self.refuse("delete", exec);
    }

    /// The gate is the argument *count*, not its type: `initialize(5)`,
    /// `initialize(null)` and `initialize(undefined)` all resolve on a fresh
    /// context while `initialize()` rejects (measured, one fresh context per
    /// value). Both failures are rejections rather than throws, because the
    /// operation answers a promise.
    pub fn initialize(
        self: *CrashReportContext,
        options_: ?js.Value,
        exec: *const Execution,
    ) !js.Promise {
        const local = exec.js.local.?;
        if (options_ == null) {
            return local.rejectPromise(.{
                .type_error = PREFIX ++ "initialize' on 'CrashReportContext': " ++
                    "1 argument required, but only 0 present.",
            });
        }
        if (self._initialized) {
            // A DOMException with Chrome's own sentence, which RejectError's
            // dom_exception variant cannot carry. It outlives this call, so it
            // goes on an arena rather than the call arena.
            const dom = try exec.arena.create(DOMException);
            dom.* = DOMException.init(
                PREFIX ++ "initialize' on 'CrashReportContext': " ++
                    "The initialize() method has already been called.",
                "InvalidStateError",
            );
            const resolver = local.createPromiseResolver();
            resolver.reject("CrashReportContext.initialize", dom);
            return resolver.promise();
        }
        self._initialized = true;
        return local.resolvePromise({});
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CrashReportContext);

        pub const Meta = struct {
            pub const name = "CrashReportContext";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        const C = CrashReportContext;

        // Chrome's order on the prototype, which is neither declaration order
        // nor alphabetical-by-accident: delete, initialize, set.
        pub const delete = bridge.function(C.delete, .{ .arity = 1 });
        pub const initialize = bridge.function(C.initialize, .{ .arity = 1 });
        pub const set = bridge.function(C.set, .{ .arity = 2 });
    };
};

const testing = @import("../../testing.zig");
test "WebApi: ReportingFamily" {
    try testing.htmlRunner("reporting_family.html", .{});
}
