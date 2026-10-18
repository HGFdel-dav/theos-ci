// TWContainerListController.h — 「分身应用（容器）」与「Arc 图标顺序」两个列表页。
//
// 0.4.0 的模型：一个应用有几个容器，Arc 菜单里就有几个图标（角标区分），
// 点哪个就用哪个容器打开。所以这里管的是 TWKeyCraneContainers（每个容器一条）
// 与 TWKeyCraneAppList（Arc 里的显示顺序）。
#import <UIKit/UIKit.h>

// 分身应用（容器）：列出/增删应用与容器的对应关系。
@interface TWContainerListController : UITableViewController
@end

// Arc 图标顺序：拖动排序 TWKeyCraneAppList。
@interface TWArcOrderController : UITableViewController
@end