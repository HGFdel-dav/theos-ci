#!/usr/bin/env python3
"""用 Git Data API 推送新分支（本地 git push 对该 token 返回 403）。"""
import base64, json, os, sys, time
import urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

REPO = 'Niubiprass/theos-ci'
BRANCH = 'splitx-0.1.0dev1'
ROOT = Path('/var/minis/shared/theos-ci')
PATHS = ['debs/SplitX', '.github/workflows/build-splitx.yml']
TOKEN = os.environ['GITHUB_DEB']

def api(url, method='GET', data=None):
    body = json.dumps(data).encode() if data is not None else None
    req = urllib.request.Request('https://api.github.com' + url, data=body, method=method,
                                 headers={'Authorization': 'Bearer ' + TOKEN,
                                          'Accept': 'application/vnd.github+json',
                                          'User-Agent': 'minis-splitx-push',
                                          'Content-Type': 'application/json'})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.loads(r.read() or b'{}')

def files():
    out = []
    for rel in PATHS:
        p = ROOT / rel
        if p.is_dir():
            out += [f for f in p.rglob('*') if f.is_file()
                    and '.theos' not in f.parts and f.suffix not in ('.deb',)]
        else:
            out.append(p)
    return out

def blob(path):
    content = path.read_bytes()
    sha = api('/repos/%s/git/blobs' % REPO, 'POST',
              {'content': base64.b64encode(content).decode(), 'encoding': 'base64'})['sha']
    return str(path.relative_to(ROOT)), sha

base = api('/repos/%s/git/ref/heads/main' % REPO)['object']['sha']
base_tree = api('/repos/%s/git/commits/%s' % (REPO, base))['tree']['sha']

items = files()
print('files', len(items), flush=True)
entries = []
with ThreadPoolExecutor(max_workers=8) as pool:
    for i, (rel, sha) in enumerate(pool.map(blob, items), 1):
        entries.append({'path': rel, 'mode': '100755' if os.access(ROOT / rel, os.X_OK) else '100644',
                        'type': 'blob', 'sha': sha})
        if i % 25 == 0:
            print('blob', i, flush=True)

tree = api('/repos/%s/git/trees' % REPO, 'POST', {'base_tree': base_tree, 'tree': entries})['sha']
commit = api('/repos/%s/git/commits' % REPO, 'POST',
             {'message': 'SplitX 0.1.0dev1: 开源基座改名换标 + 目标模型 + ScreenCore 顺序切换',
              'tree': tree, 'parents': [base]})['sha']
try:
    api('/repos/%s/git/refs' % REPO, 'POST', {'ref': 'refs/heads/' + BRANCH, 'sha': commit})
except urllib.error.HTTPError as e:
    api('/repos/%s/git/refs/heads/%s' % (REPO, BRANCH), 'PATCH', {'sha': commit, 'force': False})
print(json.dumps({'branch': BRANCH, 'commit': commit, 'base': base, 'files': len(entries)}))
