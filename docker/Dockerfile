FROM node:20-bookworm-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
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
  && rm -rf /var/lib/apt/lists/* \
  # Ensure `python` resolves (several tool adapters call `python3` but some call `python`)
  && ln -sf /usr/bin/python3 /usr/local/bin/python

# Install CLIs globally as published packages
RUN npm install -g \
    @anthropic-ai/claude-code \
    @google/gemini-cli \
    @codacy/codacy-cloud-cli \
    @codacy/analysis-cli

# Firewall init — node user gets sudo rights for this script only
# Pre-bake skills — Claude loads via --plugin-dir, Gemini installs from local path
RUN git clone --depth 1 https://github.com/codacy/codacy-skills.git /opt/codacy-skills

COPY docker/init-firewall.sh /usr/local/bin/init-firewall.sh
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY docker/pipeline.sh /usr/local/bin/pipeline.sh
RUN chmod +x /usr/local/bin/init-firewall.sh /usr/local/bin/entrypoint.sh /usr/local/bin/pipeline.sh \
  && printf 'node ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh\nnode ALL=(root) NOPASSWD: /bin/chown -R node\\:node /home/node/.codacy\n' \
     > /etc/sudoers.d/node-firewall \
  && chmod 0440 /etc/sudoers.d/node-firewall

USER node

# Install skills into ~/.claude/commands/ — claude reads these natively without --plugin-dir,
# which avoids the v2.1.123 regression where --plugin-dir silently fails in stream-json mode
COPY --chown=node:node docker/claude-settings.json /home/node/.claude/settings.json
RUN mkdir -p /home/node/.claude/commands/references \
  && cp /opt/codacy-skills/skills/configure-codacy/SKILL.md /home/node/.claude/commands/configure-codacy.md \
  && cp /opt/codacy-skills/skills/codacy-analysis-cli/SKILL.md /home/node/.claude/commands/codacy-analysis-cli.md \
  && cp /opt/codacy-skills/skills/codacy-cloud-cli/SKILL.md /home/node/.claude/commands/codacy-cloud-cli.md \
  && cp /opt/codacy-skills/skills/codacy-analysis-cli/references/* /home/node/.claude/commands/references/

WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["pipeline.sh"]
