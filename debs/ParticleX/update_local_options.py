"""Update only local settings XML; do not run the full project generator."""
from pathlib import Path
import plistlib
r=Path(__file__).resolve().parent
p=r/'Prefs/Resources/Root.plist'
d=plistlib.loads(p.read_bytes());items=d['items']
for item in items:
    if item.get('key')=='clearAllButton':item['label']='显示一键清除按钮'
    if item.get('label')=='消散参数':
        item['footerText']='四档密度保留原色。选择随风轻散或晶砂解体，通知、小组件和 App 删除统一使用同一风格。低电量自动降档；严重发热或内存告警时暂时停用。'
if not any(x.get('key')=='effectStyle' for x in items):
    index=next(i for i,x in enumerate(items) if x.get('label')=='消散参数')+1
    items.insert(index,{'cell':'PSLinkListCell','label':'消散风格','key':'effectStyle','default':0,
        'detail':'PSListItemsController','validValues':[0,1],'validTitles':['随风轻散','晶砂解体'],
        'defaults':'com.niubiprass.particlex','get':'readPreferenceValue:','set':'setPreferenceValue:specifier:'})
assert len({x['key'] for x in items if 'key' in x})==sum('key' in x for x in items)
p.write_bytes(plistlib.dumps(d,sort_keys=False))
print('Local settings: Wind/Crystal, clear-button switch; no build, push or device operations')
