# text tools that write files themselves are faked, not run
printf 'b\na\n' | sort -o /tmp/rehearse-sort-out
sed -i 's/x/y/' /tmp/rehearse-sed-in-place

printf 'b\na\n' | sort -ro /tmp/rehearse-sort-out2
echo reached
