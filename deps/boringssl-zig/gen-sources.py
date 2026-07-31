#!/usr/bin/env python3
"""Regenerates the source-file arrays at the tail of build.zig.

BoringSSL ships gen/sources.json, the same manifest its own Bazel and CMake
builds read, so the Zig arrays never have to be curated by hand — hand-curating
them is how a bump silently drops a translation unit and produces a link error
three layers away.

    python3 deps/boringssl-zig/gen-sources.py /path/to/boringssl-checkout

Everything above the first `const pki_sources` line in build.zig is left alone.

The asm arrays deliberately keep every architecture's files. BoringSSL wraps
each generated .S in its own `#if defined(__x86_64__)`-style guard, so the ones
that do not apply to the target compile to nothing; filtering them here would
mean duplicating BoringSSL's own target logic.
"""

import json
import pathlib
import sys

# Zig array name -> (sources.json target, key). Order is the order they appear
# in build.zig.
ARRAYS = [
    ("pki_sources", "pki", "srcs"),
    ("bssl_sources", "bssl", "srcs"),
    ("ssl_sources", "ssl", "srcs"),
    ("crypto_sources", "crypto", "srcs"),
    ("decrepit_sources", "decrepit", "srcs"),
    ("fipsmodule_sources", "bcm", "srcs"),
    ("generated_fipsmodule_sources", "bcm", "asm"),
    ("generated_crypto_sources", "crypto", "asm"),
]

MARKER = "const pki_sources = &.{"


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2

    checkout = pathlib.Path(sys.argv[1])
    manifest = checkout / "gen" / "sources.json"
    if not manifest.is_file():
        print(f"no manifest at {manifest}", file=sys.stderr)
        return 1
    sources = json.loads(manifest.read_text())

    here = pathlib.Path(__file__).parent
    build_zig = here / "build.zig"
    text = build_zig.read_text()
    if MARKER not in text:
        print(f"{build_zig} has no `{MARKER}` to splice at", file=sys.stderr)
        return 1
    head = text[: text.index(MARKER)]

    chunks = []
    for name, target, key in ARRAYS:
        files = sources.get(target, {}).get(key, [])
        if not files:
            print(f"warning: {target}.{key} is empty", file=sys.stderr)
        body = "".join(f'    "{f}",\n' for f in sorted(files))
        chunks.append(f"const {name} = &.{{\n{body}}};\n")
        print(f"{name}: {len(files)} files")

    build_zig.write_text(head + "\n".join(chunks))
    return 0


if __name__ == "__main__":
    sys.exit(main())
