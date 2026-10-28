# dokploy.xedoc.ru

Infrastructure notes for the Dokploy instance on `132.243.118.214`.

The target Dokploy server `132.243.118.214` already runs nginx on ports `80`
and `443` for other `xedoc.ru` sites, so this setup keeps nginx in front and
proxies the Dokploy UI from the local `3000` port via an nginx virtual host.

During DNS propagation, `dokploy.xedoc.ru` may still resolve to the older
frontend server `82.146.42.213`. That server uses
`nginx/dokploy.xedoc.ru.front.conf` to proxy traffic to
`132.243.118.214:3000`.

The installer creates two Docker secrets:

- `dokploy_postgres_password` for PostgreSQL
- `dokploy-auth-secret` for `BETTER_AUTH_SECRET_FILE`

## Server setup

Run the installer on the server as `root`:

```bash
SERVER_IP=132.243.118.214 bash scripts/install-dokploy-nginx.sh
```

Then install the nginx vhost:

```bash
install -m 0644 nginx/dokploy.xedoc.ru.conf /etc/nginx/conf.d/dokploy.xedoc.ru.conf
nginx -t
systemctl reload nginx
```

## DNS and TLS

Long-term, `dokploy.xedoc.ru` should have an A record pointing to
`132.243.118.214`.

The active certificate was issued on `132.243.118.214` with:

```bash
certbot certonly --webroot -w /var/www/_letsencrypt -d dokploy.xedoc.ru
```

It expires on `2026-09-08`. If traffic still goes through `82.146.42.213` at
renewal time, copy the renewed certificate there or move DNS fully to
`132.243.118.214` before renewal.
