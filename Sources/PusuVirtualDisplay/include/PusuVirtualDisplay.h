#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

/// macOS'un sanal ekran arayüzü (CGVirtualDisplay) üzerinde ince bir sarmalayıcı.
///
/// Nesne yaşadığı sürece macOS gerçek bir monitör takılıymış gibi davranır; nesne serbest
/// bırakıldığında (ya da süreç kapandığında) ekran kendiliğinden kaybolur. Arayüz resmi
/// değildir: bulunamazsa `init` `nil` döner.
@interface PusuVirtualDisplay : NSObject

- (nullable instancetype)initWithWidth:(unsigned int)width
                                height:(unsigned int)height
                                  name:(NSString *)name NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

@property (nonatomic, readonly) CGDirectDisplayID displayID;

/// Bu Mac'te sanal ekran arayüzü var mı?
+ (BOOL)isSupported;

@end

NS_ASSUME_NONNULL_END
