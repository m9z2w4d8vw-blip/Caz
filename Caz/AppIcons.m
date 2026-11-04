#import "AppIcons.h"

// Private UIKit class method that returns an app's icon by bundle ID. TrollStore and Filza use it
// to show icons for other apps.
@interface UIImage (CazPrivate)
+ (instancetype)_applicationIconImageForBundleIdentifier:(NSString *)bundleIdentifier format:(int)format scale:(CGFloat)scale;
@end

UIImage *CazAppIcon(NSString *bundleIdentifier) {
    if (![UIImage respondsToSelector:@selector(_applicationIconImageForBundleIdentifier:format:scale:)]) return nil;
    CGFloat scale = UITraitCollection.currentTraitCollection.displayScale;
    if (scale < 1) scale = 3;
    // Format 2 is the 60 pt home screen icon, already masked to the icon shape.
    return [UIImage _applicationIconImageForBundleIdentifier:bundleIdentifier format:2 scale:scale];
}
