# syntax=docker/dockerfile:1
#
# Devcontainer image for the dev codespaces OpenVPN P2S approach.
#
# This is the standard typescript-node image used by the rest of the project,
# extended with the OpenVPN client so the post-start script can bring up a
# Point-to-Site tunnel into the dev Azure VNet. See
# docs/dev-codespaces-openvpn.md for the end-to-end flow.
ARG VARIANT=20
FROM mcr.microsoft.com/devcontainers/typescript-node:${VARIANT}

# Install the OpenVPN client. iproute2 ships with the base image but is named
# explicitly so that the post-start script can rely on `ip` being on PATH.
#
# We use `openresolv` (not `resolvconf`) because `resolvconf`'s post-install
# tries to replace /etc/resolv.conf with a symlink, which fails inside
# `docker build` (the daemon bind-mounts that file so the build can resolve
# DNS, and ln returns EBUSY). `openresolv` provides the same /sbin/resolvconf
# interface that openvpn's `update-resolv-conf` script calls, but its
# postinst leaves /etc/resolv.conf alone — see issue #40.
#
# `netcat-openbsd` (`nc`) and `postgresql-client` (`psql`, `pg_isready`) are
# the canonical smoke-test tools called out in docs/dev-codespaces-openvpn.md
# for verifying the tunnel reaches the postgres flexible servers; without
# them on the image, copy-pasting the documented one-liners fails and the
# operator has to apt-install them by hand inside every fresh codespace.
# See issue #40 follow-up #2.
RUN export DEBIAN_FRONTEND=noninteractive \
    && apt-get update \
    && apt-get -y install --no-install-recommends \
        openvpn \
        iproute2 \
        openresolv \
        ca-certificates \
        netcat-openbsd \
        postgresql-client \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# The default 'node' user already has password-less sudo via the base image
# (/etc/sudoers.d/node), which the post-start script relies on to launch
# openvpn with the privileges granted by --cap-add=NET_ADMIN.
