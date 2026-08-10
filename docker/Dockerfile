FROM node:20-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get upgrade -y && apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    git \
    jq \
    unzip \
    sudo \
    # Used by gemini's file search
    ripgrep \
  && rm -rf /var/lib/apt/lists/*

# Install CLIs globally as published packages
ARG CLAUDE_CODE_VERSION=2.1.226
RUN npm install -g \
    @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
    @google/gemini-cli \
    @codacy/codacy-cloud-cli \
    @codacy/analysis-cli

# --- Privilege separation ------------------------------------------------
# runner (1001): holds the Codacy token and runs the real Codacy CLIs.
# agent  (1002): runs claude/gemini and the pipeline; holds no credential.
# Shared group `codacy` (1003) lets both read and write /workspace/.codacy.
RUN groupadd -g 1003 codacy \
  && useradd -m -u 1001 -g codacy runner \
  && useradd -m -u 1002 -g codacy agent \
  # Relocate the real Codacy CLIs to <name>-real in the SAME dir so their relative npm symlinks
  # stay valid; the shims below take over the original names.
  && mv /usr/local/bin/codacy          /usr/local/bin/codacy-real \
  && mv /usr/local/bin/codacy-analysis /usr/local/bin/codacy-analysis-real
COPY docker/codacy-shim.sh /usr/local/bin/codacy
COPY docker/codacy-run.sh /usr/local/bin/codacy-run
RUN cp /usr/local/bin/codacy /usr/local/bin/codacy-analysis \
  && chmod +x /usr/local/bin/codacy /usr/local/bin/codacy-analysis /usr/local/bin/codacy-run \
  # Codacy tool cache lives in runner's home, unreadable by the agent.
  && mkdir -p /home/runner/.codacy \
  && chown -R runner:codacy /home/runner/.codacy \
  && chmod 700 /home/runner/.codacy \
  # The CLIs run as runner against an agent-owned checkout — git's dubious-ownership guard would
  # otherwise reject it.
  && git config --system --add safe.directory /workspace

# Pre-bake skills — Claude loads via --plugin-dir, Gemini installs from local path
# ADD'ing the master ref content makes Docker invalidate this layer whenever codacy-skills master moves,
# so a fresh `docker build` always gets the latest skills without --no-cache.
ADD https://api.github.com/repos/codacy/codacy-skills/git/refs/heads/master /tmp/codacy-skills-ref
RUN git clone --depth 1 https://github.com/codacy/codacy-skills.git /opt/codacy-skills

COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/agent-lib.sh /usr/local/bin/agent-lib.sh
COPY docker/local-pipeline.sh /usr/local/bin/local-pipeline.sh
COPY docker/server-pipeline.sh /usr/local/bin/server-pipeline.sh
COPY docker/clone-workspace.sh /usr/local/bin/clone-workspace.sh
COPY docker/sanitize-workspace.sh /usr/local/bin/sanitize-workspace.sh
COPY docker/summary-sanitize.sh /usr/local/bin/summary-sanitize.sh
# Root-owned so the agent user cannot relax it at runtime
COPY docker/managed-settings.json /etc/claude-code/managed-settings.json
RUN chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/local-pipeline.sh /usr/local/bin/server-pipeline.sh /usr/local/bin/clone-workspace.sh /usr/local/bin/sanitize-workspace.sh /usr/local/bin/summary-sanitize.sh \
  # The agent may run ONLY the runner-side CLI launcher, and only as runner.
  && printf 'agent ALL=(runner) NOPASSWD: /usr/local/bin/codacy-run\n' \
     > /etc/sudoers.d/agent-cli \
  && chmod 0440 /etc/sudoers.d/agent-cli

# Image starts as root; the entrypoint performs the privileged setup and then drops to `agent`.
USER root

# Install skills into the agent's ~/.claude/commands/ — claude reads these natively without
# --plugin-dir, which avoids the v2.1.123 regression where --plugin-dir silently fails in
# stream-json mode
COPY --chown=agent:codacy docker/claude-settings.json /home/agent/.claude/settings.json
RUN mkdir -p /home/agent/.claude/commands/references \
  && cp /opt/codacy-skills/skills/configure-codacy/SKILL.md /home/agent/.claude/commands/configure-codacy.md \
  && cp /opt/codacy-skills/skills/configure-codacy-cloud/SKILL.md /home/agent/.claude/commands/configure-codacy-cloud.md \
  && cp /opt/codacy-skills/skills/codacy-analysis-cli/SKILL.md /home/agent/.claude/commands/codacy-analysis-cli.md \
  && cp /opt/codacy-skills/skills/codacy-cloud-cli/SKILL.md /home/agent/.claude/commands/codacy-cloud-cli.md \
  && cp /opt/codacy-skills/skills/codacy-analysis-cli/references/* /home/agent/.claude/commands/references/ \
  && chown -R agent:codacy /home/agent/.claude

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["server-pipeline.sh"]
