//
//  DKRuntimeDiagnosticsEntry.xm
//  DYKiller
//
//  只负责把运行时诊断接入 DYKiller 设置页；采集与导出实现保持在独立模块。
//

#import "DKRuntimeDiagnostics.h"
#import "DKKeys.h"
#import "DKSettings.h"
#import "DKDebugInspector.h"

%ctor {
    DKRuntimeDiagnosticsPreferenceDidChange();

    DKSettingsRegisterItem(@"调试", ^AWESettingItemModel *{
        AWESettingItemModel *item = DKMakeSwitch(
            DKKeyRuntimeDiagnosticsEnabled,
            @"智能运行诊断",
            @"记录插件状态、页面转场和 App 响应；异常时截图，默认关闭"
        );
        void (^origBlock)(void) = [item.switchChangedBlock copy];
        item.switchChangedBlock = ^{
            if (origBlock) origBlock();
            DKRuntimeDiagnosticsPreferenceDidChange();
        };
        return item;
    });

    DKSettingsRegisterItem(@"调试", ^AWESettingItemModel *{
        AWESettingItemModel *item = DKMakeSwitch(
            DKKeyRuntimeDiagnosticsFloatingButton,
            @"诊断导出悬浮按钮",
            @"在主屏幕显示导出入口；默认关闭"
        );
        item.isSwitchOn = DKRuntimeDiagnosticsFloatingButtonEnabled();
        void (^origBlock)(void) = [item.switchChangedBlock copy];
        item.switchChangedBlock = ^{
            if (origBlock) origBlock();
            DKDebugInspectorRefreshOverlay();
        };
        return item;
    });
}
