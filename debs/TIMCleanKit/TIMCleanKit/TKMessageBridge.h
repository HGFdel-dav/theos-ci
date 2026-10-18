// TIM 4.1.0.81 Objective-C bridge methods verified in kernel-targets.json.
// Included after message cache helpers. 2.0: 被拦截的对方撤回会归档消息文本到沙盒 Application Support/TIMCleanKit/recall-archive.json（上限300条），其余场景不落盘。
static NSString *const TKListenerClass=@"_TtC13GuildNTKernel20SWIKernelMsgListener";
static void TKRefreshRecallLabels(void);
static unsigned long long gTKRecallBlocked,gTKRepeatFailures,gTKMessageBinds;
static void TKArchiveRecalledRecord(id record); /* 2.0: 定义于 TKCellBridge.h，撤回内容磁盘归档 */
static void TKRestoreRecord(id record) {
    NSDictionary *saved=TKCachedMessage(record);NSArray *elements=saved[@"elements"];if(!elements.count)return;
    IMP original=TKOriginalIMP(TKRecord(@"OCMsgRecord",@selector(setElements:)));
    if(original)((void(*)(id,SEL,id))original)(record,@selector(setElements:),elements);
    original=TKOriginalIMP(TKRecord(@"OCMsgRecord",@selector(setMsgType:)));
    if(original)((void(*)(id,SEL,int))original)(record,@selector(setMsgType:),[saved[@"msgType"] intValue]);
    original=TKOriginalIMP(TKRecord(@"OCMsgRecord",@selector(setRecallTime:)));
    if(original)((void(*)(id,SEL,long long))original)(record,@selector(setRecallTime:),0);
    __atomic_fetch_add(&gTKRecallRestores,1,__ATOMIC_RELAXED);
}
static void TKBridgeRecall(id self,SEL cmd,int chat,id peer,unsigned long long seq) {
    IMP orig=OrigIMP(TKListenerClass,cmd);
    if(TKAntiRecallEnabled()&&[peer isKindOfClass:NSString.class]&&seq) {
        TKRecallFactsLoad();
        NSString *fact=TKRecallFactKey(chat,peer,seq);
        TKRecallFactAdd(fact);
        TKRecallEvent([NSString stringWithFormat:@"onMsgRecall 记录:%@(仅诊断,标记由setRecallTime≈now驱动)",fact]);
    }
    /* 2.0.7: 不再用 seq 在缓存里匹配并标记——真机实锤 seq 与 msgSeq 有偏移，
       "哈哈好的"被撤回却标到"好好说说"。标记统一由 setRecallTime(value≈now) 驱动。
       这里只刷新，让刚被标记的 cell 立刻出标签。 */
    if(TKAntiRecallEnabled())TKRefreshRecallLabels();
    if(orig)((void(*)(id,SEL,int,id,unsigned long long))orig)(self,cmd,chat,peer,seq);
}
static NSArray *TKPreserveUpdateRecords(id records) {
    if(![records isKindOfClass:NSArray.class])return records;
    Class recordClass=NSClassFromString(@"OCMsgRecord");
    NSMutableArray *result=[NSMutableArray arrayWithCapacity:[records count]];
    for(id record in records) {
        if(![record isKindOfClass:recordClass]){[result addObject:record];continue;}
        // 2.0.3: 只要确认被撤回（事实记录/缓存标记）就处理——有快照恢复内容，无快照用归档重建；都没有也保留标记
        if(TKAntiRecallEnabled()&&TKWasRecalled(record)) {
            TKMarkRecall(record);
            if(TKHasCachedContent(record)) {
                TKRestoreRecord(record);
                id old=TKCachedMessage(record)[@"record"];
                if(old){TKMarkRecall(old);TKRestoreRecord(old);[result addObject:old];}else [result addObject:record];
            } else {
                TKRestoreFromArchive(record);
                [result addObject:record];
            }
        } else {TKRememberMessage(record);[result addObject:record];}
    }
    return [result copy];
}
static void TKBridgeUpdate(id self,SEL cmd,id records) {
    IMP orig=OrigIMP(TKListenerClass,cmd);id preserved=TKPreserveUpdateRecords(records);
    if(orig)((void(*)(id,SEL,id))orig)(self,cmd,preserved);
    TKRefreshRecallLabels();
}
static void TKBridgeReceive(id self,SEL cmd,id records) {
    IMP orig=OrigIMP(TKListenerClass,cmd);
    // Cache synchronously before the app's own callback consumes or replaces the records.
    if([records isKindOfClass:NSArray.class])for(id record in records)
        if([record isKindOfClass:NSClassFromString(@"OCMsgRecord")])TKRememberMessage(record);
    if(orig)((void(*)(id,SEL,id))orig)(self,cmd,records);
}
static void TKBridgeDelete(id self,SEL cmd,id contact,id ids) {
    IMP orig=OrigIMP(TKListenerClass,cmd);id filtered=ids;
    if(TKAntiRecallEnabled()&&[ids isKindOfClass:NSArray.class]) {
        int chat=(int)TKScalar(contact,@"chatType","i");id peer=TKObjectCall(contact,@"peerUid");
        NSMutableArray *keep=[NSMutableArray new];
        for(id mid in ids) {
            if(![mid isKindOfClass:NSNumber.class]||![peer isKindOfClass:NSString.class]){[keep addObject:mid];continue;}
            NSString *identity=[NSString stringWithFormat:@"%d:%@:%lld",chat,peer,[mid longLongValue]];
            [gTKCacheLock lock];BOOL recalled=[gTKRecalledIDs containsObject:identity];[gTKCacheLock unlock];
            if(!recalled)[keep addObject:mid];
        }
        if(!keep.count)return;filtered=[keep copy];
    }
    if(orig)((void(*)(id,SEL,id,id))orig)(self,cmd,contact,filtered);
}
static BOOL TKNativeRepeat(id record) {
    if(!prefBool(kEnabled,YES)||!prefBool(kRepeater,YES))return NO;
    Class rc=NSClassFromString(@"OCMsgRecord");if(![record isKindOfClass:rc])return NO;
    NSString *peer=TKObjectCall(record,@"peerUid"),*guild=TKObjectCall(record,@"guildId");
    Class cc=NSClassFromString(@"OCContact");SEL factory=NSSelectorFromString(@"ContactWithChatType:peerUid:guildId:");
    if(![peer isKindOfClass:NSString.class]||!peer.length||!TKMethodABI(cc,factory,"@36@0:8i16@20@28"))return NO;
    id contact=((id(*)(id,SEL,int,id,id))objc_msgSend)(cc,factory,(int)TKScalar(record,@"chatType","i"),peer,guild);
    NSArray *elements=TKObjectCall(record,@"elements");if(![elements isKindOfClass:NSArray.class]||!elements.count)return NO;
    NSMutableString *text=[NSMutableString new];BOOL onlyText=YES;
    for(id element in elements) {
        id te=TKObjectCall(element,@"textElement"),value=TKObjectCall(te,@"content");
        if(![value isKindOfClass:NSString.class]){onlyText=NO;break;}[text appendString:value];
    }
    if(onlyText&&text.length) {
        // Create fresh text elements: avoids copied message IDs, sender and @-mention metadata.
        Class ec=NSClassFromString(@"OCMsgElement"),tc=NSClassFromString(@"OCTextElement");
        id te=[[tc alloc] init],element=[[ec alloc] init];
        SEL content=NSSelectorFromString(@"setContent:"),type=NSSelectorFromString(@"setElementType:"),setter=NSSelectorFromString(@"setTextElement:");
        Class facade=NSClassFromString(@"QQMsgService");id service=TKObjectCall(facade,@"getInstance");
        SEL send=NSSelectorFromString(@"sendMsgWithOCContactAndOCMsgElements:msgElems:msgAttributeInfos:callBack:");
        if(!TKMethodABI(te,content,"v24@0:8@16")||!TKMethodABI(element,type,"v20@0:8i16")||!TKMethodABI(element,setter,"v24@0:8@16")||!TKMethodABI(service,send,"v48@0:8@16@24@32@?40"))return NO;
        ((void(*)(id,SEL,id))objc_msgSend)(te,content,[text copy]);
        ((void(*)(id,SEL,int))objc_msgSend)(element,type,1);
        ((void(*)(id,SEL,id))objc_msgSend)(element,setter,te);
        ((void(*)(id,SEL,id,id,id,id))objc_msgSend)(service,send,contact,@[element],nil,nil);
        gTKRepeats++;return YES;
    }
    // TIM's forwarding handles supported pictures and other non-text elements.
    return TKRepeatRecord(record);
}
