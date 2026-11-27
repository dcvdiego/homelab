# rclone's official image (Alpine, busybox crond/flock/wget) with rustic's official binary copied in.
# The rustic image is FROM scratch (just /rustic), so it can't run rclone or a scheduler itself; rustic
# starts `rclone serve restic` on its own for an rclone: repository (rustic docs: init/rclone).
FROM ghcr.io/rustic-rs/rustic:v0.12.0@sha256:b357591d911ec72f14a8d9cf1382da4371f3c5829eb2075e23b27f1b6702c59f AS rustic

FROM rclone/rclone:1.76.0@sha256:7cbeec24a44f206067597c0368be4de90ae19a64d5113c7d1938bd737a81e466
COPY --from=rustic /rustic /usr/local/bin/rustic
ENTRYPOINT ["/opt/offsite/entrypoint.sh"]
