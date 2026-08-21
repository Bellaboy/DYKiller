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
#import "DKRuntimeDiagnostics.h"
#import <objc/runtime.h>
#import <math.h>

// 覆盖 @3x 像素对齐与进度条收放时的亚像素漂移。
static const CGFloat kDKUnderlineTolerance = 0.5;
// 清屏时异常坐标会产生整屏级别的位移；超过根视图一半直接拒绝，等待下一次稳定布局。
static const CGFloat kDKPureProgressMaxLiftRatio = 0.5;

static char kDKUnderlineColorKey;
static char kDKUnderlineOpaqueKey;
static char kDKProgressLiftTransformKey;

static NSHashTable<UIView *> *gLiftedProgressViews;
static BOOL DKPureModeActiveForView(UIView *view);

static Class DKPureModeControllerClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cls = NSClassFromString(@"AFDPureModePageContainerViewController");
    });
    return cls;
}

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
    DKRuntimeDiagnosticsObserveState(@"video.progress", @"lifted", @{
        @"pure_mode": @(DKPureModeActiveForView(view)),
        @"lift": @(round(lift * 2.0) / 2.0)
    });
    return YES;
}

static void DKRestoreProgressLift(UIView *view) {
    NSValue *baseline = objc_getAssociatedObject(view, &kDKProgressLiftTransformKey);
    if (!baseline) return;

    CGAffineTransform target = baseline.CGAffineTransformValue;
    if (!CGAffineTransformEqualToTransform(view.transform, target)) {
        view.transform = target;
    }
    DKRuntimeDiagnosticsRecordEvent(@"video.progress", @"restored", @{});
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
            Class controllerClass = DKPureModeControllerClass();
            if (controllerClass && [responder isKindOfClass:controllerClass]) {
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

static NSString *DKProgressOwnerChain(UIView *progress) {
    NSMutableArray<NSString *> *classes = [NSMutableArray array];
    for (UIView *cursor = progress; cursor && classes.count < 8; cursor = cursor.superview) {
        [classes addObject:NSStringFromClass(cursor.class) ?: @"?"];
    }
    return [classes componentsJoinedByString:@">"];
}

static NSString *DKProgressSubviewSummary(UIView *progress) {
    NSMutableArray<NSString *> *items = [NSMutableArray array];
    for (UIView *subview in progress.subviews) {
        if (items.count >= 8) break;
        [items addObject:[NSString stringWithFormat:@"%@:%@:%@:%@",
                          NSStringFromClass(subview.class) ?: @"?",
                          NSStringFromCGRect(subview.frame),
                          subview.hidden ? @"H" : @"V",
                          subview.alpha <= 0.01 ? @"0" : @"1"]];
    }
    return [items componentsJoinedByString:@";"];
}

static NSDictionary *DKProgressGeometryFields(UIView *progress, CGFloat lift, BOOL pureMode) {
    NSMutableDictionary *fields = [@{
        @"instance_id": [NSString stringWithFormat:@"%p", progress],
        @"progress_class": NSStringFromClass(progress.class) ?: @"?",
        @"parent_class": progress.superview ? NSStringFromClass(progress.superview.class) : @"(nil)",
        @"owner_chain": DKProgressOwnerChain(progress),
        @"subviews": DKProgressSubviewSummary(progress),
        @"window_attached": @(progress.window != nil),
        @"controller_found": @(DKPureModeControllerForView(progress) != nil),
        @"main_feed": @(DKVideoIsMainFeedView(progress)),
        @"pure_mode": @(pureMode),
        @"lift": @(round(lift * 2.0) / 2.0),
        @"bounds_width": @(round(CGRectGetWidth(progress.bounds) * 2.0) / 2.0),
        @"bounds_height": @(round(CGRectGetHeight(progress.bounds) * 2.0) / 2.0),
        @"alpha": @(round(progress.alpha * 100.0) / 100.0),
        @"hidden": @(progress.hidden),
        @"transform_a": @(round(progress.transform.a * 1000.0) / 1000.0),
        @"transform_b": @(round(progress.transform.b * 1000.0) / 1000.0),
        @"transform_c": @(round(progress.transform.c * 1000.0) / 1000.0),
        @"transform_d": @(round(progress.transform.d * 1000.0) / 1000.0),
        @"transform_tx": @(round(progress.transform.tx * 2.0) / 2.0),
        @"transform_ty": @(round(progress.transform.ty * 2.0) / 2.0),
    } mutableCopy];

    AFDPureModePageContainerViewController *controller = DKPureModeControllerForView(progress);
    UIView *table = DKFeedTableForView(progress);
    NSNumber *original = DKVideoFeedTableOriginalHeight(table);
    fields[@"table_original_height"] = original
        ? @(round(original.doubleValue * 2.0) / 2.0)
        : @0.0;
    UIView *root = controller.viewIfLoaded;
    UIView *parent = progress.superview;
    if (!root || !parent || ![progress isDescendantOfView:root]) return fields;

    CGRect identity = DKProgressIdentityFrame(progress);
    CGRect inRoot = [parent convertRect:identity toView:root];
    fields[@"root_width"] = @(round(CGRectGetWidth(root.bounds) * 2.0) / 2.0);
    fields[@"root_height"] = @(round(CGRectGetHeight(root.bounds) * 2.0) / 2.0);
    fields[@"safe_bottom"] = @(round(root.safeAreaInsets.bottom * 2.0) / 2.0);
    fields[@"identity_y"] = @(round(CGRectGetMinY(identity) * 2.0) / 2.0);
    fields[@"identity_height"] = @(round(CGRectGetHeight(identity) * 2.0) / 2.0);
    fields[@"root_y"] = @(round(CGRectGetMinY(inRoot) * 2.0) / 2.0);
    fields[@"root_bottom"] = @(round(CGRectGetMaxY(inRoot) * 2.0) / 2.0);
    return fields;
}

// 清屏时仍只调整官方进度条容器；不扫描不稳定的控件树，也不并行安装第二套容器变换。
static CGFloat DKPureModeProgressLift(UIView *progress) {
    if (!progress || !DKVideoFullscreenOn() || !DKPureModeActiveForView(progress)) return 0.0;

    AFDPureModePageContainerViewController *controller = DKPureModeControllerForView(progress);
    UIView *root = controller.viewIfLoaded;
    UIView *parent = progress.superview;
    if (!root || !parent || ![progress isDescendantOfView:root]) {
        DKRuntimeDiagnosticsObserveState(@"video.progress", @"pure_progress_outside_controller_tree", @{});
        return 0.0;
    }

    CGRect identity = DKProgressIdentityFrame(progress);
    CGRect inRoot = [parent convertRect:identity toView:root];
    if (CGRectGetMinY(inRoot) < -CGRectGetHeight(root.bounds)
        || CGRectGetMaxY(inRoot) > CGRectGetHeight(root.bounds) * 1.5) {
        DKRuntimeDiagnosticsObserveState(@"video.progress", @"pure_progress_invalid_geometry", @{});
        return 0.0;
    }

    CGFloat targetMaxY = CGRectGetHeight(root.bounds) - root.safeAreaInsets.bottom - 84.0;
    CGFloat lift = CGRectGetMaxY(inRoot) - targetMaxY;
    if (!isfinite(lift) || lift <= kDKUnderlineTolerance) return 0.0;

    CGFloat maximum = CGRectGetHeight(root.bounds) * kDKPureProgressMaxLiftRatio;
    if (maximum <= 0.0 || lift > maximum) {
        DKRuntimeDiagnosticsObserveState(@"video.progress", @"pure_progress_rejected", @{
            @"root_height": @(round(CGRectGetHeight(root.bounds) * 2.0) / 2.0),
            @"root_bottom": @(round(CGRectGetMaxY(inRoot) * 2.0) / 2.0),
            @"target_bottom": @(round(targetMaxY * 2.0) / 2.0),
            @"lift": @(round(lift * 2.0) / 2.0),
        });
        return 0.0;
    }
    return lift;
}

static void DKUpdateProgressLayout(UIView *progress) {
    AFDPureModePageContainerViewController *pureMode = DKPureModeControllerForView(progress);
    BOOL pureActive = pureMode && DKPureModeActiveForView(progress);

    // isEnteringPureMode 只表示转场尚未稳定。此时不要把已经应用的位移恢复为 0，
    // 否则进入清屏会先回到底部，根布局完成后又跳回目标位置。
    if (pureMode && !pureActive) {
        DKRuntimeDiagnosticsObserveState(@"video.progress", @"pure_transition_preserved", @{
            @"instance_id": [NSString stringWithFormat:@"%p", progress],
            @"hidden": @(progress.hidden),
            @"transform_ty": @(round(progress.transform.ty * 2.0) / 2.0),
        });
        return;
    }

    CGFloat lift = pureActive ? DKPureModeProgressLift(progress)
                              : DKProgressFullscreenLift(progress);

    DKRuntimeDiagnosticsObserveState(@"video.progress", @"layout_snapshot",
                                     DKProgressGeometryFields(progress, lift, pureActive));
    if (lift > kDKUnderlineTolerance) {
        DKApplyProgressLift(progress, lift);
    } else {
        DKRestoreProgressLift(progress);
    }
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

    DKUpdateProgressLayout(self);

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

#pragma mark - 清屏根布局同步

// 某些视频/图集的官方进度条在清屏切换时不会再次触发自己的 layoutSubviews，
// 但它们仍然会在 AFDPureModePageContainerViewController 根布局中完成最终位置。
// 这里统一扫当前清屏根下的官方容器，只重复使用 DKUpdateProgressLayout，不创建第二套控件。
static void DKSyncPureModeProgressDescendants(UIView *root) {
    if (!root) return;

    Class progressClass = NSClassFromString(@"AWEDPlayerProgressContainerView");
    if (progressClass && [root isKindOfClass:progressClass]) {
        DKUpdateProgressLayout(root);
    }

    for (UIView *subview in root.subviews) {
        DKSyncPureModeProgressDescendants(subview);
    }
}

%hook AFDPureModePageContainerViewController

- (void)viewDidLayoutSubviews {
    %orig;
    DKSyncPureModeProgressDescendants(self.viewIfLoaded);
}

%end

%ctor {
    gLiftedProgressViews = [NSHashTable weakObjectsHashTable];
    DKVideoFullscreenRegisterRestore(DKRestoreAllProgressLifts);
}
