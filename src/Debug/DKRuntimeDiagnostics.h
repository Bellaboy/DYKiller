//
//  DKRuntimeDiagnostics.h
//  DYKiller
//
//  自适应运行时诊断：记录插件设置状态、页面/转场状态及主线程响应异常。
//

#ifndef DKRuntimeDiagnostics_h
#define DKRuntimeDiagnostics_h

#import <Foundation/Foundation.h>

@class UIViewController;

#ifdef __cplusplus
extern "C" {
#endif

/// 诊断总开关；未设置时为关闭。
BOOL DKRuntimeDiagnosticsEnabled(void);

/// 诊断导出悬浮按钮开关；未设置时为关闭。
BOOL DKRuntimeDiagnosticsFloatingButtonEnabled(void);

/// 设置项变化后调用，立即打开或关闭当前 session。
void DKRuntimeDiagnosticsPreferenceDidChange(void);

/// 状态变化采样。同一 domain/state/fields 自动去重，避免布局回调刷屏。
void DKRuntimeDiagnosticsObserveState(NSString *domain,
                                      NSString *state,
                                      NSDictionary *fields);

/// 一次性运行事件。每次调用都落盘，不做状态去重；用于手势、转场开始/结束等事件。
void DKRuntimeDiagnosticsRecordEvent(NSString *domain,
                                     NSString *event,
                                     NSDictionary *fields);

/// 报告确定的异常并自动截图。不得传入账号、消息内容、网络请求或媒体内容字段。
void DKRuntimeDiagnosticsReportAnomaly(NSString *code, NSDictionary *fields);

/// 在问题状态发生变化时抓取一次当前主窗口截图，并把截图与事件关联写入诊断包。
/// 仅在运行时诊断开启时生效；调用方不需要也不应该主动指定页面。
void DKRuntimeDiagnosticsCaptureScreenshot(NSString *event, NSDictionary *fields);

/// 当前 session 的时间线路径，位于主 App Documents 沙盒内；打开新 session 时会覆盖旧 session。
NSString *DKRuntimeDiagnosticsCurrentPath(void);

/// 由主屏幕诊断悬浮按钮调用，生成并分享只含当前 session 的诊断 ZIP。
void DKRuntimeDiagnosticsPresentExport(UIViewController *presenter);

#ifdef __cplusplus
}
#endif

#endif /* DKRuntimeDiagnostics_h */
