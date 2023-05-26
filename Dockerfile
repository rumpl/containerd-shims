# syntax=docker/dockerfile:1.5-labs

ARG RUST_VERSION=1.69.0
ARG WASMEDGE_VERSION=0.12.1
ARG XX_VERSION=1.2.1

FROM --platform=$BUILDPLATFORM tonistiigi/xx:${XX_VERSION} AS xx
FROM --platform=$BUILDPLATFORM rust:${RUST_VERSION} AS base
COPY --from=xx / /
RUN apt-get update -y && apt-get install --no-install-recommends -y clang cmake protobuf-compiler pkg-config dpkg-dev

# See https://github.com/tonistiigi/xx/issues/108
RUN sed -i -E 's/xx-clang --setup-target-triple/XX_VENDOR=\$vendor xx-clang --setup-target-triple/' $(which xx-cargo) && \
    sed -i -E 's/\$\(xx-info\)-/\$\(XX_VENDOR=\$vendor xx-info\)-/g' $(which xx-cargo)

# See https://github.com/rust-lang/cargo/issues/9167
RUN mkdir -p /.cargo && \
    echo '[net]' > /.cargo/config && \
    echo 'git-fetch-with-cli = true' >> /.cargo/config

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
ARG BUILD_TAGS TARGETPLATFORM WASMEDGE_VERSION
RUN xx-apt-get install -y gcc g++ libc++6-dev zlib1g libdbus-1-dev libseccomp-dev
RUN rustup target add wasm32-wasi

RUN <<EOT
    set -ex
    os=$(xx-info os)
    curl -sSf https://raw.githubusercontent.com/WasmEdge/WasmEdge/master/utils/install.sh | bash -s -- \
        --version ${WASMEDGE_VERSION} \
        --platform ${os^} \
        --machine $(xx-info march) \
        --path /usr/local
EOT

RUN --mount=type=cache,target=/usr/local/cargo/git/db \
    --mount=type=cache,target=/usr/local/cargo/registry/cache \
    --mount=type=cache,target=/usr/local/cargo/registry/index \
    --mount=type=cache,target=/build/app,id=wasmedge-wasmtime-$TARGETPLATFORM <<EOT
    set -e
    xx-cargo build --release --target-dir /build/app
    cp /build/app/$(xx-cargo --print-target-triple)/release/containerd-shim-wasm{time,edge}-v1 /
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
RUN rustup target add wasm32-{wasi,unknown-unknown}

RUN --mount=type=cache,target=/usr/local/cargo/git/db \
    --mount=type=cache,target=/usr/local/cargo/registry/cache \
    --mount=type=cache,target=/usr/local/cargo/registry/index \
    --mount=type=cache,target=/build/app,id=containerd-shims-$TARGETPLATFORM <<EOT
    set -e
    xx-cargo build --release --target-dir /build/app --manifest-path=containerd-shim-spin-v1/Cargo.toml
    xx-cargo build --release --target-dir /build/app --manifest-path=containerd-shim-slight-v1/Cargo.toml
    cp /build/app/$(xx-cargo --print-target-triple)/release/containerd-shim-{spin,slight}-v1 /
EOT

FROM scratch AS release

# Deislabs containerd shims
COPY --link --from=build-containerd-wasm-shims /containerd-shim-spin-v1 /containerd-shim-spin-v1
COPY --link --from=build-containerd-wasm-shims /containerd-shim-slight-v1 /containerd-shim-slight-v1

# Runwasi shims
COPY --link --from=build-runwasi /usr/local/lib/libwasmedge.so.0.0.2 /libwasmedge.so.0.0.2
COPY --link --from=build-runwasi /containerd-shim-wasmedge-v1 /containerd-shim-wasmedge-v1
COPY --link --from=build-runwasi /containerd-shim-wasmtime-v1 /containerd-shim-wasmtime-v1

FROM release
