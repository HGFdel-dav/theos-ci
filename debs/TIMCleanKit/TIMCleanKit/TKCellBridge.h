#import <mach-o/dyld.h>
#import <mach-o/loader.h>
#import <malloc/malloc.h>
// Verified cell bind selector and strong reference fields from Swift field descriptors.
static NSString *const TKCellClass=@"_TtC13NTAIOBaseCell17NTAIOBaseCellView";
static BOOL TKIsUsableObjectPtr(id p) {
    // 1.0.12: 布局回调读取任意外部对象前的指针合法性检查，防止对悬垂/非对象内存做 ARC retain（objc_retain 崩溃）。
    if(!p)return NO;
    uintptr_t v=(uintptr_t)p;
    if(v % sizeof(void*))return NO;
    size_t sz=malloc_size((__bridge const void*)p);
    if(!sz)return NO;
    Class isa=object_getClass(p);
    if(!isa)return NO;
    uintptr_t isav=(uintptr_t)isa;
    if(isav % sizeof(void*) || isav<0x1000)return NO;
    return YES;
}
static char kTKBoundModelKey,kTKRecallLabelKey,kTKLabelRecordKey,kTKLabelRetryKey;
static NSHashTable *gTKVisibleCells;
static unsigned long long gTKRecordReadFailures;
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
    if(!TKIsUsableObjectPtr(record))return nil;
    return [record isKindOfClass:NSClassFromString(@"OCMsgRecord")]?record:nil;
}
static id TKStrongKnownField(id object,const char *field) {
    if(!object)return nil;
    Ivar ivar=class_getInstanceVariable(object_getClass(object),field);
    if(!ivar)return nil;
    ptrdiff_t offset=ivar_getOffset(ivar);
    if(offset<0 || (size_t)offset+sizeof(id)>class_getInstanceSize(object_getClass(object)))return nil;
    // Only called for the two fields proved to be strong Objective-C references.
    id value=object_getIvar(object,ivar);
    return TKIsUsableObjectPtr(value)?value:nil;
}
static id TKFirstIvarOfKind(id object,Class wanted) {
    // 1.0.9: 兜底——遍历实例可枚举 ivar，直取目标类型（Swift 存储属性对 ObjC runtime 的可见性因类而异）。
    // 1.0.12: 只读类型编码以 '@' 开头的对象 ivar，并校验指针合法；跳过值类型/悬垂，修复布局中 objc_retain 崩溃。
    if(!object||!wanted)return nil;
    Class cls=object_getClass(object);
    while(cls) {
        unsigned count=0;Ivar *ivars=class_copyIvarList(cls,&count);
        for(unsigned i=0;i<count;i++) {
            const char *enc=ivar_getTypeEncoding(ivars[i]);
            if(!enc||enc[0]!='@')continue;               // 只读对象引用 ivar
            id value=object_getIvar(object,ivars[i]);
            if(!TKIsUsableObjectPtr(value))continue;     // 悬垂/垃圾指针直接跳过
            if([value isKindOfClass:wanted]){free(ivars);return value;}
        }
        if(ivars)free(ivars);
        cls=class_getSuperclass(cls);
    }
    return nil;
}
static id TKRecordForCell(UIView *cell) {
    if(!cell)return nil;
    id vm=objc_getAssociatedObject(cell,&kTKBoundModelKey);
    if(!vm)vm=TKStrongKnownField(cell,"viewModel");
    if(!vm)vm=TKStrongKnownField(cell,"_viewModel");
    Class vmClass=NSClassFromString(@"NTAIOBaseCell.NTAIOBaseCellViewModel");
    if(!vmClass)vmClass=NSClassFromString(@"_TtC13NTAIOBaseCell22NTAIOBaseCellViewModel");
    if(!vm)vm=TKFirstIvarOfKind(cell,vmClass);
    id record=TKStrongKnownField(vm,"record");
    if(!record)record=TKStrongKnownField(vm,"_record");
    if(!record)record=TKSwiftRecordField(vm);
    if(!record)record=TKFirstIvarOfKind(vm,NSClassFromString(@"OCMsgRecord"));
    if([record isKindOfClass:NSClassFromString(@"OCMsgRecord")])return record;
    return nil;
}
static void TKEnsureCellBinding(UIView *cell) {
    // 1.0.9: 布局时尝试建立 cell→viewModel 关联（TIM 的 bindViewModel:/setViewModel: 均不触发时兜底），供双击复读使用。
    if(!cell||objc_getAssociatedObject(cell,&kTKBoundModelKey))return;
    id vm=TKStrongKnownField(cell,"viewModel");
    if(!vm)vm=TKStrongKnownField(cell,"_viewModel");
    Class vmClass=NSClassFromString(@"NTAIOBaseCell.NTAIOBaseCellViewModel");
    if(!vmClass)vmClass=NSClassFromString(@"_TtC13NTAIOBaseCell22NTAIOBaseCellViewModel");
    if(!vm)vm=TKFirstIvarOfKind(cell,vmClass);
    if(vm)objc_setAssociatedObject(cell,&kTKBoundModelKey,vm,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
// ============ 1.0.15: 双击复读 —— 气泡文本 ↔ 消息缓存匹配（Swift cell 拿不到 record 的替代路径） ============
static int gTKTextProbeWritten;
static unsigned long long gTKLayoutAssociations;
static unsigned long long gTKLayoutMatchFails;
static unsigned long long gTKNoRecordNoCell;
static unsigned long long gTKNoRecordAssocFail;
static unsigned long long gTKNoRecordMatchFail;
static NSString *TKCellBubbleText(UIView *cell) {
    // 1.0.17: TIM 气泡文本是自定义渲染控件，无 UILabel/UITextView——
    // 收集 cell 子树中最长的 UILabel/UITextView 文本与 accessibility 文本，取最长者。
    if(!cell)return nil;
    NSMutableArray *scan=[NSMutableArray arrayWithObject:cell];
    NSString *best=nil;NSUInteger bestLen=0;
    for(NSUInteger i=0;i<scan.count&&i<600;i++) {
        UIView *view=scan[i];
        if(!view.hidden&&view.alpha>.01) {
            if([view isKindOfClass:UITextView.class]) {
                NSString *t=((UITextView*)view).text;
                if(t.length>=3&&t.length>bestLen){bestLen=t.length;best=t;}
            } else if([view isKindOfClass:UILabel.class]) {
                NSString *t=((UILabel*)view).text;
                if(t.length>=3&&t.length>bestLen){bestLen=t.length;best=t;}
            } else {
                NSString *ax=view.accessibilityLabel;
                if([ax isKindOfClass:NSString.class]&&ax.length>bestLen){bestLen=ax.length;best=ax;}
                NSArray *el=view.accessibilityElements;
                if([el isKindOfClass:NSArray.class])for(id e in el) {
                    if([e isKindOfClass:UIAccessibilityElement.class]) {
                        NSString *t=[(UIAccessibilityElement*)e accessibilityLabel];
                        if([t isKindOfClass:NSString.class]&&t.length>bestLen){bestLen=t.length;best=t;}
                    }
                }
            }
        }
        if(view.subviews.count&&scan.count<800)[scan addObjectsFromArray:view.subviews];
    }
    return best;
}
static NSString *TKRecordTextOfElements(NSArray *elements) {
    // 与 TKNativeRepeat 一致：textElement.content 优先，text 兜底。
    if(![elements isKindOfClass:NSArray.class])return nil;
    NSMutableString *all=[NSMutableString new];
    for(id e in elements) {
        if(!e)continue;
        id te=TK_performObject(e,@"textElement");
        id value=te?TK_performObject(te,@"content"):nil;
        if(![value isKindOfClass:NSString.class])value=te?TK_performObject(te,@"text"):nil;
        if(![value isKindOfClass:NSString.class])value=TK_performObject(e,@"text");
        if([value isKindOfClass:NSString.class])[all appendString:value];
        else {
            // 1.0.20 探针：记录读不出文本的元素结构
            if(!__atomic_load_n(&gTKTextProbeWritten,__ATOMIC_RELAXED)) {
                __atomic_store_n(&gTKTextProbeWritten,1,__ATOMIC_RELAXED);
                const char *cls=te?class_getName(object_getClass(te)):"none";
                const char *ecls=class_getName(object_getClass(e));
                const char *elem0=elements.count?class_getName(object_getClass(elements[0])):"none";
                NSString *probe=[NSString stringWithFormat:@"ecls=%s elem0=%s teCls=%s teCount=%lu",ecls,elem0,cls,(unsigned long)[elements count]];
                strlcpy(gTKTextProbeBuf,probe.UTF8String,sizeof(gTKTextProbeBuf));   // 1.0.22: 拷进静态缓冲（原写法保存临时串内部指针，释放后读取崩）
                __atomic_store_n(&gTKTextProbe,gTKTextProbeBuf,__ATOMIC_RELAXED);
            }
        }
    }
    return all.length?all:nil;
}

// 2.0: 撤回消息磁盘归档——拦截到对方撤回时把消息文本快照写入沙盒;
// 独立于进程内存缓存，供后续版本做冷启动/历史撤回恢复。最多保留最近 300 条，后台队列写盘，失败静默。
static void TKArchiveRecalledRecord(id record) {
    NSString *identity=TKMessageIdentity(record);if(!identity)return;
    id elements=TKObjectCall(record,@"elements");
    NSString *text=TKRecordTextOfElements([elements isKindOfClass:NSArray.class]?elements:@[]);
    NSDictionary *context=@{@"text":text?:@"",@"time":@([[NSDate date] timeIntervalSince1970]),@"v":@2}; /* 2.0.7: v>=2 的归档才参与重启后标签恢复 */
    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND,0),^{
        @try {
            NSString *base=[NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory,NSUserDomainMask,YES) firstObject];
            if(!base)return;
            NSString *dir=[base stringByAppendingPathComponent:@"TIMCleanKit"];
            [[NSFileManager defaultManager] createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL];
            NSString *path=[dir stringByAppendingPathComponent:@"recall-archive.json"];
            NSMutableDictionary *archive=[[NSDictionary dictionaryWithContentsOfFile:path] mutableCopy];
            if(!archive)archive=[NSMutableDictionary dictionary];
            archive[identity]=context;
            if(archive.count>300) {
                NSArray *sorted=[archive keysSortedByValueUsingComparator:^NSComparisonResult(NSDictionary *a,NSDictionary *b){ return [a[@"time"] compare:b[@"time"]]; }];
                for(NSUInteger i=0;i+300<sorted.count;i++)[archive removeObjectForKey:sorted[i]];
            }
            NSData *data=[NSJSONSerialization dataWithJSONObject:archive options:0 error:NULL];
            [data writeToFile:path atomically:YES];
        } @catch(NSException *ignored) {}
    });
}
static id TKRecordMatchingTextInCache(UIView *cell) {
    // 在最近 500 条缓存消息里找文本与气泡完全一致的最后一条（最近者优先）。
    NSString *want=TKCellBubbleText(cell);
    if(!want.length)return nil;
    [gTKCacheLock lock];
    id found=nil;
    for(id identity in gTKRecentMessages.reverseObjectEnumerator) {
        NSDictionary *saved=gTKMessageCache[identity];
        id record=saved?[saved objectForKey:@"record"]:nil;
        NSString *have=TKRecordTextOfElements(saved?[saved objectForKey:@"elements"]:nil);
        if(have.length) {
            if([have isEqualToString:want]){found=record;break;}
            // 1.0.19: 模糊匹配只对长文本生效（>=8 字），短文本（如红包"恭喜发财"、问候语）必须完全一致，避免误匹配
            if(want.length>=8&&have.length>=8&&([want containsString:have]||[have containsString:want])){found=record;break;}
        }
    }
    [gTKCacheLock unlock];
    return found;
}

static const void *kTKCellRecordKey=&kTKCellRecordKey;
static void TKCellSetRecord(UIView *cell,id record){if(cell)objc_setAssociatedObject(cell,kTKCellRecordKey,record,OBJC_ASSOCIATION_RETAIN_NONATOMIC);}
static id TKCellRecord(UIView *cell){return cell?objc_getAssociatedObject(cell,kTKCellRecordKey):nil;}
static void TKScanViewsForRedPacket(UIView *v,BOOL *found) {   // 1.0.23: 递归扫描子视图找红包视图类
    if(*found)return;
    for(UIView *s in v.subviews){
        if(*found)return;
        NSString *cn=NSStringFromClass(object_getClass(s));
        if([cn rangeOfString:@"RedPacket"].location!=NSNotFound ||
           [cn rangeOfString:@"RedEnvelope"].location!=NSNotFound ||
           [cn rangeOfString:@"Hongbao"].location!=NSNotFound ||
           [cn rangeOfString:@"RedGift"].location!=NSNotFound ||
           [cn rangeOfString:@"Envelope"].location!=NSNotFound) { *found=YES; return; }
        TKScanViewsForRedPacket(s,found);
    }
}
static BOOL TKCellHasRedPacketView(UIView *cell) {   // 1.0.23: 视图级红包检测——文本关联错位时也不给红包贴"拦截撤回"标签
    BOOL found=NO;
    TKScanViewsForRedPacket(cell,&found);
    return found;
}
static void TKUpdateRecallLabel(UIView *cell);
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
static NSString *TKLabelBriefText(id record) {
    id els=TKObjectCall(record,@"elements");
    NSString *t=TKRecordTextOfElements([els isKindOfClass:NSArray.class]?els:@[]);
    if(!t.length)return @"?";
    return t.length>8?[t substringToIndex:8]:t;
}
static void TKUpdateRecallLabel(UIView *cell) {
    if(!cell || !NSThread.isMainThread)return;
    id record=TKRecordForCell(cell);
    BOOL highConfidence=(record!=nil);                     // 2.0.4: 从 cell→viewModel 直读=高可信
    if(!record)record=TKCellRecord(cell);                  // 1.0.17: 布局时已文本匹配并关联
    if(!record)record=TKRecordMatchingTextInCache(cell);
    UILabel *label=objc_getAssociatedObject(cell,&kTKRecallLabelKey);
    // 1.0.19: 红包消息不贴标签——QQ 红包无法撤回，此前"恭喜发财"短文本模糊匹配会误贴到红包上。
    if(record && redElementFromRecord(record)) {label.hidden=YES;return;}
    if(TKCellHasRedPacketView(cell)){if(label)label.hidden=YES;return;}   // 1.0.23: 视图级兜底——关联错位时也不给红包贴标签
    BOOL recalled=record?TKWasRecalled(record):NO; /* 2.0.9: 判定一次，下面日志复用 */
    if(!TKAntiRecallEnabled()||!record||!recalled) { /* 2.0.3: 确认撤回就一定显示——不再要求有缓存内容 */
        /* 2.0.4: 修误贴——标签若属于"另一条消息"（当前匹配 record 不同于标签记录的那条），必须隐藏；
           仅当仍是同一条消息（偶发判定波动）才保留不动。 */
        id labelRecord=label?objc_getAssociatedObject(label,&kTKLabelRecordKey):nil;
        if(label&&!label.hidden&&record&&labelRecord==record)return;
        if(label&&!label.hidden){__atomic_fetch_add(&gTKLabelHidden,1,__ATOMIC_RELAXED);TKLabelDiag([NSString stringWithFormat:@"隐:%@%@",record?TKLabelBriefText(record):@"无记录",highConfidence?@"(高可信)":@"(文本匹配)"]);}
        else if(!record&&TKAntiRecallEnabled()) TKLabelDiag(@"未贴:record为空(绑定失败)");
        else if(record&&!recalled) TKLabelDiag([NSString stringWithFormat:@"未贴:未标记 %@%@",TKLabelBriefText(record),highConfidence?@"(高可信)":@"(文本匹配)"]);
        label.hidden=YES;if(label)label.frame=CGRectZero;return;
    }
    if(!label) {
        label=[UILabel new];label.text=@"拦截撤回";label.font=[UIFont systemFontOfSize:10 weight:UIFontWeightSemibold];
        label.textColor=UIColor.systemOrangeColor;label.backgroundColor=[UIColor.secondarySystemBackgroundColor colorWithAlphaComponent:.92];
        label.textAlignment=NSTextAlignmentCenter;label.layer.cornerRadius=6;label.clipsToBounds=YES;label.userInteractionEnabled=NO;
        [cell addSubview:label];objc_setAssociatedObject(cell,&kTKRecallLabelKey,label,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    label.hidden=YES;label.frame=CGRectZero;   /* 2.0.4: 先隐藏并归零，锚定成功后才显示——杜绝 cell 复用残留帧错位 */
    CGFloat width=70,height=18;
    CGFloat cellW=cell.bounds.size.width,cellH=cell.bounds.size.height;
    if(cellW<120||cellH<30){TKUpdateRecallLabelRetry(cell);return;}
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
    if(CGRectIsEmpty(bubble)) {label.hidden=YES;TKUpdateRecallLabelRetry(cell);return;} // 识别失败宁可不放；布局未完成时 0.2s 后补标
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
    label.hidden=NO;   /* 2.0.4: 锚定成功才显示 */
    objc_setAssociatedObject(label,&kTKLabelRecordKey,record,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    __atomic_fetch_add(&gTKLabelShown,1,__ATOMIC_RELAXED);
    TKLabelDiag([NSString stringWithFormat:@"贴:%@%@",TKLabelBriefText(record),highConfidence?@"(高可信)":@"(文本匹配)"]);
}
// 2.0.1: 保证双击复读手势能被收到——窗口级手势会被聊天列表/气泡控件吃掉（真机 gestureTaps=0），
// 改为直接挂到每个消息 cell 上（cancelsTouchesInView=NO 不影响原有点击）。
static void TKEnsureCellGesture(UIView *cell) {
    if(!cell)return;
    static char kTKGestureCell;
    if(objc_getAssociatedObject(cell,&kTKGestureCell))return;
    Class targetClass=NSClassFromString(@"TIMCKGestureTarget");
    if(!targetClass)return;
    id target=nil;
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    target=[targetClass performSelector:NSSelectorFromString(@"shared")];
#pragma clang diagnostic pop
    if(!target)return;
    UITapGestureRecognizer *g=[[UITapGestureRecognizer alloc] initWithTarget:target action:NSSelectorFromString(@"onMessageDoubleTap:")];
    g.numberOfTapsRequired=2;g.numberOfTouchesRequired=1;g.cancelsTouchesInView=NO;g.delaysTouchesBegan=NO;g.delaysTouchesEnded=NO;
    g.delegate=target;
    [cell addGestureRecognizer:g];
    objc_setAssociatedObject(cell,&kTKGestureCell,@YES,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}
static BOOL TKCellBind(id self,SEL cmd,id vm) {
    IMP orig=OrigIMP(TKCellClass,cmd);BOOL accepted=orig?((BOOL(*)(id,SEL,id))orig)(self,cmd,vm):NO;
    objc_setAssociatedObject(self,&kTKBoundModelKey,accepted?vm:nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    if(accepted&&[self isKindOfClass:UIView.class]) {
        gTKMessageBinds++;if(!gTKVisibleCells)gTKVisibleCells=[NSHashTable weakObjectsHashTable];[gTKVisibleCells addObject:self];
        id record=TKRecordForCell(self);if(record)TKRememberMessage(record);else gTKRecordReadFailures++;
        TKUpdateRecallLabel(self);
        TKEnsureCellGesture((UIView*)self);
    }
    return accepted;
}
static void TKCellBindVM(id self,SEL cmd,id vm) {
    // 1.0.8: TIM 4.1.0.81 实际用属性赋值 setViewModel: 绑定数据（bindViewModel: 从未被调用）。
    IMP orig=OrigIMP(TKCellClass,cmd);
    if(orig)((void(*)(id,SEL,id))orig)(self,cmd,vm);
    if(vm&&[self isKindOfClass:UIView.class]) {
        objc_setAssociatedObject(self,kTKCellRecordKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);   // 1.0.23: 复用绑定新消息先清旧文本关联
        UILabel *oldLbl=objc_getAssociatedObject(self,&kTKRecallLabelKey);oldLbl.hidden=YES;   // 1.0.23: 清除复用残留标签（TIM 复用不总走 prepareForReuse）
        objc_setAssociatedObject(self,&kTKBoundModelKey,vm,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        gTKMessageBinds++;if(!gTKVisibleCells)gTKVisibleCells=[NSHashTable weakObjectsHashTable];[gTKVisibleCells addObject:self];
        id record=TKRecordForCell(self);if(record)TKRememberMessage(record);else gTKRecordReadFailures++;
        TKUpdateRecallLabel(self);
        TKEnsureCellGesture((UIView*)self);
    }
}
static void TKCellClear(id self,SEL cmd) {
    IMP orig=OrigIMP(TKCellClass,cmd);objc_setAssociatedObject(self,&kTKBoundModelKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(self,kTKCellRecordKey,nil,OBJC_ASSOCIATION_RETAIN_NONATOMIC);   // 1.0.21: 复用时清除文本关联
    UILabel *label=objc_getAssociatedObject(self,&kTKRecallLabelKey);label.hidden=YES;
    if(orig)((void(*)(id,SEL))orig)(self,cmd);
}
static void TKCellLayout(id self,SEL cmd) {
    IMP orig=OrigIMP(TKCellClass,cmd);if(orig)((void(*)(id,SEL))orig)(self,cmd);
    if([self isKindOfClass:UIView.class]) {
        TKEnsureCellBinding(self);
        id assoc=TKRecordMatchingTextInCache(self);
        if(assoc){TKCellSetRecord(self,assoc);gTKLayoutAssociations++;}else if(!TKCellRecord(self))gTKLayoutMatchFails++;   // 1.0.22: 匹配失败不再覆盖旧的有效关联（修复标签闪没）

        if(!gTKVisibleCells)gTKVisibleCells=[NSHashTable weakObjectsHashTable];
        [gTKVisibleCells addObject:self];
        TKUpdateRecallLabel(self);
    }
}
static void TKCollectMessageCells(UIView *root,NSMutableArray *out) {
    for(UIView *v in root.subviews) {
        NSString *cls=NSStringFromClass(v.class);
        if([cls containsString:@"Cell"]||[cls containsString:@"Bubble"])[out addObject:v];
        if(v.subviews.count)TKCollectMessageCells(v,out);
    }
}
static void TKRefreshRecallLabels(void) {
    if(!NSThread.isMainThread){dispatch_async(dispatch_get_main_queue(),^{TKRefreshRecallLabels();});return;}
    /* 2.0.5: 全窗口扫描——原只刷 gTKVisibleCells（登记不全/翻旧消息的 cell 不在里面），导致"要退出重进才显示标签" */
    NSMutableArray *cells=[NSMutableArray array];
    for(UIWindow *window in UIApplication.sharedApplication.windows) if(window.subviews.count)TKCollectMessageCells(window,cells);
    for(UIView *cell in cells)TKUpdateRecallLabel(cell);
    for(UIView *cell in gTKVisibleCells.allObjects)TKUpdateRecallLabel(cell);
}
