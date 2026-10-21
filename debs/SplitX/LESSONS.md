# SplitX 必须遵守的教训清单（来自 Twin 的实战）

## 闪退
- 子页一律真 PSListController；`init` 只调 `[super init]`，**绝不覆写 `initForContentSize:`**（曾导致无限递归、511 帧栈溢出）。
- 只要覆写了 `numberOfSections`/`numberOfRows`，就必须同时提供**等量的真实 specifier**；否则父类查分组高度会数组越界。
- 设置进程里取表格用 `self.table`；`PSListController` 没有 `self.tableView`（曾 `doesNotRecognizeSelector` 崩溃）。

## 点不了 / 卡住
- 不建全屏触摸层；热区只覆盖真实触发区域，其余 `hitTest` 返回 nil。
- 调试图层必须 `userInteractionEnabled = NO` 且 `hitTest` 返回 nil。
- 总开关关闭时：反注册手势，且把识别器 `enabled = NO`（即使系统拒绝移除）。

## 盖住 / 对齐
- 有图标的行才缩进（`indentationLevel = 1`），无图标行必须为 0，否则整页出现空栏。
- 图标绘制在独立列，文字不再二次手动挪动，避免双重偏移。
- 滑杆行：系统已画标题/数值时**不再添加第二套标签**；整数区间不显示小数；轨道放在标题下方，行高留够。

## 配置
- 启动时不得强制把总开关写回开启；关闭只停功能，不删配置。
- 不重写原版引擎的偏好清单（`applications`/`customActions`）；需要过滤只在自家显示层做。
- 两边原版设置 Bundle 原样随包安装，点进去用它们自己的控制器，不重画。

## 发布
- 每次推送前：静态语法检查 + plist/资源校验 + 包内路径核验；编译成功不等于真机可用。
