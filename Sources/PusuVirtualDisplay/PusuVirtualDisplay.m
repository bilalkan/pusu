#import "PusuVirtualDisplay.h"

// CoreGraphics'in özel sınıfları. Doğrudan bağlanmazlar; çalışma anında NSClassFromString
// ile bulunurlar, böylece sınıflar yoksa uygulama açılışta çökmez.
@protocol PusuCGVirtualDisplayDescriptor <NSObject>
@property (retain, nonatomic) dispatch_queue_t queue;
@property (retain, nonatomic) NSString *name;
@property (nonatomic) unsigned int maxPixelsHigh;
@property (nonatomic) unsigned int maxPixelsWide;
@property (nonatomic) CGSize sizeInMillimeters;
@property (nonatomic) unsigned int productID;
@property (nonatomic) unsigned int vendorID;
@property (nonatomic) unsigned int serialNum;
@end

@protocol PusuCGVirtualDisplayMode <NSObject>
- (instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height refreshRate:(double)refreshRate;
@end

@protocol PusuCGVirtualDisplaySettings <NSObject>
@property (retain, nonatomic) NSArray *modes;
@property (nonatomic) unsigned int hiDPI;
@end

@protocol PusuCGVirtualDisplay <NSObject>
- (instancetype)initWithDescriptor:(id)descriptor;
- (BOOL)applySettings:(id)settings;
@property (readonly, nonatomic) unsigned int displayID;
@end

@implementation PusuVirtualDisplay {
    id<PusuCGVirtualDisplay> _display;
}

+ (BOOL)isSupported {
    return NSClassFromString(@"CGVirtualDisplay") != nil
        && NSClassFromString(@"CGVirtualDisplayDescriptor") != nil
        && NSClassFromString(@"CGVirtualDisplaySettings") != nil
        && NSClassFromString(@"CGVirtualDisplayMode") != nil;
}

- (nullable instancetype)initWithWidth:(unsigned int)width height:(unsigned int)height name:(NSString *)name {
    self = [super init];
    if (!self || ![PusuVirtualDisplay isSupported]) { return nil; }

    id<PusuCGVirtualDisplayDescriptor> descriptor = [[NSClassFromString(@"CGVirtualDisplayDescriptor") alloc] init];
    if (!descriptor) { return nil; }
    descriptor.queue = dispatch_get_main_queue();
    descriptor.name = name;
    descriptor.maxPixelsWide = width;
    descriptor.maxPixelsHigh = height;
    // ~24 inç: macOS ölçeklemeyi buna göre seçer.
    descriptor.sizeInMillimeters = CGSizeMake(518, 324);
    descriptor.vendorID = 0x5055;  // "PU"
    descriptor.productID = 0x5355; // "SU"
    descriptor.serialNum = 1;

    id<PusuCGVirtualDisplay> display = [(id<PusuCGVirtualDisplay>)[NSClassFromString(@"CGVirtualDisplay") alloc] initWithDescriptor:descriptor];
    if (!display) { return nil; }

    id<PusuCGVirtualDisplaySettings> settings = [[NSClassFromString(@"CGVirtualDisplaySettings") alloc] init];
    id<PusuCGVirtualDisplayMode> mode = [(id<PusuCGVirtualDisplayMode>)[NSClassFromString(@"CGVirtualDisplayMode") alloc]
        initWithWidth:width height:height refreshRate:60];
    if (!settings || !mode) { return nil; }
    settings.hiDPI = 0;
    settings.modes = @[mode];
    if (![display applySettings:settings] || display.displayID == 0) { return nil; }

    _display = display;
    return self;
}

- (CGDirectDisplayID)displayID {
    return _display.displayID;
}

@end
