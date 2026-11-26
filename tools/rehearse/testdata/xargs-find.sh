# long commands behind xargs and find -exec
ssh -F "$OPS_SSH_CONFIG" pve "find /docker -name '*.db' -print0 | xargs -0 -n 1 tar czf /backup/all.tgz"
ssh -F "$OPS_SSH_CONFIG" pve "find /docker -name '*.db' -exec rsync -a {} /backup/ ';'"
