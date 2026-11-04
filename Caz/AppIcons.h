#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

/// An installed app's home screen icon from iOS's icon cache, or nil if iOS can't provide one.
UIImage * _Nullable CazAppIcon(NSString *bundleIdentifier);

NS_ASSUME_NONNULL_END
