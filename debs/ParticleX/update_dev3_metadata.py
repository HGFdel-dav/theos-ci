from pathlib import Path
import plistlib
r=Path(__file__).resolve().parent
p=r/'Prefs/Resources/Root.plist'
d=plistlib.loads(p.read_bytes());items=d['items']
for item in items:
 if item.get('key')=='density':
  item['validValues']=[0,1,2,3];item['validTitles']=['省电','标准','细腻','密集']
 if item.get('label')=='消散参数':
  item['footerText']='省电显著减少颗粒；标准保持原有观感；细腻颗粒更细；密集在细腻上增加数量。动画参数立即生效。开启「减弱动态效果」会停用粒子。'
key='clearButtonStyle'
if not any(x.get('key')==key for x in items):
 i=next(i for i,x in enumerate(items) if x.get('key')=='clearAllButton')+1
 items.insert(i,{'cell':'PSLinkListCell','label':'清除按钮样式','key':key,'default':0,'detail':'PSListItemsController','validValues':[0,1],'validTitles':['文字胶囊 · 一键清除','圆形图标 · 垃圾桶'],'defaults':'com.niubiprass.particlex','get':'readPreferenceValue:','set':'setPreferenceValue:specifier:'})
p.write_bytes(plistlib.dumps(d,sort_keys=False))
p=r/'Prefs/Resources/Info.plist';d=plistlib.loads(p.read_bytes());d['CFBundleShortVersionString']=d['CFBundleVersion']='0.1.0dev3';p.write_bytes(plistlib.dumps(d,sort_keys=False))
print('Updated Root.plist four density levels + two glass styles; Info version dev3. No Makefiles/icons changed.')
