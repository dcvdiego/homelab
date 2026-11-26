# a heredoc that is data, not a script, is not parsed
ssh -F "$OPS_SSH_CONFIG" pve 'cat > /tmp/f' <<'SH'
this is "not shell
SH
