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

//! The Credential Management family: the nine interface classes plus the
//! container that hands them out.
//!
//! Two of the nine are constructible from script and therefore have real
//! behaviour a detector can reach — `PasswordCredential` and
//! `FederatedCredential`, both of which `navigator.credentials.create()` also
//! resolves with. The other seven refuse construction ("Illegal constructor")
//! and their instances only ever come from a platform authenticator or a
//! federated-identity flow, neither of which exists here, so shape is their
//! whole observable surface.
//!
//! Every message, every default and every enum here was read off a headed
//! Chrome 150 over http://localhost — win20-chrome.json for the shapes,
//! win21/win21b/win21c/win21d-chrome.json for the behaviours. Two measured
//! details worth keeping in view:
//!
//!   * `provider` is stored as the *origin* of the URL handed in, not the URL:
//!     `new FederatedCredential({id, provider: 'https://idp.example/x'})` reads
//!     back "https://idp.example". `iconURL` keeps the whole URL.
//!   * `protocol` is **not** echoed from the init dictionary. Chrome reads back
//!     "" whatever you pass, including a plausible "openidconnect" (measured
//!     three ways), so the member is parsed and dropped.
//!   * The refusals come in WebIDL order — dictionary conversion first (in
//!     alphabetical member order), then the algorithm's own checks. That is why
//!     `get({password: true, mediation: 'nope'})` is a TypeError about
//!     `mediation` while `get({password: false})` is a NotSupportedError about
//!     no credential type.
//!
//! One deliberate shallowness, for want of a caller that would notice: the two
//! `PublicKeyCredential.parse*OptionsFromJSON` statics decode `challenge` and
//! `user.id` into real ArrayBuffers, but pass `rp`, `pubKeyCredParams` and the
//! credential-descriptor lists through as the objects they arrived as — so a
//! `Base64URLString` nested inside `allowCredentials[i].id` stays a string where
//! Chrome would hand back an ArrayBuffer. The refusals (argument count,
//! non-dictionary, each missing required member in WebIDL's alphabetical order,
//! and invalid base64url) are all measured and exact.

const std = @import("std");

const js = @import("../../js/js.zig");
const permissions_policy = @import("../../permissions_policy.zig");
const URL = @import("../../URL.zig");
const Node = @import("../Node.zig");
const Element = @import("../Element.zig");
const Form = @import("../element/html/Form.zig");
const DOMException = @import("../DOMException.zig");

const Execution = js.Execution;

pub fn registerTypes() []const type {
    return &.{
        CredentialsContainer,
        Credential,
        FederatedCredential,
        PasswordCredential,
        PublicKeyCredential,
        IdentityCredential,
        OTPCredential,
        AuthenticatorResponse,
        AuthenticatorAssertionResponse,
        AuthenticatorAttestationResponse,
    };
}

fn throwTypeError(message: []const u8, exec: *const Execution) anyerror {
    const isolate = exec.js.isolate;
    _ = isolate.throwException(isolate.createTypeError(message));
    return error.JsException;
}

fn throwDom(comptime name: []const u8, message: []const u8, exec: *const Execution) anyerror {
    const local = exec.js.local.?;
    const value = local.zigValueToJs(DOMException.init(message, name), .{}) catch return error.JsException;
    _ = local.isolate.throwException(value.handle);
    return error.JsException;
}

// Why a failure is carried rather than thrown where it happens: the same
// credential builders serve `new PasswordCredential(...)`, which *throws*, and
// `navigator.credentials.create({password})`, which *rejects* with the very same
// message (both measured). Whoever called the builder decides which.
const Fail = struct {
    kind: Kind = .type_error,
    message: []const u8 = "",

    const Kind = enum { type_error, syntax_error, encoding_error };

    fn throwIt(self: Fail, exec: *const Execution) anyerror {
        return switch (self.kind) {
            .type_error => throwTypeError(self.message, exec),
            .syntax_error => throwDom("SyntaxError", self.message, exec),
            .encoding_error => throwDom("EncodingError", self.message, exec),
        };
    }

    fn reject(self: Fail, exec: *const Execution) js.Promise {
        return switch (self.kind) {
            .type_error => rejectType(self.message, exec),
            .syntax_error => rejectDom("SyntaxError", self.message, exec),
            .encoding_error => rejectDom("EncodingError", self.message, exec),
        };
    }

    fn set(out: *Fail, kind: Kind, message: []const u8) error{CredentialRefused} {
        out.* = .{ .kind = kind, .message = message };
        return error.CredentialRefused;
    }
};

// A promise rejected with a DOMException carrying Chrome's own text; the bridge's
// bare `error.NotSupportedError` would produce a generic message instead.
fn rejectDom(comptime name: []const u8, message: []const u8, exec: *const Execution) js.Promise {
    var resolver = exec.js.local.?.createPromiseResolver();
    resolver.reject("credentials", DOMException.init(message, name));
    return resolver.promise();
}

fn rejectType(message: []const u8, exec: *const Execution) js.Promise {
    return exec.js.local.?.rejectPromise(.{ .type_error = message });
}

// A promise that never settles, for the two requests a real Chrome parks on a
// UI nobody answers (an SMS OTP listener, a passkey chooser).
fn pending(exec: *const Execution) js.Promise {
    const resolver = exec.js.local.?.createPromiseResolver();
    const promise = resolver.promise();
    promise.markAsHandled();
    return promise;
}

fn member(dict: js.Object, key: []const u8) !?js.Value {
    const value = try dict.get(key);
    if (value.isUndefined()) return null;
    return value;
}

fn optionalString(dict: js.Object, key: []const u8, exec: *const Execution) !?[]const u8 {
    const value = try member(dict, key) orelse return null;
    if (value.isNull()) return null;
    return try exec.arena.dupe(u8, try value.toStringSlice());
}

// WebIDL turns `undefined` into an empty dictionary. Chrome does *not* do the
// same for `null` on these interfaces — `new FederatedCredential(null)` names
// the dictionary type rather than its first required member (measured) — so null
// is refused here and only undefined becomes "no members".
fn asDictionary(value: js.Value) !?js.Object {
    if (value.isUndefined()) return null;
    if (!value.isObject()) return error.NotDictionary;
    return value.toZig(js.Object) catch error.NotDictionary;
}

fn dictionary(value: js.Value, comptime message: []const u8, exec: *const Execution) !?js.Object {
    return asDictionary(value) catch throwTypeError(message, exec);
}

// A `Base64URLString`. Chrome accepts unpadded base64url and refuses anything
// else with an EncodingError naming the member (measured on `challenge`).
fn base64Url(text: []const u8, comptime message: []const u8, exec: *const Execution) !js.ArrayBuffer {
    const decoders = [_]std.base64.Base64Decoder{
        std.base64.url_safe_no_pad.Decoder,
        std.base64.url_safe.Decoder,
        std.base64.standard.Decoder,
    };
    for (decoders) |decoder| {
        const len = decoder.calcSizeForSlice(text) catch continue;
        const out = try exec.arena.alloc(u8, len);
        decoder.decode(out, text) catch continue;
        return .{ .values = out };
    }
    const local = exec.js.local.?;
    const value = local.zigValueToJs(DOMException.init(message, "EncodingError"), .{}) catch return error.JsException;
    _ = local.isolate.throwException(value.handle);
    return error.JsException;
}

/// The base class. Not constructible, and `id`/`type` are the only two members
/// on it — everything else lives on the subclass.
pub const Credential = struct {
    _kind: Kind,
    _id: []const u8,

    pub const Kind = enum {
        password,
        federated,
        public_key,
        identity,
        otp,
    };

    pub fn getId(self: *const Credential) []const u8 {
        return self._id;
    }

    pub fn getType(self: *const Credential) []const u8 {
        return switch (self._kind) {
            .password => "password",
            .federated => "federated",
            .public_key => "public-key",
            .identity => "identity",
            .otp => "otp",
        };
    }

    // Chrome answers false here while `PublicKeyCredential`'s own copy of the
    // same static answers true (both measured on the same page): this one asks
    // about conditional mediation for *password* credentials, which Chrome does
    // not offer.
    pub fn isConditionalMediationAvailable(exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(false);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(Credential);

        pub const Meta = struct {
            pub const name = "Credential";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const id = bridge.accessor(Credential.getId, null, .{});
        pub const @"type" = bridge.accessor(Credential.getType, null, .{});
        pub const isConditionalMediationAvailable = bridge.function(
            Credential.isConditionalMediationAvailable,
            .{ .static = true },
        );
    };
};

/// `new FederatedCredential({id, provider})`. The one credential type besides
/// password that `create()` will hand back.
pub const FederatedCredential = struct {
    pub const Proto = Credential;

    _proto: *Credential,
    _provider: []const u8,
    _name: []const u8 = "",
    _icon_url: []const u8 = "",

    pub fn constructor(data_: ?js.Value, exec: *const Execution) !*FederatedCredential {
        const data = data_ orelse return throwTypeError(
            "Failed to construct 'FederatedCredential': 1 argument required, but only 0 present.",
            exec,
        );
        var fail: Fail = .{};
        return build(data, "Failed to construct 'FederatedCredential': ", exec, &fail) catch |err| switch (err) {
            error.CredentialRefused => fail.throwIt(exec),
            else => err,
        };
    }

    // Shared with CredentialsContainer.create({federated: ...}), which reports
    // the same failures wrapped in its own prefix and as a rejection rather than
    // a throw (measured), hence the Fail out-parameter.
    pub fn build(
        data: js.Value,
        comptime prefix: []const u8,
        exec: *const Execution,
        fail: *Fail,
    ) !*FederatedCredential {
        const maybe_dict = asDictionary(data) catch return Fail.set(
            fail,
            .type_error,
            prefix ++ "The provided value is not of type 'FederatedCredentialInit'.",
        );
        const dict = maybe_dict orelse return Fail.set(
            fail,
            .type_error,
            prefix ++ "Failed to read the 'id' property from 'CredentialData': Required member is undefined.",
        );

        const id_value = try member(dict, "id") orelse return Fail.set(
            fail,
            .type_error,
            prefix ++ "Failed to read the 'id' property from 'CredentialData': Required member is undefined.",
        );
        const id = try exec.arena.dupe(u8, try id_value.toStringSlice());

        const provider_value = try member(dict, "provider") orelse return Fail.set(
            fail,
            .type_error,
            prefix ++ "Failed to read the 'provider' property from 'FederatedCredentialInit': Required member is undefined.",
        );
        const provider = try absolute(try provider_value.toStringSlice(), prefix, exec, fail);

        // The icon is validated as a URL too, with the same SyntaxError, but it
        // is kept whole rather than reduced to an origin (measured).
        const icon_text = try optionalString(dict, "iconURL", exec);
        const icon_url = if (icon_text) |text| try absolute(text, prefix, exec, fail) else "";

        return exec._factory.chained(.{
            Credential{ ._kind = .federated, ._id = id },
            FederatedCredential{
                ._proto = undefined,
                ._provider = URL.getOrigin(exec.arena, provider) catch null orelse provider,
                ._name = try optionalString(dict, "name", exec) orelse "",
                ._icon_url = icon_url,
            },
        });
    }

    // Chrome refuses a string it cannot parse with a SyntaxError naming the
    // string (measured on both `provider` and `iconURL`).
    fn absolute(
        text: []const u8,
        comptime prefix: []const u8,
        exec: *const Execution,
        fail: *Fail,
    ) ![:0]const u8 {
        return URL.resolve(exec.arena, "", text, .{}) catch Fail.set(
            fail,
            .syntax_error,
            try std.fmt.allocPrint(exec.arena, prefix ++ "'{s}' is not a valid URL.", .{text}),
        );
    }

    pub fn getProvider(self: *const FederatedCredential) []const u8 {
        return self._provider;
    }

    // Always "": Chrome parses the init's `protocol` member and then reports the
    // protocol it would itself use, which for a script-built credential is none
    // (measured with and without the member).
    pub fn getProtocol(_: *const FederatedCredential) []const u8 {
        return "";
    }

    pub fn getName(self: *const FederatedCredential) []const u8 {
        return self._name;
    }

    pub fn getIconURL(self: *const FederatedCredential) []const u8 {
        return self._icon_url;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(FederatedCredential);

        pub const Meta = struct {
            pub const name = "FederatedCredential";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = Credential;

        pub const constructor = bridge.constructor(FederatedCredential.constructor, .{ .arity = 1 });
        pub const provider = bridge.accessor(FederatedCredential.getProvider, null, .{});
        pub const protocol = bridge.accessor(FederatedCredential.getProtocol, null, .{});
        pub const name = bridge.accessor(FederatedCredential.getName, null, .{});
        pub const iconURL = bridge.accessor(FederatedCredential.getIconURL, null, .{});
    };
};

/// `new PasswordCredential({id, password})`, or the same from a form.
pub const PasswordCredential = struct {
    pub const Proto = Credential;

    _proto: *Credential,
    _password: []const u8,
    _name: []const u8 = "",
    _icon_url: []const u8 = "",

    pub fn constructor(data_: ?js.Value, exec: *const Execution) !*PasswordCredential {
        const data = data_ orelse return throwTypeError(
            "Failed to construct 'PasswordCredential': 1 argument required, but only 0 present.",
            exec,
        );
        var fail: Fail = .{};
        return build(data, "Failed to construct 'PasswordCredential': ", exec, &fail) catch |err| switch (err) {
            error.CredentialRefused => fail.throwIt(exec),
            else => err,
        };
    }

    // Two overloads — an HTMLFormElement or a PasswordCredentialData — so a
    // value that is neither an object nor a form fails overload resolution
    // before any member is read (measured: `new PasswordCredential(5)`). A plain
    // element is *not* refused: it goes to the dictionary overload, where
    // `element.id` happens to satisfy `id` and the missing `password` is what
    // Chrome names (measured with a <div>).
    pub fn build(
        data: js.Value,
        comptime prefix: []const u8,
        exec: *const Execution,
        fail: *Fail,
    ) !*PasswordCredential {
        if (!data.isObject()) return Fail.set(fail, .type_error, prefix ++ "Overload resolution failed.");

        if (data.toZig(*Form)) |form| {
            return fromForm(form, prefix, exec, fail);
        } else |_| {}

        const maybe_dict = asDictionary(data) catch return Fail.set(
            fail,
            .type_error,
            prefix ++ "Overload resolution failed.",
        );
        const dict = maybe_dict orelse return Fail.set(
            fail,
            .type_error,
            prefix ++ "Failed to read the 'id' property from 'CredentialData': Required member is undefined.",
        );

        const id_value = try member(dict, "id") orelse return Fail.set(
            fail,
            .type_error,
            prefix ++ "Failed to read the 'id' property from 'CredentialData': Required member is undefined.",
        );
        const id = try exec.arena.dupe(u8, try id_value.toStringSlice());

        const password_value = try member(dict, "password") orelse return Fail.set(
            fail,
            .type_error,
            prefix ++ "Failed to read the 'password' property from 'PasswordCredentialData': Required member is undefined.",
        );
        const password = try exec.arena.dupe(u8, try password_value.toStringSlice());
        if (password.len == 0) return Fail.set(fail, .type_error, prefix ++ "'password' must not be empty.");

        return exec._factory.chained(.{
            Credential{ ._kind = .password, ._id = id },
            PasswordCredential{
                ._proto = undefined,
                ._password = password,
                ._name = try optionalString(dict, "name", exec) orelse "",
                ._icon_url = try optionalString(dict, "iconURL", exec) orelse "",
            },
        });
    }

    // The HTMLFormElement overload. Chrome reads the fields by their
    // `autocomplete` tokens and refuses a form that names none of them —
    // "'username' must be specified in the form's autocomplete attribute."
    // (measured on a form whose inputs carry only names). The `name`/`photo`
    // tokens follow the same table; only `username` and `current-password` were
    // measured on a live form.
    fn fromForm(
        form: *Form,
        comptime prefix: []const u8,
        exec: *const Execution,
        fail: *Fail,
    ) !*PasswordCredential {
        var found_username = false;
        var id: []const u8 = "";
        var password: []const u8 = "";
        var name: []const u8 = "";
        var icon: []const u8 = "";

        var node: ?*Node = form.asNode().firstChild();
        const root = form.asNode();
        while (node) |current| {
            if (current.is(Element)) |element| {
                if (element.getAttributeSafe(comptime .wrap("autocomplete"))) |tokens| {
                    const value = if (element.is(Form.Input)) |input| input.getValue() else "";
                    var it = std.mem.tokenizeAny(u8, tokens, " \t\r\n");
                    while (it.next()) |token| {
                        if (std.ascii.eqlIgnoreCase(token, "username")) {
                            found_username = true;
                            if (id.len == 0) id = try exec.arena.dupe(u8, value);
                        } else if (std.ascii.eqlIgnoreCase(token, "current-password") or
                            std.ascii.eqlIgnoreCase(token, "new-password"))
                        {
                            if (password.len == 0) password = try exec.arena.dupe(u8, value);
                        } else if (std.ascii.eqlIgnoreCase(token, "name") or std.ascii.eqlIgnoreCase(token, "nickname")) {
                            if (name.len == 0) name = try exec.arena.dupe(u8, value);
                        } else if (std.ascii.eqlIgnoreCase(token, "photo")) {
                            if (icon.len == 0) icon = try exec.arena.dupe(u8, value);
                        }
                    }
                }
            }
            node = descend(current, root);
        }

        if (!found_username) return Fail.set(
            fail,
            .type_error,
            prefix ++ "'username' must be specified in the form's autocomplete attribute.",
        );
        if (password.len == 0) return Fail.set(fail, .type_error, prefix ++ "'password' must not be empty.");

        return exec._factory.chained(.{
            Credential{ ._kind = .password, ._id = id },
            PasswordCredential{
                ._proto = undefined,
                ._password = password,
                ._name = name,
                ._icon_url = icon,
            },
        });
    }

    // Depth-first successor of `current` inside `root`'s subtree.
    fn descend(current: *Node, root: *Node) ?*Node {
        if (current.firstChild()) |child| return child;
        var node = current;
        while (node != root) {
            if (node.nextSibling()) |sibling| return sibling;
            node = node.parentNode() orelse return null;
        }
        return null;
    }

    pub fn getPassword(self: *const PasswordCredential) []const u8 {
        return self._password;
    }

    pub fn getName(self: *const PasswordCredential) []const u8 {
        return self._name;
    }

    pub fn getIconURL(self: *const PasswordCredential) []const u8 {
        return self._icon_url;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PasswordCredential);

        pub const Meta = struct {
            pub const name = "PasswordCredential";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = Credential;

        pub const constructor = bridge.constructor(PasswordCredential.constructor, .{ .arity = 1 });
        pub const password = bridge.accessor(PasswordCredential.getPassword, null, .{});
        pub const name = bridge.accessor(PasswordCredential.getName, null, .{});
        pub const iconURL = bridge.accessor(PasswordCredential.getIconURL, null, .{});
    };
};

/// WebAuthn's credential. Only a platform or roaming authenticator produces
/// one, so no instance is reachable here; the eight statics are, and a detector
/// reads them for what the *platform* supports.
pub const PublicKeyCredential = struct {
    pub const Proto = Credential;

    _proto: *Credential,

    // Chrome 150 on a Mac with Touch ID answers true to both of these
    // (measured). The engine reports the same platform in its user agent, so
    // answering false here would contradict it.
    pub fn isConditionalMediationAvailable(exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(true);
    }

    pub fn isUserVerifyingPlatformAuthenticatorAvailable(exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(true);
    }

    // Chrome's own answer, copied key for key in its own order (measured; the
    // order is alphabetical because Blink builds it from a sorted map).
    const ClientCapabilities = struct {
        conditionalCreate: bool = true,
        conditionalGet: bool = true,
        @"extension:appid": bool = true,
        @"extension:appidExclude": bool = true,
        @"extension:cmtgKey": bool = false,
        @"extension:credBlob": bool = true,
        @"extension:credProps": bool = true,
        @"extension:credentialProtectionPolicy": bool = true,
        @"extension:crossDeviceFallbackUrl": bool = false,
        @"extension:enforceCredentialProtectionPolicy": bool = true,
        @"extension:getCredBlob": bool = true,
        @"extension:hmacCreateSecret": bool = true,
        @"extension:largeBlob": bool = true,
        @"extension:minPinLength": bool = true,
        @"extension:payment": bool = true,
        @"extension:prf": bool = true,
        hybridTransport: bool = true,
        immediateGet: bool = true,
        passkeyPlatformAuthenticator: bool = true,
        relatedOrigins: bool = true,
        signalAllAcceptedCredentials: bool = true,
        signalCurrentUserDetails: bool = true,
        signalUnknownCredential: bool = true,
        userVerifyingPlatformAuthenticator: bool = true,
    };

    pub fn getClientCapabilities(exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise(ClientCapabilities{});
    }

    // The three signal methods validate their dictionary and then resolve with
    // nothing — there is no credential store to signal about (all measured).
    pub fn signalAllAcceptedCredentials(options_: ?js.Value, exec: *const Execution) !js.Promise {
        return signal(options_, "signalAllAcceptedCredentials", "AllAcceptedCredentialsOptions", &.{ "allAcceptedCredentialIds", "rpId", "userId" }, exec);
    }

    pub fn signalCurrentUserDetails(options_: ?js.Value, exec: *const Execution) !js.Promise {
        return signal(options_, "signalCurrentUserDetails", "CurrentUserDetailsOptions", &.{ "displayName", "name", "rpId", "userId" }, exec);
    }

    pub fn signalUnknownCredential(options_: ?js.Value, exec: *const Execution) !js.Promise {
        return signal(options_, "signalUnknownCredential", "UnknownCredentialOptions", &.{ "credentialId", "rpId" }, exec);
    }

    // Chrome names the first missing required member in WebIDL's alphabetical
    // order, which is the order the member lists above are written in — measured
    // on all three (`{}` names allAcceptedCredentialIds, displayName and
    // credentialId respectively, not rpId).
    fn signal(
        options_: ?js.Value,
        comptime method: []const u8,
        comptime dict_name: []const u8,
        comptime members: []const []const u8,
        exec: *const Execution,
    ) !js.Promise {
        const prefix = "Failed to execute '" ++ method ++ "' on 'PublicKeyCredential': ";
        const options = options_ orelse return rejectType(
            prefix ++ "1 argument required, but only 0 present.",
            exec,
        );
        const dict = asDictionary(options) catch return rejectType(
            prefix ++ "The provided value is not of type '" ++ dict_name ++ "'.",
            exec,
        );
        inline for (members) |name| {
            const present = if (dict) |d| (try member(d, name)) != null else false;
            if (!present) return rejectType(
                prefix ++ "Failed to read the '" ++ name ++ "' property from '" ++ dict_name ++
                    "': Required member is undefined.",
                exec,
            );
        }
        return exec.js.local.?.resolvePromise({});
    }

    // The two JSON deserialisers. Chrome converts the dictionary in WebIDL's
    // alphabetical member order and stops at the first missing required member,
    // which is why `{challenge}` alone is refused for `pubKeyCredParams` rather
    // than for `rp` (measured). The object handed back carries the members that
    // were given plus the ones that default, in that same alphabetical order.
    // The result is built member by member rather than returned as a Zig struct
    // because Chrome *omits* the optional members that were not given
    // (`{challenge}` alone comes back with four keys, not six), while a struct
    // with optional fields would spell them out as nulls.
    pub fn parseCreationOptionsFromJSON(json_: ?js.Value, exec: *const Execution) !js.Object {
        const prefix = "Failed to execute 'parseCreationOptionsFromJSON' on 'PublicKeyCredential': ";
        const dict = try requiredDictionary(json_, prefix, "PublicKeyCredentialCreationOptionsJSON", exec);

        const challenge = try requiredMember(dict, "challenge", prefix, "PublicKeyCredentialCreationOptionsJSON", exec);
        const params = try requiredMember(dict, "pubKeyCredParams", prefix, "PublicKeyCredentialCreationOptionsJSON", exec);
        const rp = try requiredMember(dict, "rp", prefix, "PublicKeyCredentialCreationOptionsJSON", exec);
        const user = try requiredMember(dict, "user", prefix, "PublicKeyCredentialCreationOptionsJSON", exec);

        const local = exec.js.local.?;
        const out = local.newObject();

        // Chrome's key order: alphabetical, with the defaults filled in.
        _ = try out.set("attestation", try optionalString(dict, "attestation", exec) orelse "none", .{});
        _ = try out.set("challenge", try base64Url(
            try challenge.toStringSlice(),
            prefix ++ "'challenge' contains invalid base64url data",
            exec,
        ), .{});
        _ = try out.set(
            "excludeCredentials",
            try member(dict, "excludeCredentials") orelse try local.zigValueToJs(@as([]const []const u8, &.{}), .{}),
            .{},
        );
        _ = try out.set("hints", try member(dict, "hints") orelse try local.zigValueToJs(@as([]const []const u8, &.{}), .{}), .{});
        if (try member(dict, "authenticatorSelection")) |value| _ = try out.set("authenticatorSelection", value, .{});
        if (try member(dict, "extensions")) |value| _ = try out.set("extensions", value, .{});
        _ = try out.set("pubKeyCredParams", params, .{});
        _ = try out.set("rp", rp, .{});
        if (try member(dict, "timeout")) |value| _ = try out.set("timeout", value, .{});

        // The user entity is rebuilt because its `id` is a Base64URLString that
        // Chrome hands back as an ArrayBuffer; the key order is Chrome's own.
        const user_dict = try dictionary(user, prefix ++ "The provided value is not of type 'PublicKeyCredentialUserEntityJSON'.", exec);
        const user_out = local.newObject();
        _ = try user_out.set("name", if (user_dict) |u| try optionalString(u, "name", exec) orelse "" else "", .{});
        _ = try user_out.set("displayName", if (user_dict) |u| try optionalString(u, "displayName", exec) orelse "" else "", .{});
        const user_id = if (user_dict) |u| try member(u, "id") else null;
        _ = try user_out.set("id", if (user_id) |value| try base64Url(
            try value.toStringSlice(),
            prefix ++ "'user.id' contains invalid base64url data",
            exec,
        ) else js.ArrayBuffer{ .values = "" }, .{});
        _ = try out.set("user", user_out, .{});

        return out;
    }

    pub fn parseRequestOptionsFromJSON(json_: ?js.Value, exec: *const Execution) !js.Object {
        const prefix = "Failed to execute 'parseRequestOptionsFromJSON' on 'PublicKeyCredential': ";
        const dict = try requiredDictionary(json_, prefix, "PublicKeyCredentialRequestOptionsJSON", exec);
        const challenge = try requiredMember(dict, "challenge", prefix, "PublicKeyCredentialRequestOptionsJSON", exec);

        const local = exec.js.local.?;
        const out = local.newObject();
        _ = try out.set(
            "allowCredentials",
            try member(dict, "allowCredentials") orelse try local.zigValueToJs(@as([]const []const u8, &.{}), .{}),
            .{},
        );
        _ = try out.set("challenge", try base64Url(
            try challenge.toStringSlice(),
            prefix ++ "'challenge' contains invalid base64url data",
            exec,
        ), .{});
        if (try member(dict, "extensions")) |value| _ = try out.set("extensions", value, .{});
        _ = try out.set("hints", try member(dict, "hints") orelse try local.zigValueToJs(@as([]const []const u8, &.{}), .{}), .{});
        if (try member(dict, "rpId")) |value| _ = try out.set("rpId", value, .{});
        if (try member(dict, "timeout")) |value| _ = try out.set("timeout", value, .{});
        _ = try out.set("userVerification", try optionalString(dict, "userVerification", exec) orelse "preferred", .{});
        return out;
    }

    fn requiredDictionary(
        value_: ?js.Value,
        comptime prefix: []const u8,
        comptime dict_name: []const u8,
        exec: *const Execution,
    ) !js.Object {
        const value = value_ orelse return throwTypeError(
            prefix ++ "1 argument required, but only 0 present.",
            exec,
        );
        return try dictionary(value, prefix ++ "The provided value is not of type '" ++ dict_name ++ "'.", exec) orelse
            throwTypeError(prefix ++ "The provided value is not of type '" ++ dict_name ++ "'.", exec);
    }

    fn requiredMember(
        dict: js.Object,
        comptime key: []const u8,
        comptime prefix: []const u8,
        comptime dict_name: []const u8,
        exec: *const Execution,
    ) !js.Value {
        return try member(dict, key) orelse throwTypeError(
            prefix ++ "Failed to read the '" ++ key ++ "' property from '" ++ dict_name ++
                "': Required member is undefined.",
            exec,
        );
    }

    pub fn getRawId(_: *const PublicKeyCredential) ?[]const u8 {
        return null;
    }

    pub fn getResponse(_: *const PublicKeyCredential) ?*AuthenticatorResponse {
        return null;
    }

    pub fn getAuthenticatorAttachment(_: *const PublicKeyCredential) ?[]const u8 {
        return null;
    }

    pub fn getClientExtensionResults(_: *const PublicKeyCredential) struct {} {
        return .{};
    }

    pub fn toJSON(_: *const PublicKeyCredential) struct {} {
        return .{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(PublicKeyCredential);

        pub const Meta = struct {
            pub const name = "PublicKeyCredential";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = Credential;

        const P = PublicKeyCredential;

        pub const rawId = bridge.accessor(P.getRawId, null, .{});
        pub const response = bridge.accessor(P.getResponse, null, .{});
        pub const authenticatorAttachment = bridge.accessor(P.getAuthenticatorAttachment, null, .{});
        pub const getClientExtensionResults = bridge.function(P.getClientExtensionResults, .{});
        pub const toJSON = bridge.function(P.toJSON, .{});

        // Chrome's own static order.
        pub const getClientCapabilities = bridge.function(P.getClientCapabilities, .{ .static = true });
        pub const isConditionalMediationAvailable = bridge.function(P.isConditionalMediationAvailable, .{ .static = true });
        pub const isUserVerifyingPlatformAuthenticatorAvailable = bridge.function(P.isUserVerifyingPlatformAuthenticatorAvailable, .{ .static = true });
        pub const parseCreationOptionsFromJSON = bridge.function(P.parseCreationOptionsFromJSON, .{ .static = true, .arity = 1 });
        pub const parseRequestOptionsFromJSON = bridge.function(P.parseRequestOptionsFromJSON, .{ .static = true, .arity = 1 });
        pub const signalAllAcceptedCredentials = bridge.function(P.signalAllAcceptedCredentials, .{ .static = true, .arity = 1 });
        pub const signalCurrentUserDetails = bridge.function(P.signalCurrentUserDetails, .{ .static = true, .arity = 1 });
        pub const signalUnknownCredential = bridge.function(P.signalUnknownCredential, .{ .static = true, .arity = 1 });
    };
};

/// FedCM's credential. `navigator.credentials.get({identity})` needs a real
/// identity provider, so no instance is reachable.
pub const IdentityCredential = struct {
    pub const Proto = Credential;

    _proto: *Credential,

    pub fn getToken(_: *const IdentityCredential) ?[]const u8 {
        return null;
    }

    pub fn getIsAutoSelected(_: *const IdentityCredential) bool {
        return false;
    }

    pub fn getConfigURL(_: *const IdentityCredential) ?[]const u8 {
        return null;
    }

    // Measured: rejects naming the missing `configURL`, and there is no provider
    // to disconnect from either way.
    pub fn disconnect(options_: ?js.Value, exec: *const Execution) !js.Promise {
        const prefix = "Failed to execute 'disconnect' on 'IdentityCredential': ";
        const options = options_ orelse return rejectType(prefix ++ "1 argument required, but only 0 present.", exec);
        const dict = asDictionary(options) catch return rejectType(
            prefix ++ "The provided value is not of type 'IdentityProviderConfig'.",
            exec,
        );
        const has_config = if (dict) |d| (try member(d, "configURL")) != null else false;
        if (!has_config) return rejectType(
            prefix ++ "Failed to read the 'configURL' property from 'IdentityProviderConfig': Required member is undefined.",
            exec,
        );
        const has_client = if (dict) |d| (try member(d, "clientId")) != null else false;
        if (!has_client) return rejectType(
            prefix ++ "Failed to read the 'clientId' property from 'IdentityProviderConfig': Required member is undefined.",
            exec,
        );
        return rejectDom("NetworkError", "Error retrieving a token.", exec);
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(IdentityCredential);

        pub const Meta = struct {
            pub const name = "IdentityCredential";
            // Chrome's `constructor` sits here rather than last; the members
            // below it are the ones Blink installs per context. See
            // Snapshot.moveConstructorSlots.
            pub const constructor_after = "isAutoSelected";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = Credential;

        pub const token = bridge.accessor(IdentityCredential.getToken, null, .{});
        pub const isAutoSelected = bridge.accessor(IdentityCredential.getIsAutoSelected, null, .{});
        pub const configURL = bridge.accessor(IdentityCredential.getConfigURL, null, .{});
        pub const disconnect = bridge.function(IdentityCredential.disconnect, .{ .static = true, .arity = 1 });
    };
};

/// WebOTP's credential. Only an SMS the browser itself received produces one.
pub const OTPCredential = struct {
    pub const Proto = Credential;

    _proto: *Credential,

    pub fn getCode(_: *const OTPCredential) ?[]const u8 {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(OTPCredential);

        pub const Meta = struct {
            pub const name = "OTPCredential";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = Credential;

        pub const code = bridge.accessor(OTPCredential.getCode, null, .{});
    };
};

/// The base of the two WebAuthn responses.
pub const AuthenticatorResponse = struct {
    _pad: bool = false,

    pub fn getClientDataJSON(_: *const AuthenticatorResponse) ?[]const u8 {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(AuthenticatorResponse);

        pub const Meta = struct {
            pub const name = "AuthenticatorResponse";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const clientDataJSON = bridge.accessor(AuthenticatorResponse.getClientDataJSON, null, .{});
    };
};

pub const AuthenticatorAssertionResponse = struct {
    pub const Proto = AuthenticatorResponse;

    _proto: *AuthenticatorResponse,

    fn none(_: *const AuthenticatorAssertionResponse) ?[]const u8 {
        return null;
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(AuthenticatorAssertionResponse);

        pub const Meta = struct {
            pub const name = "AuthenticatorAssertionResponse";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = AuthenticatorResponse;

        const R = AuthenticatorAssertionResponse;

        pub const authenticatorData = bridge.accessor(R.none, null, .{});
        pub const signature = bridge.accessor(R.none, null, .{});
        pub const userHandle = bridge.accessor(R.none, null, .{});
    };
};

pub const AuthenticatorAttestationResponse = struct {
    pub const Proto = AuthenticatorResponse;

    _proto: *AuthenticatorResponse,

    fn none(_: *const AuthenticatorAttestationResponse) ?[]const u8 {
        return null;
    }

    fn noneMethod(_: *const AuthenticatorAttestationResponse) ?[]const u8 {
        return null;
    }

    fn zero(_: *const AuthenticatorAttestationResponse) i32 {
        return 0;
    }

    fn transports(_: *const AuthenticatorAttestationResponse) []const []const u8 {
        return &.{};
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(AuthenticatorAttestationResponse);

        pub const Meta = struct {
            pub const name = "AuthenticatorAttestationResponse";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
        };

        pub const Prototype = AuthenticatorResponse;

        const R = AuthenticatorAttestationResponse;

        pub const attestationObject = bridge.accessor(R.none, null, .{});
        pub const getAuthenticatorData = bridge.function(R.noneMethod, .{});
        pub const getPublicKey = bridge.function(R.noneMethod, .{});
        pub const getPublicKeyAlgorithm = bridge.function(R.zero, .{});
        pub const getTransports = bridge.function(R.transports, .{});
    };
};

/// `navigator.credentials`. Was a stub that resolved null for every get() and
/// rejected every create(); now that the credential classes exist it answers
/// the way Chrome does, which for `create({password})` means handing back a
/// real PasswordCredential.
pub const CredentialsContainer = struct {
    _pad: bool = false,

    const Mediation = enum { silent, optional, conditional, required };
    const OTPTransport = enum { sms, auth };

    // Chrome converts the whole dictionary before it runs the algorithm, in
    // alphabetical member order, so a conversion failure anywhere outranks the
    // "no credential type" refusal (measured: `{password: true, mediation:
    // 'nope'}` is the mediation TypeError).
    pub fn get(_: *const CredentialsContainer, options_: ?js.Value, exec: *const Execution) !js.Promise {
        const prefix = "Failed to execute 'get' on 'CredentialsContainer': ";
        const dict = if (options_) |options|
            asDictionary(options) catch return rejectType(
                prefix ++ "The provided value is not of type 'CredentialRequestOptions'.",
                exec,
            )
        else
            null;

        var otp_transport: ?OTPTransport = null;
        var has_password = false;
        var has_federated = false;

        if (dict) |d| {
            if (try member(d, "identity")) |identity| {
                const inner = asDictionary(identity) catch return rejectType(
                    prefix ++ "Failed to read the 'identity' property from 'CredentialRequestOptions': " ++
                        "The provided value is not of type 'IdentityCredentialRequestOptions'.",
                    exec,
                );
                const has_providers = if (inner) |i| (try member(i, "providers")) != null else false;
                if (!has_providers) return rejectType(
                    prefix ++ "Failed to read the 'identity' property from 'CredentialRequestOptions': " ++
                        "Failed to read the 'providers' property from 'IdentityCredentialRequestOptions': " ++
                        "Required member is undefined.",
                    exec,
                );
            }
            if (try member(d, "mediation")) |mediation| {
                const text = try mediation.toStringSlice();
                if (std.meta.stringToEnum(Mediation, text) == null) return rejectType(try std.fmt.allocPrint(
                    exec.arena,
                    prefix ++ "Failed to read the 'mediation' property from 'CredentialRequestOptions': " ++
                        "The provided value '{s}' is not a valid enum value of type CredentialMediationRequirement.",
                    .{text},
                ), exec);
            }
            if (try member(d, "otp")) |otp| {
                const inner = asDictionary(otp) catch return rejectType(
                    prefix ++ "Failed to read the 'otp' property from 'CredentialRequestOptions': " ++
                        "The provided value is not of type 'OTPCredentialRequestOptions'.",
                    exec,
                );
                if (inner) |i| {
                    if (try member(i, "transport")) |transport| {
                        const list = try transport.toZig([]const []const u8);
                        for (list) |text| {
                            const parsed = std.meta.stringToEnum(OTPTransport, text) orelse return rejectType(try std.fmt.allocPrint(
                                exec.arena,
                                prefix ++ "Failed to read the 'otp' property from 'CredentialRequestOptions': " ++
                                    "Failed to read the 'transport' property from 'OTPCredentialRequestOptions': " ++
                                    "The provided value '{s}' is not a valid enum value of type OTPCredentialTransportType.",
                                .{text},
                            ), exec);
                            otp_transport = parsed;
                        }
                    }
                }
                // An otp request with no usable transport is refused outright.
                if (otp_transport == null) return rejectDom(
                    "NotSupportedError",
                    "Unsupported transport type for OTP Credentials",
                    exec,
                );
            }
            if (try member(d, "password")) |password| {
                has_password = password.toBool();
            }
            if (try member(d, "federated")) |federated| {
                has_federated = !federated.isNullOrUndefined();
            }
            if (try member(d, "publicKey")) |public_key| {
                const inner = asDictionary(public_key) catch return rejectType(
                    prefix ++ "Failed to read the 'publicKey' property from 'CredentialRequestOptions': " ++
                        "The provided value is not of type 'PublicKeyCredentialRequestOptions'.",
                    exec,
                );
                const has_challenge = if (inner) |i| (try member(i, "challenge")) != null else false;
                if (!has_challenge) return rejectType(
                    prefix ++ "Failed to read the 'publicKey' property from 'CredentialRequestOptions': " ++
                        "Failed to read the 'challenge' property from 'PublicKeyCredentialRequestOptions': " ++
                        "Required member is undefined.",
                    exec,
                );
                // A frame the publickey-credentials-get feature did not reach
                // is refused with Chrome 153's wording.
                if (!permissions_policy.execAllows(exec, "publickey-credentials-get")) return rejectDom(
                    "NotAllowedError",
                    "The 'publickey-credentials-get' feature is not enabled in this document. Permissions Policy may be used to delegate Web Authentication capabilities to cross-origin child frames.",
                    exec,
                );
                // A well-formed passkey request opens Chrome's own chooser and
                // the promise stays pending until somebody answers it.
                return pending(exec);
            }
        }

        // A well-formed otp request parks on an SMS that never arrives
        // (measured: still pending after 2.5s).
        if (otp_transport != null) return pending(exec);

        // We store no credentials, so a password or federated request finds
        // none — which is the null Chrome resolves with (measured).
        if (has_password or has_federated) return exec.js.local.?.resolvePromise(null);

        return rejectDom("NotSupportedError", "No credential type was specified in the request.", exec);
    }

    // Exactly one of password / federated / publicKey, else NotSupportedError —
    // and the dictionary conversions run first, in alphabetical order.
    pub fn create(_: *const CredentialsContainer, options_: ?js.Value, exec: *const Execution) !js.Promise {
        const prefix = "Failed to execute 'create' on 'CredentialsContainer': ";
        const dict = if (options_) |options|
            asDictionary(options) catch return rejectType(
                prefix ++ "The provided value is not of type 'CredentialCreationOptions'.",
                exec,
            )
        else
            null;

        var federated: ?js.Value = null;
        var password: ?js.Value = null;
        var public_key = false;

        if (dict) |d| {
            federated = try member(d, "federated");
            password = try member(d, "password");
            if (try member(d, "publicKey")) |value| {
                const inner = asDictionary(value) catch return rejectType(
                    prefix ++ "Failed to read the 'publicKey' property from 'CredentialCreationOptions': " ++
                        "The provided value is not of type 'PublicKeyCredentialCreationOptions'.",
                    exec,
                );
                const has_challenge = if (inner) |i| (try member(i, "challenge")) != null else false;
                if (!has_challenge) return rejectType(
                    prefix ++ "Failed to read the 'publicKey' property from 'CredentialCreationOptions': " ++
                        "Failed to read the 'challenge' property from 'PublicKeyCredentialCreationOptions': " ++
                        "Required member is undefined.",
                    exec,
                );
                public_key = true;
            }
        }

        var count: usize = 0;
        if (federated != null) count += 1;
        if (password != null) count += 1;
        if (public_key) count += 1;
        if (count != 1) return rejectDom(
            "NotSupportedError",
            "Only exactly one of 'password', 'federated', and 'publicKey' credential types are currently supported.",
            exec,
        );

        var fail: Fail = .{};
        if (password) |value| {
            const credential = PasswordCredential.build(
                value,
                prefix ++ "Failed to read the 'password' property from 'CredentialCreationOptions': ",
                exec,
                &fail,
            ) catch |err| switch (err) {
                error.CredentialRefused => return fail.reject(exec),
                else => return err,
            };
            return exec.js.local.?.resolvePromise(credential);
        }
        if (federated) |value| {
            const credential = FederatedCredential.build(
                value,
                prefix ++ "Failed to read the 'federated' property from 'CredentialCreationOptions': ",
                exec,
                &fail,
            ) catch |err| switch (err) {
                error.CredentialRefused => return fail.reject(exec),
                else => return err,
            };
            return exec.js.local.?.resolvePromise(credential);
        }

        // A passkey creation opens Chrome's own dialog; nothing answers it here.
        return pending(exec);
    }

    pub fn preventSilentAccess(_: *const CredentialsContainer, exec: *const Execution) !js.Promise {
        return exec.js.local.?.resolvePromise({});
    }

    // Measured: storing a real Credential resolves with nothing (Chrome keeps it
    // in its own password manager, which a page cannot read back), and anything
    // that is not one is the TypeError below.
    pub fn store(_: *const CredentialsContainer, credential_: ?js.Value, exec: *const Execution) !js.Promise {
        const prefix = "Failed to execute 'store' on 'CredentialsContainer': ";
        const credential = credential_ orelse return rejectType(
            prefix ++ "1 argument required, but only 0 present.",
            exec,
        );
        _ = credential.toZig(*Credential) catch return rejectType(
            prefix ++ "parameter 1 is not of type 'Credential'.",
            exec,
        );
        return exec.js.local.?.resolvePromise({});
    }

    pub const JsApi = struct {
        pub const bridge = js.Bridge(CredentialsContainer);

        pub const Meta = struct {
            pub const name = "CredentialsContainer";
            pub const prototype_chain = bridge.prototypeChain();
            pub var class_id: bridge.ClassId = undefined;
            pub const empty_with_no_proto = true;
        };

        pub const create = bridge.function(CredentialsContainer.create, .{});
        pub const get = bridge.function(CredentialsContainer.get, .{});
        pub const preventSilentAccess = bridge.function(CredentialsContainer.preventSilentAccess, .{});
        pub const store = bridge.function(CredentialsContainer.store, .{ .arity = 1 });
    };
};
