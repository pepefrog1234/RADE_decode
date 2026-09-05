#import "FDVExceptionGuard.h"

NSException * _Nullable FDVCatchObjCException(void (NS_NOESCAPE ^block)(void)) {
    @try {
        block();
        return nil;
    } @catch (NSException *exception) {
        return exception;
    }
}
