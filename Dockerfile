# syntax=docker/dockerfile:1.5-labs

ARG XX_VERSION=1.2.1
ARG RUST_VERSION=1.69.0
ARG WASMEDGE_VERSION=0.13.1
ARG DEISLABS_SHIMS_VERSION=0.8.0

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
ARG BUILD_TAGS TARGETPLATFORM DEISLABS_SHIMS_VERSION
SHELL ["/bin/bash", "-c"]
RUN mkdir -p /dist/ && \
    curl -sSfL https://github.com/deislabs/containerd-wasm-shims/releases/download/v${DEISLABS_SHIMS_VERSION}/containerd-wasm-shims-v1-linux-$(xx-info march).tar.gz \
        | tar -xzC/dist/

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

RUN curl -sSf https://raw.githubusercontent.com/WasmEdge/WasmEdge/master/utils/install.sh | bash -s -- \
        --version ${WASMEDGE_VERSION} \
        --platform $(xx-info os | sed -e 's/\b\(.\)/\u\1/g') \
        --machine $(xx-info march) \
        --path /usr/local

RUN --mount=type=cache,target=/usr/local/cargo/git/db \
    --mount=type=cache,target=/usr/local/cargo/registry/cache \
    --mount=type=cache,target=/usr/local/cargo/registry/index \
    --mount=type=cache,target=/build,id=containerd-wasi-shims-$TARGETPLATFORM <<EOT
    set -e
    export RUSTFLAGS='-Clink-arg=-Wl,-rpath,$ORIGIN'
    xx-cargo build --release --target-dir /build/ --bin=containerd-shim-wasm{time,edge}-v1
    mkdir -p /dist/
    cp /build/$(xx-cargo --print-target-triple)/release/containerd-shim-wasm{time,edge}-v1 /dist/
    cp /usr/local/lib/libwasmedge.so.0.* /dist/libwasmedge.so.0
EOT

FROM scratch AS release

# Deislabs containerd shims
COPY --link --from=containerd-wasm-shims /dist/* /

# Runwasi shims
COPY --link --from=build-runwasi /dist/* /

FROM release
