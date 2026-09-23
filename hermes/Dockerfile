# Derived Hermes Agent image: official base + host-like operator tools and coding CLIs.
# The base image starts as root under s6-overlay and drops to the `hermes` user per
# service, so we deliberately do NOT add a trailing `USER` instruction.
FROM nousresearch/hermes-agent:latest

USER root
ARG DEBIAN_FRONTEND=noninteractive

RUN apt-get -o Acquire::Retries=3 update && \
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends \
        tmux jq less nano postgresql-client && \
    install -d -m 0755 /etc/apt/keyrings && \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        -o /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        > /etc/apt/sources.list.d/github-cli.list && \
    apt-get -o Acquire::Retries=3 update && \
    apt-get -o Acquire::Retries=3 install -y --no-install-recommends gh && \
    rm -rf /var/lib/apt/lists/*

# Coding CLIs that authenticate with consumer subscriptions (Claude Max, ChatGPT, SuperGrok).
# Installed globally under /usr/local so they are on PATH for the runtime `hermes` user.
# Their credentials land under the tool-subprocess HOME (/opt/data/home) at runtime.
RUN npm install -g --no-audit --no-fund --fetch-retries=5 \
        --allow-scripts=@anthropic-ai/claude-code,@xai-official/grok \
        @anthropic-ai/claude-code \
        @openai/codex \
        @xai-official/grok && \
    npm cache clean --force

# The image is immutable; CLI updates are applied by rebuilding it.
ENV DISABLE_AUTOUPDATER=1 \
    CODEX_DISABLE_UPDATE_CHECK=1

# The agent's terminal tool runs with a reduced PATH that lacks /opt/hermes/bin, so `hermes …`
# from inside a session fails; /usr/local/bin is on every PATH. The shim is safe to symlink (it
# execs the venv binary by absolute path).
RUN ln -s /opt/hermes/bin/hermes /usr/local/bin/hermes

RUN gh --version && psql --version && claude --version && codex --version && grok --version && /usr/local/bin/hermes --version
