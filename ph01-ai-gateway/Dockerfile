FROM oven/bun:1@sha256:0733e50325078969732ebe3b15ce4c4be5082f18c4ac1a0f0ca4839c2e4e42a7 AS builder

ARG NPM_REGISTRY=https://registry.npmmirror.com

WORKDIR /build
COPY web/default/package.json .
COPY web/default/bun.lock .
RUN bun install --registry "$NPM_REGISTRY"
COPY ./web/default .
COPY ./VERSION .
RUN DISABLE_ESLINT_PLUGIN='true' VITE_REACT_APP_VERSION=$(cat VERSION) bun run build

FROM oven/bun:1@sha256:0733e50325078969732ebe3b15ce4c4be5082f18c4ac1a0f0ca4839c2e4e42a7 AS builder-classic

ARG NPM_REGISTRY=https://registry.npmmirror.com

WORKDIR /build
COPY web/classic/package.json .
COPY web/classic/bun.lock .
RUN bun install --registry "$NPM_REGISTRY"
COPY ./web/classic .
COPY ./VERSION .
RUN VITE_REACT_APP_VERSION=$(cat VERSION) bun run build

FROM golang:1.26.1-alpine@sha256:2389ebfa5b7f43eeafbd6be0c3700cc46690ef842ad962f6c5bd6be49ed82039 AS builder2
ENV GO111MODULE=on CGO_ENABLED=0

ARG GOPROXY=https://goproxy.cn,direct
ARG GOSUMDB=sum.golang.google.cn
ARG TARGETOS
ARG TARGETARCH
ENV GOOS=${TARGETOS:-linux} \
    GOARCH=${TARGETARCH:-amd64} \
    GOPROXY=${GOPROXY} \
    GOSUMDB=${GOSUMDB} \
    GOEXPERIMENT=greenteagc

WORKDIR /build

ADD go.mod go.sum ./
RUN go mod download

COPY . .
COPY --from=builder /build/dist ./web/default/dist
COPY --from=builder-classic /build/dist ./web/classic/dist
RUN go build -ldflags "-s -w -X 'github.com/QuantumNous/new-api/common.Version=$(cat VERSION)'" -o new-api

FROM debian:bookworm-slim@sha256:f06537653ac770703bc45b4b113475bd402f451e85223f0f2837acbf89ab020a

ARG DEBIAN_MIRROR=http://mirrors.aliyun.com/debian
ARG DEBIAN_SECURITY_MIRROR=http://mirrors.aliyun.com/debian-security
RUN if [ -f /etc/apt/sources.list ]; then \
      sed -i "s|http://deb.debian.org/debian-security|$DEBIAN_SECURITY_MIRROR|g; s|https://deb.debian.org/debian-security|$DEBIAN_SECURITY_MIRROR|g; s|http://security.debian.org/debian-security|$DEBIAN_SECURITY_MIRROR|g; s|https://security.debian.org/debian-security|$DEBIAN_SECURITY_MIRROR|g; s|http://deb.debian.org/debian|$DEBIAN_MIRROR|g; s|https://deb.debian.org/debian|$DEBIAN_MIRROR|g" /etc/apt/sources.list; \
    fi \
    && if [ -f /etc/apt/sources.list.d/debian.sources ]; then \
      sed -i "s|http://deb.debian.org/debian-security|$DEBIAN_SECURITY_MIRROR|g; s|https://deb.debian.org/debian-security|$DEBIAN_SECURITY_MIRROR|g; s|http://security.debian.org/debian-security|$DEBIAN_SECURITY_MIRROR|g; s|https://security.debian.org/debian-security|$DEBIAN_SECURITY_MIRROR|g; s|http://deb.debian.org/debian|$DEBIAN_MIRROR|g; s|https://deb.debian.org/debian|$DEBIAN_MIRROR|g" /etc/apt/sources.list.d/debian.sources; \
    fi \
    && apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates tzdata libasan8 wget \
    && rm -rf /var/lib/apt/lists/* \
    && update-ca-certificates

COPY --from=builder2 /build/new-api /
EXPOSE 3000
WORKDIR /data
ENTRYPOINT ["/new-api"]
