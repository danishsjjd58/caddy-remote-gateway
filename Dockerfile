FROM caddy:2.11.4-builder AS builder

RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    xcaddy build v2.11.4 \
    --with github.com/caddy-dns/cloudflare@a8737d095ad5a48ca031cea6ab704057dbc2d250

FROM caddy:2.11.4

COPY --from=builder /usr/bin/caddy /usr/bin/caddy
