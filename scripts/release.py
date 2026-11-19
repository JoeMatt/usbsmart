#!/usr/bin/env python3
"""Build, sign, notarize and package a DriverKit app. No publication side effects.

preview: unsigned packaging check, explicitly not an installable public release.
check-profiles: inspect Apple-issued Developer ID profiles without building.
package: require distribution profiles, sign inside-out, notarize and staple app and DMG.

Profiles and certificates remain outside the source tree. This script never exports keys.
"""
import argparse
import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parent.parent
CONFIG = ROOT / 'packaging/release.json'

class ReleaseError(Exception):
    pass

def require(condition, message):
    if not condition:
        raise ReleaseError(message)

def run(args, capture=False):
    result = subprocess.run([str(a) for a in args], check=True, cwd=ROOT,
                            stdout=subprocess.PIPE if capture else None,
                            stderr=subprocess.PIPE if capture else None)
    return result.stdout if capture else None

def read_plist(path):
    return plistlib.loads(Path(path).read_bytes())

def profile_entitlements(profile, bundle_id, team, required):
    """Pure validation also exercised with synthetic profiles in tests."""
    expiry = profile.get('ExpirationDate')
    require(isinstance(expiry, dt.datetime), f'{bundle_id}: profile has no expiry')
    expiry = expiry.replace(tzinfo=dt.timezone.utc) if expiry.tzinfo is None else expiry
    require(expiry > dt.datetime.now(dt.timezone.utc), f'{bundle_id}: expired profile')
    require(not profile.get('ProvisionedDevices'), f'{bundle_id}: development/device-limited profile')
    require(profile.get('ProvisionsAllDevices') is True, f'{bundle_id}: not an all-devices distribution profile')
    require(team in profile.get('TeamIdentifier', []), f'{bundle_id}: wrong team')
    ent = profile.get('Entitlements', {})
    ids = [ent[k] for k in ('application-identifier', 'com.apple.application-identifier') if k in ent]
    require(ids and all(v == team + '.' + bundle_id for v in ids), f'{bundle_id}: profile must explicitly match this bundle ID')
    require(ent.get('get-task-allow') is not True and ent.get('com.apple.security.get-task-allow') is not True,
            f'{bundle_id}: debugging entitlement in distribution profile')
    for key, value in required.items():
        require(ent.get(key) == value, f'{bundle_id}: Apple profile does not grant {key}={value!r}')
    require(profile.get('DeveloperCertificates'), f'{bundle_id}: profile contains no signing certificates')
    return ent

def pci_subset(ent, requested):
    if not requested:
        return []
    # Request exact IDs in the release signature, even when a grant permits a broader mask.
    grants = ent.get('com.apple.developer.driverkit.transport.pci', [])
    def permits(match):
        for grant in grants:
            expression = grant.get('IOPCIPrimaryMatch', '') if isinstance(grant, dict) else ''
            for term in expression.split():
                if not re.fullmatch(r'0x[0-9a-fA-F]{1,8}(?:&0x[0-9a-fA-F]{1,8})?', term):
                    continue
                pieces = term.split('&')
                value = int(pieces[0], 16)
                mask = int(pieces[1], 16) if len(pieces) == 2 else 0xffffffff
                if int(match, 16) & mask == value & mask:
                    return True
        return False
    matches = [m for m in requested if permits(m)]
    require(requested[0] in matches, 'Apple profile does not grant the primary hardware PCI match')
    return matches

def load_profiles(config, args):
    require(args.host_profile and args.driver_profile, 'Supply --host-profile and --driver-profile from Apple after distribution approval')
    host_path, driver_path = Path(args.host_profile).expanduser(), Path(args.driver_profile).expanduser()
    require(host_path.is_file() and driver_path.is_file(), 'A provisioning profile path does not exist')
    host = plistlib.loads(run(['security', 'cms', '-D', '-i', host_path], capture=True))
    driver = plistlib.loads(run(['security', 'cms', '-D', '-i', driver_path], capture=True))
    host_required = read_plist(ROOT / config['host_entitlements'])
    driver_required = read_plist(ROOT / config['driver_entitlements'])
    driver_required.pop('com.apple.developer.driverkit.transport.pci', None)
    host_ent = profile_entitlements(host, config['app_id'], config['team'], host_required)
    driver_ent = profile_entitlements(driver, config['driver_id'], config['team'], driver_required)
    matches = pci_subset(driver_ent, config['pci_matches'])
    if matches:
        driver_required['com.apple.developer.driverkit.transport.pci'] = [{'IOPCIPrimaryMatch': m} for m in matches]
    def signing_entitlements(required, granted):
        out = dict(required)
        for key in ('application-identifier', 'com.apple.application-identifier', 'com.apple.developer.team-identifier'):
            if key in granted:
                out[key] = granted[key]
        return out
    return host_path, driver_path, host, driver, signing_entitlements(host_required, host_ent), signing_entitlements(driver_required, driver_ent), matches

def build(config, output):
    run(['xcodegen', 'generate'])
    derived = output / 'DerivedData'
    run(['xcodebuild', '-project', config['project'], '-scheme', config['scheme'],
         '-configuration', 'Release', '-derivedDataPath', derived,
         'CODE_SIGNING_ALLOWED=NO', 'ARCHS=arm64', 'ONLY_ACTIVE_ARCH=YES', 'build'])
    source = derived / 'Build/Products/Release' / (config['product'] + '.app')
    require(source.is_dir(), 'Build did not produce the expected app')
    stage = output / 'staging'
    stage.mkdir()
    app = stage / source.name
    run(['ditto', source, app])
    version = read_plist(app / 'Contents/Info.plist')['CFBundleShortVersionString']
    require(re.fullmatch(r'\d+\.\d+\.\d+', version), 'Expected a numeric x.y.z app version')
    return app, stage, version

def make_dmg(stage, target, volume):
    os.symlink('/Applications', stage / 'Applications')
    run(['hdiutil', 'create', '-volname', volume, '-srcfolder', stage, '-ov', '-format', 'UDZO', target])
    run(['hdiutil', 'verify', target])

def notarize(path, profile, receipt):
    require(profile, 'Supply --notary-profile with an existing notarytool Keychain credential profile')
    command = ['xcrun', 'notarytool', 'submit', path, '--keychain-profile', profile, '--wait', '--output-format', 'json']
    if os.environ.get('RELEASE_KEYCHAIN'):
        command += ['--keychain', os.environ['RELEASE_KEYCHAIN']]
    raw = run(command, capture=True)
    receipt.write_bytes(raw)
    result = json.loads(raw)
    require(result.get('status') == 'Accepted', f'Notarization was not accepted; see {receipt}')

def signature_check(path, config, entitlements=None):
    run(['codesign', '--verify', '--strict', '--verbose=2', path])
    # codesign writes display output to stderr, so inspect it explicitly.
    result = subprocess.run(['codesign', '-d', '--verbose=4', str(path)], capture_output=True, check=True)
    details = result.stderr.decode()
    require('Authority=Developer ID Application:' in details, 'Expected a Developer ID Application signature')
    require('TeamIdentifier=' + config['team'] in details, 'Signature has the wrong Team ID')
    require('runtime' in details, 'Hardened runtime is missing')
    require('Timestamp=' in details and 'Timestamp=none' not in details, 'Missing secure signing timestamp')
    if entitlements is not None:
        signed = plistlib.loads(run(['codesign', '-d', '--entitlements', ':-', path], capture=True))
        require(not signed.get('get-task-allow') and not signed.get('com.apple.security.get-task-allow'), 'Signed artifact enables debugging')
        for key, value in entitlements.items():
            require(signed.get(key) == value, f'Signature is missing expected entitlement {key}')

def check_certificate(path, profile, output, label):
    prefix = output / (label + '-certificate-')
    run(['codesign', '-d', '--extract-certificates=' + str(prefix), path], capture=True)
    require(Path(str(prefix) + '0').read_bytes() in profile['DeveloperCertificates'],
            f'{label}: signing certificate is not authorized by the embedded profile')
    for cert in output.glob(label + '-certificate-*'):
        cert.unlink()

def package(config, args, output):
    host_path, driver_path, host_profile, driver_profile, host_ent, driver_ent, matches = load_profiles(config, args)
    require(args.identity and (args.identity.startswith('Developer ID Application:') or re.fullmatch(r'[0-9A-Fa-f]{40}', args.identity)), 'Supply --identity with a Developer ID Application certificate name or SHA-1 fingerprint')
    require(args.notary_profile, 'Supply --notary-profile before building a distribution release')
    app, stage, version = build(config, output)
    if args.version:
        require(version == args.version, 'Requested release version differs from project.yml')
    driver = app / 'Contents/Library/SystemExtensions' / (config['driver_id'] + '.dext')
    cli = app / 'Contents/MacOS' / config['cli']
    require(driver.is_dir() and cli.is_file(), 'Missing driver or bundled command')
    require(run(['lipo', '-archs', driver / config['driver_id']], capture=True).decode().strip() == 'arm64', 'Driver must contain exactly arm64 (no arm64e)')
    # An 8D-only PCI grant is enough: remove unapproved optional hardware personalities.
    if matches:
        path = driver / 'Info.plist'
        info = read_plist(path)
        info['IOKitPersonalities'] = {k: v for k, v in info['IOKitPersonalities'].items() if v.get('IOPCIMatch') in matches}
        require(info['IOKitPersonalities'], 'No approved hardware personalities remain')
        path.write_bytes(plistlib.dumps(info, sort_keys=False))
    shutil.copyfile(host_path, app / 'Contents/embedded.provisionprofile')
    shutil.copyfile(driver_path, driver / 'embedded.provisionprofile')
    for label, ent in [('host', host_ent), ('driver', driver_ent)]:
        (output / (label + '-entitlements.plist')).write_bytes(plistlib.dumps(ent))
    # No --deep signing: sign each executable from the inside out.
    for target, ent in [(cli, None), (driver, 'driver'), (app, 'host')]:
        command = ['codesign', '--force', '--sign', args.identity, '--timestamp', '--options', 'runtime']
        if ent:
            command += ['--entitlements', output / (ent + '-entitlements.plist')]
        run(command + [target])
        signature_check(target, config, driver_ent if ent == 'driver' else host_ent if ent == 'host' else None)
    check_certificate(app, host_profile, output, 'host')
    check_certificate(driver, driver_profile, output, 'driver')
    run(['codesign', '--verify', '--deep', '--strict', app])
    zip_for_notary = output / 'notary-submission.zip'
    run(['ditto', '-c', '-k', '--keepParent', app, zip_for_notary])
    notarize(zip_for_notary, args.notary_profile, output / 'app-notarization.json')
    run(['xcrun', 'stapler', 'staple', app])
    run(['xcrun', 'stapler', 'validate', app])
    run(['spctl', '--assess', '--type', 'execute', '--verbose=2', app])
    (stage / 'Install.txt').write_text(config['install_text'])
    shutil.copyfile(ROOT / 'LICENSE', stage / 'LICENSE.txt')
    stem = f'{config["product"]}-{version}-arm64'
    dmg = output / (stem + '.dmg')
    make_dmg(stage, dmg, config['product'])
    run(['codesign', '--sign', args.identity, '--timestamp', dmg])
    notarize(dmg, args.notary_profile, output / 'dmg-notarization.json')
    run(['xcrun', 'stapler', 'staple', dmg])
    run(['xcrun', 'stapler', 'validate', dmg])
    run(['spctl', '--assess', '--type', 'open', '--context', 'context:primary-signature', '--verbose=2', dmg])
    final_zip = output / (stem + '.zip')
    run(['ditto', '-c', '-k', '--keepParent', app, final_zip])
    zip_for_notary.unlink()
    (output / 'SHA256SUMS.txt').write_text(''.join(hashlib.sha256(p.read_bytes()).hexdigest() + '  ' + p.name + '\n' for p in [dmg, final_zip]))
    print(f'Ready for release review: {dmg}\n{final_zip}\nNo release has been published.')

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=['preview', 'check-profiles', 'package'])
    parser.add_argument('--output', default='build/release')
    parser.add_argument('--host-profile', default=os.environ.get('RELEASE_HOST_PROFILE'))
    parser.add_argument('--driver-profile', default=os.environ.get('RELEASE_DRIVER_PROFILE'))
    parser.add_argument('--identity', default=os.environ.get('RELEASE_IDENTITY'))
    parser.add_argument('--notary-profile', default=os.environ.get('RELEASE_NOTARY_PROFILE'))
    parser.add_argument('--version', help='Require this exact version (without v)')
    args = parser.parse_args()
    config = json.loads(CONFIG.read_text())
    if args.command == 'check-profiles':
        *_, matches = load_profiles(config, args)
        print('Distribution profiles passed. Approved PCI matches:', matches or 'not applicable')
        return
    output = Path(args.output).expanduser().resolve()
    # Never overwrite an earlier signed artifact or a source directory.
    require(not output.exists(), f'{output} already exists; choose a fresh output directory')
    if args.command == 'package':
        load_profiles(config, args)  # Fail before creating output or compiling when approval is absent.
    output.mkdir(parents=True)
    if args.command == 'package':
        package(config, args, output)
    else:
        app, stage, version = build(config, output)
        (stage / 'UNSIGNED-PREVIEW.txt').write_text('PACKAGING PREVIEW ONLY. NOT A PUBLIC RELEASE.\nThis app is unsigned and cannot activate its driver with normal macOS security. Do not install it.\n')
        shutil.copyfile(ROOT / 'LICENSE', stage / 'LICENSE.txt')
        make_dmg(stage, output / f'{config["product"]}-{version}-arm64-UNSIGNED-PREVIEW.dmg', config['product'] + ' Preview')
        print('Unsigned packaging preview only. No signing, notarization or publication was performed.')

if __name__ == '__main__':
    try:
        main()
    except (ReleaseError, subprocess.CalledProcessError, OSError, ValueError) as error:
        print(f'Release blocked: {error}', file=sys.stderr)
        sys.exit(1)
