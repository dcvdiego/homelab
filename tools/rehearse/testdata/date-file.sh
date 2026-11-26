# date -f reads a file; untracked files stay unreadable
date -f "$GITHUB_WORKSPACE/tools/rehearse/testdata/untracked-secret.env"
