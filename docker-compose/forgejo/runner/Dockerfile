# Forgejo runner with python3 for host-executor CI jobs (scripts/check-images.py). The upstream image
# is Alpine with git and bash already. No Docker socket, no secrets: see docker-compose/forgejo.
FROM data.forgejo.org/forgejo/runner:13.2.1@sha256:568cea8c15ddc01fc8f330124892f572af7db37fa28344a2c1914405793bf61d
USER root
RUN apk add --no-cache ca-certificates curl python3
USER 1000:1000
