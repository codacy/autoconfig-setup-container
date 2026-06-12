FROM node:20-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive
ENV PATH="/usr/local/go/bin:${PATH}"

RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
    # Firewall
    iptables \
    ipset \
    iproute2 \
    dnsutils \
    aggregate \
    # Utilities
    curl \
    ca-certificates \
    git \
    jq \
    unzip \
    sudo \
    # Python runtime — checkov, pylint, bandit, lizard, flawfinder, prospector
    python3 \
    python3-pip \
    python3-venv \
    # Java runtime — pmd, checkstyle, detekt, scalastyle
    default-jdk-headless \
    # shellcheck — adapter finds it on PATH, skips the GitHub release download
    shellcheck \
    # Ruby runtime — rubocop, reek, brakeman, sqlint
    ruby \
    ruby-dev \
    build-essential \
  && rm -rf /var/lib/apt/lists/* \
  # Ensure `python` resolves (several tool adapters call `python3` but some call `python`)
  && ln -sf /usr/bin/python3 /usr/local/bin/python \
  # Go runtime — revive type-checking rules
  && curl -fsSL https://go.dev/dl/go1.26.3.linux-amd64.tar.gz | tar -C /usr/local -xz

# Install CLIs globally as published packages
RUN npm install -g \
    @anthropic-ai/claude-code \
    @google/gemini-cli \
    @codacy/codacy-cloud-cli \
    @codacy/analysis-cli

# --- Privilege separation ------------------------------------------------
# runner (1001): owns credentials + the Anthropic auth proxy; runs the real CLIs.
# agent  (1002): runs claude; holds no secret. Shared group `codacy` lets both
# read/write /workspace/.codacy via setgid (Task 7).
RUN groupadd -g 1003 codacy \
  && useradd -m -u 1001 -g codacy runner \
  && useradd -m -u 1002 -g codacy agent \
  # Relocate the real Codacy CLIs to <name>-real in the SAME dir so their
  # relative npm symlinks stay valid; install shims at the original names that
  # elevate to runner.
  && mv /usr/local/bin/codacy          /usr/local/bin/codacy-real \
  && mv /usr/local/bin/codacy-analysis /usr/local/bin/codacy-analysis-real
COPY docker/codacy-shim.sh /usr/local/bin/codacy
RUN cp /usr/local/bin/codacy /usr/local/bin/codacy-analysis \
  && chmod +x /usr/local/bin/codacy /usr/local/bin/codacy-analysis \
  # Codacy credentials live in runner's home, unreadable by agent.
  && mkdir -p /home/runner/.codacy \
  && chown -R runner:codacy /home/runner/.codacy \
  && chmod 700 /home/runner/.codacy

# Pre-bake skills — Claude loads via --plugin-dir, Gemini installs from local path
# ADD'ing the master ref content makes Docker invalidate this layer whenever codacy-skills master moves,
# so a fresh `docker build` always gets the latest skills without --no-cache.
ADD https://api.github.com/repos/codacy/codacy-skills/git/refs/heads/master /tmp/codacy-skills-ref
RUN git clone --depth 1 https://github.com/codacy/codacy-skills.git /opt/codacy-skills

COPY docker/anthropic-proxy.js /usr/local/bin/anthropic-proxy.js
COPY docker/init-firewall.sh /usr/local/bin/init-firewall.sh
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/local-pipeline.sh /usr/local/bin/local-pipeline.sh
COPY docker/server-pipeline.sh /usr/local/bin/server-pipeline.sh
COPY docker/summary-sanitize.sh /usr/local/bin/summary-sanitize.sh
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh /usr/local/bin/local-pipeline.sh /usr/local/bin/server-pipeline.sh /usr/local/bin/summary-sanitize.sh \
  # The agent may run ONLY the two real CLIs, and only as runner.
  && printf 'agent ALL=(runner) NOPASSWD: /usr/local/bin/codacy-real, /usr/local/bin/codacy-analysis-real\n' \
     > /etc/sudoers.d/agent-cli \
  && chmod 0440 /etc/sudoers.d/agent-cli

# Image starts as root; entrypoint performs setup then drops to `agent`.
USER root

# Install skills into the agent's ~/.claude/commands/ — claude reads these natively
# without --plugin-dir, which avoids the v2.1.123 regression where --plugin-dir
# silently fails in stream-json mode. Managed settings lock the policy so the
# repo/agent cannot widen it.
COPY --chown=agent:codacy docker/claude-settings.json /home/agent/.claude/settings.json
COPY docker/managed-settings.json /etc/claude-code/managed-settings.json
RUN mkdir -p /home/agent/.claude/commands/references \
  && cp /opt/codacy-skills/skills/configure-codacy/SKILL.md /home/agent/.claude/commands/configure-codacy.md \
  && cp /opt/codacy-skills/skills/configure-codacy-cloud/SKILL.md /home/agent/.claude/commands/configure-codacy-cloud.md \
  && cp /opt/codacy-skills/skills/codacy-analysis-cli/SKILL.md /home/agent/.claude/commands/codacy-analysis-cli.md \
  && cp /opt/codacy-skills/skills/codacy-cloud-cli/SKILL.md /home/agent/.claude/commands/codacy-cloud-cli.md \
  && cp /opt/codacy-skills/skills/codacy-analysis-cli/references/* /home/agent/.claude/commands/references/ \
  && chown -R agent:codacy /home/agent/.claude \
  && chmod 0644 /etc/claude-code/managed-settings.json

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["local-pipeline.sh"]
