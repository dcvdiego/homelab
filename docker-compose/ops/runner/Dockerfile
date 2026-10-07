# GitHub Actions runner that applies approved changes (see docs/agent-access.md).
# No Docker socket: jobs talk to Portainer/Cloudflare/Technitium APIs and SSH, nothing else.
FROM ghcr.io/actions/actions-runner:latest
USER root
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl git jq openssh-client python3 \
 && rm -rf /var/lib/apt/lists/*
COPY entrypoint.sh job-started.sh /opt/ops/
RUN chmod 755 /opt/ops/*.sh
USER runner
ENTRYPOINT ["/opt/ops/entrypoint.sh"]
