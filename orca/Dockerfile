# Orca remote server (https://www.onorca.dev/docs/remote-servers) on top of the agent image, so
# `orca serve` sees the same CLIs (claude / codex / grok / gh / git / node / python) and — via
# HOME=/opt/data/home — the same logins and the same /workspace as the Hermes agent.
# `base` is a named build context: compose points it at the hermes-agent service image.

# ── Stage 1: download + verify + extract the AppImage (no FUSE in containers) ─────────────
# Separate stage so the ~200 MB download is cached by ORCA_VERSION only, not redone every time
# the agent base image changes. update.sh resolves ORCA_VERSION=latest to the release tag.
FROM debian:trixie-slim AS orca-dl
ARG ORCA_VERSION=latest
RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*
# electron-builder publishes latest-linux.yml next to the asset with its sha512 (base64).
RUN set -eu; \
    case "$ORCA_VERSION" in latest) base=https://github.com/stablyai/orca/releases/latest/download ;; \
      *) base="https://github.com/stablyai/orca/releases/download/${ORCA_VERSION}" ;; esac; \
    cd /tmp \
    && curl -fsSL "$base/latest-linux.yml" -o latest-linux.yml \
    && curl -fsSL "$base/orca-linux.AppImage" -o orca.AppImage \
    && want="$(sed -n '/url: orca-linux.AppImage/{n;s/^ *sha512: *//p}' latest-linux.yml | head -n1 | base64 -d | od -An -tx1 -v | tr -d ' \n')" \
    && got="$(sha512sum orca.AppImage | cut -d' ' -f1)" \
    && [ -n "$want" ] && [ "$want" = "$got" ] || { echo "orca-linux.AppImage: sha512 mismatch (want $want got $got)" >&2; exit 1; } \
    && chmod +x orca.AppImage && ./orca.AppImage --appimage-extract >/dev/null \
    && mv squashfs-root /opt/orca && rm -f orca.AppImage latest-linux.yml

# ── Stage 2: runtime on the agent image ───────────────────────────────────────────────────
FROM base
USER root
ENV DEBIAN_FRONTEND=noninteractive

# Electron headless matrix (docs/reference/headless-linux-server.md, Debian 13 t64 names) + Xvfb.
# Orca starts Xvfb on :99 itself when DISPLAY is unset.
RUN apt-get update && apt-get install -y --no-install-recommends \
      xvfb file zlib1g-dev \
      libgtk-3-0t64 libnss3 libatk1.0-0t64 libatk-bridge2.0-0t64 libgbm1 libasound2t64 \
      libxtst6 libcups2t64 libdrm2 libxkbcommon0 libpango-1.0-0 libcairo2 libatspi2.0-0t64 \
      libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libxrender1 libx11-xcb1 libxcb-dri3-0 libxss1 \
    && rm -rf /var/lib/apt/lists/*

COPY --from=orca-dl /opt/orca /opt/orca
RUN chown root:root /opt/orca/chrome-sandbox && chmod 4755 /opt/orca/chrome-sandbox \
    && ln -s /opt/orca/AppRun /usr/local/bin/orca \
    && orca --version

# Runtime user = host owner of /srv/hermes (same uid as the agent's runtime user).
ARG HERMES_UID=1000
ARG HERMES_GID=1000
RUN (getent group "$HERMES_GID" >/dev/null || groupadd -g "$HERMES_GID" orca) \
    && (getent passwd "$HERMES_UID" >/dev/null || useradd -u "$HERMES_UID" -g "$HERMES_GID" -M -d /opt/data/home -s /bin/bash orca)

ENV HOME=/opt/data/home LIBGL_ALWAYS_SOFTWARE=1
WORKDIR /workspace
EXPOSE 6768
# Drop the agent image's s6 entrypoint: this container is just `orca serve` as the runtime user.
ENTRYPOINT []
CMD ["orca", "serve", "--port", "6768"]
