//
//  DKCommentGlass.h
//  DYKiller
//
//  评论区液态玻璃对外只暴露最近接管的两个槽位，供调试导出采集其状态。
//  玻璃层挂在槽位的最底层，探针从槽位自己推出来即可。
//

#ifndef DKCommentGlass_h
#define DKCommentGlass_h

#import <UIKit/UIKit.h>

#ifdef __cplusplus
extern "C" {
#endif

/// 最近接管的评论面板槽位；从未接管过时为 nil。
UIView *DKCommentGlassCurrentSlot(void);

/// 最近接管的输入框槽位（那枚圆角胶囊）；从未接管过时为 nil。
/// 它的尺寸由抖音在常驻态与回复态之间来回改，探针据此核对玻璃有没有跟上。
UIView *DKCommentGlassCurrentField(void);

/// 最近接管的输入栏底色槽；从未接管过时为 nil。
/// 它那块玻璃与主面板玻璃上下拼接，探针据此核对主面板有没有正确让位。
UIView *DKCommentGlassCurrentInputBackdrop(void);

/// 在场的小表情栏（键盘输入附件，住在 UITextEffectsWindow 里）；不在屏时为 nil。
/// 它靠透出输入栏那块玻璃取得同档观感，探针据此核对底色清了没有、玻璃在不在它背后。
UIView *DKCommentGlassCurrentEmoticonPanel(void);

/// 本次会话拦下「不透明绘制优化」网关的次数。恒为 0 说明抖音没走这个网关——
/// 那就要靠探针的「残留面板底色」判断面板有没有被刷上底色。
NSUInteger DKCommentGlassRenderOptimizeBlocks(void);

#ifdef __cplusplus
}
#endif

#endif /* DKCommentGlass_h */
