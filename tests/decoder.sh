#!/bin/sh
# Decoder check that needs no hardware: builds a made-up set of ATA pages, decodes them with
# `usbsmart --decode`, and compares the result with tests/expected.txt.
#   usage: tests/decoder.sh path/to/usbsmart
set -eu
tool=$1
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
mkdir "$work/fixture"
python3 "$here/make_fixture.py" "$work/fixture"
# The first line names the source directory, which differs per run.
(cd "$work" && "$tool" --decode fixture) | tail -n +2 > "$work/actual.txt"
diff -u "$here/expected.txt" "$work/actual.txt"
echo "decoder check passed"
