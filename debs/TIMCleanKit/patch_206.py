#!/usr/bin/env python3
# TIMCleanKit 2.0.6：延迟补标修复"要重进才显示"
#  真机 2.0.5 毫秒日志：撤回处理 55.185 → 55.271 已贴上标签(86ms)，但随后 TIM 刷新/重绑 cell
#  把标签清掉，重绑瞬间布局未完成、补不回来 → 用户要退出重进（布局完整）才看到。
#  修法：判定"该贴"但布局未就绪（cell 尺寸过小/气泡未找到）时，安排 0.2s 后重试一次。
BASE='/var/minis/shared/theos-ci/debs/TIMCleanKit/TIMCleanKit'
def read(p): return open(p,encoding='utf-8').read()
def write(p,s): open(p,'w',encoding='utf-8').write(s)

p=BASE+'/TKCellBridge.h'; s=read(p)

# 1. 新增重试 key
old='static char kTKBoundModelKey,kTKRecallLabelKey,kTKLabelRecordKey;'
assert s.count(old)==1,'key=%d'%s.count(old)
s=s.replace(old,'static char kTKBoundModelKey,kTKRecallLabelKey,kTKLabelRecordKey,kTKLabelRetryKey;')

# 2. 前向声明 + 重试函数（放在 TKUpdateRecallLabel 前）
old='''static NSString *TKLabelBriefText(id record) {'''
assert s.count(old)==1,'brief=%d'%s.count(old)
s=s.replace(old,'''static void TKUpdateRecallLabel(UIView *cell);
static void TKUpdateRecallLabelRetry(UIView *cell) {
    /* 2.0.6: cell 刚重绑时布局未完成，锚定会失败且之后可能没有第二次评估——
       0.2s 后（布局完成）补一次，标签就不会"要退出重进才显示"。 */
    if(!cell)return;
    if(objc_getAssociatedObject(cell,&kTKLabelRetryKey))return;
    objc_setAssociatedObject(cell,&kTKLabelRetryKey,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(0.2*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        objc_setAssociatedObject(cell,&kTKLabelRetryKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        TKUpdateRecallLabel(cell);
    });
}
static NSString *TKLabelBriefText(id record) {''')

# 3. 早退点一：cell 尺寸未就绪
old='''    CGFloat cellW=cell.bounds.size.width,cellH=cell.bounds.size.height;
    if(cellW<120||cellH<30)return;'''
assert s.count(old)==1,'size=%d'%s.count(old)
s=s.replace(old,'''    CGFloat cellW=cell.bounds.size.width,cellH=cell.bounds.size.height;
    if(cellW<120||cellH<30){TKUpdateRecallLabelRetry(cell);return;}''')

# 4. 早退点二：气泡未找到（布局未完成）
old='''    if(CGRectIsEmpty(bubble)) {label.hidden=YES;return;} // 识别失败宁可不放，避免错位重叠。'''
assert s.count(old)==1,'bubble=%d'%s.count(old)
s=s.replace(old,'''    if(CGRectIsEmpty(bubble)) {label.hidden=YES;TKUpdateRecallLabelRetry(cell);return;} // 识别失败宁可不放；布局未完成时 0.2s 后补标''')
write(p,s)
print('1-4. TKCellBridge 延迟补标 OK')

# 5. 版本
p=BASE+'/Tweak.xm'; s=read(p)
assert s.count('@"version":@"2.0.5"')==2,'ver=%d'%s.count('@"version":@"2.0.5"')
s=s.replace('@"version":@"2.0.5"','"version":@"2.0.6"'.join(['@','']))
write(p,s)
p=BASE+'/TKSettingsUI.h'; s=read(p)
s=s.replace('@"2.0.5 · 双指长按唤醒"','"2.0.6 · 双指长按唤醒"'.join(['@','']))
s=s.replace('?:@"2.0.5"','?:@"2.0.6"')
write(p,s)
p='/var/minis/shared/theos-ci/debs/TIMCleanKit/control'
s=read(p); s=s.replace('Version: 2.0.5','Version: 2.0.6'); write(p,s)
print('5. 版本 2.0.6 OK')
print('ALL PATCHES APPLIED (2.0.6)')