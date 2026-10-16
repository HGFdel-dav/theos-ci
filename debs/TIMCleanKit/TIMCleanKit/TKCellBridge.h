// Verified cell bind selector and strong reference fields from Swift field descriptors.
static NSString *const TKCellClass=@"_TtC13NTAIOBaseCell17NTAIOBaseCellView";
static char kTKBoundModelKey,kTKRecallLabelKey;
static NSHashTable *gTKVisibleCells;
static unsigned long long gTKRecordReadFailures;
#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <malloc/malloc.h>
static id TKSwiftRecordField(id vm) {
    if(!vm)return nil;
    Class expected=NSClassFromString(@"NTAIOBaseCell.NTAIOBaseCellViewModel");
    if(!expected)expected=NSClassFromString(@"_TtC13NTAIOBaseCell22NTAIOBaseCellViewModel");
    if(!expected||![vm isKindOfClass:expected])return nil;
    static const uint64_t *offsetVariable;
    static dispatch_once_t once;
    dispatch_once(&once,^{
        const uint8_t expectedUUID[16]={0x3c,0x23,0x7f,0xa0,0x59,0x85,0x33,0x76,0xbf,0x98,0xef,0x16,0x98,0x56,0x32,0x47};
        const struct mach_header_64 *header=(const struct mach_header_64 *)_dyld_get_image_header(0);
        if(!header||header->magic!=MH_MAGIC_64)return;
        const uint8_t *p=(const uint8_t *)(header+1);BOOL uuidOK=NO,offsetMapped=NO;
        for(uint32_t i=0;i<header->ncmds;i++) {
            const struct load_command *lc=(const struct load_command *)p;if(lc->cmdsize<sizeof(*lc))return;
            if(lc->cmd==LC_UUID && lc->cmdsize>=sizeof(struct uuid_command))uuidOK=!memcmp(((const struct uuid_command *)p)->uuid,expectedUUID,16);
            if(lc->cmd==LC_SEGMENT_64 && lc->cmdsize>=sizeof(struct segment_command_64)) {
                const struct segment_command_64 *seg=(const struct segment_command_64 *)p;
                if(0x10e681078ULL>=seg->vmaddr && 0x10e681080ULL<=seg->vmaddr+seg->vmsize)offsetMapped=YES;
            }
            p+=lc->cmdsize;
        }
        // Getter 0x1049e4654, setter 0x1049e4698 and modify 0x1049e46e8 all use this global.
        if(uuidOK&&offsetMapped)offsetVariable=(const uint64_t *)(0x10e681078ULL+_dyld_get_image_vmaddr_slide(0));
    });
    if(!offsetVariable)return nil;
    uint64_t offset=*offsetVariable;size_t allocation=malloc_size((__bridge const void *)vm);
    if(offset<sizeof(void *) || offset%sizeof(void *) || !allocation || offset+sizeof(id)>allocation)return nil;
    id __unsafe_unretained record=nil;
    memcpy(&record,(const uint8_t *)(__bridge const void *)vm+offset,sizeof(record));
    return [record isKindOfClass:NSClassFromString(@"OCMsgRecord")]?record:nil;
}
static id TKStrongKnownField(id object,const char *field) {
    if(!object)return nil;
    Ivar ivar=class_getInstanceVariable(object_getClass(object),field);
    if(!ivar)return nil;
    ptrdiff_t offset=ivar_getOffset(ivar);
    if(offset<0 || (size_t)offset+sizeof(id)>class_getInstanceSize(object_getClass(object)))return nil;
    // Only called for the two fields proved to be strong Objective-C references.
    return object_getIvar(object,ivar);
}
static id TKRecordForCell(UIView *cell) {
    id vm=objc_getAssociatedObject(cell,&kTKBoundModelKey);
    if(!vm)vm=TKStrongKnownField(cell,"viewModel");
    id record=TKStrongKnownField(vm,"record");
    if(!record)record=TKSwiftRecordField(vm);
    if([record isKindOfClass:NSClassFromString(@"OCMsgRecord")])return record;
    return nil;
}
static void TKUpdateRecallLabel(UIView *cell) {
    if(!cell || !NSThread.isMainThread)return;
    id record=TKRecordForCell(cell);
    UILabel *label=objc_getAssociatedObject(cell,&kTKRecallLabelKey);
    if(!TKAntiRecallEnabled()||!record||!TKWasRecalled(record)||!TKHasCachedContent(record)) {label.hidden=YES;return;}
    if(!label) {
        label=[UILabel new];label.text=@"拦截撤回";label.font=[UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
        label.textColor=UIColor.systemOrangeColor;label.backgroundColor=[UIColor.secondarySystemBackgroundColor colorWithAlphaComponent:.92];
        label.textAlignment=NSTextAlignmentCenter;label.layer.cornerRadius=6;label.clipsToBounds=YES;label.userInteractionEnabled=NO;
        [cell addSubview:label];objc_setAssociatedObject(cell,&kTKRecallLabelKey,label,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    label.hidden=NO;
    CGFloat width=70,height=18;
    CGFloat cellW=cell.bounds.size.width,cellH=cell.bounds.size.height;
    if(cellW<120||cellH<30)return;
    // 1) 气泡识别：类名含 "Bubble" 的可见视图，取其中面积最大且非整行者（最外层气泡容器）。
    CGRect bubble=CGRectZero;double bestArea=0;
    NSMutableArray *queue=[NSMutableArray arrayWithArray:cell.subviews];
    for(NSUInteger i=0;i<queue.count&&i<150;i++) {
        UIView *view=queue[i];
        if(view!=label&&!view.hidden&&view.alpha>.01&&[NSStringFromClass(view.class) containsString:@"Bubble"]&&view.bounds.size.width>=60&&view.bounds.size.height>=20) {
            CGRect r=[view convertRect:view.bounds toView:cell];
            if(r.size.width<=cellW*.88&&r.size.height<=cellH*.95) {
                double area=(double)r.size.width*r.size.height;
                if(area>bestArea){bestArea=area;bubble=r;}
            }
        }
        [queue addObjectsFromArray:view.subviews];
    }
    // 2) 几何兜底：面积最大的可见内容视图（排除小控件与整行容器，避免把头像/整行当气泡）。
    if(CGRectIsEmpty(bubble)) {
        NSMutableArray *q2=[NSMutableArray arrayWithArray:cell.subviews];
        for(NSUInteger i=0;i<q2.count&&i<150;i++) {
            UIView *view=q2[i];
            if(view!=label&&!view.hidden&&view.alpha>.01&&view.bounds.size.width>=cellW*.3&&view.bounds.size.width<=cellW*.88&&view.bounds.size.height>=24&&view.bounds.size.height<=cellH*.92) {
                CGRect r=[view convertRect:view.bounds toView:cell];double area=(double)r.size.width*r.size.height;
                if(area>bestArea){bestArea=area;bubble=r;}
            }
            [q2 addObjectsFromArray:view.subviews];
        }
    }
    if(CGRectIsEmpty(bubble)) {label.hidden=YES;return;} // 识别失败宁可不放，避免错位重叠。
    // 3) 三档锚定：右侧尾部 → 左侧尾部（自己消息）→ 气泡正上方；垂直优先居中，始终钳制在 cell 内。
    CGFloat x=6,y=MAX(0,(cellH-height)/2);
    CGFloat rightSpace=MAX(0,cellW-CGRectGetMaxX(bubble)-6);
    CGFloat leftSpace=MAX(0,CGRectGetMinX(bubble)-6);
    if(rightSpace>=width+6) {
        x=MIN(CGRectGetMaxX(bubble)+6,MAX(6,cellW-width-6));
        y=CGRectGetMinY(bubble)+(CGRectGetHeight(bubble)-height)/2;
    } else if(leftSpace>=width+6) {
        x=MAX(6,CGRectGetMinX(bubble)-width-6);
        y=CGRectGetMinY(bubble)+(CGRectGetHeight(bubble)-height)/2;
    } else {
        x=MAX(CGRectGetMinX(bubble),MIN(CGRectGetMaxX(bubble)-width,CGRectGetMidX(bubble)-width/2));
        y=MAX(0,CGRectGetMinY(bubble)-height-3);
    }
    x=MAX(0,MIN(x,MAX(0,cellW-width)));
    y=MAX(0,MIN(y,MAX(0,cellH-height)));
    label.frame=CGRectMake(x,y,width,height);[cell bringSubviewToFront:label];
}
static BOOL TKCellBind(id self,SEL cmd,id vm) {
    IMP orig=OrigIMP(TKCellClass,cmd);BOOL accepted=orig?((BOOL(*)(id,SEL,id))orig)(self,cmd,vm):NO;
    objc_setAssociatedObject(self,&kTKBoundModelKey,accepted?vm:nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if(accepted&&[self isKindOfClass:UIView.class]) {
        gTKMessageBinds++;if(!gTKVisibleCells)gTKVisibleCells=[NSHashTable weakObjectsHashTable];[gTKVisibleCells addObject:self];
        id record=TKRecordForCell(self);if(record)TKRememberMessage(record);else gTKRecordReadFailures++;
        TKUpdateRecallLabel(self);
    }
    return accepted;
}
static void TKCellBindVM(id self,SEL cmd,id vm) {
    // 1.0.8: TIM 4.1.0.81 实际用属性赋值 setViewModel: 绑定数据（bindViewModel: 从未被调用）。
    IMP orig=OrigIMP(TKCellClass,cmd);
    if(orig)((void(*)(id,SEL,id))orig)(self,cmd,vm);
    if(vm&&[self isKindOfClass:UIView.class]) {
        objc_setAssociatedObject(self,&kTKBoundModelKey,vm,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        gTKMessageBinds++;if(!gTKVisibleCells)gTKVisibleCells=[NSHashTable weakObjectsHashTable];[gTKVisibleCells addObject:self];
        id record=TKRecordForCell(self);if(record)TKRememberMessage(record);else gTKRecordReadFailures++;
        TKUpdateRecallLabel(self);
    }
}
static void TKCellClear(id self,SEL cmd) {
    IMP orig=OrigIMP(TKCellClass,cmd);objc_setAssociatedObject(self,&kTKBoundModelKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    UILabel *label=objc_getAssociatedObject(self,&kTKRecallLabelKey);label.hidden=YES;
    if(orig)((void(*)(id,SEL))orig)(self,cmd);
}
static void TKCellLayout(id self,SEL cmd) {
    IMP orig=OrigIMP(TKCellClass,cmd);if(orig)((void(*)(id,SEL))orig)(self,cmd);
    if([self isKindOfClass:UIView.class])TKUpdateRecallLabel(self);
}
static void TKRefreshRecallLabels(void) {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{TKRefreshRecallLabels();});return;}
    for(UIView *cell in gTKVisibleCells.allObjects)TKUpdateRecallLabel(cell);
}
