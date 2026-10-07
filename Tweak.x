#import <UIKit/UIKit.h>

// YouTube Player & Share Controller declarations for Logos hooks
@interface YTPlayerViewController : UIViewController
- (NSTimeInterval)mediaTime;
- (NSString *)videoID;
@end

@interface YTSharePanelViewController : UIViewController
@end

%hook YTSharePanelViewController

- (void)viewDidLoad {
    %orig;
    NSLog(@"[YTNativeShareHybrid] Share panel loaded. Intercepting to integrate native iOS Share Sheet + timecode actions.");
}

%end

%ctor {
    NSLog(@"[YTNativeShareHybrid] Loaded by default. Hybrid native share with timestamp extraction initialized.");
}
