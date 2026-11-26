# curl and python3 are faked; their output is empty
out=$(curl -fsS https://example.invalid/)
[ -z "$out" ]
python3 -c 'import sys; sys.exit(3)'
echo reached
