# AGENTS.md

See [CONTRIBUTING.md](CONTRIBUTING.md) for how to open a pull request (CLA, dev setup, pre-PR checks).

## Build and tests

Run `make download-v8` once first: it fetches the prebuilt V8 archive into `.lp-cache/`, which `build.zig` picks up automatically. Without it every build compiles V8 from source (10+ minutes).

```bash
make test                                       # Run all tests
make test F="server"                            # Filter by substring
TEST_FILTER="WebApi: #selector_all" make test   # Filter main + subtest (separator: #)
TEST_VERBOSE=true make test
TEST_FAIL_FIRST=true make test
METRICS=true make test                          # Capture allocation/duration metrics as JSON
```

The custom test runner (`src/test_runner.zig`) detects memory leaks in debug builds. **A test that allocates without freeing fails** — not just lints.

The test servers bind fixed ports (9582 HTTP, 9583 CDP, 9584 WS), so a run takes
an advisory lock on `/tmp/lightpanda-test-servers.lock` first. A second run on
the same machine — another worktree, another agent — prints
`another test run holds …` and waits its turn rather than interleaving with the
first. Expect roughly `n × 35s` for `n` concurrent runs.

## Formatting

```bash
zig fmt --check ./*.zig ./**/*.zig    # Exact command CI runs
```

`zig build` depends on the fmt step, so a local build catches drift too.

## Flags that break the disguise

Two upstream features announce the client as a bot. Both are off unless asked
for, and both should stay off for any run whose point is to look like a browser:

- `--obey-robots` fetches `/robots.txt` and honours it. Real Chrome never
  requests that file, so the request itself is the tell — and with this fork's
  Chrome user-agent the matcher reads the product token as `Mozilla`, which
  matches no real robots.txt group anyway.
- `--web-bot-auth-key-file` / `--web-bot-auth-keyid` / `--web-bot-auth-domain`
  (all three required) add `Signature-Agent`, `Signature-Input` and `Signature`
  headers: an Ed25519-signed, cryptographically attested "I am a bot".
- `--webmcp` puts this fork's WebMCP surface back on the page:
  `navigator.modelContext` plus the `ModelContext` / `ModelContextClient`
  interface objects. Chrome has none of those three names, and Kasada was
  measured reading `navigator.modelContext` twice on x-hyatt, so one expression
  separates the engine from every real browser. The `mcp` command carries the
  surface by default — that is what it is for — unless given `--no-webmcp`
  (its browser tools never use it; the crawl service's `/mcp` runs with it off),
  and the CDP `WebMCP` domain needs this flag to be usable from `serve`.

## Conventions

Mirror the patterns in neighboring files. In particular:

- `@import` alias case follows the imported file's basename (`const Frame = @import("Frame.zig")`, `const ast = @import("ast.zig")`).
- Prefer struct-init type inference (`.{ ... }`) where the expected type is known from the function signature or variable annotation.
