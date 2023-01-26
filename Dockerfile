# syntax=docker/dockerfile:1.5-labs

ARG RUST_VERSION=1.66.1
ARG XX_VERSION=1.1.0

FROM --platform=$BUILDPLATFORM tonistiigi/xx:${XX_VERSION} AS xx

FROM --platform=$BUILDPLATFORM rust:${RUST_VERSION} AS base
COPY --from=xx / /
RUN apt-get update -y && apt-get install --no-install-recommends -y clang cmake

FROM base as containerd-wasm-shims
ADD https://github.com/deislabs/containerd-wasm-shims.git /containerd-wasm-shims

FROM base as runwasi
ADD https://github.com/containerd/runwasi.git /runwasi



FROM runwasi as build-runwasi
WORKDIR /runwasi
RUN --mount=type=cache,target=/usr/local/cargo/git/db \
    --mount=type=cache,target=/usr/local/cargo/registry/cache \
    --mount=type=cache,target=/usr/local/cargo/registry/index \
    --mount=type=cache,target=/build/app,id=wasmedge-wasmtime-$TARGETPLATFORM \
    cargo fetch
SHELL ["/bin/bash", "-c"]
ARG BUILD_TAGS TARGETPLATFORM
ENV WASMEDGE_INCLUDE_DIR=/root/.wasmedge/include
ENV WASMEDGE_LIB_DIR=/root/.wasmedge/lib
ENV LD_LIBRARY_PATH=/root/.wasmedge/lib
RUN xx-apt-get install -y gcc g++ libc++6-dev zlib1g
RUN rustup target add $(xx-info march)-unknown-$(xx-info os)-$(xx-info libc)

RUN <<EOT
    set -ex
    os=$(xx-info os)
    curl -sSf https://raw.githubusercontent.com/WasmEdge/WasmEdge/master/utils/install.sh | bash -s -- --version=0.11.2 --platform=${os^} --machine=$(xx-info march)
EOT

RUN --mount=type=cache,target=/usr/local/cargo/git/db \
    --mount=type=cache,target=/usr/local/cargo/registry/cache \
    --mount=type=cache,target=/usr/local/cargo/registry/index \
    --mount=type=cache,target=/build/app,id=wasmedge-wasmtime-$TARGETPLATFORM <<EOT
    set -e
    export "CARGO_NET_GIT_FETCH_WITH_CLI=true"
    export "CARGO_TARGET_$(xx-info march | tr '[:lower:]' '[:upper:]' | tr - _)_UNKNOWN_$(xx-info os | tr '[:lower:]' '[:upper:]' | tr - _)_$(xx-info libc | tr '[:lower:]' '[:upper:]' | tr - _)_LINKER=$(xx-info)-gcc"
    export "CC_$(xx-info march | tr '[:lower:]' '[:upper:]' | tr - _)_UNKNOWN_$(xx-info os | tr '[:lower:]' '[:upper:]' | tr - _)_$(xx-info libc | tr '[:lower:]' '[:upper:]' | tr - _)=$(xx-info)-gcc"
    cargo build --release --target-dir /build/app --target=$(xx-info march)-unknown-$(xx-info os)-$(xx-info libc)
    cp /build/app/$(xx-info march)-unknown-$(xx-info os)-$(xx-info libc)/release/containerd-shim-wasmedge-v1 /containerd-shim-wasmedge-v1
    cp /build/app/$(xx-info march)-unknown-$(xx-info os)-$(xx-info libc)/release/containerd-shim-wasmtime-v1 /containerd-shim-wasmtime-v1
EOT



FROM containerd-wasm-shims as build-containerd-wasm-shims
WORKDIR /containerd-wasm-shims
RUN --mount=type=cache,target=/usr/local/cargo/git/db \
    --mount=type=cache,target=/usr/local/cargo/registry/cache \
    --mount=type=cache,target=/usr/local/cargo/registry/index \
    --mount=type=cache,target=/build/app,id=containerd-shims-$TARGETPLATFORM \
    cargo fetch
ARG BUILD_TAGS TARGETPLATFORM
SHELL ["/bin/bash", "-c"]
RUN xx-apt-get install -y gcc g++ libc++6-dev zlib1g
RUN rustup target add $(xx-info march)-unknown-$(xx-info os)-$(xx-info libc)

RUN --mount=type=cache,target=/usr/local/cargo/git/db \
    --mount=type=cache,target=/usr/local/cargo/registry/cache \
    --mount=type=cache,target=/usr/local/cargo/registry/index \
    --mount=type=cache,target=/build/app,id=containerd-shims-$TARGETPLATFORM <<EOT
    set -e
    export "CARGO_NET_GIT_FETCH_WITH_CLI=true"
    export "CARGO_TARGET_$(xx-info march | tr '[:lower:]' '[:upper:]' | tr - _)_UNKNOWN_$(xx-info os | tr '[:lower:]' '[:upper:]' | tr - _)_$(xx-info libc | tr '[:lower:]' '[:upper:]' | tr - _)_LINKER=$(xx-info)-gcc"
    export "CC_$(xx-info march | tr '[:lower:]' '[:upper:]' | tr - _)_UNKNOWN_$(xx-info os | tr '[:lower:]' '[:upper:]' | tr - _)_$(xx-info libc | tr '[:lower:]' '[:upper:]' | tr - _)=$(xx-info)-gcc"
    cargo build --release --target-dir /build/app --target=$(xx-info march)-unknown-$(xx-info os)-$(xx-info libc) --manifest-path=containerd-shim-spin-v1/Cargo.toml
    cp /build/app/$(xx-info march)-unknown-$(xx-info os)-$(xx-info libc)/release/containerd-shim-spin-v1 /containerd-shim-spin-v1

    cargo build --release --target-dir /build/app --target=$(xx-info march)-unknown-$(xx-info os)-$(xx-info libc) --manifest-path=containerd-shim-slight-v1/Cargo.toml
    cp /build/app/$(xx-info march)-unknown-$(xx-info os)-$(xx-info libc)/release/containerd-shim-slight-v1 /containerd-shim-slight-v1
EOT



FROM scratch AS release
# Deislabs containerd shims
COPY --link --from=build-containerd-wasm-shims /containerd-shim-spin-v1 /containerd-shim-spin-v1
COPY --link --from=build-containerd-wasm-shims /containerd-shim-slight-v1 /containerd-shim-slight-v1

# Runwasi shims
COPY --link --from=build-runwasi /root/.wasmedge/lib/libwasmedge.so.0.0.1 /libwasmedge.so.0.0.1
COPY --link --from=build-runwasi /containerd-shim-wasmedge-v1 /containerd-shim-wasmedge-v1

COPY --link --from=build-runwasi /containerd-shim-wasmtime-v1 /containerd-shim-wasmtime-v1

FROM release
