#!/usr/bin/env python3
"""Verify Android component boundaries using isolated acceptance packages."""
import os
from pathlib import Path
import subprocess
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
TARGET = 'local.boox.sidecar.acceptance'
CALLER = 'local.boox.sidecar.provisioningcaller'
ADB = [os.environ.get('ADB', 'adb')]
if os.environ.get('ANDROID_SERIAL'):
    ADB += ['-s', os.environ['ANDROID_SERIAL']]


def adb(*args, check=True):
    result = subprocess.run(ADB + list(args), capture_output=True, text=True, timeout=45)
    if check and result.returncode:
        raise RuntimeError('ADB operation failed: ' + ' '.join(args[:3]))
    return result


def pairing():
    result = adb('shell', 'run-as', TARGET, 'cat', 'shared_prefs/pairing.xml', check=False)
    if result.returncode:
        return {}
    return {item.attrib['name']: item.text or item.attrib.get('value', '') for item in ET.fromstring(result.stdout)}


def launch(component, token='a' * 64):
    adb('shell', 'pm', 'enable', TARGET)
    command = ['broadcast', '-f', '32'] if component == 'ProvisioningReceiver' else ['start', '-W']
    result = adb('shell', 'am', *command, '-n', TARGET + '/local.boox.sidecar.' + component,
                '--ei', 'pairing_version', '2', '--es', 'host', 'https://127.0.0.1:9',
                '--es', 'usb_host', 'https://127.0.0.1:9', '--es', 'token', token,
                '--es', 'spki_sha256', 'b' * 64, '--es', 'host_id', 'c' * 64)
    if 'Error:' in result.stdout or 'Exception' in result.stdout:
        details = [line for line in result.stdout.splitlines() if line.startswith(('Error:', 'Error type', 'java.lang.SecurityException:'))]
        raise AssertionError('Shell could not launch ' + component + ': ' + ' '.join(details))


def wait_for(check):
    deadline = time.monotonic() + 8
    while time.monotonic() < deadline:
        if check():
            return
        time.sleep(.1)
    raise AssertionError('Timed out waiting for component result')


def main():
    adb('get-state')
    packages = [
        (TARGET, ROOT / 'android/app/build/outputs/apk/acceptance/app-acceptance.apk'),
        (CALLER, ROOT / 'android/provisioning-caller/build/outputs/apk/debug/provisioning-caller-debug.apk'),
    ]
    installed = []
    try:
        for package, apk in packages:
            if not apk.is_file():
                raise RuntimeError('Build acceptance APKs before running component tests')
            if 'package:' in adb('shell', 'pm', 'path', package, check=False).stdout:
                raise RuntimeError('Remove the existing test-only package before testing: ' + package)
            adb('install', str(apk))
            installed.append(package)
            adb('shell', 'pm', 'enable', package)
        launch('MainActivity', 'd' * 64)
        time.sleep(.5)
        assert not pairing(), 'Public launcher accepted pairing extras'
        launch('ProvisioningReceiver')
        wait_for(lambda: pairing().get('token') == 'a' * 64)
        saved = pairing()
        assert saved['spkiPin'] == 'b' * 64 and saved['hostId'] == 'c' * 64
        launch('ProvisioningReceiver', 'invalid')
        time.sleep(.5)
        assert pairing() == saved, 'Invalid provisioning changed pairing'
        launch('MainActivity', 'd' * 64)
        time.sleep(.5)
        assert pairing() == saved, 'Public launcher replaced pairing'
        adb('shell', 'pm', 'enable', CALLER)
        launched = adb('shell', 'am', 'start', '-W', '-n', CALLER + '/.CallerActivity')
        if 'Error' in launched.stdout:
            raise AssertionError('Caller launch failed: ' + launched.stdout)
        wait_for(lambda: adb('shell', 'run-as', CALLER, 'cat', 'files/result', check=False).returncode == 0)
        result = adb('shell', 'run-as', CALLER, 'cat', 'files/result').stdout.strip()
        assert result == 'DENIED', 'Ordinary UID provisioning result: ' + result
        assert pairing() == saved, 'Ordinary UID changed pairing'
        print('PASS: shell provisioning, public launcher isolation, invalid update retention, ordinary-UID denial')
    finally:
        for package in reversed(installed):
            adb('uninstall', package)


if __name__ == '__main__':
    main()
