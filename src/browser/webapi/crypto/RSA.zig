// Copyright (C) 2023-2026 Lightpanda (Selecy SAS)
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

//! RSA key generation for RSA-OAEP, RSASSA-PKCS1-v1_5 and RSA-PSS. The key
//! material is a libcrypto RSA behind an EVP_PKEY in `CryptoKey._vary.pkey`,
//! the same place EC.zig keeps its keys.
//!
//! Every observable here was measured against a headed Chrome 150
//! (`probe-g25`): the pair splits the requested usages, the public half is
//! extractable even when the pair is not, and `algorithm.publicExponent`
//! reads back as a Uint8Array.

const std = @import("std");
const crypto = @import("../../../sys/libcrypto.zig");

const js = @import("../../js/js.zig");

const CryptoKey = @import("../CryptoKey.zig");
const algorithm = @import("algorithm.zig");
const common = @import("common.zig");

const Execution = js.Execution;

/// Errors mapped to DOMException names by the caller.
pub const Error = error{ InvalidAccessError, DataError, NotSupported, OperationError, OutOfMemory };

/// Which usages each half of the pair may keep. `validate` has already
/// rejected any usage that belongs to neither.
fn usageSets(name: []const u8) struct { private: []const []const u8, public: []const []const u8 } {
    if (eql(name, "RSA-OAEP")) {
        return .{ .private = &.{ "decrypt", "unwrapKey" }, .public = &.{ "encrypt", "wrapKey" } };
    }
    // RSASSA-PKCS1-v1_5 and RSA-PSS
    return .{ .private = &.{"sign"}, .public = &.{"verify"} };
}

/// The spelling Chrome reports back from `key.algorithm.name`, which is the
/// registered casing rather than whatever the caller passed.
pub fn canonicalName(name: []const u8) ?[]const u8 {
    if (eql(name, "RSA-OAEP")) return "RSA-OAEP";
    if (eql(name, "RSASSA-PKCS1-v1_5")) return "RSASSA-PKCS1-v1_5";
    if (eql(name, "RSA-PSS")) return "RSA-PSS";
    return null;
}

/// Likewise for the hash: `hash: "sha-256"` reads back as "SHA-256".
pub fn canonicalHash(name: []const u8) ?[]const u8 {
    if (eql(name, "SHA-1")) return "SHA-1";
    if (eql(name, "SHA-256")) return "SHA-256";
    if (eql(name, "SHA-384")) return "SHA-384";
    if (eql(name, "SHA-512")) return "SHA-512";
    return null;
}

/// Generates an RSA key pair and hands back the two `CryptoKey`s.
pub fn generate(
    params: algorithm.Init.RsaHashedKeyGen,
    extractable: bool,
    key_usages: []const []const u8,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;
    validate(params, key_usages) catch |err| {
        return local.rejectPromise(.{ .dom_exception = .{ .err = err } });
    };

    const name = canonicalName(params.name).?;
    const hash = canonicalHash(switch (params.hash) {
        .string => |s| s,
        .object => |o| o.name,
    }).?;
    const sets = usageSets(name);
    const private_mask = maskOf(sets.private, key_usages);
    const public_mask = maskOf(sets.public, key_usages);

    // Chrome refuses a modulus it cannot generate rather than silently
    // rounding; anything under 512 bits is not a key it will make.
    if (params.modulusLength < 512 or params.modulusLength > 16384) {
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.OperationError } });
    }

    const exponent = crypto.BN_new() orelse return error.OutOfMemory;
    defer crypto.BN_free(exponent);
    const raw = params.publicExponent.values;
    if (crypto.BN_bin2bn(raw.ptr, raw.len, exponent) == null) return error.OutOfMemory;

    const rsa = crypto.RSA_new() orelse return error.OutOfMemory;
    defer crypto.RSA_free(rsa);
    if (crypto.RSA_generate_key_ex(rsa, @intCast(params.modulusLength), exponent, null) != 1) {
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.OperationError } });
    }

    const private_pkey = crypto.EVP_PKEY_new() orelse return error.OutOfMemory;
    errdefer crypto.EVP_PKEY_free(private_pkey);
    if (crypto.EVP_PKEY_set1_RSA(private_pkey, rsa) != 1) return error.OutOfMemory;

    // The public half is a copy holding only (n, e) -- handing out the private
    // key with a narrower usage mask would leak the private components to
    // anything that exported it.
    const pub_rsa = crypto.RSAPublicKey_dup(rsa) orelse return error.OutOfMemory;
    defer crypto.RSA_free(pub_rsa);
    const public_pkey = crypto.EVP_PKEY_new() orelse return error.OutOfMemory;
    errdefer crypto.EVP_PKEY_free(public_pkey);
    if (crypto.EVP_PKEY_set1_RSA(public_pkey, pub_rsa) != 1) return error.OutOfMemory;

    // Read the modulus and exponent back off the generated key rather than
    // echoing the request: they are what the key actually has.
    const modulus_length = crypto.RSA_bits(rsa);
    const exponent_bytes = try exponentBytes(exec, rsa);

    const meta: CryptoKey.Algorithm = .{
        .name = name,
        .hash = hash,
        .modulus_length = modulus_length,
        .public_exponent = exponent_bytes,
    };

    const private = try CryptoKey.init(exec, .{
        ._type = .rsa,
        ._kind = .private,
        ._extractable = extractable,
        ._usages = private_mask,
        ._key = &.{},
        ._algorithm = meta,
        ._vary = .{ .pkey = private_pkey },
    });

    const public = try CryptoKey.init(exec, .{
        ._type = .rsa,
        ._kind = .public,
        // A public key is always extractable, even out of a sealed pair.
        ._extractable = true,
        ._usages = public_mask,
        ._key = &.{},
        ._algorithm = meta,
        ._vary = .{ .pkey = public_pkey },
    });

    return local.resolvePromise(CryptoKey.Pair{ .privateKey = private, .publicKey = public });
}

/// Imports an RSA key from DER (`spki` public / `pkcs8` private). The DER says
/// nothing about which RSA algorithm or hash the key is for, so both come from
/// the caller; the modulus and exponent are read back off the parsed key.
/// libcrypto does the parsing, so malformed DER is DataError.
pub fn import(
    name: []const u8,
    hash_name: []const u8,
    format: []const u8,
    der: []const u8,
    is_private: bool,
    extractable: bool,
    usages_mask: u8,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;

    const canonical = canonicalName(name).?;
    const hash = canonicalHash(hash_name) orelse {
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } });
    };

    var ptr: [*c]const u8 = der.ptr;
    const pkey: *crypto.EVP_PKEY = blk: {
        if (std.mem.eql(u8, format, "spki")) {
            break :blk crypto.d2i_PUBKEY(null, &ptr, @intCast(der.len)) orelse {
                return local.rejectPromise(.{ .dom_exception = .{ .err = error.DataError } });
            };
        }
        if (std.mem.eql(u8, format, "pkcs8")) {
            break :blk crypto.d2i_AutoPrivateKey(null, &ptr, @intCast(der.len)) orelse {
                return local.rejectPromise(.{ .dom_exception = .{ .err = error.DataError } });
            };
        }
        // jwk / raw not handled here.
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } });
    };
    errdefer crypto.EVP_PKEY_free(pkey);

    // An EC key in a well-formed SPKI parses fine; it just isn't an RSA key.
    if (crypto.EVP_PKEY_id(pkey) != crypto.EVP_PKEY_RSA) {
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.DataError } });
    }
    const rsa = crypto.EVP_PKEY_get0_RSA(pkey) orelse {
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.DataError } });
    };

    const crypto_key = try CryptoKey.init(exec, .{
        ._type = .rsa,
        ._kind = if (is_private) .private else .public,
        ._extractable = extractable,
        ._usages = usages_mask,
        ._key = &.{},
        ._algorithm = .{
            .name = canonical,
            .hash = hash,
            .modulus_length = crypto.RSA_bits(rsa),
            .public_exponent = try exponentBytes(exec, rsa),
        },
        ._vary = .{ .pkey = pkey },
    });

    return local.resolvePromise(crypto_key);
}

/// Marshals the key as DER: `spki` for the public half, `pkcs8` for the
/// private one. Each format names one half of the pair, and Chrome refuses the
/// other half rather than deriving it -- `exportKey('spki', privateKey)` is
/// InvalidAccessError there (probe-g25), not a public-key export.
pub fn exportDer(key: *const CryptoKey, format: []const u8, exec: *const Execution) Error![]const u8 {
    const want_public = std.mem.eql(u8, format, "spki");
    if (key._kind != (if (want_public) CryptoKey.Kind.public else CryptoKey.Kind.private)) {
        return error.InvalidAccessError;
    }

    // Both encoders allocate the buffer themselves when handed a null pointer.
    var out: ?[*]u8 = null;
    const len = blk: {
        if (want_public) {
            break :blk crypto.i2d_PUBKEY(key.getKeyObject(), &out);
        }
        const info = crypto.EVP_PKEY2PKCS8(key.getKeyObject()) orelse return error.OperationError;
        defer crypto.PKCS8_PRIV_KEY_INFO_free(info);
        break :blk crypto.i2d_PKCS8_PRIV_KEY_INFO(info, &out);
    };

    const buf = out orelse return error.OperationError;
    defer crypto.OPENSSL_free(buf);
    if (len <= 0) {
        return error.OperationError;
    }
    return exec.local_arena.dupe(u8, buf[0..@intCast(len)]);
}

/// The public exponent as big-endian bytes, which is how `algorithm`
/// reports it.
fn exponentBytes(exec: *const Execution, rsa: *const crypto.RSA) ![]const u8 {
    const e = crypto.RSA_get0_e(rsa) orelse return error.OperationError;
    const len = crypto.BN_num_bytes(e);
    const buf = try exec.local_arena.alloc(u8, len);
    const written = crypto.BN_bn2bin(e, buf.ptr);
    return buf[0..written];
}

fn maskOf(set: []const []const u8, usages: []const []const u8) u8 {
    var mask: u8 = 0;
    for (usages) |u| {
        for (set) |s| {
            if (std.mem.eql(u8, s, u)) {
                mask |= common.usageBit(u).?;
                break;
            }
        }
    }
    return mask;
}

pub fn validate(params: algorithm.Init.RsaHashedKeyGen, key_usages: []const []const u8) !void {
    const allowed: []const []const u8 = blk: {
        if (eql(params.name, "RSASSA-PKCS1-v1_5") or eql(params.name, "RSA-PSS")) {
            break :blk &.{ "sign", "verify" };
        }
        if (eql(params.name, "RSA-OAEP")) {
            break :blk &.{ "encrypt", "decrypt", "wrapKey", "unwrapKey" };
        }
        return error.NotSupported;
    };

    const hash_name = switch (params.hash) {
        .string => |s| s,
        .object => |o| o.name,
    };
    if (!eql(hash_name, "SHA-1") and
        !eql(hash_name, "SHA-256") and
        !eql(hash_name, "SHA-384") and
        !eql(hash_name, "SHA-512"))
    {
        return error.NotSupported;
    }

    for (key_usages) |usage| {
        var ok = false;
        for (allowed) |a| {
            if (std.mem.eql(u8, a, usage)) {
                ok = true;
                break;
            }
        }
        if (!ok) {
            return error.SyntaxError;
        }
    }

    if (!isValidPublicExponent(params.publicExponent.values)) {
        return error.OperationError;
    }

    if (key_usages.len == 0) {
        return error.SyntaxError;
    }
}

// WebCrypto only mandates rejection on key-generation failure, but in
// practice browsers accept the standard exponents 3 and 65537 and reject
// the rest. Match that.
fn isValidPublicExponent(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    var i: usize = 0;
    while (i + 1 < bytes.len and bytes[i] == 0) : (i += 1) {}
    const trimmed = bytes[i..];
    if (trimmed.len == 1 and trimmed[0] == 3) return true;
    if (trimmed.len == 3 and trimmed[0] == 0x01 and trimmed[1] == 0x00 and trimmed[2] == 0x01) return true;
    return false;
}

fn eql(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}
