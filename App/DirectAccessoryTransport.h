#import <Foundation/Foundation.h>
NS_ASSUME_NONNULL_BEGIN
/// Direct accessory transport. All methods and callbacks run on the main queue.
@interface DirectAccessoryTransport : NSObject
@property(nonatomic, copy, nullable) void (^onData)(NSData *data);
- (BOOL)startWithIdentifier:(NSString *)identifier transportType:(NSUInteger)transportType error:(NSError **)error;
- (BOOL)sendData:(NSData *)data error:(NSError **)error;
- (void)stop;
/// 诊断：列出 CoreAccessories ACCTransportClient 上与投屏相关的私有方法（名字/参数个数），
/// 用来对比不同 iOS 版本，定位「连不上 CarPlay」是哪个方法签名变了。
+ (NSString *)coreAccessoriesDiagnostics;
@end
NS_ASSUME_NONNULL_END
