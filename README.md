# usbsmart

SMART data for SATA drives in USB docks on Apple silicon Macs, with no kernel extension and no
change to the Mac's security settings.

macOS gives user programs no way to send ATA commands to a disk behind a USB bridge, so
`smartctl` fails there ("Operation not supported by device"), and the usual fix is a kext that
needs Reduced Security. This project is a small DriverKit driver extension that does the same
job from user space, plus a `usbsmart` command that prints the result.

```
$ usbsmart disk9
Device Model:     TESTDISK FIXTURE 8TB
Serial Number:    TESTSERIAL0001
Firmware Version: FW01
User Capacity:    8,001,563,222,016 bytes [8.00 TB]
Sector Sizes:     512 bytes logical, 4096 bytes physical
Rotation Rate:    7200 rpm
SMART support:    Available, enabled

SMART overall-health self-assessment test result: PASSED

ID# ATTRIBUTE_NAME          FLAG     VALUE WORST THRESH TYPE      UPDATED  WHEN_FAILED RAW_VALUE
  1 Raw_Read_Error_Rate     0x000b   100   100   016    Pre-fail  Always       -       0
  5 Reallocated_Sector_Ct   0x0033   100   100   005    Pre-fail  Always       -       24
  9 Power_On_Hours          0x0012   094   094   000    Old_age   Always       -       43210
197 Current_Pending_Sector  0x0022   100   100   000    Old_age   Always       -       8
...

Worth a look (these counters are zero on a healthy drive):
    5 Reallocated_Sector_Ct = 24: sectors already remapped to spares
  197 Current_Pending_Sector = 8: unstable sectors waiting to be remapped
```

(That output is from the made-up pages in `tests/`, shortened.)

## Status

Verified on one setup: MacBook Pro (M2 Max), macOS 27.2.1, SIP enabled, Full Security, a
Sabrent USB 3 SATA dock (VIA Labs VL715, `0x2109:0x0715`) holding a WD Caviar Green and, later, a
Seagate ST8000DM004.

| What | Result |
|---|---|
| Driver activates with SIP on, development-signed | works |
| Driver takes the dock's disk in place of Apple's driver; disk still mounts normally | works |
| IDENTIFY DEVICE, SMART READ DATA, SMART READ THRESHOLDS | work |
| SMART READ LOG (error log, self-test log) | works |
| SMART RETURN STATUS (the drive's own pass/fail verdict) | the command completes, but this bridge does not hand back the drive's registers, so the verdict is worked out from the thresholds instead (smartctl does the same) |
| `--smartctl` hand-off | works with smartmontools 7.5 |
| Additional SAT bridges | See the compatibility list in Driver Setup |
| UAS bridges | not tried |

## How it works

A USB disk on macOS is a stack of drivers. This project replaces one layer:

```
IOUSBHostInterface                  the dock's USB interface
  IOUSBMassStorageDriver            Apple's USB mass-storage driver (unchanged)
    IOSCSIPeripheralDeviceNub       one SCSI logical unit
      IOSCSIPeripheralDeviceType00  Apple's disk driver      <- replaced by USBSmartDevice
        IOBlockStorageServices ... IOMedia (disk9)
```

`USBSmartDevice` subclasses `IOUserSCSIPeripheralDeviceType00` from SCSIPeripheralsDriverKit.
Its kernel half is Apple's same disk driver, so the disk appears, mounts and performs as
before; ordinary reads and writes never pass through this project's code. What the subclass
adds is `UserSendCDB`, which the driver uses to send ATA PASS-THROUGH (16) commands to the
bridge. Apple ships helpers for exactly these SMART commands in the same framework.

Two details that are not obvious from Apple's documentation:

- **Winning the match.** Apple's driver and this one both match "Peripheral Device Type 0".
  The SCSI family adds a personality's `IOProbeScore` (clamped below 5000) to its own ranking,
  so any `IOProbeScore` from 1 to 4999 outranks Apple's personality, which has none.
- **Not taking every disk.** `IOParentMatch` with an `IOPropertyMatch` on `idVendor` and
  `idProduct` limits the personality to disks that have that USB device among their ancestors.

No USB transport entitlement is involved, because the driver never touches the USB interface.
It needs `com.apple.developer.driverkit`, `...driverkit.family.scsicontroller` and
`...driverkit.allow-any-userclient-access`, all of which Xcode's automatic signing adds to a
development profile on a paid developer account without a request to Apple.

## Read-only

The driver can send five ATA commands, all of which only read: IDENTIFY DEVICE, SMART READ
DATA, SMART READ THRESHOLDS, SMART READ LOG and SMART RETURN STATUS. Each command is checked
byte by byte against that list after it is built and before it is sent
(`IsAllowedCDB` in `Driver/USBSmartDevice.cpp`). There is no code path for self-tests, SMART
enable/disable, log writes, firmware or any other command, and none should be added casually:
the drives this was written for may hold the only copy of someone's data.

One thing the driver does not change: macOS itself still mounts any volume it recognises on the
disk, read-write, exactly as it does without this driver.

## Downloadable releases

[Download USBSmart 0.3.2 for Apple silicon](https://github.com/JoeMatt/usbsmart/releases/download/v0.3.2/USBSmart-0.3.2-arm64.dmg).
Drag USBSmart into Applications. Open Driver Setup, activate the driver, then approve it in
System Settings. Eject any mounted volumes before reconnecting the dock. The app requires
macOS 14 or later and runs without a developer account or Xcode.

The signed GUI and bundled CLI are authorized to connect to this driver through
`com.apple.developer.driverkit.userclient-access`. The distribution driver does not claim
`allow-any-userclient-access`. The CLI carries its profile in a nested app-like bundle, with
a signed launcher preserving the usual command path.

The [release instructions](packaging/release-instructions.txt) describe the three verified
profiles and the packaging workflow. The signed 0.3.2 driver activated on a Mac Studio and
returned distinct SMART reports from all four bays of a Sabrent JMS561 dock.

## Install

You need a paid Apple Developer account, Xcode with the DriverKit SDK, and
[XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

1. In `project.yml`, change `DEVELOPMENT_TEAM` to your Team ID and the three
   `PRODUCT_BUNDLE_IDENTIFIER` values to identifiers of your own (the driver's must be the
   app's plus `.driver`). Change `driverIdentifier` in `Host/USBSmartApp.swift` to match.
2. Build. Xcode registers the identifiers, the capabilities and this Mac for you:

   ```bash
   xcodegen generate
   ```

   ```bash
   xcodebuild -project USBSmart.xcodeproj -scheme USBSmartHost -configuration Release -derivedDataPath build -allowProvisioningUpdates build
   ```

3. Copy the app to Applications (macOS only loads drivers from apps there) and activate:

   ```bash
   cp -R build/Build/Products/Release/USBSmart.app /Applications/
   ```

   ```bash
   open /Applications/USBSmart.app --args --activate
   ```

4. Approve it: System Settings → General → Login Items & Extensions → Driver Extensions →
   switch USBSmart on. This is the normal consent prompt for any driver; it does not lower the
   Mac's security.
5. Unplug and replug the dock.

Open USBSmart to see supported drives in the sidebar. Select a drive for its identity, health
summary and SMART attributes. Refresh reads the pages again, and the list updates when drives
are connected or removed. Driver setup is available from the toolbar. No Terminal is needed
to read a report.

The command is also inside the app. To have it on your `PATH`:

```bash
ln -s /Applications/USBSmart.app/Contents/MacOS/usbsmart /opt/homebrew/bin/usbsmart
```

A development-signed driver runs only on Macs registered in your developer account, and the
signing lasts a year. This is the current development-signing path. A public download needs
Apple to grant the DriverKit distribution entitlements, followed by Developer ID signing and
notarization. A distribution request was submitted to Apple on 2026-11-18; approval is pending.

To renew or update: rebuild, eject the dock's volumes, copy the app again,
activate again. Bump both version numbers in `project.yml` for any driver change, or macOS
keeps the installed one.

To remove it: `open /Applications/USBSmart.app --args --deactivate`, then delete the app.

## Use

```
usbsmart                          list the disks the driver is attached to
usbsmart disk9                    identity, health verdict, attribute table
usbsmart disk9 --smartctl         the same pages decoded by smartctl -a, with its drive database
usbsmart disk9 --smartctl -x      any other smartctl options
usbsmart disk9 --raw              hex dump of the raw 512-byte pages
usbsmart disk9 --save pages/      write the raw pages as .bin files
usbsmart --decode pages/          decode pages saved earlier
usbsmart disk9 --replay           the pages as text that `smartctl -a -` reads on stdin
usbsmart disk9 --debug            also show each command sent and the bridge's answer
```

`--smartctl` works because smartctl can replay a recorded session: given `-` as the device, it
reads `smartctl -r ataioctl,2` debug output from standard input and decodes it as if it had
talked to the drive. `usbsmart` writes the pages it read in that format. Install smartctl with
`brew install smartmontools`.

Exit status is 4 when the drive reports failure (its own verdict, or an attribute at or below
its threshold), so the command can be used in scripts.

Saved pages contain the drive's serial number. `captures/` is git-ignored for that reason.

## Adding another bridge

`bridges.json` lists the exact USB bridge IDs.
`scripts/generate-bridges.py` generates both the driver personalities in `Driver/Info.plist`
and the compatibility list in the app. The driver code uses the same standard SAT commands
for every match.

| USB IDs | Bridge family | Status with USBSmart |
| --- | --- | --- |
| `2109:0715` | VIA Labs VL715 | Verified on hardware |
| `174c:55aa`, `174c:1153`, `174c:235c` | ASMedia SATA | Untested candidates |
| `152d:0567`, `152d:0577`, `152d:0578`, `152d:0579`, `152d:0580` | JMicron SATA | Untested candidates |
| `152d:1561` | JMicron JMS561 (Sabrent SATA dock) | SMART reads verified on four bays |
| `1759:5000`, `1759:5002`, `1759:5100` | LucidPort SATA | Untested candidates |

The catalog also includes exact USB IDs from a pinned
[smartmontools bridge database snapshot](https://github.com/smartmontools/smartmontools/blob/3e35033664efd115a1ca523701f9f41a10b94b6b/drivedb/drivedb.h).
The imported entries use plain `-d sat` without a firmware restriction, warning, or conflicting
mode. Each imported ID is a candidate until tested through Apple's `UserSendCDB`. UAS operation
remains unverified. The driver matches exact IDs individually.

To add a bridge, add its exact USB vendor/product pair to `bridges.json` with `verified: false`,
then run `python3 scripts/generate-bridges.py`. Bump the driver version, rebuild and activate,
then safely eject mounted volumes before reconnecting the dock. Mark a bridge verified only
after testing real SMART pages with this driver. CI checks that the generated matches stay
in sync with the catalog.

Bridges that require proprietary commands or ATA PASS-THROUGH (12) are outside the current
command set. A listed bridge may still reject SMART commands, in which case the app reports
the failed read. There is a
[developer forum report](https://developer.apple.com/forums/thread/802099) of `UserSendCDB` not
moving data over UAS.

## Limits

- SATA drives only. NVMe-to-USB bridges use different commands.
- Drives with SMART switched off return no attributes; this tool will not switch it on.
- Only the attribute names smartctl uses as generic defaults are built in. Vendors reuse some
  IDs with other meanings; `--smartctl` applies smartctl's per-drive database.
- If the dext fails to start, macOS should fall back to Apple's driver for that disk. That is
  standard IOKit behaviour; it has not been tested here.

## Layout

| Path | What |
|---|---|
| `Driver/` | The dext. `USBSmartDevice.*` is the disk driver subclass and the only place commands are built; `USBSmartUserClient.*` is the command's connection to it; `USBSmartShared.h` is the wire format between them |
| `CLI/` | `usbsmart`. `Driver.swift` finds the driver and calls it, `Pages.swift` decodes the ATA pages, `main.swift` is arguments and output |
| `Host/` | The app that installs the driver |
| `tests/` | A decoder check on made-up pages that needs no hardware: `tests/decoder.sh path/to/usbsmart` |
| `project.yml` | XcodeGen spec. The `.xcodeproj` is generated and not committed |

## License

MIT. See [LICENSE](LICENSE).
