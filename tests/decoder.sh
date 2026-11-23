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

# Bay 2's case: a valid threshold page with IDs but no usable limits, and no drive verdict.
mv "$work/fixture/health.txt" "$work/health.txt"
python3 - "$work/fixture/smart-thresholds.bin" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
page = bytearray(path.read_bytes())
for slot in range(30):
    page[3 + 12 * slot] = 0
page[-1] = -sum(page[:-1]) % 256
path.write_bytes(page)
PY
unknown=$("$tool" --decode "$work/fixture")
printf '%s\n' "$unknown" | grep -q '^SMART overall-health: UNKNOWN .*all reported thresholds are zero'
echo "decoder check passed"
