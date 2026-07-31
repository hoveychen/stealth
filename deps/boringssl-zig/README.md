# Vendored boringssl-zig

The Zig build wrapper for BoringSSL, carried in-tree instead of fetched from
`github.com/lightpanda-io/boringssl-zig`. `build.zig.zon` points at this
directory by path.

It is here because the wrapper pins which BoringSSL revision gets compiled, and
we need a different one: the ClientHello has to offer Chrome's ML-DSA signature
algorithms (`SSL_SIGN_ML_DSA_44` / `_65` / `_87`, code points
`0x0904`–`0x0906`), and the revision upstream pins predates them. BoringSSL
rejects an entire signature-algorithm preference list if it contains one code
point it does not recognise, so this is all-or-nothing — see
`tools/fingerprint/README.md`.

Upstream: `lightpanda-io/boringssl-zig` at `f07cc58fa4a051eb0985287e691db5dbb0e7e76f`.
`2007c1a27456` is one commit further along but only merges the Zig 0.16 PR that
`f07cc58` already contains; the BoringSSL pin is the same in both.

## What differs from upstream

Two things.

**The BoringSSL revision.** `7515be5c` (2026-07-31) instead of `535cc391`
(2025-06-24). That is the whole point of vendoring: the older revision has no
`SSL_SIGN_ML_DSA_*`, and BoringSSL rejects a signature-algorithm preference
list whole if it contains one code point it cannot name.

**The source lists are generated, not hand-curated.** `gen-sources.py` reads
BoringSSL's own `gen/sources.json` — the manifest its Bazel and CMake builds
read — and rewrites everything below the first `const pki_sources` line in
`build.zig`:

```
python3 deps/boringssl-zig/gen-sources.py /path/to/boringssl-checkout
zig fmt deps/boringssl-zig/build.zig
```

Hand-curating those lists is how a bump silently drops a translation unit and
surfaces as a link error three layers away. Across the thirteen months of drift
this bump covers, the manifest moved `fips_shared_support.cc` out of the FIPS
module, added one pki source and dropped three crypto ones — none of which is
obvious by reading a diff of C files.

Everything above `const pki_sources` in `build.zig` is upstream's, untouched.

The asm arrays deliberately keep every architecture's files, as upstream's
wrapper does. BoringSSL wraps each generated `.S` in its own
`#if defined(__x86_64__)`-style guard, so the ones that do not apply compile to
nothing; filtering them here would duplicate BoringSSL's target logic.

**No API drift had to be absorbed.** curl 8.20 and `src/sys/libcrypto.zig`
compile against the new headers unchanged, and the suite passes 1150/1150.

## Re-syncing

If upstream bumps its own BoringSSL past the ML-DSA code points, this whole
directory should be deleted and `build.zig.zon` pointed back at the fetched
dependency. Check with:

```
gh api repos/lightpanda-io/boringssl-zig/contents/build.zig.zon --jq '.content' | base64 -d
```
