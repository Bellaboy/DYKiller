//
//  DKRuntimeDiagnostics.m
//  DYKiller
//
//  诊断原则：默认关闭、状态变化才落盘、异常才截图；不采集账号、内容或网络数据。
//

#import "DKRuntimeDiagnostics.h"
#import "DKKeys.h"
#import "DKZipWriter.h"
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>

static NSString *const kDKDiagnosticsDirectoryName = @"DYKillerDiagnostics";
static NSString *const kDKDiagnosticsCurrentName = @"timeline.jsonl";
static NSString *const kDKDiagnosticsScreensDirectoryName = @"screens";
static NSString *const kDKDiagnosticsCurrentScreensName = @"current";
static NSUInteger const kDKDiagnosticsMaxScreenshotsPerSession = 8;

static dispatch_queue_t gDiagnosticsQueue;
static NSFileHandle *gDiagnosticsHandle;
static NSUInteger gDiagnosticsSequence;
static NSUInteger gDiagnosticsScreenshotCount;
static NSMutableDictionary<NSString *, NSString *> *gDiagnosticsStateSignatures;
static NSMutableDictionary<NSString *, NSNumber *> *gDiagnosticsEventCounts;
static NSDate *gDiagnosticsSessionStartDate;
static NSDate *gDiagnosticsSessionEndDate;

static dispatch_queue_t DKDiagnosticsQueue(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        gDiagnosticsQueue = dispatch_queue_create("com.dykiller.runtime-diagnostics", DISPATCH_QUEUE_SERIAL);
    });
    return gDiagnosticsQueue;
}

static NSString *DKDiagnosticsDocumentsPath(void) {
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    return paths.firstObject ?: NSTemporaryDirectory();
}

static NSString *DKDiagnosticsDirectoryPath(void) {
    return [DKDiagnosticsDocumentsPath() stringByAppendingPathComponent:kDKDiagnosticsDirectoryName];
}

static NSString *DKDiagnosticsScreensDirectoryPath(void) {
    return [DKDiagnosticsDirectoryPath() stringByAppendingPathComponent:kDKDiagnosticsScreensDirectoryName];
}

static NSString *DKDiagnosticsCurrentScreensPath(void) {
    return [DKDiagnosticsScreensDirectoryPath() stringByAppendingPathComponent:kDKDiagnosticsCurrentScreensName];
}

NSString *DKRuntimeDiagnosticsCurrentPath(void) {
    return [DKDiagnosticsDirectoryPath() stringByAppendingPathComponent:kDKDiagnosticsCurrentName];
}

BOOL DKRuntimeDiagnosticsEnabled(void) {
    return [[NSUserDefaults standardUserDefaults] boolForKey:DKKeyRuntimeDiagnosticsEnabled];
}

BOOL DKRuntimeDiagnosticsFloatingButtonEnabled(void) {
    id value = [NSUserDefaults.standardUserDefaults objectForKey:DKKeyRuntimeDiagnosticsFloatingButton];
    return value == nil ? NO : [value boolValue];
}

static NSString *DKDiagnosticsISO8601String(NSDate *date) {
    static NSISO8601DateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSISO8601DateFormatter new];
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime
            | NSISO8601DateFormatWithFractionalSeconds;
    });
    return [formatter stringFromDate:date ?: NSDate.date] ?: @"";
}

static NSString *DKDiagnosticsTimestamp(void) {
    return DKDiagnosticsISO8601String(NSDate.date);
}

static NSString *DKDiagnosticsFilenameTimestamp(NSDate *date) {
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [NSDateFormatter new];
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        formatter.dateFormat = @"yyyyMMdd-HHmmss";
    });
    return [formatter stringFromDate:date ?: NSDate.date] ?: @"unknown";
}

static void DKDiagnosticsWriteLocked(NSString *event, NSDictionary *fields);

static void DKDiagnosticsCloseLocked(void) {
    if (!gDiagnosticsHandle) return;
    gDiagnosticsSessionEndDate = NSDate.date;
    DKDiagnosticsWriteLocked(@"session_end", @{
        @"session_start": DKDiagnosticsISO8601String(gDiagnosticsSessionStartDate),
        @"session_end": DKDiagnosticsISO8601String(gDiagnosticsSessionEndDate),
        @"duration_seconds": @(MAX(0.0, [gDiagnosticsSessionEndDate
            timeIntervalSinceDate:(gDiagnosticsSessionStartDate ?: gDiagnosticsSessionEndDate)])),
    });
    [gDiagnosticsHandle synchronizeFile];
    [gDiagnosticsHandle closeFile];
    gDiagnosticsHandle = nil;
}

static void DKDiagnosticsWriteLocked(NSString *event, NSDictionary *fields) {
    if (!gDiagnosticsHandle || !event.length) return;

    NSMutableDictionary *record = [NSMutableDictionary dictionaryWithDictionary:@{
        @"schema": @2,
        @"seq": @(++gDiagnosticsSequence),
        @"ts": DKDiagnosticsTimestamp(),
        @"event": event,
    }];
    if ([fields isKindOfClass:NSDictionary.class] && fields.count) {
        record[@"fields"] = fields;
    }

    NSError *jsonError = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:record
                                                     options:NSJSONWritingSortedKeys
                                                       error:&jsonError];
    if (!data) return;

    NSMutableData *line = [data mutableCopy];
    [line appendBytes:"\n" length:1];
    @try {
        [gDiagnosticsHandle writeData:line];
        NSUInteger count = [gDiagnosticsEventCounts[event] unsignedIntegerValue];
        gDiagnosticsEventCounts[event] = @(count + 1);
        // 状态事件很少，优先保证进程异常退出后最后一个关键状态仍可读。
        [gDiagnosticsHandle synchronizeFile];
    } @catch (__unused NSException *exception) {
        [gDiagnosticsHandle closeFile];
        gDiagnosticsHandle = nil;
    }
}

static NSDictionary *DKDiagnosticsPluginPreferences(void) {
    NSDictionary *defaults = NSUserDefaults.standardUserDefaults.dictionaryRepresentation;
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    [defaults enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, __unused BOOL *stop) {
        if (![key hasPrefix:@"DYKiller"]) return;
        if ([value isKindOfClass:NSNumber.class]) result[key] = value;
        else if (value) result[key] = @"configured";
    }];
    return result;
}

static void DKDiagnosticsOpenLocked(void) {
    if (gDiagnosticsHandle || !DKRuntimeDiagnosticsEnabled()) return;

    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *directory = DKDiagnosticsDirectoryPath();
    if (![fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:nil]) return;
    // 每次打开都从空目录开始：导出包只允许包含这一轮 session。
    [fm removeItemAtPath:[directory stringByAppendingPathComponent:@"current.jsonl"] error:nil];
    [fm removeItemAtPath:[directory stringByAppendingPathComponent:@"previous.jsonl"] error:nil];

    NSString *current = DKRuntimeDiagnosticsCurrentPath();
    [fm removeItemAtPath:current error:nil];
    [fm removeItemAtPath:[directory stringByAppendingPathComponent:@"previous-timeline.jsonl"] error:nil];

    [fm createFileAtPath:current contents:nil attributes:nil];
    gDiagnosticsHandle = [NSFileHandle fileHandleForWritingAtPath:current];
    gDiagnosticsSequence = 0;
    gDiagnosticsScreenshotCount = 0;
    gDiagnosticsStateSignatures = [NSMutableDictionary dictionary];
    gDiagnosticsEventCounts = [NSMutableDictionary dictionary];
    gDiagnosticsSessionStartDate = NSDate.date;
    gDiagnosticsSessionEndDate = nil;

    NSString *screens = DKDiagnosticsScreensDirectoryPath();
    NSString *currentScreens = DKDiagnosticsCurrentScreensPath();
    [fm createDirectoryAtPath:screens withIntermediateDirectories:YES attributes:nil error:nil];
    [fm removeItemAtPath:currentScreens error:nil];
    [fm createDirectoryAtPath:currentScreens withIntermediateDirectories:YES attributes:nil error:nil];

    DKDiagnosticsWriteLocked(@"session_start", @{
        @"schema": @2,
        @"module_version": DK_VERSION,
        @"build_id": DK_BUILD_ID,
        @"app_version": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"",
        @"app_build": [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleVersion"] ?: @"",
        @"os_version": UIDevice.currentDevice.systemVersion ?: @"",
        @"session_start": DKDiagnosticsISO8601String(gDiagnosticsSessionStartDate),
        @"current_path": kDKDiagnosticsCurrentName,
        @"screenshots_path": [kDKDiagnosticsScreensDirectoryName stringByAppendingPathComponent:kDKDiagnosticsCurrentScreensName],
        @"plugin_preferences": DKDiagnosticsPluginPreferences(),
        @"privacy_scope": @"plugin-state-ui-geometry-app-responsiveness",
    });
}

void DKRuntimeDiagnosticsPreferenceDidChange(void) {
    dispatch_async(DKDiagnosticsQueue(), ^{
        if (DKRuntimeDiagnosticsEnabled()) {
            DKDiagnosticsOpenLocked();
        } else {
            DKDiagnosticsCloseLocked();
        }
    });
}

static NSArray<UIWindow *> *DKDiagnosticsActiveWindows(void) {
    NSMutableArray<UIWindow *> *windows = [NSMutableArray array];
    for (UIWindow *window in UIApplication.sharedApplication.windows) {
        if (!window || window.hidden || window.alpha <= 0.01) continue;
        [windows addObject:window];
    }
    return [windows sortedArrayUsingComparator:^NSComparisonResult(UIWindow *lhs, UIWindow *rhs) {
        if (lhs.windowLevel == rhs.windowLevel) return NSOrderedSame;
        return lhs.windowLevel < rhs.windowLevel ? NSOrderedAscending : NSOrderedDescending;
    }];
}

static UIWindow *DKDiagnosticsTargetWindow(NSArray<UIWindow *> *windows) {
    for (UIWindow *window in windows) {
        if (window.isKeyWindow && window.windowLevel == UIWindowLevelNormal) return window;
    }
    for (UIWindow *window in windows) {
        if (window.windowLevel == UIWindowLevelNormal) return window;
    }
    return windows.lastObject;
}

static NSData *DKDiagnosticsScreenshotPNG(UIWindow *window, NSArray<UIWindow *> *windows) {
    if (!window || window.bounds.size.width <= 0.0 || window.bounds.size.height <= 0.0) return nil;

    CGFloat scale = window.screen.scale > 0.0 ? window.screen.scale : UIScreen.mainScreen.scale;
    UIGraphicsBeginImageContextWithOptions(window.bounds.size, NO, scale);
    for (UIWindow *activeWindow in windows) {
        BOOL drawn = [activeWindow drawViewHierarchyInRect:activeWindow.bounds afterScreenUpdates:NO];
        if (!drawn) [activeWindow.layer renderInContext:UIGraphicsGetCurrentContext()];
    }
    UIImage *image = UIGraphicsGetImageFromCurrentImageContext();
    UIGraphicsEndImageContext();
    return image ? UIImagePNGRepresentation(image) : nil;
}

static NSString *DKDiagnosticsSafeFileComponent(NSString *value) {
    if (!value.length) return @"event";

    NSMutableString *result = [NSMutableString stringWithCapacity:value.length];
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
                               @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_" ];
    for (NSUInteger i = 0; i < value.length; i++) {
        unichar character = [value characterAtIndex:i];
        [result appendFormat:@"%c", [allowed characterIsMember:character] ? (char)character : '_'];
    }
    return result.length ? result : @"event";
}

void DKRuntimeDiagnosticsCaptureScreenshot(NSString *event, NSDictionary *fields) {
    if (!DKRuntimeDiagnosticsEnabled() || !event.length) return;

    NSString *eventCopy = [event copy];
    NSDictionary *fieldsCopy = [fields isKindOfClass:NSDictionary.class] ? [fields copy] : @{};
    dispatch_async(dispatch_get_main_queue(), ^{
        if (!DKRuntimeDiagnosticsEnabled()) return;

        NSArray<UIWindow *> *windows = DKDiagnosticsActiveWindows();
        UIWindow *window = DKDiagnosticsTargetWindow(windows);
        NSData *png = DKDiagnosticsScreenshotPNG(window, windows);
        if (!png) {
            DKRuntimeDiagnosticsObserveState(@"diagnostics.screenshot", @"failed", @{
                @"source": eventCopy,
            });
            return;
        }

        NSDictionary *windowFields = @{
            @"window_bounds": NSStringFromCGRect(window.bounds),
            @"window_scale": @(window.screen.scale),
        };
        NSMutableDictionary *captureFields = [fieldsCopy mutableCopy];
        [captureFields addEntriesFromDictionary:windowFields];

        dispatch_async(DKDiagnosticsQueue(), ^{
            if (!DKRuntimeDiagnosticsEnabled()) return;
            DKDiagnosticsOpenLocked();
            if (!gDiagnosticsHandle) return;

            if (gDiagnosticsScreenshotCount >= kDKDiagnosticsMaxScreenshotsPerSession) {
                DKDiagnosticsWriteLocked(@"screenshot.skipped", @{
                    @"source_event": eventCopy,
                    @"reason": @"session_limit",
                    @"limit": @(kDKDiagnosticsMaxScreenshotsPerSession),
                });
                return;
            }

            NSString *component = DKDiagnosticsSafeFileComponent(eventCopy);
            NSString *filename = [NSString stringWithFormat:@"%03lu-%@.png",
                                  (unsigned long)gDiagnosticsScreenshotCount + 1,
                                  component];
            NSString *path = [DKDiagnosticsCurrentScreensPath() stringByAppendingPathComponent:filename];
            if (![png writeToFile:path options:NSDataWritingAtomic error:nil]) {
                DKDiagnosticsWriteLocked(@"screenshot.failed", @{
                    @"source_event": eventCopy,
                    @"reason": @"write_failed",
                });
                return;
            }

            gDiagnosticsScreenshotCount++;
            captureFields[@"screenshot"] = [kDKDiagnosticsScreensDirectoryName
                                               stringByAppendingPathComponent:
                                               [kDKDiagnosticsCurrentScreensName stringByAppendingPathComponent:filename]];
            DKDiagnosticsWriteLocked(eventCopy, captureFields);
        });
    });
}

static NSString *DKDiagnosticsSignature(NSString *state, NSDictionary *fields) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:fields ?: @{}
                                                   options:NSJSONWritingSortedKeys error:nil];
    NSString *json = data ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"{}";
    return [NSString stringWithFormat:@"%@|%@", state ?: @"", json ?: @"{}"];
}

void DKRuntimeDiagnosticsObserveState(NSString *domain,
                                      NSString *state,
                                      NSDictionary *fields) {
    if (!DKRuntimeDiagnosticsEnabled() || !domain.length || !state.length) return;

    NSString *domainCopy = [domain copy];
    NSString *stateCopy = [state copy];
    NSDictionary *fieldsCopy = [fields isKindOfClass:NSDictionary.class] ? [fields copy] : @{};
    dispatch_async(DKDiagnosticsQueue(), ^{
        if (!DKRuntimeDiagnosticsEnabled()) return;
        DKDiagnosticsOpenLocked();
        NSString *signature = DKDiagnosticsSignature(stateCopy, fieldsCopy);
        if ([gDiagnosticsStateSignatures[domainCopy] isEqualToString:signature]) return;
        gDiagnosticsStateSignatures[domainCopy] = signature;
        NSMutableDictionary *payload = [fieldsCopy mutableCopy];
        payload[@"domain"] = domainCopy;
        payload[@"state"] = stateCopy;
        DKDiagnosticsWriteLocked(@"state_change", payload);
    });
}

void DKRuntimeDiagnosticsRecordEvent(NSString *domain,
                                    NSString *event,
                                    NSDictionary *fields) {
    if (!DKRuntimeDiagnosticsEnabled() || !domain.length || !event.length) return;

    NSString *domainCopy = [domain copy];
    NSString *eventCopy = [event copy];
    NSDictionary *fieldsCopy = [fields isKindOfClass:NSDictionary.class] ? [fields copy] : @{};
    dispatch_async(DKDiagnosticsQueue(), ^{
        if (!DKRuntimeDiagnosticsEnabled()) return;
        DKDiagnosticsOpenLocked();
        NSMutableDictionary *payload = [fieldsCopy mutableCopy];
        payload[@"domain"] = domainCopy;
        payload[@"event"] = eventCopy;
        DKDiagnosticsWriteLocked(@"runtime_event", payload);
    });
}

void DKRuntimeDiagnosticsReportAnomaly(NSString *code, NSDictionary *fields) {
    if (!DKRuntimeDiagnosticsEnabled() || !code.length) return;

    NSString *codeCopy = [code copy];
    NSDictionary *fieldsCopy = [fields isKindOfClass:NSDictionary.class] ? [fields copy] : @{};
    NSString *domain = [@"anomaly." stringByAppendingString:codeCopy];
    dispatch_async(DKDiagnosticsQueue(), ^{
        if (!DKRuntimeDiagnosticsEnabled()) return;
        DKDiagnosticsOpenLocked();
        NSString *signature = DKDiagnosticsSignature(codeCopy, fieldsCopy);
        if ([gDiagnosticsStateSignatures[domain] isEqualToString:signature]) return;
        gDiagnosticsStateSignatures[domain] = signature;
        NSMutableDictionary *payload = [fieldsCopy mutableCopy];
        payload[@"code"] = codeCopy;
        DKDiagnosticsWriteLocked(@"anomaly", payload);
        dispatch_async(dispatch_get_main_queue(), ^{
            DKRuntimeDiagnosticsCaptureScreenshot([@"anomaly." stringByAppendingString:codeCopy],
                                                  payload);
        });
    });
}

static NSString *DKDiagnosticsReadText(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    return data.length ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : @"";
}

static void DKDiagnosticsShowError(UIViewController *presenter, NSString *message) {
    dispatch_async(dispatch_get_main_queue(), ^{
        UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"诊断导出失败"
                                                                       message:message ?: @"未知错误"
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"确定" style:UIAlertActionStyleCancel handler:nil]];
        [presenter presentViewController:alert animated:YES completion:nil];
    });
}

static void DKDiagnosticsShareAndCleanup(NSURL *zipURL, NSURL *rootURL,
                                         UIViewController *presenter) {
    if (!zipURL || !presenter) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIActivityViewController *activity = [[UIActivityViewController alloc]
            initWithActivityItems:@[zipURL] applicationActivities:nil];
        if (activity.popoverPresentationController) {
            activity.popoverPresentationController.sourceView = presenter.view;
            activity.popoverPresentationController.sourceRect = presenter.view.bounds;
        }
        activity.completionWithItemsHandler = ^(__unused UIActivityType type,
                                                __unused BOOL completed,
                                                __unused NSArray *items,
                                                __unused NSError *error) {
            [NSFileManager.defaultManager removeItemAtURL:rootURL error:nil];
            [NSFileManager.defaultManager removeItemAtURL:zipURL error:nil];
        };
        [presenter presentViewController:activity animated:YES completion:nil];
    });
}

void DKRuntimeDiagnosticsPresentExport(UIViewController *presenter) {
    if (!presenter) return;

    dispatch_async(DKDiagnosticsQueue(), ^{
        DKDiagnosticsCloseLocked();

        NSString *current = DKDiagnosticsReadText(DKRuntimeDiagnosticsCurrentPath());
        if (!current.length) {
            DKDiagnosticsShowError(presenter, @"没有可导出的诊断日志。请先开启“智能运行诊断”，再重现问题。");
            return;
        }

        NSDate *endDate = gDiagnosticsSessionEndDate ?: NSDate.date;
        NSDate *startDate = gDiagnosticsSessionStartDate ?: endDate;
        NSString *startToken = DKDiagnosticsFilenameTimestamp(startDate);
        NSString *endToken = DKDiagnosticsFilenameTimestamp(endDate);
        NSString *rootName = [NSString stringWithFormat:@"DYKiller-Diagnostics-%@-%@",
                              startToken, endToken];
        NSString *logName = [rootName stringByAppendingPathExtension:@"jsonl"];
        NSString *rootPath = [NSTemporaryDirectory() stringByAppendingPathComponent:rootName];
        NSString *zipPath = [NSTemporaryDirectory() stringByAppendingPathComponent:
                             [rootName stringByAppendingPathExtension:@"zip"]];
        NSFileManager *fm = NSFileManager.defaultManager;
        [fm removeItemAtPath:rootPath error:nil];
        [fm removeItemAtPath:zipPath error:nil];
        NSError *error = nil;
        if (![fm createDirectoryAtPath:rootPath withIntermediateDirectories:YES attributes:nil error:&error]) {
            DKDiagnosticsShowError(presenter, error.localizedDescription);
            return;
        }

        NSDictionary *manifest = @{
            @"schema": @2,
            @"module": @"DYKiller",
            @"build_id": DK_BUILD_ID,
            @"diagnostics": @"adaptive-runtime-state-monitor",
            @"current_present": @(current.length > 0),
            @"session_start": DKDiagnosticsISO8601String(startDate),
            @"session_end": DKDiagnosticsISO8601String(endDate),
            @"log_file": logName,
            @"screenshots": @"anomalies-only",
            @"privacy_scope": @"no-account-content-network-or-media-fields",
        };
        NSData *manifestData = [NSJSONSerialization dataWithJSONObject:manifest
                                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                                     error:&error];
        BOOL ok = manifestData
            && [manifestData writeToFile:[rootPath stringByAppendingPathComponent:@"manifest.json"]
                                  options:NSDataWritingAtomic error:&error];
        if (ok && current.length) {
            ok = [current writeToFile:[rootPath stringByAppendingPathComponent:logName]
                              atomically:YES encoding:NSUTF8StringEncoding error:&error];
        }
        if (ok) {
            NSDictionary *summary = @{
                @"schema": @2,
                @"event_counts": gDiagnosticsEventCounts ?: @{},
                @"last_states": gDiagnosticsStateSignatures ?: @{},
            };
            NSData *summaryData = [NSJSONSerialization dataWithJSONObject:summary
                                                                   options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys
                                                                     error:&error];
            ok = summaryData && [summaryData
                writeToFile:[rootPath stringByAppendingPathComponent:@"state-summary.json"]
                options:NSDataWritingAtomic error:&error];
        }
        if (ok) {
            NSString *exportScreens = [rootPath stringByAppendingPathComponent:kDKDiagnosticsScreensDirectoryName];
            [fm createDirectoryAtPath:exportScreens withIntermediateDirectories:YES attributes:nil error:&error];
            NSString *currentScreens = DKDiagnosticsCurrentScreensPath();
            if ([fm fileExistsAtPath:currentScreens]) {
                ok = [fm copyItemAtPath:currentScreens
                                 toPath:[exportScreens stringByAppendingPathComponent:kDKDiagnosticsCurrentScreensName]
                                  error:&error];
            }
        }
        if (!ok) {
            [fm removeItemAtPath:rootPath error:nil];
            DKDiagnosticsShowError(presenter, error.localizedDescription ?: @"日志文件写入失败");
            return;
        }

        NSArray *relativeFiles = [fm subpathsAtPath:rootPath];
        NSMutableArray *files = [NSMutableArray arrayWithCapacity:relativeFiles.count];
        for (NSString *relative in relativeFiles) {
            NSString *path = [rootPath stringByAppendingPathComponent:relative];
            BOOL isDirectory = NO;
            if ([fm fileExistsAtPath:path isDirectory:&isDirectory] && !isDirectory) {
                [files addObject:path];
            }
        }
        NSError *zipError = nil;
        if (![DKZipWriter createZipAtPath:zipPath rootDir:rootPath files:files progress:nil error:&zipError]) {
            [fm removeItemAtPath:rootPath error:nil];
            DKDiagnosticsShowError(presenter, zipError.localizedDescription ?: @"ZIP 生成失败");
            return;
        }

        DKDiagnosticsShareAndCleanup([NSURL fileURLWithPath:zipPath],
                                     [NSURL fileURLWithPath:rootPath isDirectory:YES], presenter);
    });
}
