/*
 * YouTube Plus — Hybrid Native Share Sheet with Timecode support.
 *
 * Заменяет кастомное меню «Поделиться» YouTube на родной iOS UIActivityViewController
 * (иконки AirDrop / Сообщения / Копировать как в системе) и ДОБАВЛЯЕТ копирование
 * ссылки с текущим тайм-кодом (&t=N Ns) — как отдельно, так и через пункт шаринга.
 *
 * Основано на реальных первоисточниках:
 *   - нативный share sheet  : jkhsjdhjs/youtube-native-share (GPL-3.0)
 *   - получение тайм-кода   : dayanch96/YTLite (YTMainAppVideoPlayerOverlayViewController.mediaTime/videoID)
 *
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#include <UIKit/UIKit.h>

// ── Реальные классы YouTube (из YTLite.h / youtube-native-share) ──────────────

@interface YTUIUtils : NSObject
+ (UIViewController *)topViewControllerForPresenting;
@end

@interface YTMainAppVideoPlayerOverlayViewController : UIViewController
@property (readonly, nonatomic) CGFloat mediaTime;
@property (readonly, nonatomic) NSString *videoID;
@end

// ── Фикс входа в Google: возвращаем реальную keychain access group из entitlements ──
// Без этого YouTube (особенно после ресайна Feather'ом) не может найти ключи
// сессии и падает в ошибку авторизации. Реализация — как в YTLitePlus/uYouPlus.
#import <Security/Security.h>

static NSString *accessGroupID(void) {
    NSDictionary *query = @{
        (__bridge NSString *)kSecClass       : (__bridge NSString *)kSecClassGenericPassword,
        (__bridge NSString *)kSecAttrAccount : @"bundleSeedID",
        (__bridge NSString *)kSecAttrService : @"",
        (__bridge NSString *)kSecReturnAttributes : @YES,
    };
    CFDictionaryRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
    if (status == errSecItemNotFound)
        status = SecItemAdd((__bridge CFDictionaryRef)query, (CFTypeRef *)&result);
    if (status != errSecSuccess || !result)
        return nil;
    NSString *accessGroup = [(__bridge NSDictionary *)result
        objectForKey:(__bridge NSString *)kSecAttrAccessGroup];
    CFRelease(result);
    return accessGroup;
}

%hook SSOKeychainHelper
+ (NSString *)accessGroup      { return accessGroupID() ?: %orig; }
+ (NSString *)sharedAccessGroup{ return accessGroupID() ?: %orig; }
%end

%hook SSOKeychainCore
+ (NSString *)accessGroup      { return accessGroupID() ?: %orig; }
+ (NSString *)sharedAccessGroup{ return accessGroupID() ?: %orig; }
%end

// ── Состояние: последний открытый плеер, чтобы взять из него тайм-код ─────────
static __weak YTMainAppVideoPlayerOverlayViewController *gLastPlayerOverlay = nil;

// ── Хелперы ──────────────────────────────────────────────────────────────────

static NSString *const kTimecodeActivityTitle = @"Копировать ссылку с тайм-кодом";

// Формирует ссылку с текущим тайм-кодом, если плеер активен.
static NSString *currentTimestampedURL(void) {
    YTMainAppVideoPlayerOverlayViewController *overlay = gLastPlayerOverlay;
    if (!overlay || !overlay.videoID)
        return nil;

    NSInteger t = (NSInteger)overlay.mediaTime;
    return [NSString stringWithFormat:@"https://www.youtube.com/watch?v=%@&t=%lds",
                                      overlay.videoID, (long)t];
}

static void copyToPasteboard(NSString *string) {
    if (string.length == 0) return;
    [UIPasteboard generalPasteboard].string = string;
    if (@available(iOS 13.0, *)) {
        UINotificationFeedbackGenerator *gen = [[UINotificationFeedbackGenerator alloc] init];
        [gen notificationOccurred:UINotificationFeedbackTypeSuccess];
    }
}

// ── Кастомное действие «Копировать с тайм-кодом» для UIActivityViewController ─
@interface YTCopyTimestampActivity : UIActivity
@property (nonatomic, copy) NSString *timestampURL;
@end

@implementation YTCopyTimestampActivity

- (NSString *)activityType  { return @"com.braintimebox.youtubeplus.copyTimestamp"; }
- (NSString *)activityTitle { return kTimecodeActivityTitle; }

- (UIImage *)activityImage {
    if (@available(iOS 13.0, *))
        return [UIImage systemImageNamed:@"clock.arrow.circlepath"];
    return nil;
}

- (BOOL)canPerformWithActivityItems:(NSArray *)activityItems { return YES; }

- (void)performActivity {
    copyToPasteboard(self.timestampURL);
    [self activityDidFinish:YES];
}

@end

// ── Запоминаем активный плеер (отсюда берём mediaTime + videoID) ──────────────
%hook YTMainAppVideoPlayerOverlayViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    gLastPlayerOverlay = self;
}

%end

// ── Извлечение URL из отладочного описания share-entity (порт extractUrlFromDescription
//    из jkhsjdhjs/youtube-native-share — работает без protobuf-зависимости) ──────
typedef NS_ENUM(NSInteger, ShareEntityType) {
    ShareEntityFieldVideo     = 1,
    ShareEntityFieldPlaylist  = 2,
    ShareEntityFieldChannel   = 3,
    ShareEntityFieldPost      = 6,
    ShareEntityFieldClip      = 8,
    ShareEntityFieldShortFlag = 10
};

static NSString *ytURLForField(NSString *desc, ShareEntityType field, NSString *urlFmt) {
    NSRegularExpression *re = [NSRegularExpression
        regularExpressionWithPattern:
            [NSString stringWithFormat:@"\\b%ld: \"([^\"]+)\"", (long)field]
                              options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:desc options:0
                                               range:NSMakeRange(0, desc.length)];
    if (!m) return nil;
    NSString *value = [desc substringWithRange:[m rangeAtIndex:1]];
    return [NSString stringWithFormat:urlFmt, value];
}

static NSString *extractUrlFromDescription(NSString *desc) {
    if (desc.length == 0) return nil;

    // Shorts: флаг стоит отдельным полем.
    NSRegularExpression *shortRe =
        [NSRegularExpression regularExpressionWithPattern:
            [NSString stringWithFormat:@"\\b%ld: ", (long)ShareEntityFieldShortFlag]
                                                  options:0 error:nil];
    BOOL isShort = [shortRe firstMatchInString:desc options:0
                                         range:NSMakeRange(0, desc.length)] != nil;

    NSString *url;
    if ((url = ytURLForField(desc, ShareEntityFieldPlaylist, @"%@"))) {
        if (![url hasPrefix:@"PL"] && ![url hasPrefix:@"FL"])
            url = [url stringByAppendingString:@"&playnext=1"];
        return [@"https://www.youtube.com/playlist?list=" stringByAppendingString:url];
    }
    if ((url = ytURLForField(desc, ShareEntityFieldChannel,
                             @"https://www.youtube.com/channel/%@"))) return url;
    if ((url = ytURLForField(desc, ShareEntityFieldPost,
                             @"https://www.youtube.com/post/%@")))     return url;
    if ((url = ytURLForField(desc, ShareEntityFieldVideo,
                             isShort ? @"https://www.youtube.com/shorts/%@"
                                     : @"https://www.youtube.com/watch?v=%@"))) return url;
    return nil;
}

// ── Перехват вызова Share-меню: показываем НАТИВНЫЙ шаринг + кнопку тайм-кода ─
%hook YTShareEntityEndpointCommandHandler

- (void)executeWithCommand:(id)command entry:(id)entry fromView:(UIView *)fromView sender:(id)sender {
    NSString *desc = [command description];

    // 1. Базовая ссылка — из share-entity (без si-идентификатора отслеживания).
    NSString *baseURL = extractUrlFromDescription(desc);

    // 2. Фоллбэк: если entity не распарсился, а плеер активен — берём ID оттуда.
    NSString *tsURL = currentTimestampedURL();
    if (!baseURL && gLastPlayerOverlay.videoID)
        baseURL = [NSString stringWithFormat:@"https://www.youtube.com/watch?v=%@",
                                             gLastPlayerOverlay.videoID];

    if (!baseURL)
        return %orig;   // не смогли разобрать — оставляем родное поведение YouTube

    // 3. Если плеер активен — обычная ссылка тоже становится ссылкой с тайм-кодом.
    if (!tsURL) tsURL = baseURL;

    YTCopyTimestampActivity *tsAct = [[YTCopyTimestampActivity alloc] init];
    tsAct.timestampURL = tsURL;

    UIActivityViewController *vc =
        [[UIActivityViewController alloc] initWithActivityItems:@[baseURL]
                                         applicationActivities:@[tsAct]];
    vc.excludedActivityTypes = @[UIActivityTypeAssignToContact, UIActivityTypePrint];

    UIViewController *top = [%c(YTUIUtils) topViewControllerForPresenting];
    if (!top) return %orig;

    if (vc.popoverPresentationController) {
        if (fromView) {
            vc.popoverPresentationController.sourceView = fromView;
            vc.popoverPresentationController.sourceRect =
                [fromView convertRect:fromView.bounds toView:top.view];
        } else {
            vc.popoverPresentationController.sourceView = top.view;
            CGSize s = [UIScreen mainScreen].bounds.size;
            vc.popoverPresentationController.sourceRect = CGRectMake(s.width / 2.0, s.height, 0, 0);
        }
    }
    [top presentViewController:vc animated:YES completion:nil];
}

%end

%ctor {
    NSLog(@"[YouTubePlus] Hybrid Native Share + Timecode module loaded.");
}
