#!/bin/sh
set -eu
here=$(cd "$(dirname "$0")" && pwd)
work=$(mktemp -d)
mkdir "$work/pages"
python3 "$here/make_fixture.py" "$work/pages"
xcrun swiftc "$here/../CLI/Driver.swift" "$here/../CLI/Pages.swift" \
    "$here/../CLI/AttributeNames.swift" "$here/../Shared/DriveReport.swift" \
    "$here/../Shared/DriveScan.swift" "$here/../Shared/SelfTest.swift" \
    "$here/../CLI/Prometheus.swift" "$here/../Host/ScanHistory.swift" \
    "$here/report.swift" -o "$work/check-report"
"$work/check-report" "$work/pages"
