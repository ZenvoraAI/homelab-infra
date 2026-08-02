#!/bin/sh
set -eu

cd /opt/homelab-infra
/usr/bin/docker compose exec -T nginx nginx -s reload
