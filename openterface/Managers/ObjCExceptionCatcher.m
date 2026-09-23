#import "ObjCExceptionCatcher.h"

@implementation ObjCExceptionCatcher

+ (BOOL)catchException:(void (^)())tryBlock {
    @try {
        tryBlock();
        return YES;
    } @catch (NSException *exception) {
        return NO;
    }
}

@end