from pathlib import Path
import plistlib
r=Path(__file__).resolve().parent
p=r/'Prefs/Resources/Root.plist';d=plistlib.loads(p.read_bytes());items=d['items']
if not any(x.get('key')=='appDeletion' for x in items):
 idx=next(i for i,x in enumerate(items) if x.get('key')=='controlCenter')+1
 items[idx:idx]=[
 {'cell':'PSSwitchCell','label':'删除 App 消散','key':'appDeletion','default':True,'defaults':'com.niubiprass.particlex','get':'readPreferenceValue:','set':'setPreferenceValue:specifier:'},
 {'cell':'PSLinkListCell','label':'删除 App 消散方向','key':'appDeletionDirection','default':0,'detail':'PSListItemsController','validValues':[0,1,2,3,4],'validTitles':['左 → 右','右 → 左','上 → 下','下 → 上','随机'],'defaults':'com.niubiprass.particlex','get':'readPreferenceValue:','set':'setPreferenceValue:specifier:'}]
# local metadata currently dev4
p.write_bytes(plistlib.dumps(d,sort_keys=False))
print('app deletion settings added; no compile/push performed')
