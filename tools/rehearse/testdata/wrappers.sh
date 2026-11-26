# options with values are skipped per wrapper; each of these is a long tar
ssh -F "$OPS_SSH_CONFIG" pve "pct exec 101 -- env -u FOO tar czf /x.tgz /y"
ssh -F "$OPS_SSH_CONFIG" pve "sudo -n tar czf /x.tgz /y"
ssh -F "$OPS_SSH_CONFIG" pve "nice -n 19 ionice -c 3 timeout -s KILL 30m tar czf /x.tgz /y"
