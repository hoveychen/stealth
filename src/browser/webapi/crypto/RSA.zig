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

/// RSA-OAEP encrypt/decrypt. The result is one modulus-wide block whatever the
/// plaintext length, and OAEP seeds each block randomly, so encrypting the same
/// plaintext twice gives two different blocks (probe-g25 confirms Chrome does).
pub fn crypt(
    params: anytype, // algorithm.Encrypt.params
    key: *const CryptoKey,
    data: []const u8,
    encrypting: bool,
    exec: *const Execution,
) Error![]const u8 {
    // OAEP is the only RSA encryption scheme WebCrypto exposes, and the key
    // has to have been made for it.
    if (!eql(params.name, "RSA-OAEP") or !eql(key._algorithm.name, "RSA-OAEP")) {
        return error.InvalidAccessError;
    }
    if ((encrypting and !key.canEncrypt()) or (!encrypting and !key.canDecrypt())) {
        return error.InvalidAccessError;
    }

    const md = crypto.findDigest(key._algorithm.hash orelse "") catch return error.OperationError;

    const ctx = crypto.EVP_PKEY_CTX_new(key.getKeyObject(), null) orelse return error.OperationError;
    defer crypto.EVP_PKEY_CTX_free(ctx);

    const started = if (encrypting) crypto.EVP_PKEY_encrypt_init(ctx) else crypto.EVP_PKEY_decrypt_init(ctx);
    if (started != 1) {
        return error.OperationError;
    }
    if (crypto.EVP_PKEY_CTX_set_rsa_padding(ctx, crypto.RSA_PKCS1_OAEP_PADDING) != 1) {
        return error.OperationError;
    }
    // MGF-1 is left alone: it defaults to the OAEP digest, which is what
    // WebCrypto specifies.
    if (crypto.EVP_PKEY_CTX_set_rsa_oaep_md(ctx, md) != 1) {
        return error.OperationError;
    }
    if (params.label) |label| {
        if (label.values.len > 0) {
            // The context takes ownership of the label and frees it itself, so
            // it has to be a libcrypto allocation rather than an arena slice.
            const owned: [*]u8 = @ptrCast(crypto.OPENSSL_malloc(label.values.len) orelse return error.OutOfMemory);
            @memcpy(owned[0..label.values.len], label.values);
            if (crypto.EVP_PKEY_CTX_set0_rsa_oaep_label(ctx, owned, label.values.len) != 1) {
                crypto.OPENSSL_free(owned);
                return error.OperationError;
            }
        }
    }

    const op: *const @TypeOf(crypto.EVP_PKEY_encrypt) =
        if (encrypting) &crypto.EVP_PKEY_encrypt else &crypto.EVP_PKEY_decrypt;

    // The first call with a null buffer reports the space the result needs.
    var len: usize = 0;
    if (op(ctx, null, &len, data.ptr, data.len) != 1) {
        // A plaintext too long for one block fails here, which is the
        // OperationError Chrome answers for 500 bytes under a 2048-bit key.
        return error.OperationError;
    }
    const out = try exec.local_arena.alloc(u8, len);
    if (op(ctx, out.ptr, &len, data.ptr, data.len) != 1) {
        return error.OperationError;
    }
    return out[0..len];
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

/// The public half of a JSON Web Key: the modulus and exponent plus the
/// bookkeeping members. Chrome answers `RSA/RSA-OAEP-256/AQAB/true/342` for
/// (kty, alg, e, ext, n.length) on a 2048-bit RSA-OAEP key (probe-g25).
const JwkPublic = struct {
    kty: []const u8 = "RSA",
    n: []const u8,
    e: []const u8,
    alg: []const u8,
    ext: bool,
    key_ops: []const []const u8,
};

/// The private half adds the private exponent and the CRT components. Chrome's
/// member set is exactly `alg,d,dp,dq,e,ext,key_ops,kty,n,p,q,qi`.
const JwkPrivate = struct {
    kty: []const u8 = "RSA",
    n: []const u8,
    e: []const u8,
    d: []const u8,
    p: []const u8,
    q: []const u8,
    dp: []const u8,
    dq: []const u8,
    qi: []const u8,
    alg: []const u8,
    ext: bool,
    key_ops: []const []const u8,
};

/// The JWA `alg` name, which encodes the algorithm and the hash together --
/// RSA-OAEP with SHA-256 is "RSA-OAEP-256", the same pair under PSS is "PS256".
/// SHA-1 is the odd one out: it is the unsuffixed form.
fn jwkAlg(name: []const u8, hash: []const u8) ?[]const u8 {
    //                                 SHA-1        SHA-256          SHA-384          SHA-512
    const row: [4][]const u8 = blk: {
        if (eql(name, "RSA-OAEP")) break :blk .{ "RSA-OAEP", "RSA-OAEP-256", "RSA-OAEP-384", "RSA-OAEP-512" };
        if (eql(name, "RSA-PSS")) break :blk .{ "PS1", "PS256", "PS384", "PS512" };
        break :blk .{ "RS1", "RS256", "RS384", "RS512" };
    };

    if (eql(hash, "SHA-1")) return row[0];
    if (eql(hash, "SHA-256")) return row[1];
    if (eql(hash, "SHA-384")) return row[2];
    if (eql(hash, "SHA-512")) return row[3];
    return null;
}

/// Exports the key as a JSON Web Key. The private half is the public one plus
/// the six private components; both carry the same `alg`, `ext` and `key_ops`.
pub fn exportJwk(key: *const CryptoKey, exec: *const Execution) !js.Promise {
    const local = exec.js.local.?;

    const alg = jwkAlg(key._algorithm.name, key._algorithm.hash orelse "") orelse {
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } });
    };
    const rsa = crypto.EVP_PKEY_get0_RSA(key.getKeyObject()) orelse {
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.OperationError } });
    };

    const n = try bnBase64(exec, crypto.RSA_get0_n(rsa));
    const e = try bnBase64(exec, crypto.RSA_get0_e(rsa));
    const key_ops = try key.getUsages(exec);

    if (key._kind == .public) {
        return local.resolvePromise(JwkPublic{
            .n = n,
            .e = e,
            .alg = alg,
            .ext = key._extractable,
            .key_ops = key_ops,
        });
    }

    return local.resolvePromise(JwkPrivate{
        .n = n,
        .e = e,
        .d = try bnBase64(exec, crypto.RSA_get0_d(rsa)),
        .p = try bnBase64(exec, crypto.RSA_get0_p(rsa)),
        .q = try bnBase64(exec, crypto.RSA_get0_q(rsa)),
        .dp = try bnBase64(exec, crypto.RSA_get0_dmp1(rsa)),
        .dq = try bnBase64(exec, crypto.RSA_get0_dmq1(rsa)),
        .qi = try bnBase64(exec, crypto.RSA_get0_iqmp(rsa)),
        .alg = alg,
        .ext = key._extractable,
        .key_ops = key_ops,
    });
}

/// Imports a key from a JSON Web Key. `d` marks the private form, which the
/// caller has already used to pick the usage set; a JWK missing the members its
/// form requires is DataError, the same answer malformed DER gets.
pub fn importJwk(
    name: []const u8,
    hash_name: []const u8,
    jwk: algorithm.KeyData.Jwk,
    extractable: bool,
    usages_mask: u8,
    exec: *const Execution,
) !js.Promise {
    const local = exec.js.local.?;

    const canonical = canonicalName(name).?;
    const hash = canonicalHash(hash_name) orelse {
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.NotSupported } });
    };
    if (!std.mem.eql(u8, jwk.kty, "RSA")) {
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.DataError } });
    }

    // Every RSA JWK carries the modulus and the public exponent, whichever
    // half it describes.
    var bignums: BigNums = .{};
    defer bignums.deinit();
    const n = bignums.add(exec, jwk.n) catch {
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.DataError } });
    };
    const e = bignums.add(exec, jwk.e) catch {
        return local.rejectPromise(.{ .dom_exception = .{ .err = error.DataError } });
    };

    const rsa: *crypto.RSA = blk: {
        if (jwk.d == null) {
            break :blk crypto.RSA_new_public_key(n, e) orelse {
                return local.rejectPromise(.{ .dom_exception = .{ .err = error.DataError } });
            };
        }
        const d = bignums.add(exec, jwk.d) catch {
            return local.rejectPromise(.{ .dom_exception = .{ .err = error.DataError } });
        };
        // A JWK may carry only (n, e, d); the CRT members are an optimisation
        // the spec lets a producer leave out.
        const crt = jwk.p != null and jwk.q != null and jwk.dp != null and jwk.dq != null and jwk.qi != null;
        if (!crt) {
            break :blk crypto.RSA_new_private_key_no_crt(n, e, d) orelse {
                return local.rejectPromise(.{ .dom_exception = .{ .err = error.DataError } });
            };
        }
        const made = crypto.RSA_new_private_key(
            n,
            e,
            d,
            bignums.add(exec, jwk.p) catch return local.rejectPromise(.{ .dom_exception = .{ .err = error.DataError } }),
            bignums.add(exec, jwk.q) catch return local.rejectPromise(.{ .dom_exception = .{ .err = error.DataError } }),
            bignums.add(exec, jwk.dp) catch return local.rejectPromise(.{ .dom_exception = .{ .err = error.DataError } }),
            bignums.add(exec, jwk.dq) catch return local.rejectPromise(.{ .dom_exception = .{ .err = error.DataError } }),
            bignums.add(exec, jwk.qi) catch return local.rejectPromise(.{ .dom_exception = .{ .err = error.DataError } }),
        );
        break :blk made orelse {
            return local.rejectPromise(.{ .dom_exception = .{ .err = error.DataError } });
        };
    };
    defer crypto.RSA_free(rsa);

    const pkey = crypto.EVP_PKEY_new() orelse return error.OutOfMemory;
    errdefer crypto.EVP_PKEY_free(pkey);
    if (crypto.EVP_PKEY_set1_RSA(pkey, rsa) != 1) return error.OutOfMemory;

    const crypto_key = try CryptoKey.init(exec, .{
        ._type = .rsa,
        ._kind = if (jwk.d == null) .public else .private,
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

/// The BIGNUMs decoded from one JWK. They have to outlive the `RSA_new_*` call
/// that consumes them, and freeing them one by one across eight fallible steps
/// is what this saves.
const BigNums = struct {
    items: [8]?*crypto.BIGNUM = @splat(null),
    len: usize = 0,

    /// Decodes one base64url member into a BIGNUM. A missing or malformed
    /// member is an error, which the caller turns into DataError.
    fn add(self: *BigNums, exec: *const Execution, member: ?[]const u8) !*crypto.BIGNUM {
        const encoded = member orelse return error.DataError;
        const bytes = try common.base64Decode(exec.local_arena, encoded);
        const bn = crypto.BN_bin2bn(bytes.ptr, bytes.len, null) orelse return error.OutOfMemory;
        self.items[self.len] = bn;
        self.len += 1;
        return bn;
    }

    fn deinit(self: *BigNums) void {
        for (self.items[0..self.len]) |bn| {
            crypto.BN_free(bn);
        }
    }
};

/// A BIGNUM as the base64url string a JWK member holds.
fn bnBase64(exec: *const Execution, bn: ?*const crypto.BIGNUM) ![]const u8 {
    const value = bn orelse return error.OperationError;
    const buf = try exec.local_arena.alloc(u8, crypto.BN_num_bytes(value));
    const written = crypto.BN_bn2bin(value, buf.ptr);
    return common.base64Encode(exec.local_arena, buf[0..written]);
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
