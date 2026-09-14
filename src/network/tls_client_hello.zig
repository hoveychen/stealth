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

//! Shapes the TLS ClientHello like Chrome's instead of like libcurl's.
//!
//! Nothing above the socket can hide this layer: a server sees the cipher
//! list, the extension list, the named groups and the signature algorithms
//! before a single byte of HTTP is exchanged, and JA3/JA4 turn exactly those
//! into a fingerprint. Out of the box libcurl offers two ciphers Chrome
//! dropped, no GREASE, and nine fewer extensions, so the hello is recognisable
//! as "not a browser" regardless of what the User-Agent says.
//!
//! We share BoringSSL with Chrome, so most of this is calling the same knobs
//! Chrome calls. The values below are transcribed from a measured Chrome
//! ClientHello (`tools/fingerprint/collect-tls.mjs`), not from memory.
//!
//! Two things here are deliberately *not* fixed values. GREASE (RFC 8701) and
//! extension permutation both make Chrome's hello differ connection to
//! connection; reproducing Chrome means reproducing that variation, so JA3 is
//! expected to change per connection while JA4 — which sorts extensions and
//! drops GREASE — stays put.

const std = @import("std");

const brotli = @import("../sys/libbrotli.zig");
const crypto = @import("../sys/libcrypto.zig");

pub const Error = error{TlsProfileRejected};

/// TLS 1.2-and-below cipher suites, in Chrome's order. BoringSSL always emits
/// its three TLS 1.3 suites first and does not take them from this list.
///
/// Against libcurl's default this drops ECDHE-ECDSA-AES128-SHA (0xc009) and
/// ECDHE-ECDSA-AES256-SHA (0xc00a), the only two Chrome does not offer. Their
/// presence is why libcurl's hello counts 17 ciphers where Chrome counts 15.
const CIPHER_LIST =
    "ECDHE-ECDSA-AES128-GCM-SHA256:" ++
    "ECDHE-RSA-AES128-GCM-SHA256:" ++
    "ECDHE-ECDSA-AES256-GCM-SHA384:" ++
    "ECDHE-RSA-AES256-GCM-SHA384:" ++
    "ECDHE-ECDSA-CHACHA20-POLY1305:" ++
    "ECDHE-RSA-CHACHA20-POLY1305:" ++
    "ECDHE-RSA-AES128-SHA:" ++
    "ECDHE-RSA-AES256-SHA:" ++
    "AES128-GCM-SHA256:" ++
    "AES256-GCM-SHA384:" ++
    "AES128-SHA:" ++
    "AES256-SHA";

/// Chrome's supported_groups, in order. The post-quantum hybrid comes first;
/// libcurl offers only the three classical curves, and a missing
/// X25519MLKEM768 is on its own a strong "not Chrome" signal now that every
/// shipping Chrome offers it.
const CURVE_LIST = "X25519MLKEM768:X25519:P-256:P-384";

/// Chrome's signature_algorithms, in order.
///
/// The three ML-DSA entries come first, as they do in Chrome's hello.
/// BoringSSL rejects the whole list if it contains one code point it cannot
/// name, so these are the reason `deps/boringssl-zig` pins a revision newer
/// than the upstream wrapper's.
const SIGNATURE_ALGORITHMS = [_]u16{
    0x0904, // ML-DSA-44
    0x0905, // ML-DSA-65
    0x0906, // ML-DSA-87
    0x0403, // ecdsa_secp256r1_sha256
    0x0804, // rsa_pss_rsae_sha256
    0x0401, // rsa_pkcs1_sha256
    0x0503, // ecdsa_secp384r1_sha384
    0x0805, // rsa_pss_rsae_sha384
    0x0501, // rsa_pkcs1_sha384
    0x0806, // rsa_pss_rsae_sha512
    0x0601, // rsa_pkcs1_sha512
};

/// The one ALPN protocol Chrome offers application settings for.
const ALPS_PROTO = "h2";

/// Applies the profile to a connection's `SSL_CTX`. Call this from libcurl's
/// `CURLOPT_SSL_CTX_FUNCTION`, which runs after libcurl has finished its own
/// setup, so every value here wins.
pub fn configure(ssl_ctx: *crypto.SSL_CTX) Error!void {
    if (crypto.SSL_CTX_set_min_proto_version(ssl_ctx, crypto.TLS1_2_VERSION) != 1) {
        return error.TlsProfileRejected;
    }
    if (crypto.SSL_CTX_set_max_proto_version(ssl_ctx, crypto.TLS1_3_VERSION) != 1) {
        return error.TlsProfileRejected;
    }
    if (crypto.SSL_CTX_set_cipher_list(ssl_ctx, CIPHER_LIST) != 1) {
        return error.TlsProfileRejected;
    }
    if (crypto.SSL_CTX_set1_curves_list(ssl_ctx, CURVE_LIST) != 1) {
        return error.TlsProfileRejected;
    }
    if (crypto.SSL_CTX_set_verify_algorithm_prefs(
        ssl_ctx,
        &SIGNATURE_ALGORITHMS,
        SIGNATURE_ALGORITHMS.len,
    ) != 1) {
        return error.TlsProfileRejected;
    }

    // status_request (5) and signed_certificate_timestamp (18). Chrome asks
    // for both; libcurl asks for neither.
    crypto.SSL_CTX_enable_ocsp_stapling(ssl_ctx);
    crypto.SSL_CTX_enable_signed_cert_timestamps(ssl_ctx);

    // compress_certificate (27), advertising Brotli. Only the decompressor is
    // needed: a client compresses nothing, it just has to be able to read a
    // compressed certificate back, which it now can be sent because we asked.
    if (crypto.SSL_CTX_add_cert_compression_alg(
        ssl_ctx,
        crypto.TLSEXT_cert_compression_brotli,
        null,
        decompressCertificate,
    ) != 1) {
        return error.TlsProfileRejected;
    }

    // session_ticket (35). libcurl sets SSL_OP_NO_TICKET during its own setup,
    // which suppresses the extension outright; browsers send it.
    _ = crypto.SSL_CTX_clear_options(ssl_ctx, crypto.SSL_OP_NO_TICKET);

    // trust_anchors (0xca34). Chrome 152 sends it and BoringSSL only writes it
    // when the application has asked for one, so ours was the single extension
    // Chrome had and we did not: measured against tls.browserleaks.com the two
    // hellos agreed on everything else -- same cipher hash (8daaf6152771), same
    // curves, same signature algorithms, byte-identical Akamai h2 fingerprint
    // -- and differed only in JA4's extension count, t13d1517h2 against
    // t13d1516h2. One expression told the arms apart.
    //
    // The list is empty on purpose. A fingerprint reads the extension's
    // presence and its code point, never its contents, and an empty list is
    // the honest thing to say: this client has no trust anchor subset to
    // advertise. BoringSSL accepts it -- ssl_is_valid_trust_anchor_list walks
    // the entries and an empty span has none to reject.
    const requested_trust_anchors = [_]u8{};
    if (crypto.SSL_CTX_set1_requested_trust_anchors(ssl_ctx, &requested_trust_anchors, 0) != 1) {
        return error.TlsProfileRejected;
    }

    crypto.SSL_CTX_set_grease_enabled(ssl_ctx, 1);
    // signature_algorithms has its own GREASE switch, and it is off by default,
    // so this was the one GREASE position where our hello differed from
    // Chrome's: measured over eight of Chrome's hellos it always carries one
    // fake code point at the FRONT of the list and picks a different one per
    // connection (caca, eaea, 0a0a, 9a9a, fafa, fafa, dada, 7a7a), while ours
    // carried none. Every other position already matched -- cipher list,
    // extension list and supported_groups all come from the switch above.
    //
    // It cannot be done by putting a GREASE value in SIGNATURE_ALGORITHMS
    // below: `SSL_CTX_set_verify_algorithm_prefs` runs every entry through
    // `get_signature_algorithm` and rejects the whole list on the first one it
    // cannot name. BoringSSL adds the fake one when it writes the extension,
    // which is why it needs a flag rather than a list entry.
    crypto.SSL_CTX_set_grease_sigalgs_enabled(ssl_ctx, 1);
    crypto.SSL_CTX_set_permute_extensions(ssl_ctx, 1);

    // application_settings (17613) and encrypted_client_hello (65037) have no
    // SSL_CTX-level setter, so they are applied per handshake instead.
    crypto.SSL_CTX_set_info_callback(ssl_ctx, onHandshakeStart);
}

/// BoringSSL hands us the `SSL` here and nowhere else. `SSL_CB_HANDSHAKE_START`
/// fires at the top of the client's `do_start_connect`, before the ECH config
/// is selected and before any extension is written, so this is early enough to
/// add extensions to the hello.
fn onHandshakeStart(ssl: *crypto.SSL, where: c_int, _: c_int) callconv(.c) void {
    if (where != crypto.SSL_CB_HANDSHAKE_START) {
        return;
    }

    // A GREASE ECH extension, which is what Chrome sends whenever it has no
    // real ECHConfig for the host — i.e. almost always.
    crypto.SSL_set_enable_ech_grease(ssl, 1);

    // ALPS on h2, at the newer 0x44cd code point Chrome uses. An empty
    // settings value is correct for the ClientHello: the extension body there
    // is only the list of protocols that support ALPS.
    crypto.SSL_set_alps_use_new_codepoint(ssl, 1);
    _ = crypto.SSL_add_application_settings(ssl, ALPS_PROTO, ALPS_PROTO.len, "", 0);
}

/// RFC 8879 certificate decompression. The result has to be exactly
/// `uncompressed_len` bytes; anything else is a protocol error and the
/// handshake should fail rather than proceed on a truncated chain.
fn decompressCertificate(
    _: *crypto.SSL,
    out: **crypto.CRYPTO_BUFFER,
    uncompressed_len: usize,
    in: [*]const u8,
    in_len: usize,
) callconv(.c) c_int {
    var data: [*]u8 = undefined;
    const buffer = crypto.CRYPTO_BUFFER_alloc(&data, uncompressed_len) orelse return 0;

    var written = uncompressed_len;
    const result = brotli.BrotliDecoderDecompress(in_len, in, &written, data);
    if (result != brotli.BROTLI_DECODER_RESULT_SUCCESS or written != uncompressed_len) {
        crypto.CRYPTO_BUFFER_free(buffer);
        return 0;
    }

    out.* = buffer;
    return 1;
}
