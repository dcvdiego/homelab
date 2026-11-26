# long commands inside $(...) count
ssh -F "$OPS_SSH_CONFIG" pve 'echo "size: $(du -sh /docker/big)"'
