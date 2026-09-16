# Obsidian Sync headless client — minimal image running only `ob sync --continuous`.
# Kept separate from the agent image: the agent never calls `ob`, and the Obsidian
# credentials stay out of the agent's HOME.
FROM node:22-bookworm-slim

ARG OBSIDIAN_HEADLESS_VERSION=latest
RUN npm install -g --no-audit --no-fund --fetch-retries=5 "obsidian-headless@${OBSIDIAN_HEADLESS_VERSION}" && \
    npm cache clean --force && \
    ob --version

# Credentials/config live under $HOME (mounted), the vault under /vault (mounted).
ENV HOME=/data
WORKDIR /vault
ENTRYPOINT ["ob"]
CMD ["sync", "--continuous", "--path", "/vault"]
