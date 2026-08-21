//
//  DKProgressUnderline.xm
//  清除进度条底边压着的那条纯黑细垫层。视频撑满后它会横在视频与底栏之间形成割裂。
//
//  全项目唯一一处 AWEDPlayerProgressContainerView 的 hook：详情页全屏与首页/朋友页全屏
//  面对的是同一条黑边、同一套识别与还原逻辑，只是作用域来源不同，故合并在此。
//

#import "DKVideoFullscreen.h"
#import "DKVideoFeedTable.h"
#import "DouyinHeaders.h"
#import "DKUtils.h"
#import <objc/runtime.h>
#import <math.h>

// 覆盖 @3x 像素对齐与进度条收放时的亚像素漂移。
static const CGFloat kDKUnderlineTolerance = 0.5;

static char kDKUnderlineColorKey;
static char kDKUnderlineOpaqueKey;
static char kDKProgressLiftTransformKey;

static NSHashTable<UIView *> *gLiftedProgressViews;

// 忽略已有 transform，读取抖音实际排版出的 identity frame。
// 这样重复 layout 时不会把我们自己的抬升再次算进判断。
static CGRect DKProgressIdentityFrame(UIView *view) {
    if (!view.superview) return view.frame;

    CGFloat width = CGRectGetWidth(view.bounds);
    CGFloat height = CGRectGetHeight(view.bounds);
    CGFloat minX = view.center.x - width * view.layer.anchorPoint.x;
    CGFloat minY = view.center.y - height * view.layer.anchorPoint.y;
    return CGRectMake(minX, minY, width, height);
}

static CGFloat DKProgressFullscreenLift(UIView *progress) {
    if (!progress || !DKVideoFullscreenOn()) return 0.0;

    UIView *table = DKFeedTableForView(progress);
    NSNumber *original = DKVideoFeedTableOriginalHeight(table);
    UIView *contentView = DKCellContentView(progress);
    if (!table || !original || !contentView) return 0.0;

    CGFloat fullHeight = CGRectGetHeight(contentView.bounds);
    CGFloat originalHeight = original.doubleValue;
    if (fullHeight <= originalHeight + kDKUnderlineTolerance
        || CGRectGetHeight(table.bounds) < fullHeight - kDKUnderlineTolerance) {
        return 0.0;
    }

    UIView *parent = progress.superview;
    if (!parent) return 0.0;

    CGRect identity = DKProgressIdentityFrame(progress);
    CGRect inContent = [parent convertRect:identity toView:contentView];
    if (CGRectGetMaxY(inContent) <= originalHeight + kDKUnderlineTolerance) return 0.0;

    // 与 HUD/直播 chrome 使用同一高度差：把全屏后新增的底部空间整体抵消，
    // 让官方进度条回到全屏前的底部位置，避开 Home Indicator 手势区。
    return fullHeight - originalHeight;
}

static BOOL DKApplyProgressLift(UIView *view, CGFloat lift) {
    if (!view || lift <= kDKUnderlineTolerance) return NO;

    NSValue *baseline = objc_getAssociatedObject(view, &kDKProgressLiftTransformKey);
    if (!baseline) {
        baseline = [NSValue valueWithCGAffineTransform:view.transform];
        objc_setAssociatedObject(view, &kDKProgressLiftTransformKey, baseline,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        [gLiftedProgressViews addObject:view];
    }

    CGAffineTransform target = baseline.CGAffineTransformValue;
    target.ty -= lift;
    if (!CGAffineTransformEqualToTransform(view.transform, target)) {
        view.transform = target;
    }
    return YES;
}

static void DKRestoreProgressLift(UIView *view) {
    NSValue *baseline = objc_getAssociatedObject(view, &kDKProgressLiftTransformKey);
    if (!baseline) return;

    CGAffineTransform target = baseline.CGAffineTransformValue;
    if (!CGAffineTransformEqualToTransform(view.transform, target)) {
        view.transform = target;
    }
    objc_setAssociatedObject(view, &kDKProgressLiftTransformKey, nil,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

static void DKRestoreAllProgressLifts(void) {
    for (UIView *view in gLiftedProgressViews.allObjects) {
        DKRestoreProgressLift(view);
    }
    [gLiftedProgressViews removeAllObjects];
}

#pragma mark - 清屏进度条

static AFDPureModePageContainerViewController *DKPureModeControllerForView(UIView *view) {
    for (UIView *cursor = view; cursor; cursor = cursor.superview) {
        UIResponder *responder = cursor.nextResponder;
        for (NSUInteger i = 0; responder && i < 4; i++, responder = responder.nextResponder) {
            if ([responder isKindOfClass:AFDPureModePageContainerViewController.class]) {
                return (AFDPureModePageContainerViewController *)responder;
            }
        }
    }
    return nil;
}

static BOOL DKPureModeActiveForView(UIView *view) {
    AFDPureModePageContainerViewController *controller = DKPureModeControllerForView(view);
    return controller && controller.viewIfLoaded.window && !controller.isEnteringPureMode;
}

static CGFloat DKPureModeControlTop(UIView *root) {
    CGFloat top = CGFLOAT_MAX;
    NSMutableArray<UIView *> *pending = [NSMutableArray arrayWithObject:root];
    while (pending.count > 0) {
        UIView *view = pending.lastObject;
        [pending removeLastObject];

        NSString *name = NSStringFromClass(view.class);
        if ([name hasPrefix:@"AFDRoundRectangleBox"]
            && !view.hidden && view.alpha > 0.01
            && CGRectGetWidth(view.bounds) >= 40.0
            && CGRectGetHeight(view.bounds) >= 30.0
            && CGRectGetHeight(view.bounds) <= 80.0) {
            CGRect frame = [view.superview convertRect:view.frame toView:root];
            if (CGRectGetMaxY(frame) > CGRectGetHeight(root.bounds) * 0.55) {
                top = MIN(top, CGRectGetMinY(frame));
            }
        }
        [pending addObjectsFromArray:view.subviews];
    }

    if (top != CGFLOAT_MAX) return top;
    return CGRectGetHeight(root.bounds) - root.safeAreaInsets.bottom - 56.0;
}

// 清屏时仍只调整官方进度条容器；不创建覆盖层，也不并行安装第二套容器变换。
static CGFloat DKPureModeProgressLift(UIView *progress) {
    if (!progress || !DKVideoFullscreenOn() || !DKPureModeActiveForView(progress)) return 0.0;

    AFDPureModePageContainerViewController *controller = DKPureModeControllerForView(progress);
    UIView *root = controller.viewIfLoaded;
    UIView *parent = progress.superview;
    if (!root || !parent) return 0.0;

    CGRect identity = DKProgressIdentityFrame(progress);
    CGRect inRoot = [parent convertRect:identity toView:root];
    CGFloat targetMaxY = DKPureModeControlTop(root) - 12.0;
    CGFloat lift = CGRectGetMaxY(inRoot) - targetMaxY;
    return lift > kDKUnderlineTolerance ? lift : 0.0;
}

// 签名：容器直属 + 普通 UIView + 满宽 + 极薄 + 底色不透明。
//
// 不用「贴容器底边」做锚点：beta6 实测该层是 {0, 115.1, 428, 2}、容器高 200，
// 它贴的是进度条轨道底边（轨道 y 111.1 + 高 4 = 115.1）而不是容器底边，
// 位置随进度条收放而漂移。改用「底色不透明」——容器里另一条细线是 rgba(1,1,1,0.15)
// 的半透明分隔线，透明度足以把两者分开，且不依赖任何坐标。
static BOOL DKIsUnderlineView(UIView *view, UIView *container) {
    if (object_getClass(view) != [UIView class]) return NO;

    UIColor *color = view.backgroundColor;
    if (!color || CGColorGetAlpha(color.CGColor) < 0.99) return NO;

    CGRect frame = view.frame;
    CGFloat height = CGRectGetHeight(frame);
    return height > 0.0
        && height <= 2.0 + kDKUnderlineTolerance
        && fabs(CGRectGetMinX(frame)) <= kDKUnderlineTolerance
        && fabs(CGRectGetWidth(frame) - CGRectGetWidth(container.bounds)) <= kDKUnderlineTolerance;
}

static void DKClearUnderline(UIView *view) {
    if (!objc_getAssociatedObject(view, &kDKUnderlineColorKey)) {
        objc_setAssociatedObject(view, &kDKUnderlineColorKey, view.backgroundColor,
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(view, &kDKUnderlineOpaqueKey, @(view.opaque),
                                 OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

    if (![view.backgroundColor isEqual:UIColor.clearColor]) {
        view.backgroundColor = UIColor.clearColor;
    }
    if (view.opaque) view.opaque = NO;
}

static void DKRestoreUnderline(UIView *view) {
    UIColor *color = objc_getAssociatedObject(view, &kDKUnderlineColorKey);
    if (!color) return;

    view.backgroundColor = color;
    view.opaque = [objc_getAssociatedObject(view, &kDKUnderlineOpaqueKey) boolValue];
    objc_setAssociatedObject(view, &kDKUnderlineColorKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    objc_setAssociatedObject(view, &kDKUnderlineOpaqueKey, nil, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

%hook AWEDPlayerProgressContainerView

- (void)layoutSubviews {
    %orig;

    AFDPureModePageContainerViewController *pureMode = DKPureModeControllerForView(self);
    CGFloat lift = pureMode ? DKPureModeProgressLift(self) : DKProgressFullscreenLift(self);
    if (lift > kDKUnderlineTolerance) {
        DKApplyProgressLift(self, lift);
    } else {
        DKRestoreProgressLift(self);
    }

    BOOL enabled = DKVideoFullscreenOn();

    for (UIView *view in self.subviews) {
        // 已接管的视图只按开关决定去留：进度条收起时签名会漂移，据此还原会让黑边重现。
        if (objc_getAssociatedObject(view, &kDKUnderlineColorKey)) {
            enabled ? DKClearUnderline(view) : DKRestoreUnderline(view);
        } else if (enabled && DKIsUnderlineView(view, self)) {
            DKClearUnderline(view);
        }
    }
}

%end

%hook AWEFeedProgressSlider

- (void)setAlpha:(CGFloat)alpha {
    UIView *slider = (UIView *)self;
    %orig(DKPureModeActiveForView(slider) ? 1.0 : alpha);
}

- (void)setHidden:(BOOL)hidden {
    UIView *slider = (UIView *)self;
    %orig(DKPureModeActiveForView(slider) ? NO : hidden);
}

%end

%ctor {
    gLiftedProgressViews = [NSHashTable weakObjectsHashTable];
    DKVideoFullscreenRegisterRestore(DKRestoreAllProgressLifts);
}
