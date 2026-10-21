# syntax=docker/dockerfile:1
#
# Crawl service image: the Lightpanda engine built from THIS checkout (the
# root Dockerfile is upstream's: it clones lightpanda-io/browser instead) plus
# the Node HTTP service in service/. See service/README.md.
#
#   docker build -f service/Dockerfile -t lp-crawl .
#   docker run --rm -p 8080:8080 lp-crawl
#
# The engine's CDP port stays on the container's loopback; only the HTTP
# service is exposed.
#
# Multi-arch: linux/amd64 and linux/arm64 via TARGETPLATFORM (build each arch
# natively; there is no cross-compilation here).
#
# Slow networks. Every download source defaults to upstream and can be
# swapped for a mirror:
#   --build-arg APT_MIRROR=mirrors.tuna.tsinghua.edu.cn
#   --build-arg RUSTUP_MIRROR=https://mirrors.tuna.tsinghua.edu.cn/rustup
#   --build-arg CARGO_MIRROR=sparse+https://rsproxy.cn/index/
#     (tuna's crates.io-index mirrors only the index; its downloads still
#     come from static.crates.io)
#   --build-arg ZIG_MIRROR=https://fs.liujiacai.net/zigbuilds   (minisign-verified)
# The two GitHub-only inputs can be handed in from the host instead of
# downloaded; both are optional and fall back to downloading when absent:
#   --build-context v8=.lp-cache/prebuilt-v8/<zig-v8 tag>   (dir holding libc_v8_<v8>_linux_<arch>.a)
#   --build-context zigpkg=zig-pkg                          (zig's package dir, hash-named)
# The Node runtime is copied out of an official node image:
#   --build-arg NODE_IMAGE=<registry mirror>/library/node:22-slim

ARG NODE_IMAGE=node:22-slim

# Empty defaults for the optional host-provided inputs above.
FROM scratch AS v8
FROM scratch AS zigpkg
FROM ${NODE_IMAGE} AS node

FROM debian:stable-slim AS build

ARG MINISIG=0.12
ARG ZIG_MINISIG=RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U
ARG TARGETPLATFORM
ARG APT_MIRROR=
ARG RUSTUP_MIRROR=
ARG CARGO_MIRROR=
ARG ZIG_MIRROR=
# Optional -Dversion override; .git is not in the build context, so without
# it the binary reports build.zig.zon's version.
ARG LP_VERSION=

RUN if [ -n "$APT_MIRROR" ]; then \
      sed -i "s#deb.debian.org#${APT_MIRROR}#g" /etc/apt/sources.list.d/debian.sources; \
    fi && \
    apt-get update -yq && \
    apt-get install -yq --no-install-recommends xz-utils ca-certificates \
        pkg-config libglib2.0-dev \
        clang make curl git && \
    rm -rf /var/lib/apt/lists/*

# Resume and retry on any error rather than failing the build on one stall.
RUN printf '%s\n' '#!/bin/sh' \
      'set -e' \
      'out="$1"; url="$2"; i=0' \
      'until curl --fail -L --connect-timeout 30 --speed-limit 1024 --speed-time 60 -C - -o "$out" "$url"; do' \
      '  i=$((i+1)); [ "$i" -ge 8 ] && { echo "giving up on $url" >&2; exit 1; }' \
      '  echo "retry $i: $url" >&2; sleep $((i*5))' \
      'done' > /usr/local/bin/fetch && chmod +x /usr/local/bin/fetch

# Rust (src/rust: html5ever bridge, renderer).
ENV PATH="/root/.cargo/bin:${PATH}" \
    CARGO_NET_RETRY=10 \
    CARGO_HTTP_TIMEOUT=120
RUN case $TARGETPLATFORM in \
      "linux/arm64") ARCH="aarch64" ;; \
      *) ARCH="x86_64" ;; \
    esac && \
    ROOT=${RUSTUP_MIRROR:-https://static.rust-lang.org} && \
    fetch /tmp/rustup-init ${ROOT}/rustup/dist/${ARCH}-unknown-linux-gnu/rustup-init && \
    chmod +x /tmp/rustup-init && \
    RUSTUP_DIST_SERVER=${ROOT} /tmp/rustup-init --profile minimal -y --no-modify-path && \
    rm /tmp/rustup-init && \
    if [ -n "$CARGO_MIRROR" ]; then \
      printf '[source.crates-io]\nreplace-with = "mirror"\n[source.mirror]\nregistry = "%s"\n' \
        "$CARGO_MIRROR" > /root/.cargo/config.toml; \
    fi

RUN fetch /tmp/minisign.tar.gz https://github.com/jedisct1/minisign/releases/download/${MINISIG}/minisign-${MINISIG}-linux.tar.gz && \
    tar xzf /tmp/minisign.tar.gz -C / && \
    rm /tmp/minisign.tar.gz

WORKDIR /browser

# Zig: the version is build.zig.zon's minimum_zig_version; the minisign
# check is what makes a third-party mirror safe to use.
COPY build.zig.zon ./
RUN ZIG=$(grep '\.minimum_zig_version = "' build.zig.zon | cut -d'"' -f2) && \
    case $TARGETPLATFORM in \
      "linux/arm64") ARCH="aarch64" ;; \
      *) ARCH="x86_64" ;; \
    esac && \
    BASE=${ZIG_MIRROR:-https://ziglang.org/download/${ZIG}} && \
    FILE=zig-${ARCH}-linux-${ZIG}.tar.xz && \
    cd /tmp && \
    fetch ${FILE} ${BASE}/${FILE} && \
    fetch ${FILE}.minisig ${BASE}/${FILE}.minisig && \
    /minisign-linux/${ARCH}/minisign -Vm ${FILE} -P ${ZIG_MINISIG} && \
    tar xf ${FILE} && \
    mv zig-${ARCH}-linux-${ZIG} /usr/local/lib && \
    ln -s /usr/local/lib/zig-${ARCH}-linux-${ZIG}/zig /usr/local/bin/zig && \
    rm ${FILE} ${FILE}.minisig

# Prebuilt V8: version and zig-v8-fork tag come from the same install action
# `make download-v8` and CI read, so the image can't drift from them.
COPY .github/actions/install/action.yml /tmp/install-action.yml
RUN --mount=from=v8,target=/host-v8 \
    V8=$(awk -F\' '/^  v8:/{f=1} f&&/default:/{print $2; exit}' /tmp/install-action.yml) && \
    ZIG_V8=$(awk -F\' '/^  zig-v8:/{f=1} f&&/default:/{print $2; exit}' /tmp/install-action.yml) && \
    test -n "$V8" && test -n "$ZIG_V8" && \
    case $TARGETPLATFORM in \
      "linux/arm64") ARCH="aarch64" ;; \
      *) ARCH="x86_64" ;; \
    esac && \
    ASSET=libc_v8_${V8}_linux_${ARCH}.a && \
    echo "prebuilt V8 ${V8} (${ZIG_V8}) ${ASSET}" && \
    mkdir -p v8 && \
    if [ -f /host-v8/${ASSET} ]; then \
      echo "using host-provided ${ASSET}" && cp /host-v8/${ASSET} v8/libc_v8.a; \
    else \
      fetch v8/libc_v8.a https://github.com/lightpanda-io/zig-v8-fork/releases/download/${ZIG_V8}/${ASSET}; \
    fi

# Cargo crates in their own layer, ahead of build.zig so neither a source
# nor a build.zig edit refetches them. Only this platform's: the lockfile
# also lists the windows-* crates.
COPY src/rust ./src/rust
RUN cargo fetch --manifest-path src/rust/Cargo.toml \
        --target "$(rustc -vV | sed -n 's/^host: //p')"

# Zig package dependencies, in their own layer so a source edit doesn't
# refetch them. deps/ holds the in-tree (path) packages. Packages the host
# already has are copied by hash (top level, then one level of transitive
# deps); zig fetches whatever is still missing.
COPY build.zig ./
COPY deps ./deps
RUN --mount=from=zigpkg,target=/host-zig-pkg \
    mkdir -p zig-pkg /root/.cache/zig/tmp && \
    for pass in 1 2; do \
      for h in $(cat build.zig.zon deps/*/build.zig.zon zig-pkg/*/build.zig.zon 2>/dev/null | \
                 grep -o '\.hash = "[^"]*"' | cut -d'"' -f2 | sort -u); do \
        if [ ! -e zig-pkg/$h ] && [ -d /host-zig-pkg/$h ]; then cp -a /host-zig-pkg/$h zig-pkg/; fi; \
      done; \
    done && \
    i=0; until zig build --fetch; do \
      i=$((i+1)); [ "$i" -ge 6 ] && exit 1; echo "zig fetch retry $i" >&2; sleep $((i*5)); \
    done

COPY orderfile ./orderfile
COPY src ./src

# Same steps and flags as the Linux job in .github/workflows/release.yml:
# snapshot first, then the release binary with the hot-code orderfile.
# -Dcpu keeps the binary portable (the default is the build host's CPU).
# -Dstrip drops debug info, which is what keeps the one big LLVM compile
# near 12GB instead of past 15GB (see build.zig); crash stack traces lose
# symbols as a result. Even stripped, the builder needs ~12GB of RAM + swap:
# a 6GB Docker Desktop VM gets the compile OOM-killed.
RUN --mount=type=cache,target=/root/.cache/zig,id=lp-zig-global \
    --mount=type=cache,target=/browser/.zig-cache,id=lp-zig-local \
    case $TARGETPLATFORM in \
      "linux/arm64") CPU="-Dcpu=generic" ;; \
      *) CPU="-Dcpu=x86_64" ;; \
    esac && \
    VERSION_FLAG=${LP_VERSION:+-Dversion=${LP_VERSION}} && \
    mkdir -p /root/.cache/zig/tmp && \
    zig build -Doptimize=ReleaseFast -Dstrip=true \
        -Dprebuilt_v8_path=v8/libc_v8.a \
        snapshot_creator -- src/snapshot.bin && \
    zig build -Doptimize=ReleaseFast -Dstrip=true \
        -Dsnapshot_path=../../snapshot.bin \
        -Dprebuilt_v8_path=v8/libc_v8.a \
        -Dorderfile=orderfile/lightpanda.ld \
        $CPU $VERSION_FLAG && \
    ./zig-out/bin/lightpanda version

FROM debian:stable-slim

ARG APT_MIRROR=

RUN if [ -n "$APT_MIRROR" ]; then \
      sed -i "s#deb.debian.org#${APT_MIRROR}#g" /etc/apt/sources.list.d/debian.sources; \
    fi && \
    apt-get update -yq && \
    apt-get install -yq --no-install-recommends tini ca-certificates && \
    rm -rf /var/lib/apt/lists/*

COPY --from=node /usr/local/bin/node /usr/local/bin/node
COPY --from=build /browser/zig-out/bin/lightpanda /bin/lightpanda
COPY service/package.json service/server.mjs /app/
COPY service/lib /app/lib
COPY --chmod=0755 service/entrypoint.sh /usr/local/bin/entrypoint.sh

# Session cookie jars (session_id) are written here; mount a volume on /data
# to keep them across container re-creation.
RUN mkdir -p /data/sessions

# Defaults for entrypoint.sh and the service; override with `docker run -e`.
# Each pool slot is one CDP connection, i.e. one worker thread and browser in
# the engine (~50 MB); LP_CDP_MAX_CONNECTIONS defaults to 2*POOL_SIZE+4.
# Telemetry is off: the engine checks only that the variable exists, so any
# value (even empty) keeps it off.
ENV LIGHTPANDA_DISABLE_TELEMETRY=true \
    HOST=0.0.0.0 \
    PORT=8080 \
    POOL_SIZE=4 \
    LP_HOST=127.0.0.1 \
    LP_PORT=9222 \
    LP_LOG_LEVEL=info \
    LP_RESTART_DELAY=1 \
    SESSION_DIR=/data/sessions

EXPOSE 8080/tcp

# Lightpanda installs only some signal handlers and PID 1 has no default
# SIGTERM handler; tini as PID 1 keeps `docker stop` from hanging. -g sends
# the signal to the whole group: the service, the engine and its restart loop.
ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/usr/local/bin/entrypoint.sh"]
CMD []
