//
//  DKVideoGeometry.xm
//  视频几何的唯一拦截点，以及「视频全屏」这一个开关的注册处。
//
//  全项目**只剩这一个**全局 UIView 钩子（`setFrame:`）。分派按写入方的归属控制器，
//  不按视图在哪棵树里——归属是写入方自己的身份，不会串台：
//    · AWEDPlayerViewController_Merge  → 视频容器，一套规则通吃首页/朋友页/好友聊天/搜索/作品页；
//    · AWEPlayInteractionViewController → HUD，只有撑高过的表需要钉位，其余一律放行。
//
//  为什么这一处必须是写入时拦截、不能改成事后纠正：九份导出实测
//  `HUD setFrame=128~148` 对 `布局后兜底=4~11`，写入时拦截承担 95% 以上。
//  改成事后纠正等于把一百多次修正压给布局回合，必然可见跳动。
//
//  图文不在这里：它的缩放入口是 RichContentContainerViewController 的 updateShrinkState:，
//  一个精准钩子覆盖全部图文类型，见 DKVideoPageChrome.xm。
//

#import "DouyinHeaders.h"
#import "DKVideoFullscreen.h"
#import "DKVideoFeedTable.h"
#import "DKGlassGuard.h"
#import "DKKeys.h"
#import "DKSettings.h"
#import "DKUtils.h"
#import <math.h>

// 高/宽达到此阈值才算「比例达标」，可以拉满整屏；低比例竖屏与横屏保持容器自然尺寸。
static const CGFloat kDKFullscreenMinAspect = 1.70;
static const long long kDKAwemeTypeImage = 68;
// 覆盖 @3x 像素对齐带来的亚像素漂移。
static const CGFloat kDKGeometryTolerance = 0.5;
// 关闭开关时要立刻还原的分支回调；分支不多，固定容量即可。
static void (*gRestoreHooks[4])(void);
static NSUInteger gRestoreCount = 0;

BOOL DKVideoFullscreenOn(void) {
    return DKPrefBool(DKKeyVideoFullscreen);
}

BOOL DKCommentFreezeOn(void) {
    return DKGlassOSAvailable() && DKPrefBool(DKKeyCommentGlass);
}

void DKVideoFullscreenRegisterRestore(void (*restore)(void)) {
    if (!restore || gRestoreCount >= sizeof(gRestoreHooks) / sizeof(gRestoreHooks[0])) return;
    gRestoreHooks[gRestoreCount++] = restore;
}

#pragma mark - 类缓存

static Class DKMergeClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cls = NSClassFromString(@"AWEDPlayerViewController_Merge"); });
    return cls;
}

static Class DKPlayInteractionClass(void) {
    static Class cls;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ cls = NSClassFromString(@"AWEPlayInteractionViewController"); });
    return cls;
}

BOOL DKVideoIsMainFeedView(UIView *view) {
    if (!view) return NO;

    UIView *table = [view isKindOfClass:UITableView.class]
        ? view
        : DKFeedTableForView(view);
    Class feedClass = NSClassFromString(@"AWEFeedTableView");
    return table && feedClass && [table isKindOfClass:feedClass];
}

CGFloat DKVideoViewportHeightForView(UIView *view) {
    UIWindow *window = view.window;
    UIView *coordinateView = view.superview ?: view;
    if (!window || window.windowLevel != UIWindowLevelNormal || !coordinateView) return 0.0;

    CGRect viewport = [window convertRect:window.bounds toView:coordinateView];
    CGFloat height = CGRectGetHeight(viewport);
    return isfinite(height) && height > 0.0 ? height : 0.0;
}

#pragma mark - 视频容器的钉位目标

// 主 feed 的视频容器统一拉满窗口，内容本身仍由抖音的比例策略决定是否留黑边或裁切。
// 非主 feed 页面保留比例限制，避免详情/浮层等特殊播放器被错误撑成整屏。
static BOOL DKMergeCanCoverScreen(AWEDPlayerViewController_Merge *merge) {
    if (![merge isKindOfClass:DKMergeClass()]) return NO;

    AWEAwemeModel *model = merge.model;
    if (model.awemeType == kDKAwemeTypeImage) return NO;
    if (merge.hasInlandscape) return NO;
    if ([merge respondsToSelector:@selector(isInLandscapeFeedStatus)]
        && [merge isInLandscapeFeedStatus]) {
        return NO;
    }

    AWEVideoModel *video = model.video;
    double width = video.width.doubleValue;
    double height = video.height.doubleValue;
    return width <= 0.0
        || height <= 0.0
        || (height / width) >= kDKFullscreenMinAspect;
}

// 视频容器的唯一几何规则：
//   · 主 feed 视频全屏 → 钉到窗口 viewport，画面层覆盖物理屏幕；
//   · 其他页面视频全屏 + 比例达标 → 钉到 Cell 满高；
//   · 其余情况           → 钉到容器自然满幅，也就是「不许被评论区缩放平移」。
//
// 第二条对横屏同样成立：抖音展开评论区时直接改 frame 把横屏缩小上移（实测
// {{47.79,−128.07},{332.43,654.76}}，bounds 与 frame 同尺寸、不是 transform），
// 智能背景色的承载层会跟着漂移。拉满与冻结是两件事，只有拉满需要看比例。
//
// 「要不要拉满」是 model 的函数，而 model 可能晚于 frame 写入才绑定；
// 补算在 DKVideoPageChrome.xm 的 willDisplay 里。
CGRect DKVideoContainerTargetFrame(UIView *view) {
    if (!DKVideoFullscreenOn() && !DKCommentFreezeOn()) return CGRectNull;

    // 作用域只到主窗口：浮层窗口（画中画、横屏播放器）自带一整套 Merge / PlayVideo 层级，
    // 与 feed 里那套长得一样，钉成满幅会把小窗撑成盖住整页的全屏播放器。
    // 入窗前的 frame 是布局半成品，不能在这里改写；入窗后的控制器布局钩子会补一次。
    UIWindow *window = view.window;
    if (!window) return CGRectNull;
    if (window && window.windowLevel != UIWindowLevelNormal) return CGRectNull;

    UIView *parent = view.superview;
    CGFloat width = CGRectGetWidth(parent.bounds);
    CGFloat height = CGRectGetHeight(parent.bounds);
    if (width <= 0.0 || height <= 0.0) return CGRectNull;

    if (DKVideoFullscreenOn() && DKVideoIsMainFeedView(view)) {
        // 主 feed 的视频层始终铺到窗口 viewport。视频比例只影响视频内容的
        // aspect-fit/fill，不再决定容器是否为 799pt；HUD 仍由
        // DKFeedHUDAdjustFrame 钉回撑高前高度，二者在几何上解耦。
        CGFloat viewportHeight = DKVideoViewportHeightForView(view);
        if (viewportHeight > height) height = viewportHeight;
    } else if (DKVideoFullscreenOn()
               && DKMergeCanCoverScreen((AWEDPlayerViewController_Merge *)view.nextResponder)) {
        CGFloat full = DKFullCellHeight(view);
        if (full > height) height = full;
    }
    return CGRectMake(0.0, 0.0, width, height);
}

BOOL DKRectsClose(CGRect lhs, CGRect rhs) {
    return fabs(CGRectGetMinX(lhs) - CGRectGetMinX(rhs)) <= kDKGeometryTolerance
        && fabs(CGRectGetMinY(lhs) - CGRectGetMinY(rhs)) <= kDKGeometryTolerance
        && fabs(CGRectGetWidth(lhs) - CGRectGetWidth(rhs)) <= kDKGeometryTolerance
        && fabs(CGRectGetHeight(lhs) - CGRectGetHeight(rhs)) <= kDKGeometryTolerance;
}

// 钉位目标恒在原点，所以来意的 origin 不在原点就是有人要把视频整体挪走——评论区缩放是唯一来源。
// 与「容器还没铺满」那种写入区分开：评论面板开合、拖拽、缩放进出全屏时视频不动，就是这一条在扛，
// 39.8.0 实测每页 27~36 次。
static NSUInteger gMoveWrites = 0;

NSString *DKVideoContainerMoveStats(void) {
    return [NSString stringWithFormat:@"挪动写入被拦=%lu", (unsigned long)gMoveWrites];
}

// 这条钩子挂在全局 UIView 上，抖音每一次 frame 写入都会经过，守卫必须极便宜：
// 只取一次 nextResponder、最多两次类型判断，不是目标立刻放行。
// 视频表自己的撑高不走这里：它有类可挂，直接在 DKVideoFeedTable.xm 里拦。
static CGRect DKAdjustFrame(UIView *view, CGRect frame) {
    UIResponder *owner = view.nextResponder;
    if (!owner) return CGRectNull;

    if ([owner isKindOfClass:DKMergeClass()]) {
        CGRect target = DKVideoContainerTargetFrame(view);
        if (CGRectIsNull(target) || DKRectsClose(frame, target)) return CGRectNull;
        if (fabs(CGRectGetMinX(frame)) > kDKGeometryTolerance
            || fabs(CGRectGetMinY(frame)) > kDKGeometryTolerance) {
            gMoveWrites++;
        }
        return target;
    }
    if ([owner isKindOfClass:DKPlayInteractionClass()]) {
        return DKFeedHUDAdjustFrame(view, frame);
    }
    return CGRectNull;
}

#pragma mark - 全局 UIView 钩子

%hook UIView

- (void)setFrame:(CGRect)frame {
    CGRect adjusted = DKAdjustFrame(self, frame);
    if (CGRectIsNull(adjusted)) {
        %orig;
        return;
    }
    %orig(adjusted);
}

%end

#pragma mark - 设置项注册

%ctor {
    DKSettingsRegisterItem(@"视频", ^AWESettingItemModel *{
        AWESettingItemModel *item = DKMakeSwitch(
            DKKeyVideoFullscreen,
            @"视频全屏",
            @"首页、朋友页、好友聊天页、搜索页、用户作品页统一铺满整屏；"
            @"其他比例视频的原生背景延伸至底栏，文案与进度条保持原位"
        );
        void (^origBlock)(void) = [item.switchChangedBlock copy];
        item.switchChangedBlock = ^{
            if (origBlock) origBlock();
            if (DKVideoFullscreenOn()) return;
            for (NSUInteger i = 0; i < gRestoreCount; i++) gRestoreHooks[i]();
        };
        return item;
    });
}
