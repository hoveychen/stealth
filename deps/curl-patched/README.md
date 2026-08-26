# Patched libcurl sources

Two files from the pinned libcurl, carried here instead of being taken from the
dependency. `build.zig`'s `buildCurl()` drops them from the dependency-rooted
file list and compiles these with identical flags and include paths.

They are here because three values that make up the HTTP/2 fingerprint are
hardcoded in libcurl with no runtime option, and a request whose SETTINGS frame
says "libcurl" is identifiable no matter how the ClientHello above it looks.
See the transport section of `tools/fingerprint/README.md` for the measurement.

Upstream: curl 8.20.0, the version pinned in `build.zig.zon`.

| file | sha256 of the pristine upstream copy |
|---|---|
| `lib/http.c` | `e57e4d70651e9113da1325881b9ecfc48ebca8e4f777b3270ebb165df4378fec` |
| `lib/http2.c` | `d1d27e7c5ec19c764fb7c30961a12e8bc796e68383a688dcb25ea5e547236a62` |

## What differs

Every change is marked with a `LIGHTPANDA:` comment, so
`grep -n LIGHTPANDA lib/*.c` is the complete list.

### `lib/http.c` — `Curl_add_custom_headers()`

Drops a `priority` field when the request is going out below HTTP/2. Chrome
sends an RFC 9218 hint on every h2 and h3 request and never on HTTP/1.1, where
extensible priorities do not exist, so emitting one there would be a tell in its
own right. `HttpClient.zig` adds the field unconditionally because a single
header list is reused across an h1 and an h2 attempt; this function already
receives the negotiated version, and the skip sits beside upstream's own
version-gated skip of `Transfer-Encoding`. It is the mirror of `Connection`,
which `h2_permissible_field()` drops in the other direction.

### `lib/http.c` — `Curl_http_req_to_h2()`, cookie fields

Splits the `Cookie` header into one `cookie` field per cookie, via
`h2_add_cookie_fields()`. RFC 9113 §8.2.3 allows it so HPACK's dynamic table
can hold an entry per cookie instead of an entry per combination, and Chrome
always takes it — measured over h2 on a navigation, a subresource, an XHR POST
and a fetch POST, every cookie in a field of its own. A receiver must
concatenate them again, so no server sees a difference; only something reading
the header block does.

It is here rather than in `HttpClient.zig` because the split is legal on HTTP/2
and is not on HTTP/1.1, where RFC 6265 §5.4 allows exactly one Cookie header
and Chrome sends exactly one. One header list is reused across an h1 and an h2
attempt, and the negotiated version is not known while it is built. Same
division as the `priority` hint above.

### `lib/http.c` — `Curl_http_req_to_h2()`, pseudo-header order

Emits `:authority` before `:scheme`. Upstream orders the pseudo-headers
`:method :scheme :authority :path`; Chrome orders them
`:method :authority :scheme :path`, and that order is the last field of an
Akamai HTTP/2 fingerprint. RFC 9113 §8.3.1 does not constrain the order, so
both are legal.

### `lib/http2.c` — `populate_settings()`

Sends Chrome's four SETTINGS entries in Chrome's order —
`HEADER_TABLE_SIZE=65536`, `ENABLE_PUSH=0`, `INITIAL_WINDOW_SIZE`,
`MAX_HEADER_LIST_SIZE=262144` — instead of upstream's three.

`MAX_CONCURRENT_STREAMS` is dropped rather than reordered. It caps streams the
*peer* may open, and with `ENABLE_PUSH` at 0 a server cannot open any.

Raising `HEADER_TABLE_SIZE` is safe: nghttp2 resizes its own HPACK inflater
from the value we announce, in `nghttp2_session_update_local_settings()`.

### `lib/http2.c` — `H2_STREAM_WINDOW_SIZE_INITIAL`

6 MiB, was 64 KiB. This is the constant `cf_h2_initial_win_size()` returns and
therefore the value announced as `SETTINGS_INITIAL_WINDOW_SIZE`; Chrome
announces 6291456. Changing the constant rather than the SETTINGS entry keeps
curl's per-stream bookkeeping (`stream->local_window_size`) agreeing with what
the peer was told. It stays below `H2_STREAM_WINDOW_SIZE_MAX` (10 MiB), so the
grow-to-max path is unaffected.

### `lib/http2.c` — `HTTP2_HUGE_WINDOW_SIZE`

15 MiB, was ~1 GiB (`100 * H2_STREAM_WINDOW_SIZE_MAX`). This is the connection
window, announced as a `WINDOW_UPDATE` on stream 0 right after the preface.
Chrome uses a 15 MiB connection window, so the increment over the 65535 default
reads as 15663105 the way Chrome's does.

## Re-syncing after a curl bump

1. Extract the new tarball and diff each file against the pristine copy whose
   hash is in the table above — that isolates upstream's changes from ours.
2. Copy the new files here and re-apply every `LIGHTPANDA:` hunk. They are
   small and localised; none of them has moved between 8.x releases so far.
3. Update the hash table above.
4. Re-measure: `node tools/fingerprint/collect-tls.mjs --engine lightpanda`.
   The Akamai fingerprint must come out
   `1:65536;2:0;4:6291456;6:262144|15663105|0|m,a,s,p`.
5. Re-measure the header block too, since two of the hunks above shape it:
   `node tools/fingerprint/h2-cookie-order.mjs <arm>` for each arm, then
   `--diff`. The header *name* sequence must match Chrome on all shapes,
   `cookie` included, once per cookie.

## Verification this is not just cosmetic

Measured with `tools/fingerprint/collect-tls.mjs` against Chrome 150:

| | before | after | Chrome 150 |
|---|---|---|---|
| Akamai fingerprint | `3:100;4:65536;2:0\|1048510465\|0\|m,s,a,p` | `1:65536;2:0;4:6291456;6:262144\|15663105\|0\|m,a,s,p` | identical to ours |
| Akamai hash | — | `52d84b11737d980aef856699f885ca86` | `52d84b11737d980aef856699f885ca86` |

Traffic still works: eleven real HTTPS origins across six CDNs return 200,
including an 8.9 MB body over HTTP/2, which is what exercises the wider flow
control windows. `subresource-check.mjs` still reports 8/8 and the test suite
still passes 1150/1150.
