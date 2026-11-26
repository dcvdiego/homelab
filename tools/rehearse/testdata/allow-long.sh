# rehearse: allow-long du small dir
ssh -F "$OPS_SSH_CONFIG" pve "pct exec 101 -- du -sh /small"
ssh -F "$OPS_SSH_CONFIG" pve "pct exec 101 -- tar czf /a.tgz /b"
