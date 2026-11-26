# file writes go to a scratch directory
echo secret > /root/rehearse-test-file
[ "$(cat /root/rehearse-test-file)" = secret ]
