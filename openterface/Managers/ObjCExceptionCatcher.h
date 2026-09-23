#ifndef ObjCExceptionCatcher_h
#define ObjCExceptionCatcher_h

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface ObjCExceptionCatcher : NSObject

/**
 * Executes a block and catches any Objective-C exceptions that are thrown.
 *
 * @param tryBlock The block to execute
 * @return YES if no exception was thrown, NO if an exception was caught
 */
+ (BOOL)catchException:(void (^)())tryBlock;

@end

NS_ASSUME_NONNULL_END
#endif /* ObjCExceptionCatcher_h */