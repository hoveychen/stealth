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

//! The one Brotli entry point we call directly. Response bodies are decoded by
//! libcurl, which links Brotli itself; this is for TLS certificate
//! decompression (RFC 8879), which happens inside BoringSSL and so needs a
//! decompressor we hand it.

pub const BROTLI_DECODER_RESULT_ERROR = 0;
pub const BROTLI_DECODER_RESULT_SUCCESS = 1;
pub const BROTLI_DECODER_RESULT_NEEDS_MORE_INPUT = 2;
pub const BROTLI_DECODER_RESULT_NEEDS_MORE_OUTPUT = 3;

/// One-shot decode into a caller-provided buffer. `decoded_size` is the
/// buffer's capacity on the way in and the byte count actually written on the
/// way out.
pub extern fn BrotliDecoderDecompress(
    encoded_size: usize,
    encoded_buffer: [*]const u8,
    decoded_size: *usize,
    decoded_buffer: [*]u8,
) c_int;
