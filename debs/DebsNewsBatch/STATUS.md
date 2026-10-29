# STATUS

## 0.2.0（当前）— 改成人家的样式：新闻页底部条 + 列表内勾选

用户实测 0.1.0（悬浮按钮 + 独立面板）后反馈：不要另开面板，人家是新闻页底部一条「新闻批量下载 · 选择软件包」，点开直接在新闻列表里选。

### 本轮改动

- 新增 `DNBNewsBarView`：底部条（初始 / 选择 / 下载中 / 完成 四态）
- 新增 `DNBRowTarget`：盖在新闻行上的勾选控件（空心圈 → 选中变蓝勾），盖住行 = 选择态不触发跳转
- 新增 `DNBSelectionController`：发现新闻页的列表、贴覆盖层、收集勾选、全选（走 dataSource 覆盖不可见行）、编排下载、跟随滚动
- 新增 `DNBHook`：只用 runtime 的挂钩封装（`method_setImplementation`），**不链接 substrate**
- `Tweak.m`：不再默认挂悬浮按钮，改为挂 `viewDidAppear` / `viewWillDisappear`（标题 == 新闻 或类名含 HostingController 才尝试），离开即摘
- 旧面板保留为长按蓝条的兜底入口
- `DNBLogic.h` 新增 `dnb_parse_row_label` / `dnblogic_row_matches`（纯 C，可测），单测 94 → 129 项
- `check.py` 守卫 143 → 195 项（含「不链接 substrate」「全选走 dataSource」「离开必定摘除」等）

### 已验证

- 纯 C 单测 129 项通过；静态守卫 195 项通过（本地）

### 未验证（等真机）

- 列表内勾选的观感、勾选圈位置、滚动跟手、SwiftUI 单元格取词是否稳定
- 全选枚举新建 cell 的取词成功率
- 日志定位：`debsnewsbatch.log` 里会有「新闻页已挂载 scroll=… 行数=…」；行数 0 = 取词失败
