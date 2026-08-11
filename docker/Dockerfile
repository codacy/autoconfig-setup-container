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
# Pinned: policy-engine semantics change between minors, so a bump must be tested, never picked up silently
ARG GEMINI_CLI_VERSION=0.54.4
RUN npm install -g \
    @anthropic-ai/claude-code@${CLAUDE_CODE_VERSION} \
    @google/gemini-cli@${GEMINI_CLI_VERSION} \
    @codacy/codacy-cloud-cli \
    @codacy/analysis-cli

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
COPY docker/gemini-policy.toml /etc/gemini-cli/policies/10-codacy-lockdown.toml
COPY docker/gemini-settings.json /etc/gemini-cli/settings.json
# gemini skips a policy directory that is not root-owned, and the agent user must not be able to relax either file
RUN chown -R root:root /etc/gemini-cli \
  && chmod 0755 /etc/gemini-cli /etc/gemini-cli/policies \
  && chmod 0644 /etc/gemini-cli/settings.json /etc/gemini-cli/policies/10-codacy-lockdown.toml \
  && chmod +x /usr/local/bin/entrypoint.sh /usr/local/bin/local-pipeline.sh /usr/local/bin/server-pipeline.sh /usr/local/bin/clone-workspace.sh /usr/local/bin/sanitize-workspace.sh /usr/local/bin/summary-sanitize.sh \
  && printf 'node ALL=(root) NOPASSWD: /bin/chown -R node\\:node /home/node/.codacy\n' \
     > /etc/sudoers.d/node-toolcache \
  && chmod 0440 /etc/sudoers.d/node-toolcache

USER node

# Install skills into ~/.claude/commands/ — claude reads these natively without --plugin-dir,
# which avoids the v2.1.123 regression where --plugin-dir silently fails in stream-json mode
COPY --chown=node:node docker/claude-settings.json /home/node/.claude/settings.json
RUN mkdir -p /home/node/.claude/commands/references \
  && cp /opt/codacy-skills/skills/configure-codacy/SKILL.md /home/node/.claude/commands/configure-codacy.md \
  && cp /opt/codacy-skills/skills/configure-codacy-cloud/SKILL.md /home/node/.claude/commands/configure-codacy-cloud.md \
  && cp /opt/codacy-skills/skills/codacy-analysis-cli/SKILL.md /home/node/.claude/commands/codacy-analysis-cli.md \
  && cp /opt/codacy-skills/skills/codacy-cloud-cli/SKILL.md /home/node/.claude/commands/codacy-cloud-cli.md \
  && cp /opt/codacy-skills/skills/codacy-analysis-cli/references/* /home/node/.claude/commands/references/

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["server-pipeline.sh"]
