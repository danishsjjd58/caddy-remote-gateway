# Caddy development and deployment gateway

One Caddy container routes two separate paths. The examples use `example.com`; replace it with your Cloudflare-managed domain.

This is a generic gateway template. Numeric private development hostnames work out of the box; application routes must be added explicitly.

| Use | Example URL | Route |
| --- | --- | --- |
| Private development | `https://5173.local.example.com` | Tailscale → Caddy → host port `5173` |
| Public Docker app | `https://app.example.com` | Cloudflare → Tunnel → Caddy → app container |

## How it works

- **Private** (`*.local.example.com`): HTTPS is published only on the server's Tailscale IP, so these hostnames are unreachable from LAN or the internet. Caddy holds a wildcard certificate issued via Cloudflare DNS-01. A numeric hostname such as `5173.local.example.com` proxies to that host port (`3000`–`9999`). To proxy a named hostname to an app container, add an explicit handler inside the `*.local.{$MY_DOMAIN}` block in `caddy/Caddyfile`; otherwise it returns `404`.
- **Public** (`*.example.com`): an outbound Cloudflare Tunnel delivers traffic to Caddy on `:8080`, so no app ports or inbound firewall rules are needed. Add an explicit hostname handler for each app inside the `:8080` block in `caddy/Caddyfile`; all public hostnames return `404` until configured.
- **Network**: the shared `caddy_net` (`172.18.0.0/16`, dynamic pool `172.18.1.0/24`) reserves `172.18.0.2` for Caddy and `172.18.0.3` for cloudflared outside the pool. Caddy trusts forwarded client-IP headers only from the cloudflared address.

## One-time setup

1. Enable Docker at boot and create the shared network. `--ip-range` keeps the reserved addresses out of dynamic allocation so no other container can claim them during Docker's reboot restore:

   ```bash
   sudo systemctl enable --now docker.service

   docker network create --driver bridge \
     --subnet 172.18.0.0/16 --ip-range 172.18.1.0/24 \
     --gateway 172.18.0.1 caddy_net
   ```

2. Let Docker bind the Tailscale IP even before `tailscaled` is up at boot:

   ```bash
   echo 'net.ipv4.ip_nonlocal_bind=1' | sudo tee /etc/sysctl.d/99-tailscale-bind.conf
   sudo sysctl --system
   ```

3. Create the environment file:

   ```bash
   cp .env.example .env
   $EDITOR .env
   ```

   - `MY_DOMAIN`: base domain only, such as `example.com`.
   - `TAILSCALE_IP`: output of `tailscale ip -4`. HTTPS binds to this address only; a wrong value binds silently and serves nothing, so re-check it first if HTTPS stops responding.
   - `PUID`/`PGID`: output of `id -u` and `id -g`, so `cloudflared` can read the mode-`600` token as your user.

4. In Cloudflare DNS, create a **DNS-only** record for `*.local.example.com` pointing to the server's Tailscale IP.

5. Create the DNS-01 secret, a Cloudflare token scoped to this zone with `Zone:Read` and `DNS:Edit`:

   ```bash
   cp .env.secret.example .env.secret
   chmod 600 .env.secret
   $EDITOR .env.secret
   ```

6. Create a remotely managed Cloudflare Tunnel and save its runner token:

   ```bash
   touch .cloudflared.token
   chmod 600 .cloudflared.token
   $EDITOR .cloudflared.token
   ```

   Add a published application route from `*.example.com` to `http://caddy:8080`, and a proxied `CNAME` record named `*` pointing to `<TUNNEL-UUID>.cfargotunnel.com`.

7. If UFW is active, allow Caddy to reach the host development ports:

   ```bash
   sudo ufw allow proto tcp from 172.18.0.2 to 172.18.0.1 port 3000:9999 comment 'caddy-to-host-dev'
   ```

   No inbound HTTPS rule is needed — the Tailscale-only binding is what keeps port `443` private. UFW could not restrict a published container port anyway, because Docker's firewall rules run before UFW's route rules.

8. Start the gateway:

   ```bash
   docker compose up -d --build
   ```

## Use it

For a host development server, listen on `0.0.0.0` using a port from `3000` to `9999`, then open `https://<port>.local.example.com`:

```bash
npm run dev -- --host 0.0.0.0 --port 5173
```

For a public Docker app, do not publish its port. Attach its Compose service to the external network:

```yaml
services:
  myapp:
    image: your-image
    networks:
      - caddy_net

networks:
  caddy_net:
    external: true
    name: caddy_net
```

Add a hostname handler before the fallback inside the `:8080` block of `caddy/Caddyfile`:

```caddyfile
@myapp host app.example.com
handle @myapp {
	reverse_proxy myapp:3000 {
		header_up X-Forwarded-Proto https
	}
}
```

Then validate and reload:

```bash
docker exec caddy caddy validate --config /etc/caddy/Caddyfile --adapter caddyfile
docker exec caddy caddy reload --config /etc/caddy/Caddyfile --adapter caddyfile
```

Protect public admin apps with Cloudflare Access, and prefer path allowlists over blocklists when only part of an app should be public.
