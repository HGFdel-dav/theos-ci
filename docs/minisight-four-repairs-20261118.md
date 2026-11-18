# MiniSight 0.8.47 — 四项本地补修

用户本批已明确本地修复，并独立批准“这几个问题修复了，就推送”，覆盖当前App与插件本地全部检查后的提交推送/CI；不包含安装、开麦、设备MCP、注销、重启或整IPA下载。余额与10.58GB存储盘点继续暂停。

## 本地内容
- 移除重新暴露整张图集的UIImageView getter，通过专用恢复接口依当前布局裁切帧。父层空、同图重设/冷建窗、坏帧/停止/清单切换可恢复；合法动作海报/静态图/旧图集与多宠物素材保留。
- 恢复桌宠本体宽活动区、可接近屏幕四边，只防完整身体出屏。普通桌宠不永久预留气泡/安全区；实际视觉旋转四角边缘适配，屏幕内部动效原样，不移动命中层。胶囊/审批保旧safe/headroom/按钮取消，普通文字尺寸保存和viewport恢复只作相邻保护，不能反向缩宠物活动区。
- 双端音乐符号按Apple dyld-955 __TEXT.vmaddr定位共享缓存，不错误要求fileoff为0；仍保代码/数据分类、读执行权限与原始dlsym调用指针。仅当前同步歌词、无歌名替代、五播放器/严格匹配/锁屏/隐私/退避全保。
- 配套App正常权限inactive与真实后台分离；pending启用遇真后台/lock/protected/style失效，不能回前台复活旧请求；共用Speech权限只增入口/Speech后/mic后三处协作取消。允许正常inactive保存意图但不伪造active采音。插件名字生产代码未改，旧ACK/锁屏/后台/草稿/手动发送保留。

## 本地结果
A基线a9e3d7e833aa1377b0ef34a5fc97e704a950904d（原build323）；P基线9fbc15d8669d91997c059c1ecedc6cf3e5a16070（原0.8.46）。47普通入口exit0（36含nativeSKIP）+9严格缺Apple工具exit1拒放+2diffcheck，共58全部符合预期；不是47原生通过。旧布局1600029（原1600001不删）、实际C边界449462+3compiled行为负例、7相邻便携入口过。最终独立审查LOCAL_READY_NATIVE_PENDING/blockers=[]，42个审查快照SHA均匹配。

保持ORT/VAD隔离/固定模型、Key/额度/签到、原音频协调器/VoiceBridge、Resources/Panel/动作库/录屏/视频与平台差异不整覆盖。所有新测试要求原生baseline编译成功并执行后，负例编译成功再被指定断言拒绝，不以编译失败充负例。

## 未验与证据
本批Apple Swift/ObjC/完整iOS15.5构建、最终DEB签名载荷、安装加载/冷启动素材/实际活动区/歌词和名字效果尚未验证。源码条件修复不保证用户手机当时根因已闭合；实装版本本轮未重读，不能把发布当实装。

证据：shared/openminis/local-reviews/pet-four-repairs-20261118/{SCOPE,LOCAL-RESULT,ATLAS-REPAIR,MUSIC-REPAIR,WAKE-AUDIT-REPAIR,BUBBLE-AUDIT-REPAIR,FINAL-INTEGRATION-REVIEW}.md及对应JSON。发布后准确head/run/attempt、完整CI和DEB/代码页/Source哈希另存shared/openminis/releases/Minis-0.8.47-20261118。冻结通过后按本批授权A GITHUB_TOKEN/P GITHUB_TOKEN_QQ分别推送与验包，安装/注销/重启各另问。
