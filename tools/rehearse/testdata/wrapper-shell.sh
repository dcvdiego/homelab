# a nested shell behind env -u is still parsed
ssh -F "$OPS_SSH_CONFIG" pve "pct exec 101 -- env -u FOO sh -c 'echo \"oops'"
