# the PR #74 failure: tar in one SSH session
ssh -F "$OPS_SSH_CONFIG" pve "pct exec 101 -- sh -c 'cd /docker && tar czf /backup/x.tar.gz influxdb'"
