#!/usr/bin/env python3
"""Validate the selected 15.5 SDK before the actual macOS build."""
import argparse
import json
import plistlib
from pathlib import Path
parser = argparse.ArgumentParser()
parser.add_argument('sdk', type=Path)
args = parser.parse_args()
sdk = args.sdk.resolve()
errors = []
if sdk.name != 'iPhoneOS15.5.sdk':
    errors.append('SDK directory must be iPhoneOS15.5.sdk')
settings = sdk / 'SDKSettings.plist'
try:
    data = plistlib.loads(settings.read_bytes())
    if str(data.get('Version')) != '15.5' or data.get('CanonicalName') != 'iphoneos15.5':
        errors.append('SDKSettings does not identify iOS 15.5')
except (OSError, ValueError, plistlib.InvalidFileException) as error:
    errors.append('Cannot read SDKSettings: ' + str(error))
headers = sdk / 'System/Library/Frameworks/WebKit.framework/Headers'
for name, needles in {
    'WKScriptMessageHandlerWithReply.h': ['didReceiveScriptMessage:', 'replyHandler:', 'API_AVAILABLE'],
    'WKUserContentController.h': ['addScriptMessageHandlerWithReply:', 'contentWorld:'],
    'WKWebView.h': ['inFrame:', 'inContentWorld:', 'completionHandler:'],
}.items():
    try:
        content = (headers / name).read_text()
        for needle in needles:
            if needle not in content:
                errors.append(name + ' missing ' + needle)
    except OSError:
        errors.append('Missing WebKit SDK header: ' + name)
print(json.dumps({'stage': 'sdk_static_check', 'sdk': str(sdk), 'errors': errors}, indent=2))
raise SystemExit(bool(errors))
