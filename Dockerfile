# syntax=docker/dockerfile:1.5-labs
FROM scratch AS release
ARG TARGETARCH
COPY --chmod=755 ./${TARGETARCH}/ /
