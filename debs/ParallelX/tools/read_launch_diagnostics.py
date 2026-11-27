#!/usr/bin/env python3
"""Read saved launch diagnostics without changing the device or presenting UI.
Offline: --trace FILE. Device: --mcp SERVER --out-dir LOCAL_DIRECTORY.
The device path is resolved from the current RootHide root, never a stored UUID.
"""
import argparse
import base64
import json
from pathlib import Path
import plistlib
import subprocess

TRACE_NAME = 'com.niubiprass.clonex.launch-trace.plist'


def summarize(document):
    if not isinstance(document, dict) or not isinstance(document.get('CXLaunchTrace'), list):
        raise ValueError('invalid launch trace document')
    timeline = [row for row in document['CXLaunchTrace'] if isinstance(row, dict)]
    archive = document.get('CXLaunchFailures', [])
    if not isinstance(archive, list):
        raise ValueError('invalid failure archive')
    if any(not isinstance(row, dict) or row.get('stage') != 'failed' for row in archive):
        raise ValueError('malformed saved failure record')
    failures = []
    seen = set()
    for source, rows in (('archive', archive), ('rolling_trace', timeline)):
        for row in rows:
            if not isinstance(row, dict) or row.get('stage') != 'failed':
                continue
            identifier = row.get('failureID')
            key = identifier if isinstance(identifier, str) else (
                row.get('time'), row.get('token'), row.get('bundle'), row.get('code'))
            if key in seen:
                continue
            seen.add(key)
            saved = row.get('summary')
            saved = saved if isinstance(saved, dict) else {}
            observation = saved.get('lastOpen')
            observation = observation if isinstance(observation, dict) else {}
            failures.append({
                'source': source,
                'time': row.get('time'), 'build': row.get('build'),
                'bundle': row.get('bundle'), 'code': row.get('code'),
                'failureID': identifier, 'token': row.get('token'),
                'summary': saved,
                'events': row.get('events', []),
                'has_detailed_observation': bool(observation) and not observation.get('observationException', False),
                'missing_observation_reason': ('observation raised an exception' if observation.get('observationException')
                    else None if observation else 'not recorded in this saved event'),
            })
    failures.sort(key=lambda row: row['time'] if isinstance(row.get('time'), (int, float)) else 0)
    transactions=document.get('CXLaunchTransactions',[])
    if not isinstance(transactions,list) or len(transactions)>4:
        raise ValueError('invalid transaction archive')
    stages={0:'idle',1:'closing',2:'terminating',3:'authenticating',4:'verifying',5:'opening',6:'failed',7:'quarantined'}
    summarized=[]
    for row in transactions:
        if not isinstance(row,dict) or not isinstance(row.get('stages'),list) or len(row['stages'])>40 or not isinstance(row.get('phaseDurationsMS'),dict):
            raise ValueError('malformed transaction summary')
        item=dict(row)
        item['phaseNames']={stages.get(int(k),'unknown'):v for k,v in row['phaseDurationsMS'].items()}
        item['timingBasis']='monotonic observed phase boundaries; not remote input acknowledgement'
        item['appResponsiveness']='not_measured'
        summarized.append(item)
    return {
        'transactions':summarized,
        'transaction_count':len(summarized),
        'timeline_count': len(timeline),
        'archive_count': len(archive),
        'failures': failures,
        'latest_timeline_event': timeline[-1] if timeline else None,
        'timeline': timeline,
    }


def mcp_call(server, tool, arguments):
    raw = subprocess.check_output(
        ['minis-mcp-cli', 'call', server, tool, '--input', json.dumps(arguments)],
        text=True, timeout=90)
    reply = json.loads(raw)['result']
    if reply.get('isError'):
        raise ValueError('device read failed: ' + tool)
    content = reply.get('structuredContent')
    if not isinstance(content, dict):
        raise ValueError('missing structured device result: ' + tool)
    return content


def pull_trace(server, directory):
    info = mcp_call(server, 'get_device_info', {})
    jailbreak = info.get('jailbreak', {})
    root = jailbreak.get('rootPath')
    if not isinstance(root, str) or not root:
        raise ValueError('current jailbreak root not reported')
    root_name = Path(root.rstrip('/')).name
    if jailbreak.get('type') == 'roothide':
        if not root_name.startswith('.jbroot-') or '/' in root_name:
            raise ValueError('invalid current RootHide root')
        parent = '/var/mobile/Containers/Shared/AppGroup/' + root_name
    else:
        parent = root.rstrip('/')
    path = parent + '/var/mobile/Library/Preferences/' + TRACE_NAME
    result = mcp_call(server, 'read_file', {'path': path, 'binary': True, 'max_bytes': 524288})
    if result.get('truncated') or result.get('encoding') != 'base64':
        raise ValueError('incomplete device trace')
    data = base64.b64decode(result['content'], validate=True)
    if len(data) != result.get('size'):
        raise ValueError('device trace byte count mismatch')
    document = plistlib.loads(data)
    report = summarize(document)
    directory.mkdir(parents=True, exist_ok=True)
    (directory / TRACE_NAME).write_bytes(data)
    report['device_path'] = path
    (directory / 'launch-diagnostics.json').write_text(
        json.dumps(report, ensure_ascii=False, indent=2) + '\n')
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument('--trace', type=Path)
    mode.add_argument('--mcp', metavar='SERVER')
    parser.add_argument('--out-dir', type=Path)
    args = parser.parse_args()
    if args.trace:
        report = summarize(plistlib.loads(args.trace.read_bytes()))
    else:
        if args.out_dir is None:
            parser.error('--mcp requires --out-dir for local evidence')
        report = pull_trace(args.mcp, args.out_dir)
    print(json.dumps(report, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
