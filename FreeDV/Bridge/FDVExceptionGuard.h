#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Runs `block` and returns the Objective-C exception it raised, or nil when it
/// completed normally.
///
/// Swift cannot catch NSException. AVFAudio reports precondition failures —
/// a second tap on a bus ("nullptr == Tap()"), a tap format whose sample rate
/// differs from the hardware — by raising one, which terminates the process.
/// Wrap such calls in this so a failed precondition becomes a logged failure.
///
/// The caught exception's `name` and `reason` carry AVFAudio's message.
FOUNDATION_EXPORT NSException * _Nullable FDVCatchObjCException(void (NS_NOESCAPE ^block)(void));

NS_ASSUME_NONNULL_END
