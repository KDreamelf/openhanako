FROM golang:1.26.1-alpine AS builder

WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . ./
RUN CGO_ENABLED=0 GOOS=linux go build -ldflags "-s -w" -o /out/experience-network-manager ./cmd/experience-hub

FROM alpine:3.22

RUN apk add --no-cache ca-certificates tzdata

WORKDIR /app
COPY --from=builder /out/experience-network-manager /usr/local/bin/experience-network-manager

EXPOSE 8090
ENTRYPOINT ["experience-network-manager"]
