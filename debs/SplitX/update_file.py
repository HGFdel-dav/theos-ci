#!/usr/bin/env python3
"""更新分支上的单个文件（Git Data API）。用法：update_file.py <路径> <提交信息>"""
import base64, json, os, sys
import urllib.request
from pathlib import Path

REPO = 'Niubiprass/theos-ci'
BRANCH = 'splitx-0.1.0dev1'
ROOT = Path('/var/minis/shared/theos-ci')
rel, message = sys.argv[1], sys.argv[2]
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

head = api('/repos/%s/git/ref/heads/%s' % (REPO, BRANCH))['object']['sha']
tree_sha = api('/repos/%s/git/commits/%s' % (REPO, head))['tree']['sha']
content = (ROOT / rel).read_bytes()
blob = api('/repos/%s/git/blobs' % REPO, 'POST',
           {'content': base64.b64encode(content).decode(), 'encoding': 'base64'})['sha']
mode = '100755' if os.access(ROOT / rel, os.X_OK) else '100644'
tree = api('/repos/%s/git/trees' % REPO, 'POST',
           {'base_tree': tree_sha, 'tree': [{'path': rel, 'mode': mode, 'type': 'blob', 'sha': blob}]})['sha']
commit = api('/repos/%s/git/commits' % REPO, 'POST',
             {'message': message, 'tree': tree, 'parents': [head]})['sha']
api('/repos/%s/git/refs/heads/%s' % (REPO, BRANCH), 'PATCH', {'sha': commit, 'force': False})
print(commit)
