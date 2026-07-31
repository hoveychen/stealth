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

Nothing yet beyond being copied verbatim — this commit only moves the wrapper
in-tree and proves the move is neutral (the build still succeeds and produces
the same libraries). The BoringSSL bump lands separately so that a bisect can
tell "vendoring broke it" apart from "the new BoringSSL broke it".

## Re-syncing

If upstream bumps its own BoringSSL past the ML-DSA code points, this whole
directory should be deleted and `build.zig.zon` pointed back at the fetched
dependency. Check with:

```
gh api repos/lightpanda-io/boringssl-zig/contents/build.zig.zon --jq '.content' | base64 -d
```
