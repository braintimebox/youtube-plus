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

// ── Перехват вызова Share-меню: показываем НАТИВНЫЙ шаринг + кнопку тайм-кода ─
%hook YTShareEntityEndpointCommandHandler

- (void)executeWithCommand:(id)command entry:(id)entry fromView:(UIView *)fromView sender:(id)sender {
    // Если плеер активен и у нас есть ссылка с тайм-кодом — показываем нативное
    // меню, инжектируя кастомное действие с тайм-кодом.
    NSString *tsURL = currentTimestampedURL();

    // Извлекаем «чистую» ссылку видео из сериализованного share-entity,
    // чтобы получить и обычный URL (без si-идентификатора).
    NSString *baseURL = nil;
    NSRegularExpression *re =
        [NSRegularExpression regularExpressionWithPattern:@"serialized_share_entity: \"([^\"]+)\""
                                                  options:0 error:nil];
    NSString *desc = [command description];
    NSTextCheckingResult *m = [re firstMatchInString:desc options:0 range:NSMakeRange(0, desc.length)];
    if (m) {
        NSString *serialized = [desc substringWithRange:[m rangeAtIndex:1]];
        NSData *data = [[NSData alloc] initWithBase64EncodedString:serialized options:0];
        if (!data) data = [serialized dataUsingEncoding:NSUTF8StringEncoding];
        // Простейший парсинг: ищем watch?v=ID внутри протобуф-строки.
        NSString *asString = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSRegularExpression *reId =
            [NSRegularExpression regularExpressionWithPattern:@"[A-Za-z0-9_-]{11}"
                                                      options:0 error:nil];
        NSTextCheckingResult *idMatch = [reId firstMatchInString:asString ?: @"" options:0
                                                          range:NSMakeRange(0, (asString ?: @"").length)];
        if (idMatch) {
            NSString *vid = [asString substringWithRange:idMatch.range];
            baseURL = [NSString stringWithFormat:@"https://www.youtube.com/watch?v=%@", vid];
        }
    }

    if (!tsURL && !baseURL)
        return %orig;   // не смогли разобрать — оставляем родное поведение YouTube

    NSMutableArray *items = [NSMutableArray array];
    if (baseURL) [items addObject:baseURL];

    YTCopyTimestampActivity *tsAct = [[YTCopyTimestampActivity alloc] init];
    tsAct.timestampURL = tsURL ?: baseURL;
    if (!tsAct.timestampURL)
        return %orig;

    UIActivityViewController *vc =
        [[UIActivityViewController alloc] initWithActivityItems:items
                                         applicationActivities:@[tsAct]];
    vc.excludedActivityTypes = @[UIActivityTypeAssignToContact, UIActivityTypePrint];

    UIViewController *top = [%c(YTUIUtils) topViewControllerForPresenting];
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
