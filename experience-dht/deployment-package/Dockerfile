FROM alpine:3.22

LABEL org.opencontainers.image.title="OpenHanako Experience DHT" \
      org.opencontainers.image.description="Standalone DHT / rendezvous / relay coordinator for the OpenHanako experience network" \
      org.opencontainers.image.source="https://github.com/openhanako/openhanako"

ARG ALPINE_MIRROR=http://mirrors.aliyun.com/alpine
RUN if [ -n "$ALPINE_MIRROR" ]; then \
      sed -i "s|https://dl-cdn.alpinelinux.org/alpine|$ALPINE_MIRROR|g; s|http://dl-cdn.alpinelinux.org/alpine|$ALPINE_MIRROR|g" /etc/apk/repositories; \
    fi
RUN apk add --no-cache ca-certificates tzdata
RUN mkdir -p /data/experience-dht

WORKDIR /app
COPY bin/experience-dht /usr/local/bin/experience-dht

EXPOSE 8091
EXPOSE 41001/udp
EXPOSE 41002/udp
HEALTHCHECK --start-period=15s --interval=30s --timeout=10s --retries=3 \
  CMD wget -q -O - http://127.0.0.1:8091/healthz | grep 'experience-dht' || exit 1
ENTRYPOINT ["experience-dht"]
