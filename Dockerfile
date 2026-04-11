# Stage 1: Build the JS frontend
FROM node:22-alpine AS frontend-builder
WORKDIR /app

COPY frontend/package.json frontend/yarn.lock ./frontend/
COPY frontend/email-builder/package.json frontend/email-builder/yarn.lock ./frontend/email-builder/

RUN cd frontend/email-builder && yarn install
RUN mkdir -p /app/static/public/static && cd frontend && yarn install

COPY frontend ./frontend
COPY i18n ./i18n

RUN cd frontend/email-builder && yarn build && \
  mkdir -p /app/frontend/public/static/email-builder && \
  cp -r /app/frontend/email-builder/dist/* /app/frontend/public/static/email-builder/
RUN cd frontend && yarn build

# Stage 2: Build the Go binary and pack with stuffbin
FROM golang:1.26-alpine AS go-builder
RUN apk --no-cache add git

WORKDIR /app

COPY go.mod go.sum ./
RUN go mod download

COPY . .
COPY --from=frontend-builder /app/frontend/dist ./frontend/dist
COPY --from=frontend-builder /app/frontend/public/static/email-builder ./frontend/public/static/email-builder

ARG LISTMONK_VERSION
RUN LAST_COMMIT=$(git rev-parse --short HEAD 2>/dev/null || echo "") && \
  VERSION=${LISTMONK_VERSION:-$(git describe --tags --abbrev=0 2>/dev/null || echo "nightly")} && \
  BUILDSTR="${VERSION} (#${LAST_COMMIT} $(date -u +"%Y-%m-%dT%H:%M:%S%z"))" && \
  CGO_ENABLED=0 GOOS=linux go build -o listmonk \
  -ldflags="-s -w -X 'main.buildString=${BUILDSTR}' -X 'main.versionString=${VERSION}'" \
  cmd/*.go

RUN go install github.com/knadh/stuffbin/... && \
  $(go env GOPATH)/bin/stuffbin -a stuff -in listmonk -out listmonk \
  config.toml.sample \
  schema.sql queries:/queries permissions.json \
  static/public:/public \
  static/email-templates \
  frontend/dist:/admin \
  i18n:/i18n

# Stage 3: Final minimal image
FROM alpine:latest

RUN apk --no-cache add ca-certificates tzdata shadow su-exec

WORKDIR /listmonk

COPY --from=go-builder /app/listmonk .
COPY config.toml.sample config.toml
COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

EXPOSE 9000

ENTRYPOINT ["docker-entrypoint.sh"]
CMD ["./listmonk"]
