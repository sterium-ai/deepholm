# usage: count_asserts.sh <tests dir>; counts assertion call sites (not definitions) in test_*.gd and support/*.gd
cd "$1"
files=$(ls test_*.gd support/*.gd 2>/dev/null)
a=$(cat $files | grep -v "^\s*func " | grep -oE "(^|[^A-Za-z0-9_.])(_expect|_fail|assert)\(" | wc -l)
c=$(cat $files | grep -v "^\s*func " | grep -oE "(^|[^A-Za-z0-9_.])_check_[a-z0-9_]*\(" | wc -l)
echo "expect/fail/assert call sites: $a ; _check_* call sites: $c ; test files: $(ls test_*.gd | wc -l)"
