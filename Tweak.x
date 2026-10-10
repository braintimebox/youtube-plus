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
#import <LinkPresentation/LinkPresentation.h>
#import <objc/runtime.h>

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
+ (NSString *)accessGroup {
    NSString *group = accessGroupID();
    return group ? group : %orig;
}
+ (NSString *)sharedAccessGroup {
    NSString *group = accessGroupID();
    return group ? group : %orig;
}
%end

%hook SSOKeychainCore
+ (NSString *)accessGroup {
    NSString *group = accessGroupID();
    return group ? group : %orig;
}
+ (NSString *)sharedAccessGroup {
    NSString *group = accessGroupID();
    return group ? group : %orig;
}
%end

// ── Состояние: последний открытый плеер, чтобы взять из него тайм-код ─────────
static __weak YTMainAppVideoPlayerOverlayViewController *gLastPlayerOverlay = nil;

// ── Хелперы ──────────────────────────────────────────────────────────────────

// Формирует ссылку с текущим тайм-кодом, если плеер активен.
static NSString *currentTimestampedURL(void) {
    YTMainAppVideoPlayerOverlayViewController *overlay = gLastPlayerOverlay;
    if (!overlay || !overlay.videoID)
        return nil;

    NSInteger t = (NSInteger)overlay.mediaTime;
    return [NSString stringWithFormat:@"https://www.youtube.com/watch?v=%@&t=%lds",
                                      overlay.videoID, (long)t];
}

// Текущая позиция в формате mm:ss (или h:mm:ss).
static NSString *currentTimestampLabel(void) {
    YTMainAppVideoPlayerOverlayViewController *overlay = gLastPlayerOverlay;
    if (!overlay) return nil;
    NSInteger s = (NSInteger)overlay.mediaTime;
    if (s < 0) return nil;
    if (s >= 3600)
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)(s/3600), (long)((s%3600)/60), (long)(s%60)];
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(s/60), (long)(s%60)];
}

// Ключ ассоциированного объекта: хранит ссылку для полосы тайм-кодов.
static const char kYTTimecodeURLKey;

// ── Источник данных для системного share sheet ────────────────────────────────
// Именно он заставляет iOS нарисовать нормальную верхнюю строку превью:
// без него iOS показывает просто текст ссылки без обложки и названия.
@interface YTShareItemSource : NSObject <UIActivityItemSource>
@property (nonatomic, copy) NSString *url;
@property (nonatomic, copy) NSString *title;
@end

@implementation YTShareItemSource

- (id)activityViewControllerPlaceholderItem:(UIActivityViewController *)avc {
    return self.url;
}

- (id)activityViewController:(UIActivityViewController *)avc
         itemForActivityType:(NSString *)activityType {
    return self.url;
}

- (NSString *)activityViewController:(UIActivityViewController *)avc
              subjectForActivityType:(NSString *)activityType {
    return self.title;
}

- (LPLinkMetadata *)activityViewController:(UIActivityViewController *)avc
                   linkMetadataForActivityType:(NSString *)activityType {
    LPLinkMetadata *meta = [[LPLinkMetadata alloc] init];
    NSURL *u = [NSURL URLWithString:self.url];
    meta.originalURL = u;
    meta.URL = u;
    meta.title = self.title;
    return meta;
}

@end

// ── Полоса тайм-кодов внутри share sheet (tableHeaderView) ────────────────────
@interface YTTimecodeStripView : UIView
@end

@implementation YTTimecodeStripView

- (instancetype)initWithFrame:(CGRect)frame url:(NSString *)url label:(NSString *)label {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    self.backgroundColor = [UIColor clearColor];
    self.frame = CGRectMake(0, 0, frame.size.width, 56);

    UILabel *caption = [[UILabel alloc] init];
    caption.translatesAutoresizingMaskIntoConstraints = NO;
    caption.text = @"Тайм-код";
    caption.font = [UIFont systemFontOfSize:13 weight:UIFontWeightMedium];
    caption.textColor = [UIColor secondaryLabelColor];

    UILabel *value = [[UILabel alloc] init];
    value.translatesAutoresizingMaskIntoConstraints = NO;
    value.text = label ?: @"—";
    value.font = [UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightSemibold];
    value.textAlignment = NSTextAlignmentRight;

    UIImageView *chevron = [[UIImageView alloc] init];
    chevron.translatesAutoresizingMaskIntoConstraints = NO;
    chevron.contentMode = UIViewContentModeScaleAspectFit;
    if (@available(iOS 13.0, *)) {
        chevron.image = [UIImage systemImageNamed:@"doc.on.doc"];
        chevron.tintColor = [UIColor secondaryLabelColor];
    }
    chevron.frame = CGRectMake(0, 0, 18, 18);

    UIStackView *stack = [[UIStackView alloc] initWithArrangedSubviews:@[caption, value, chevron]];
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    stack.axis = UILayoutConstraintAxisHorizontal;
    stack.spacing = 8;
    stack.alignment = UIStackViewAlignmentCenter;
    [stack setCustomSpacing:12 afterView:caption];

    [self addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [stack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [stack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
        [value.widthAnchor constraintGreaterThanOrEqualToConstant:70],
    ]];

    // Тап по полосе — копируем ссылку с тайм-кодом.
    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(yt_copy:)];
    [self addGestureRecognizer:tap];
    self.userInteractionEnabled = YES;
    objc_setAssociatedObject(tap, &kYTTimecodeURLKey, url, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    return self;
}

- (void)yt_copy:(UITapGestureRecognizer *)sender {
    NSString *url = objc_getAssociatedObject(sender, &kYTTimecodeURLKey);
    if (url.length == 0) return;
    [UIPasteboard generalPasteboard].string = url;
    if (@available(iOS 10.0, *)) {
        [[[UINotificationFeedbackGenerator alloc] init]
            notificationOccurred:UINotificationFeedbackTypeSuccess];
    }
}

@end

// Вставляет полосу внутрь системного share sheet.
static void attachTimecodeStrip(UIActivityViewController *vc, NSString *url, NSString *label) {
    if (url.length == 0) return;

    __weak UIActivityViewController *weakVC = vc;
    dispatch_async(dispatch_get_main_queue(), ^{
        UIActivityViewController *strongVC = weakVC;
        if (!strongVC) return;

        __block UITableView *table = nil;
        void (^find)(UIView *) = nil;
        find = ^(UIView *view) {
            if (table) return;
            if ([view isKindOfClass:[UITableView class]]) {
                table = (UITableView *)view;
                return;
            }
            for (UIView *sub in view.subviews) find(sub);
        };
        find(strongVC.view);

        if (!table) return;   // раскладка не найдена — просто без полосы

        CGRect r = table.bounds;
        YTTimecodeStripView *strip =
            [[YTTimecodeStripView alloc] initWithFrame:CGRectMake(0, 0, r.size.width, 56)
                                                    url:url label:label];
        table.tableHeaderView = strip;
    });
}

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

    // 4. Источник данных: без него iOS рисует голый текст ссылки. С ним —
    //    нормальная верхняя строка превью (обложка + название).
    YTShareItemSource *item = [[YTShareItemSource alloc] init];
    item.url = tsURL;
    item.title = gLastPlayerOverlay.videoID ?: @"YouTube";

    UIActivityViewController *vc =
        [[UIActivityViewController alloc] initWithActivityItems:@[item]
                                         applicationActivities:nil];
    vc.excludedActivityTypes = @[UIActivityTypeAssignToContact, UIActivityTypePrint];

    // 5. Полоса с текущим тайм-кодом — встраивается в сам share sheet.
    //    Тап по ней копирует ссылку с тайм-кодом.
    attachTimecodeStrip(vc, tsURL, currentTimestampLabel());

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
