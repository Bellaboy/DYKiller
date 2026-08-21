//
//  DKRuntimeDiagnosticsProbe.xm
//  自动状态监控：页面、App 生命周期与主线程响应。只记录类名、状态和耗时。
//

#import "DKRuntimeDiagnostics.h"
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>
#import <math.h>

static dispatch_queue_t gDKResponseQueue;
static dispatch_source_t gDKResponseTimer;
static uint64_t gDKResponseToken;
static uint64_t gDKLastResponseToken;

static NSDictionary *DKPluginPreferenceSnapshot(void) {
    NSDictionary *defaults = NSUserDefaults.standardUserDefaults.dictionaryRepresentation;
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    [defaults enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, __unused BOOL *stop) {
        if (![key hasPrefix:@"DYKiller"]) return;
        if ([value isKindOfClass:NSNumber.class]) result[key] = value;
        else if (value) result[key] = @"configured";
    }];
    return result;
}

static void DKObserveApplicationState(NSString *state) {
    DKRuntimeDiagnosticsObserveState(@"app.lifecycle", state ?: @"unknown", @{
        @"application_state": @(UIApplication.sharedApplication.applicationState),
    });
}

static void DKInstallLifecycleObservers(void) {
    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center addObserverForName:UIApplicationDidBecomeActiveNotification object:nil queue:nil
                   usingBlock:^(__unused NSNotification *note) { DKObserveApplicationState(@"active"); }];
    [center addObserverForName:UIApplicationWillResignActiveNotification object:nil queue:nil
                   usingBlock:^(__unused NSNotification *note) { DKObserveApplicationState(@"inactive"); }];
    [center addObserverForName:UIApplicationDidEnterBackgroundNotification object:nil queue:nil
                   usingBlock:^(__unused NSNotification *note) { DKObserveApplicationState(@"background"); }];
    [center addObserverForName:NSUserDefaultsDidChangeNotification object:nil queue:nil
                   usingBlock:^(__unused NSNotification *note) {
        DKRuntimeDiagnosticsObserveState(@"plugin.preferences", @"changed", @{
            @"values": DKPluginPreferenceSnapshot(),
        });
    }];
}

static void DKInstallResponseMonitor(void) {
    gDKResponseQueue = dispatch_queue_create("com.dykiller.diagnostics-response",
                                             DISPATCH_QUEUE_SERIAL);
    gDKResponseTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, gDKResponseQueue);
    dispatch_source_set_timer(gDKResponseTimer,
                              dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC),
                              2 * NSEC_PER_SEC, 200 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(gDKResponseTimer, ^{
        if (!DKRuntimeDiagnosticsEnabled()
            || UIApplication.sharedApplication.applicationState != UIApplicationStateActive) return;

        uint64_t token = ++gDKResponseToken;
        CFTimeInterval sent = CACurrentMediaTime();
        dispatch_async(dispatch_get_main_queue(), ^{
            CFTimeInterval delay = CACurrentMediaTime() - sent;
            dispatch_async(gDKResponseQueue, ^{
                gDKLastResponseToken = MAX(gDKLastResponseToken, token);
                if (delay >= 0.75) {
                    DKRuntimeDiagnosticsObserveState(@"app.main_thread", @"delayed", @{
                        @"delay_ms": @((NSInteger)llround(delay * 1000.0)),
                    });
                } else {
                    DKRuntimeDiagnosticsObserveState(@"app.main_thread", @"responsive", @{});
                }
            });
        });
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 750 * NSEC_PER_MSEC),
                       gDKResponseQueue, ^{
            if (gDKLastResponseToken < token) {
                DKRuntimeDiagnosticsObserveState(@"app.main_thread", @"unresponsive", @{
                    @"threshold_ms": @750,
                });
            }
        });
    });
    dispatch_resume(gDKResponseTimer);
}

%ctor {
    DKInstallLifecycleObservers();
    DKInstallResponseMonitor();
}
