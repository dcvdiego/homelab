# a file the request wrote is read back from scratch, even where an untracked real file exists
cd "$GITHUB_WORKSPACE/tools/rehearse/testdata"
echo mine > untracked-secret.env
[ "$(cat untracked-secret.env)" = mine ]
