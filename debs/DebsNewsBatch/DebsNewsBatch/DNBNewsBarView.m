//
//  DNBNewsBarView.m
//  DebsNewsBatch
//

#import "DNBNewsBarView.h"

@interface DNBNewsBarView ()
@property (nonatomic, strong) UILabel *titleLabel;
@property (nonatomic, strong) UIButton *leftButton;    /* 取消 / 停止 / 完成 */
@property (nonatomic, strong) UIButton *allButton;
@property (nonatomic, strong) UIButton *downloadButton;
@property (nonatomic, strong) UIStackView *actions;
@property (nonatomic, strong) UILongPressGestureRecognizer *longPress;
@end

@implementation DNBNewsBarView

- (instancetype)initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        self.layer.cornerRadius = 12;
        self.layer.cornerCurve = kCACornerCurveContinuous;

        _titleLabel = [UILabel new];
        _titleLabel.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
        _titleLabel.textColor = [UIColor whiteColor];
        _titleLabel.numberOfLines = 1;
        _titleLabel.adjustsFontSizeToFitWidth = YES;
        _titleLabel.minimumScaleFactor = 0.75;
        _titleLabel.userInteractionEnabled = NO;

        UIFont *small = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
        _leftButton = [self pillButtonWithTitle:@"取消" font:small];
        _allButton = [self pillButtonWithTitle:@"全选" font:small];
        _downloadButton = [self pillButtonWithTitle:@"下载" font:[UIFont systemFontOfSize:15 weight:UIFontWeightBold]];
        _downloadButton.backgroundColor = [UIColor colorWithWhite:1 alpha:0.24];

        _actions = [[UIStackView alloc] initWithArrangedSubviews:@[ _titleLabel, _leftButton, _allButton, _downloadButton ]];
        _actions.axis = UILayoutConstraintAxisHorizontal;
        _actions.alignment = UIStackViewAlignmentCenter;
        _actions.spacing = 8;
        _actions.translatesAutoresizingMaskIntoConstraints = NO;
        [self addSubview:_actions];

        [_actions.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:14].active = YES;
        [_actions.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-10].active = YES;
        [_actions.topAnchor constraintEqualToAnchor:self.topAnchor].active = YES;
        [_actions.bottomAnchor constraintEqualToAnchor:self.bottomAnchor].active = YES;
        [_titleLabel setContentHuggingPriority:1 forAxis:UILayoutConstraintAxisHorizontal];

        _longPress = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(handleLongPress:)];
        [self addGestureRecognizer:_longPress];
        [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(handleTap)]];

        [self applyTintColor:nil];
        self.state = DNBNewsBarStateIdle;
    }
    return self;
}

- (UIButton *)pillButtonWithTitle:(NSString *)title font:(UIFont *)font
{
    UIButton *b = [UIButton buttonWithType:UIButtonTypeSystem];
    [b setTitle:title forState:UIControlStateNormal];
    b.titleLabel.font = font;
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
    b.layer.cornerRadius = 9;
    b.layer.cornerCurve = kCACornerCurveContinuous;
    b.contentEdgeInsets = UIEdgeInsetsMake(5, 11, 5, 11);
    [b addTarget:self action:@selector(handleButton:) forControlEvents:UIControlEventTouchUpInside];
    [b.heightAnchor constraintGreaterThanOrEqualToConstant:30].active = YES;
    return b;
}

- (void)applyTintColor:(UIColor *)tint
{
    self.backgroundColor = tint ?: [UIColor systemBlueColor];
}

#pragma mark - 状态

- (void)setState:(DNBNewsBarState)state
{
    _state = state;
    BOOL selecting = (state == DNBNewsBarStateSelecting || state == DNBNewsBarStateRunning);
    self.leftButton.hidden = !selecting;
    self.allButton.hidden = (state != DNBNewsBarStateSelecting);
    self.downloadButton.hidden = selecting;
    self.allButton.enabled = (state == DNBNewsBarStateSelecting);
    if (state == DNBNewsBarStateSelecting) {
        self.leftButton.hidden = NO;
        [self.leftButton setTitle:@"取消" forState:UIControlStateNormal];
    }
    [self refreshSelectionTitles];
}

- (void)setSelectedCount:(NSInteger)count
{
    _selectedCount = count;
    [self refreshSelectionTitles];
}

- (void)setAllSelected:(BOOL)allSelected
{
    _allSelected = allSelected;
    self.allButton.enabled = (self.state == DNBNewsBarStateSelecting) && allSelected == NO;
    [self.allButton setTitle:allSelected ? @"已全选" : @"全选" forState:UIControlStateNormal];
    self.allButton.alpha = self.allButton.isEnabled ? 1.0 : 0.55;
}

- (void)refreshSelectionTitles
{
    switch (self.state) {
        case DNBNewsBarStateIdle:
            self.titleLabel.text = @"新闻批量下载 · 选择软件包";
            self.downloadButton.hidden = YES;
            break;
        case DNBNewsBarStateSelecting: {
            NSInteger n = self.selectedCount;
            self.titleLabel.text = (n == 0) ? @"勾选要下载的新闻条目" : [NSString stringWithFormat:@"已选 %ld 条", (long)n];
            self.downloadButton.hidden = NO;
            self.downloadButton.enabled = (n > 0);
            self.downloadButton.alpha = (n > 0) ? 1.0 : 0.55;
            break;
        }
        case DNBNewsBarStateRunning:
            self.downloadButton.hidden = YES;
            self.allButton.hidden = YES;
            [self.leftButton setTitle:@"停止" forState:UIControlStateNormal];
            break;
        case DNBNewsBarStateDone:
            self.leftButton.hidden = YES;
            self.allButton.hidden = YES;
            self.downloadButton.hidden = NO;
            [self.downloadButton setTitle:@"完成" forState:UIControlStateNormal];
            break;
        default:
            break;
    }
}

- (void)showProgressDone:(NSInteger)done total:(NSInteger)total success:(NSInteger)success failed:(NSInteger)failed
{
    self.titleLabel.text = [NSString stringWithFormat:@"下载中 %ld/%ld · 成功 %ld 失败 %ld", (long)done, (long)total, (long)success, (long)failed];
}

- (void)showSummarySuccess:(NSInteger)success failed:(NSInteger)failed skipped:(NSInteger)skipped
{
    self.state = DNBNewsBarStateDone;
    self.titleLabel.text = [NSString stringWithFormat:@"完成：成功 %ld · 失败 %ld · 跳过 %ld", (long)success, (long)failed, (long)skipped];
    [self applyTintColor:(failed > 0 ? [UIColor systemOrangeColor] : [UIColor systemGreenColor])];
}

#pragma mark - 事件

- (void)handleTap
{
    switch (self.state) {
        case DNBNewsBarStateIdle:
        case DNBNewsBarStateDone:
            [self.delegate barDidTapBody:self];
            break;
        default:
            break;
    }
}

- (void)handleLongPress:(UILongPressGestureRecognizer *)g
{
    if (g.state == UIGestureRecognizerStateBegan) {
        [self.delegate barDidLongPress:self];
    }
}

- (void)handleButton:(UIButton *)sender
{
    if (self.state == DNBNewsBarStateDone) {
        [self.delegate barDidTapDone:self];
        return;
    }
    if (sender == self.leftButton) {
        if (self.state == DNBNewsBarStateRunning) {
            [self.delegate barDidTapStop:self];
        } else {
            [self.delegate barDidTapCancel:self];
        }
        return;
    }
    if (sender == self.allButton) {
        [self.delegate barDidTapSelectAll:self];
        return;
    }
    if (sender == self.downloadButton) {
        [self.delegate barDidTapDownload:self];
    }
}

@end
