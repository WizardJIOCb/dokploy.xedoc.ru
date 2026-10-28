#!/usr/bin/env bash
set -euo pipefail

SERVER_IP="${SERVER_IP:-132.243.118.214}"
TIMEZONE="${TIMEZONE:-Asia/Yekaterinburg}"
SWAP_SIZE="${SWAP_SIZE:-2G}"

if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root." >&2
  exit 1
fi

ensure_swapfile() {
  if swapon --show=NAME --noheadings | grep -Fxq "/swapfile"; then
    return
  fi

  if [ ! -f /swapfile ]; then
    fallocate -l "$SWAP_SIZE" /swapfile
    chmod 600 /swapfile
    mkswap /swapfile
  fi

  swapon /swapfile

  if ! grep -Eq '^[^#[:space:]]+[[:space:]]+none[[:space:]]+swap[[:space:]]' /etc/fstab; then
    echo "/swapfile none swap sw 0 0" >> /etc/fstab
  fi
}

ensure_docker() {
  if ! command -v docker >/dev/null 2>&1; then
    curl -fsSL https://get.docker.com -o /tmp/get-docker.sh
    sh /tmp/get-docker.sh
  fi

  systemctl enable --now docker
}

ensure_swarm() {
  local swarm_state
  swarm_state="$(docker info --format '{{.Swarm.LocalNodeState}}' 2>/dev/null || true)"

  if [ "$swarm_state" != "active" ]; then
    docker swarm init --advertise-addr "$SERVER_IP"
  fi
}

ensure_network() {
  docker network inspect dokploy-network >/dev/null 2>&1 ||
    docker network create --driver overlay --attachable dokploy-network
}

ensure_secret() {
  if ! docker secret inspect dokploy_postgres_password >/dev/null 2>&1; then
    openssl rand -base64 32 | tr -d "=+/" | cut -c1-32 |
      docker secret create dokploy_postgres_password -
  fi
}

ensure_auth_secret() {
  if ! docker secret inspect dokploy-auth-secret >/dev/null 2>&1; then
    openssl rand -hex 32 | docker secret create dokploy-auth-secret -
  fi
}

ensure_postgres() {
  if docker service inspect dokploy-postgres >/dev/null 2>&1; then
    return
  fi

  docker service create \
    --name dokploy-postgres \
    --constraint 'node.role==manager' \
    --network dokploy-network \
    --env POSTGRES_USER=dokploy \
    --env POSTGRES_DB=dokploy \
    --secret source=dokploy_postgres_password,target=/run/secrets/postgres_password \
    --env POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password \
    --mount type=volume,source=dokploy-postgres,target=/var/lib/postgresql/data \
    postgres:16
}

ensure_redis() {
  if docker service inspect dokploy-redis >/dev/null 2>&1; then
    return
  fi

  docker service create \
    --name dokploy-redis \
    --constraint 'node.role==manager' \
    --network dokploy-network \
    --mount type=volume,source=dokploy-redis,target=/data \
    redis:7
}

ensure_dokploy() {
  if docker service inspect dokploy >/dev/null 2>&1; then
    ensure_dokploy_security
    return
  fi

  mkdir -p /etc/dokploy
  chmod 777 /etc/dokploy

  docker service create \
    --name dokploy \
    --replicas 1 \
    --network dokploy-network \
    --mount type=bind,source=/var/run/docker.sock,target=/var/run/docker.sock \
    --mount type=bind,source=/etc/dokploy,target=/etc/dokploy \
    --mount type=volume,source=dokploy,target=/root/.docker \
    --secret source=dokploy_postgres_password,target=/run/secrets/postgres_password \
    --secret source=dokploy-auth-secret,target=/run/secrets/dokploy-auth-secret \
    --publish published=3000,target=3000,mode=host \
    --update-parallelism 1 \
    --update-order stop-first \
    --constraint 'node.role == manager' \
    --env ADVERTISE_ADDR="$SERVER_IP" \
    --env POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password \
    --env BETTER_AUTH_SECRET_FILE=/run/secrets/dokploy-auth-secret \
    --env TZ="$TIMEZONE" \
    dokploy/dokploy:latest
}

ensure_dokploy_security() {
  local has_env
  local has_secret
  local update_args=()

  has_env="$(
    docker service inspect dokploy \
      --format '{{range .Spec.TaskTemplate.ContainerSpec.Env}}{{println .}}{{end}}' |
      grep -c '^BETTER_AUTH_SECRET_FILE=' || true
  )"

  has_secret="$(
    docker service inspect dokploy \
      --format '{{range .Spec.TaskTemplate.ContainerSpec.Secrets}}{{println .SecretName}}{{end}}' |
      grep -c '^dokploy-auth-secret$' || true
  )"

  if [ "$has_secret" = "0" ]; then
    update_args+=(--secret-add source=dokploy-auth-secret,target=/run/secrets/dokploy-auth-secret)
  fi

  if [ "$has_env" = "0" ]; then
    update_args+=(--env-add BETTER_AUTH_SECRET_FILE=/run/secrets/dokploy-auth-secret)
  fi

  if [ "${#update_args[@]}" -gt 0 ]; then
    docker service update "${update_args[@]}" dokploy
  fi
}

ensure_traefik_local() {
  if docker ps -a --format '{{.Names}}' | grep -Fxq dokploy-traefik; then
    return
  fi

  for _ in $(seq 1 60); do
    [ -f /etc/dokploy/traefik/traefik.yml ] && break
    sleep 1
  done

  if [ ! -f /etc/dokploy/traefik/traefik.yml ]; then
    echo "Warning: /etc/dokploy/traefik/traefik.yml was not created yet; skipping Traefik container." >&2
    return
  fi

  docker run -d \
    --name dokploy-traefik \
    --restart always \
    -v /etc/dokploy/traefik/traefik.yml:/etc/traefik/traefik.yml \
    -v /etc/dokploy/traefik/dynamic:/etc/dokploy/traefik/dynamic \
    -v /var/run/docker.sock:/var/run/docker.sock:ro \
    -p 127.0.0.1:8088:80/tcp \
    -p 127.0.0.1:8443:443/tcp \
    -p 127.0.0.1:8443:443/udp \
    traefik:v3.6.7

  docker network connect dokploy-network dokploy-traefik
}

ensure_swapfile
ensure_docker
ensure_swarm
ensure_network
ensure_secret
ensure_auth_secret
ensure_postgres
ensure_redis
ensure_dokploy
ensure_traefik_local

docker service ls
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}'
