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

@interface YTSingleVideoController : NSObject
@property (nonatomic, assign, readonly) CGFloat totalMediaTime;
@end

@interface YTPlayerViewController : UIViewController
@property (nonatomic, assign, readonly) YTSingleVideoController *activeVideo;
@end

@interface YTMainAppVideoPlayerOverlayViewController : UIViewController
@property (readonly, nonatomic) CGFloat mediaTime;
@property (readonly, nonatomic) NSString *videoID;
@end

// Класс-расширение: так же объявлено в YTLite.h — parentViewController у
// overlay контроллера имеет тип YTPlayerViewController *. Через него достаём
// длительность видео (activeVideo.totalMediaTime) для слайдера селектора.
@interface YTMainAppVideoPlayerOverlayViewController ()
@property (nonatomic, weak, readwrite) YTPlayerViewController *parentViewController;
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

// Форматирует произвольное число секунд в mm:ss / h:mm:ss.
static NSString *formatSeconds(NSInteger s) {
    if (s < 0) s = 0;
    if (s >= 3600)
        return [NSString stringWithFormat:@"%ld:%02ld:%02ld", (long)(s/3600), (long)((s%3600)/60), (long)(s%60)];
    return [NSString stringWithFormat:@"%ld:%02ld", (long)(s/60), (long)(s%60)];
}

// Длительность текущего видео — overlay.parentViewController.activeVideo.totalMediaTime.
// 0, если плеер недоступен (тогда слайдер скрывается, остаётся текущий тайм-код).
static NSTimeInterval currentDuration(void) {
    YTMainAppVideoPlayerOverlayViewController *overlay = gLastPlayerOverlay;
    if (!overlay) return 0;
    YTPlayerViewController *player = overlay.parentViewController;
    if (!player) return 0;
    YTSingleVideoController *video = player.activeVideo;
    if (!video) return 0;
    NSTimeInterval d = video.totalMediaTime;
    return (d > 0) ? d : 0;
}

// Ограничивает высоту листа, чтобы шторка не растягивалась на весь экран.
// Дефолтный UISheetPresentationController.detents = [.large()] (полная высота),
// поэтому голый UIActivityViewController без детентов уходит в ~95%. Здесь:
//   iOS 16+ -> custom detent ~62% (custom-детенты требуют 16.0+, не 15);
//   iOS 15  -> системный .medium() (~половина экрана);
//   iOS <15 -> остаётся pageSheet, но потолок heightAnchor удерживает высоту.
// Полоса тайм-кодов закреплена сверху (attachTimecodeStrip), поэтому место
// под неё появляется именно за счёт уменьшения листа.
static void applySheetHeightCap(UIActivityViewController *vc) {
    if (!vc) return;
    vc.modalPresentationStyle = UIModalPresentationPageSheet;

    if (@available(iOS 16.0, *)) {
        UISheetPresentationController *pc = vc.sheetPresentationController;
        if (pc) {
            UISheetPresentationControllerDetent *hybrid =
                [UISheetPresentationControllerDetent customDetentWithIdentifier:@"yt.hybrid"
                                                                       resolver:^CGFloat (id<UISheetPresentationControllerDetentResolutionContext> context) {
                    return context.maximumDetentValue * 0.62;
                }];
            pc.detents = @[hybrid];
            pc.prefersGrabberVisible = YES;
            return;
        }
    } else if (@available(iOS 15.0, *)) {
        UISheetPresentationController *pc = vc.sheetPresentationController;
        if (pc) {
            pc.detents = @[UISheetPresentationControllerDetent.mediumDetent];
            pc.prefersGrabberVisible = YES;
        }
    }

    // Фоллбэк для iOS <15 (и страховка): жёсткий потолок высоты view.
    // Не даёт листу развернуться на полный экран даже без поддержки детентов.
    [vc.view layoutIfNeeded];
    CGFloat capH = MAX([UIScreen mainScreen].bounds.size.height * 0.62, 460.0);
    NSLayoutConstraint *cap = [vc.view.heightAnchor constraintLessThanOrEqualToConstant:capH];
    cap.priority = UILayoutPriorityRequired;
    cap.active = YES;
}

// Ключи ассоциированных объектов для селектора времени: сам item source,
// базовая ссылка без &t, длительность видео и выбранные секунды (NSNumber).
static const char kYTTimecodeItemKey;
static const char kYTTimecodeBaseKey;
static const char kYTTimecodeDurationKey;
static const char kYTTimecodeSelectedKey;

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

// ── Селектор тайм-кода внутри share sheet — как в оригинальном YouTube ────────
// Верхняя строка: «Начать с» + время + переключатель. Ниже — слайдер по
// длительности видео. Переключатель и слайдер МЕНЯЮТ ССЫЛКУ, которую отдаст
// системная шторка (через YTShareItemSource.item — он читается в момент
// фактического шаринга, поэтому обновление подхватывается).
@interface YTTimecodeStripView : UIView
@property (nonatomic, weak) YTShareItemSource *item;      // куда писать текущий URL
@property (nonatomic, copy) NSString *baseURL;            // ссылка без &t
@property (nonatomic, assign) NSTimeInterval duration;     // 0 => слайдер скрыт
@property (nonatomic, assign) NSTimeInterval selected;     // выбранные секунды
@property (nonatomic, strong) UILabel *timeLabel;
@property (nonatomic, strong) UISlider *slider;
@property (nonatomic, strong) UISwitch *toggle;
@property (nonatomic, strong) NSLayoutConstraint *heightConstraint;
- (void)applyHeightAnimated:(BOOL)animated;
@end

@implementation YTTimecodeStripView

// Высота: свёрнутая (только строка) и развёрнутая (со слайдером).
static const CGFloat kYTCollapsedH = 52.0;
static const CGFloat kYTExpandedH  = 104.0;

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (!self) return nil;

    // Непрозрачный фон обязателен: с clearColor полоса визуально сливалась
    // с системным контентом под ней и выглядела отсутствующей.
    self.backgroundColor = [UIColor systemGroupedBackgroundColor];
    self.clipsToBounds = YES;

    // Строка 1: «Начать с» | время | переключатель | копировать
    UILabel *caption = [[UILabel alloc] init];
    caption.translatesAutoresizingMaskIntoConstraints = NO;
    caption.text = @"Начать с";
    caption.font = [UIFont systemFontOfSize:16 weight:UIFontWeightRegular];

    UILabel *value = [[UILabel alloc] init];
    value.translatesAutoresizingMaskIntoConstraints = NO;
    value.font = [UIFont monospacedDigitSystemFontOfSize:17 weight:UIFontWeightSemibold];
    value.textAlignment = NSTextAlignmentRight;

    UIImageView *copyIcon = [[UIImageView alloc] init];
    copyIcon.translatesAutoresizingMaskIntoConstraints = NO;
    copyIcon.contentMode = UIViewContentModeScaleAspectFit;
    copyIcon.tintColor = [UIColor secondaryLabelColor];
    if (@available(iOS 13.0, *)) {
        copyIcon.image = [UIImage systemImageNamed:@"doc.on.doc"];
    }
    [copyIcon.widthAnchor constraintEqualToConstant:18].active = YES;
    [copyIcon.heightAnchor constraintEqualToConstant:18].active = YES;

    UISwitch *sw = [[UISwitch alloc] init];
    sw.translatesAutoresizingMaskIntoConstraints = NO;
    sw.on = YES;

    UIStackView *row = [[UIStackView alloc] initWithArrangedSubviews:@[caption, value, copyIcon, sw]];
    row.translatesAutoresizingMaskIntoConstraints = NO;
    row.axis = UILayoutConstraintAxisHorizontal;
    row.alignment = UIStackViewAlignmentCenter;
    row.spacing = 10;
    [row setCustomSpacing:8 afterView:caption];

    // Строка 2: слайдер по длительности
    UISlider *sl = [[UISlider alloc] init];
    sl.translatesAutoresizingMaskIntoConstraints = NO;
    sl.minimumValue = 0;
    sl.continuous = YES;

    [self addSubview:row];
    [self addSubview:sl];

    [NSLayoutConstraint activateConstraints:@[
        [row.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [row.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [row.topAnchor constraintEqualToAnchor:self.topAnchor constant:6],
        [row.heightAnchor constraintEqualToConstant:40],

        [value.widthAnchor constraintGreaterThanOrEqualToConstant:64],

        [sl.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:16],
        [sl.trailingAnchor constraintEqualToAnchor:self.trailingAnchor constant:-16],
        [sl.topAnchor constraintEqualToAnchor:row.bottomAnchor constant:2],
    ]];

    self.timeLabel = value;
    self.slider = sl;
    self.toggle = sw;
    self.heightConstraint = [self.heightAnchor constraintEqualToConstant:kYTCollapsedH];
    self.heightConstraint.active = YES;

    [sw addTarget:self action:@selector(toggleChanged:) forControlEvents:UIControlEventValueChanged];
    [sl addTarget:self action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged];

    // Тап по иконке копирования — копирует ТЕКУЩУЮ ссылку (с учётом слайдера).
    UITapGestureRecognizer *tap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(yt_copy:)];
    copyIcon.userInteractionEnabled = YES;
    [copyIcon addGestureRecognizer:tap];

    return self;
}

// Выставляет значения извне и рисует согласованное состояние.
- (void)configureWithItem:(YTShareItemSource *)item
                  baseURL:(NSString *)baseURL
                 duration:(NSTimeInterval)duration
                 selected:(NSTimeInterval)selected {
    self.item = item;
    self.baseURL = baseURL;
    self.duration = (duration > 1) ? duration : 0;
    self.selected = MAX(0, selected);

    BOOL haveSlider = (self.duration > 0);
    self.slider.hidden = !haveSlider;
    if (haveSlider) {
        self.slider.minimumValue = 0;
        self.slider.maximumValue = (float)self.duration;
        self.slider.value = (float)MIN(self.selected, self.duration);
    }
    self.toggle.on = (self.selected > 0);
    // Высота должна учитывать состояние toggle СРАЗУ, иначе при clipsToBounds
    // слайдер окажется за пределами свёрнутого контейнера и будет обрезан.
    [self applyHeightAnimated:NO];
    [self refreshUI];
}

- (NSString *)currentURL {
    if (!self.toggle.on || self.selected <= 0 || self.baseURL.length == 0)
        return self.baseURL;
    return [NSString stringWithFormat:@"%@&t=%lds", self.baseURL, (long)lround(self.selected)];
}

- (void)refreshUI {
    self.timeLabel.text = formatSeconds((NSInteger)lround(self.selected));
    // Пush текущую ссылку в item source — шторка отдаст именно её.
    if (self.item) self.item.url = [self currentURL];
}

- (void)toggleChanged:(UISwitch *)sender {
    [self applyHeightAnimated:YES];
    [self refreshUI];
}

- (void)sliderChanged:(UISlider *)sender {
    self.selected = lround(sender.value);
    self.timeLabel.text = formatSeconds((NSInteger)self.selected);
    [self refreshUI];
}

- (void)yt_copy:(UITapGestureRecognizer *)sender {
    NSString *url = [self currentURL];
    if (url.length == 0) return;
    [UIPasteboard generalPasteboard].string = url;
    if (@available(iOS 10.0, *)) {
        [[[UINotificationFeedbackGenerator alloc] init]
            notificationOccurred:UINotificationFeedbackTypeSuccess];
    }
}

- (void)applyHeightAnimated:(BOOL)animated {
    BOOL expanded = self.toggle.on && self.duration > 0;
    self.heightConstraint.constant = expanded ? kYTExpandedH : kYTCollapsedH;
    if (animated) {
        [UIView animateWithDuration:0.25
                              delay:0
                            options:UIViewAnimationOptionCurveEaseInOut
                         animations:^{ [self layoutIfNeeded]; }
                         completion:nil];
    }
}

@end

// Помечает, что полоса уже вставлена, чтобы не дублировать при каждой раскладке.
static const char kYTStripAttachedKey;

// Ставит селектор тайм-кода внутрь share sheet. Не ищем таблицу — раньше это
// не сработало (структура меню на iOS 27 неизвестна). Вешаем прямо на view
// контроллера, закрепив сверху: так он виден всегда.
// Высоту держит сам селектор (heightConstraint), мы её не фиксируем.
static void attachTimecodeStrip(UIActivityViewController *vc, YTShareItemSource *item,
                                NSString *baseURL, NSTimeInterval duration, NSTimeInterval selected) {
    if (baseURL.length == 0) return;

    // Уже прикреплена — держим ПОВЕРХ системного контента.
    UIView *existing = objc_getAssociatedObject(vc, &kYTStripAttachedKey);
    if (existing) {
        if (existing.superview == vc.view)
            [vc.view bringSubviewToFront:existing];
        return;
    }
    if (!vc.isViewLoaded) return;
    if (vc.view.window == nil) return;   // ещё не показан — попробуем при следующей раскладке

    CGFloat w = vc.view.bounds.size.width;
    if (w <= 0) w = UIScreen.mainScreen.bounds.size.width;

    YTTimecodeStripView *strip = [[YTTimecodeStripView alloc] initWithFrame:CGRectMake(0, 0, w, 52)];
    [strip configureWithItem:item baseURL:baseURL duration:duration selected:selected];
    strip.translatesAutoresizingMaskIntoConstraints = NO;
    [vc.view addSubview:strip];

    // Якорим по safeAreaLayoutGuide, а не по сырому верху view:
    // сырой верх уходит под grabber и скруглённую шапку листа — полоса
    // оказывалась выше видимой области и обрезалась.
    UILayoutGuide *guide = vc.view.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [strip.topAnchor constraintEqualToAnchor:guide.topAnchor],
        [strip.leadingAnchor constraintEqualToAnchor:vc.view.leadingAnchor],
        [strip.trailingAnchor constraintEqualToAnchor:vc.view.trailingAnchor],
    ]];

    objc_setAssociatedObject(vc, &kYTStripAttachedKey, strip, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
}

// ── Запоминаем активный плеер (отсюда берём mediaTime + videoID) ──────────────
%hook YTMainAppVideoPlayerOverlayViewController

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    gLastPlayerOverlay = self;
}

%end

// ── Вставляем полосу тайм-кодов, когда структура share sheet построена ────────
// Вызов идёт только если наши ассоциированные объекты есть — чужие share sheet
// (из других приложений) не трогаем: проверка по ключу ничего не находит и
// функция выходит сразу.
%hook UIActivityViewController

// Гарантированный момент: к viewDidAppear окно уже привязано, поэтому
// проверка window != nil пройдёт точно. viewDidLayoutSubviews может вызваться
// ДО привязки к окну — тогда attach молча откладывался.
- (void)viewDidAppear:(BOOL)animated {
    %orig;
    NSString *base = objc_getAssociatedObject(self, &kYTTimecodeBaseKey);
    if (base.length == 0) return;
    YTShareItemSource *item = objc_getAssociatedObject(self, &kYTTimecodeItemKey);
    NSNumber *dur = objc_getAssociatedObject(self, &kYTTimecodeDurationKey);
    NSNumber *sel = objc_getAssociatedObject(self, &kYTTimecodeSelectedKey);
    attachTimecodeStrip(self, item, base, dur.doubleValue, sel.doubleValue);
}

- (void)viewDidLayoutSubviews {
    %orig;
    NSString *base = objc_getAssociatedObject(self, &kYTTimecodeBaseKey);
    if (base.length == 0) return;

    YTShareItemSource *item = objc_getAssociatedObject(self, &kYTTimecodeItemKey);
    NSNumber *dur = objc_getAssociatedObject(self, &kYTTimecodeDurationKey);
    NSNumber *sel = objc_getAssociatedObject(self, &kYTTimecodeSelectedKey);
    attachTimecodeStrip(self, item, base, dur.doubleValue, sel.doubleValue);
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

    // 5. Селектор тайм-кода — встраивается в сам share sheet.
    //    Ставим ТОЛЬКО для видео (watch/shorts): для playlist/channel/clip
    //    выбор времени бессмыслен, и там просто родная шторка.
    BOOL isVideo = ([baseURL containsString:@"/watch?v="] ||
                    [baseURL containsString:@"/shorts/"]);
    if (isVideo) {
        NSTimeInterval cur = gLastPlayerOverlay ? gLastPlayerOverlay.mediaTime : 0;
        if (cur < 0) cur = 0;

        // item изначально несёт ссылку с тайм-кодом (если плеер активен) —
        // как раньше. Селектор при открытии перезапишет item.url согласованно.
        objc_setAssociatedObject(vc, &kYTTimecodeItemKey, item, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(vc, &kYTTimecodeBaseKey, baseURL, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(vc, &kYTTimecodeDurationKey,
                                 @(currentDuration()), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
        objc_setAssociatedObject(vc, &kYTTimecodeSelectedKey,
                                 @(cur), OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }

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
    // 6. Ограничиваем высоту листа — иначе дефолтный .large() растянет шторку
    //    на весь экран (~95%), и полосе тайм-кодов сверху не останется места.
    applySheetHeightCap(vc);

    [top presentViewController:vc animated:YES completion:nil];
}

%end

%ctor {
    NSLog(@"[YouTubePlus] Hybrid Native Share + Timecode module loaded.");
}
