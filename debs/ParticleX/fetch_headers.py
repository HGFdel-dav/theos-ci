import urllib.request,urllib.error,os,json
from pathlib import Path
base='https://raw.githubusercontent.com/lechium/iPhone_OS_15.5/master/'
out=Path(__file__).resolve().parent/'reference';out.mkdir(exist_ok=True)
headers={
 'UserNotificationsUIKit':['NCNotificationListView','NCNotificationListViewController','NCNotificationListCollectionView','NCNotificationListCell','NCNotificationViewController','NCNotificationShortLookViewController','NCNotificationListSectionRevealHintView','NCNotificationDispatcher','NCNotificationStructuredListViewController','NCNotificationStructuredListView','NCNotificationListClearAllButton'],
 'SpringBoardHome':['SBIconController','SBIconListView','SBHWidgetViewController','SBHWidgetContainerView','SBHWidgetContainerViewController','SBHWidgetManager','SBHWidgetIcon','SBIconView','SBHIconManager'],
}
for framework,names in headers.items():
 for name in names:
  path=f'System/Library/PrivateFrameworks/{framework}/{name}.h'
  try:
   with urllib.request.urlopen(base+path,timeout=15) as r:b=r.read()
   (out/(name+'.h')).write_bytes(b); print(framework,name,len(b),flush=True)
  except urllib.error.HTTPError as e:
   print(name,e.code,flush=True)
  except Exception as e:print(name,type(e).__name__,flush=True)
