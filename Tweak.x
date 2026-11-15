// GlassCC - tambahan Control Center: 3 tab (Favorit / Media / Konektivitas), scroll antar halaman, tombol power.
// Target: iOS 15 (SpringBoard). Build dengan Theos. Setting: Settings > GlassCC.

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreMotion/CoreMotion.h>
#import <objc/runtime.h>
#import <objc/message.h>
#import <MediaPlayer/MediaPlayer.h>
#import <dlfcn.h>
#import <spawn.h>

#pragma mark - Pengaturan Liquid Glass (Settings > GlassCC > Tile Glass)

#define GC_DOMAIN CFSTR("com.hasan.glasscc")

static id GCPref(NSString *key) {
    return CFBridgingRelease(CFPreferencesCopyAppValue((__bridge CFStringRef)key, GC_DOMAIN));
}
static CGFloat GCNum(NSString *k, CGFloat def) {
    id v = GCPref(k);
    return [v respondsToSelector:@selector(doubleValue)] ? (CGFloat)[v doubleValue] : def;
}
static BOOL GCBool(NSString *k, BOOL def) {
    id v = GCPref(k);
    return [v respondsToSelector:@selector(boolValue)] ? [v boolValue] : def;
}
static CGFloat GCClamp(CGFloat v, CGFloat lo, CGFloat hi) { return MAX(lo, MIN(hi, v)); }
static UIColor *GCHexColor(id hex, CGFloat a, UIColor *def) {
    if ([hex isKindOfClass:NSString.class]) {
        NSString *h = [hex stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"# \n"]];
        unsigned v = 0;
        if (h.length == 6 && [[NSScanner scannerWithString:h] scanHexInt:&v])
            return [UIColor colorWithRed:((v >> 16) & 255) / 255.0 green:((v >> 8) & 255) / 255.0 blue:(v & 255) / 255.0 alpha:a];
    }
    return [def colorWithAlphaComponent:a];
}

@interface GCStyle : NSObject
@property (nonatomic) BOOL enabled, dispersion;
@property (nonatomic) CGFloat blur, refraction, index, thickness, bezel, dispStrength, corner;
@property (nonatomic) NSInteger spec;   // 0 None, 1 Border, 2 Glass, 3 iOS 26, 4 iOS 27
@property (nonatomic, strong) UIColor *lightTint, *darkTint;
+ (instancetype)loadWithPrefix:(NSString *)p;
@end
@implementation GCStyle
+ (instancetype)loadWithPrefix:(NSString *)p {
    GCStyle *s = [GCStyle new];
    #define K(x) [NSString stringWithFormat:@"%@.%@", p, x]
    s.enabled = GCBool(K(@"Enabled"), YES);
    s.blur = GCClamp(GCNum(K(@"Blur"), 20), 0, 60);
    s.refraction = GCClamp(GCNum(K(@"Refraction"), 0.35), -2, 2);
    s.index = GCClamp(GCNum(K(@"RefractiveIndex"), 1.5), 1, 2.5);
    s.thickness = GCClamp(GCNum(K(@"GlassThickness"), 1), 0.1, 4);
    s.bezel = GCClamp(GCNum(K(@"BezelWidth"), 10), 2, 60);
    s.spec = (NSInteger)GCNum(K(@"SpecularType"), 2);
    s.dispersion = GCBool(K(@"DispersionEnabled"), NO);
    s.dispStrength = GCClamp(GCNum(K(@"DispersionStrength"), 0.5), 0, 1);
    s.corner = GCClamp(GCNum(K(@"CornerRadius"), 100), 0, 100);
    s.lightTint = GCHexColor(GCPref(K(@"LightTint")), GCClamp(GCNum(K(@"LightTintAlpha"), 0.25), 0, 1), UIColor.whiteColor);
    s.darkTint = GCHexColor(GCPref(K(@"DarkTint")), GCClamp(GCNum(K(@"DarkTintAlpha"), 0.10), 0, 1), UIColor.whiteColor);
    #undef K
    return s;
}
@end

static BOOL gcMaster = YES, gcMotion = NO;
static CGFloat gcLiquidity = 1, gcQuality = 0.5, gcMotionSens = 1;
static GCStyle *gcStyle;

#pragma mark - Glass views (gaya Liquid Glass: backdrop blur + refraksi + specular rim + dispersi)

static id GCFilter(NSString *type) {
    Class CF = NSClassFromString(@"CAFilter");
    if (!CF) return nil;
    return ((id (*)(id, SEL, id))objc_msgSend)(CF, NSSelectorFromString(@"filterWithType:"), type);
}

// Peta displacement: di tepi (selebar "bezel") cahaya dibelokkan; 128 = netral
static UIImage *GCDisplacementMap(CGSize sz, CGFloat radius, GCStyle *st) {
    static NSCache *cache;
    if (!cache) { cache = [NSCache new]; cache.countLimit = 24; }
    int W = MAX(2, (int)lround(sz.width)), H = MAX(2, (int)lround(sz.height));
    NSString *key = [NSString stringWithFormat:@"%d,%d,%.1f,%.1f,%.2f,%.2f,%.2f", W, H, radius, st.bezel, st.refraction, st.index, st.thickness];
    UIImage *hit = [cache objectForKey:key];
    if (hit) return hit;
    CGFloat strength = GCClamp((st.index - 1.0) * st.refraction * st.thickness * 1.6, -1, 1);
    uint8_t *buf = malloc((size_t)W * H * 4);
    float hx = W / 2.0f, hy = H / 2.0f;
    float r = (float)MIN(radius, MIN(hx, hy)), bz = (float)MAX(1, st.bezel);
    for (int y = 0; y < H; y++) {
        for (int x = 0; x < W; x++) {
            float px = x + 0.5f - hx, py = y + 0.5f - hy;
            float qx = fabsf(px) - (hx - r), qy = fabsf(py) - (hy - r);
            float ox = MAX(qx, 0), oy = MAX(qy, 0);
            float outside = sqrtf(ox * ox + oy * oy);
            float sd = outside + MIN(MAX(qx, qy), 0) - r;     // negatif di dalam
            float d = -sd;
            uint8_t R = 128, G = 128;
            if (d >= 0 && d < bz) {
                float gx, gy;
                if (qx > 0 && qy > 0 && outside > 0) { gx = (px < 0 ? -ox : ox) / outside; gy = (py < 0 ? -oy : oy) / outside; }
                else if (qx > qy) { gx = px < 0 ? -1 : 1; gy = 0; }
                else { gx = 0; gy = py < 0 ? -1 : 1; }
                float t = 1.0f - d / bz;
                float m = powf(t, 2.2f) * (float)strength;
                R = (uint8_t)GCClamp(128 + 127 * gx * m, 0, 255);
                G = (uint8_t)GCClamp(128 + 127 * gy * m, 0, 255);
            }
            uint8_t *p = buf + ((size_t)y * W + x) * 4;
            p[0] = R; p[1] = G; p[2] = 128; p[3] = 255;
        }
    }
    CGColorSpaceRef cs = CGColorSpaceCreateDeviceRGB();
    CGContextRef ctx = CGBitmapContextCreate(buf, W, H, 8, (size_t)W * 4, cs, kCGImageAlphaPremultipliedLast | kCGBitmapByteOrder32Big);
    CGImageRef ci = CGBitmapContextCreateImage(ctx);
    UIImage *img = [UIImage imageWithCGImage:ci scale:1 orientation:UIImageOrientationUp];
    CGImageRelease(ci); CGContextRelease(ctx); CGColorSpaceRelease(cs); free(buf);
    [cache setObject:img forKey:key];
    return img;
}

// Ring tipis berwarna gradient (specular / dispersi), di-mask jadi garis tepi
@interface GCRimView : UIView
@property (nonatomic) CGFloat lineWidth;
- (void)setColors:(NSArray *)colors locations:(NSArray *)loc width:(CGFloat)w angle:(CGFloat)a;
- (void)setAngle:(CGFloat)a;
@end
@implementation GCRimView { CAShapeLayer *_mask; }
+ (Class)layerClass { return [CAGradientLayer class]; }
- (instancetype)initWithFrame:(CGRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    self.userInteractionEnabled = NO;
    self.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    _mask = [CAShapeLayer layer];
    _mask.fillColor = NULL;
    _mask.strokeColor = UIColor.whiteColor.CGColor;
    self.layer.mask = _mask;
    _lineWidth = 1;
    return self;
}
- (void)setColors:(NSArray *)colors locations:(NSArray *)loc width:(CGFloat)w angle:(CGFloat)a {
    CAGradientLayer *gl = (CAGradientLayer *)self.layer;
    NSMutableArray *cg = [NSMutableArray array];
    for (UIColor *c in colors) [cg addObject:(id)c.CGColor];
    gl.colors = cg;
    gl.locations = loc;
    _lineWidth = w;
    [self setAngle:a];
    [self setNeedsLayout];
}
- (void)setAngle:(CGFloat)a {
    CAGradientLayer *gl = (CAGradientLayer *)self.layer;
    CGFloat dx = cos(a) * 0.5, dy = sin(a) * 0.5;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    gl.startPoint = CGPointMake(0.5 - dx, 0.5 - dy);
    gl.endPoint = CGPointMake(0.5 + dx, 0.5 + dy);
    [CATransaction commit];
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat w = _lineWidth, r = self.superview.layer.cornerRadius;
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _mask.frame = self.bounds;
    _mask.lineWidth = w;
    _mask.path = [UIBezierPath bezierPathWithRoundedRect:CGRectInset(self.bounds, w / 2, w / 2) cornerRadius:MAX(0, r - w / 2)].CGPath;
    [CATransaction commit];
}
@end

@interface GCGlassView : UIView
@property (nonatomic, readonly) UIView *content;
@property (nonatomic) CGFloat maxRadius;                // 0 = tanpa batas
- (void)applyStyle;
- (void)setMotionAngle:(CGFloat)a;
- (CGFloat)radiusForSize:(CGSize)s;
@end

static NSHashTable<GCGlassView *> *GCRegistry(void) {
    static NSHashTable *t;
    if (!t) t = [NSHashTable weakObjectsHashTable];
    return t;
}

// Dasar kaca = UIVisualEffectView (backdrop yang pasti menangkap wallpaper), lalu filter
// backdrop-nya diganti (blur/saturasi/refraksi) dan lapisan gelap bawaannya disembunyikan
// supaya tampilannya ditentukan oleh tint + rim kita (lebih mirip dock / Control Center).
@implementation GCGlassView {
    UIVisualEffectView *_fx;
    UIView *_tint;
    GCRimView *_red, *_blue, *_spec;
    CGFloat _motion;
    NSString *_lastKey;
    BOOL _glassOn;
}
- (instancetype)initWithFrame:(CGRect)frame {
    if (!(self = [super initWithFrame:frame])) return nil;
    self.clipsToBounds = YES;
    self.layer.cornerCurve = kCACornerCurveContinuous;
    UIViewAutoresizing flex = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;

    _fx = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark]];
    _fx.frame = self.bounds; _fx.autoresizingMask = flex;
    [self addSubview:_fx];

    _tint = [[UIView alloc] initWithFrame:self.bounds];
    _tint.autoresizingMask = flex; _tint.userInteractionEnabled = NO;
    [self addSubview:_tint];

    _red = [[GCRimView alloc] initWithFrame:self.bounds];
    _blue = [[GCRimView alloc] initWithFrame:self.bounds];
    _spec = [[GCRimView alloc] initWithFrame:self.bounds];
    [self addSubview:_red]; [self addSubview:_blue]; [self addSubview:_spec];

    _content = [[UIView alloc] initWithFrame:self.bounds];
    _content.autoresizingMask = flex;
    [self addSubview:_content];

    [GCRegistry() addObject:self];
    [self applyStyle];
    return self;
}
- (GCStyle *)style {
    if (!gcStyle) gcStyle = [GCStyle loadWithPrefix:@"Tile"];
    return gcStyle;
}
- (CGFloat)radiusForSize:(CGSize)s {
    CGFloat full = MIN(s.width, s.height) / 2;
    if (_maxRadius > 0) full = MIN(full, _maxRadius);
    return full * [self style].corner / 100.0;
}
- (void)traitCollectionDidChange:(UITraitCollection *)prev {
    [super traitCollectionDidChange:prev];
    [self applyStyle];
}
- (void)didMoveToWindow {
    [super didMoveToWindow];
    _lastKey = nil;
    [self setNeedsLayout];
}
- (void)setMotionAngle:(CGFloat)a { _motion = a; [self updateSpecAngle]; }
- (void)updateSpecAngle { [_spec setAngle:M_PI_4 + _motion]; }

- (void)applyStyle {
    GCStyle *st = [self style];
    BOOL glass = st.enabled;
    if (_glassOn && !glass) {
        // kembali ke material bawaan: set ulang effect supaya UIKit memasang filter aslinya
        _fx.effect = nil;
        _fx.effect = [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemUltraThinMaterialDark];
    }
    _glassOn = glass;

    BOOL isDark = self.traitCollection.userInterfaceStyle != UIUserInterfaceStyleLight;
    _tint.backgroundColor = glass ? (isDark ? st.darkTint : st.lightTint) : UIColor.clearColor;

    UIColor *(^W)(CGFloat) = ^UIColor *(CGFloat a) { return [UIColor colorWithWhite:1 alpha:a]; };
    _spec.hidden = !(glass && st.spec > 0);
    switch (st.spec) {
        // tipis & halus seperti dock / Control Center; terang hanya di sudut kiri-atas & kanan-bawah
        case 1: [_spec setColors:@[W(0.22), W(0.22)] locations:@[@0, @1] width:0.7 angle:M_PI_4]; break;
        case 2: [_spec setColors:@[W(0.50), W(0.12), W(0.05), W(0.10), W(0.30)] locations:@[@0, @0.3, @0.55, @0.8, @1] width:0.8 angle:M_PI_4]; break;
        case 3: [_spec setColors:@[W(0.70), W(0.10), W(0.03), W(0.08), W(0.55)] locations:@[@0, @0.25, @0.5, @0.75, @1] width:0.9 angle:M_PI_4]; break;
        case 4: [_spec setColors:@[W(0.45), W(0.14), W(0.06), W(0.14), W(0.40)] locations:@[@0, @0.3, @0.5, @0.7, @1] width:1.1 angle:M_PI_4]; break;
        default: break;
    }
    [self updateSpecAngle];

    BOOL disp = glass && st.dispersion && st.dispStrength > 0.01;
    _red.hidden = _blue.hidden = !disp;
    if (disp) {
        CGFloat a = 0.35 * st.dispStrength;
        UIColor *rc = [UIColor colorWithRed:1 green:0.25 blue:0.25 alpha:a], *bc = [UIColor colorWithRed:0.25 green:0.55 blue:1 alpha:a];
        [_red setColors:@[rc, rc] locations:@[@0, @1] width:0.9 angle:M_PI_4];
        [_blue setColors:@[bc, bc] locations:@[@0, @1] width:0.9 angle:M_PI_4];
        CGFloat o = 0.3 + 0.9 * st.dispStrength;
        _red.transform = CGAffineTransformMakeTranslation(-o, -o);
        _blue.transform = CGAffineTransformMakeTranslation(o, o);
    }
    _lastKey = nil;
    [self setNeedsLayout];
}

- (void)refreshFilters {
    GCStyle *st = [self style];
    if (!st.enabled) return;
    CGSize sz = self.bounds.size;
    if (sz.width < 2 || sz.height < 2) return;

    // backdrop internal milik UIVisualEffectView + sembunyikan lapisan warna bawaannya
    UIView *bd = nil;
    for (UIView *s in _fx.subviews) {
        if (strstr(object_getClassName(s), "Backdrop")) bd = s;
        else s.hidden = YES;
    }
    if (!bd) return;

    NSMutableArray *f = [NSMutableArray array];
    if (fabs(st.refraction) > 0.001 && st.index > 1.001) {
        id d = GCFilter(@"displacementMap");
        UIImage *map = GCDisplacementMap(sz, self.layer.cornerRadius, st);
        if (d && map) {
            @try {
                [d setValue:(__bridge id)map.CGImage forKey:@"inputImage"];
                [d setValue:@(st.bezel * 1.2) forKey:@"inputAmount"];
                [f addObject:d];
            } @catch (id e) {}
        }
    }
    id blur = GCFilter(@"gaussianBlur");
    if (blur) {
        @try {
            [blur setValue:@(MAX(0.5, st.blur * gcLiquidity)) forKey:@"inputRadius"];
            [blur setValue:@YES forKey:@"inputNormalizeEdges"];
            [f addObject:blur];
        } @catch (id e) {}
    }
    id sat = GCFilter(@"colorSaturate");
    if (sat) { @try { [sat setValue:@1.8 forKey:@"inputAmount"]; [f addObject:sat]; } @catch (id e) {} }
    if (!f.count) return;       // filter privat tidak ada -> biarkan material bawaan

    CALayer *bl = bd.layer;
    @try {
        bl.filters = f;
        if ([bl respondsToSelector:NSSelectorFromString(@"setScale:")]) [bl setValue:@(gcQuality) forKey:@"scale"];
    } @catch (id e) {}
}

- (void)layoutSubviews {
    [super layoutSubviews];
    [_red setNeedsLayout]; [_blue setNeedsLayout]; [_spec setNeedsLayout];
    NSString *k = [NSString stringWithFormat:@"%.1f,%.1f,%.1f", self.bounds.size.width, self.bounds.size.height, self.layer.cornerRadius];
    if ([k isEqualToString:_lastKey]) return;
    _lastKey = k;
    [self refreshFilters];
}
@end


// Highlight mengikuti arah perangkat (kompas)
@interface GCMotion : NSObject
+ (void)refresh;
@end
@implementation GCMotion
+ (void)refresh {
    static CMMotionManager *mm;
    BOOL want = gcMotion && gcMaster && GCRegistry().count > 0;
    if (want && !mm) {
        mm = [CMMotionManager new];
        mm.deviceMotionUpdateInterval = 1.0 / 30;
        CMAttitudeReferenceFrame fr = ([CMMotionManager availableAttitudeReferenceFrames] & CMAttitudeReferenceFrameXMagneticNorthZVertical)
            ? CMAttitudeReferenceFrameXMagneticNorthZVertical : CMAttitudeReferenceFrameXArbitraryZVertical;
        [mm startDeviceMotionUpdatesUsingReferenceFrame:fr toQueue:NSOperationQueue.mainQueue withHandler:^(CMDeviceMotion *m, NSError *e) {
            if (!m) return;
            CGFloat a = m.attitude.yaw * gcMotionSens;
            for (GCGlassView *v in GCRegistry().allObjects) [v setMotionAngle:a];
        }];
    } else if (!want && mm) {
        [mm stopDeviceMotionUpdates];
        mm = nil;
        for (GCGlassView *v in GCRegistry().allObjects) [v setMotionAngle:0];
    }
}
@end

static BOOL gcTabs = YES, gcPower = YES, gcShrink = YES;
static CGFloat gcPowerY = 40;

static void GCLoadPrefs(void) {
    CFPreferencesAppSynchronize(GC_DOMAIN);
    gcMaster = GCBool(@"Enabled", YES);
    gcLiquidity = GCClamp(GCNum(@"Liquidity", 1), 0.2, 3);
    gcQuality = GCClamp(GCNum(@"Quality", 0.5), 0.15, 1);
    gcMotion = GCBool(@"MotionHighlights", NO);
    gcMotionSens = GCClamp(GCNum(@"MotionSensitivity", 1), 0, 3);
    gcTabs = GCBool(@"TabButtons", YES);
    gcPower = GCBool(@"PowerButton", YES);
    gcShrink = GCBool(@"ShrinkModules", YES);
    gcPowerY = GCClamp(GCNum(@"PowerY", 40), 0, 160);
    gcStyle = [GCStyle loadWithPrefix:@"Tile"];
    for (GCGlassView *v in GCRegistry().allObjects) [v applyStyle];
    [GCMotion refresh];
}

#pragma mark - Util

static UIImage *GCSymAny(NSArray<NSString *> *names, CGFloat size, UIImageSymbolWeight w) {
    UIImageSymbolConfiguration *cfg = [UIImageSymbolConfiguration configurationWithPointSize:size weight:w];
    for (NSString *n in names) {
        UIImage *i = [UIImage systemImageNamed:n withConfiguration:cfg];
        if (i) return i;
    }
    return nil;
}
static UIImage *GCSym(NSString *name, CGFloat size, UIImageSymbolWeight w) { return GCSymAny(@[name], size, w); }

static UIView *GCFindViewNamed(UIView *root, NSString *part, int depth) {
    if (!root || depth > 10) return nil;
    NSString *n = NSStringFromClass([root class]);
    if ([n containsString:part] && ![n containsString:@"Controller"]) return root;
    for (UIView *s in root.subviews) {
        UIView *r = GCFindViewNamed(s, part, depth + 1);
        if (r) return r;
    }
    return nil;
}

static void GCCollectNamed(UIView *root, NSString *part, int depth, NSMutableArray *out) {
    if (!root || depth > 5) return;
    for (UIView *s in root.subviews) {
        if ([NSStringFromClass([s class]) containsString:part]) [out addObject:s];
        else GCCollectNamed(s, part, depth + 1, out);
    }
}

static void GCOpenURL(NSString *u) {
    NSURL *url = [NSURL URLWithString:u];
    if (!url) return;
    Class c = NSClassFromString(@"LSApplicationWorkspace");
    id ws = [c performSelector:NSSelectorFromString(@"defaultWorkspace")];
    SEL s = NSSelectorFromString(@"openSensitiveURL:withOptions:");
    if ([ws respondsToSelector:s]) ((BOOL (*)(id, SEL, id, id))objc_msgSend)(ws, s, url, nil);
}

#pragma mark - Aksi sistem (Power / Radio)

extern char **environ;

static void GCShutdown(BOOL reboot) {
    id svc = [NSClassFromString(@"FBSystemService") performSelector:NSSelectorFromString(@"sharedInstance")];
    SEL s = NSSelectorFromString(@"shutdownAndReboot:");
    if ([svc respondsToSelector:s]) ((void (*)(id, SEL, BOOL))objc_msgSend)(svc, s, reboot);
}

static void GCRespring(void) {
    for (NSString *p in @[@"/var/jb/usr/bin/sbreload", @"/usr/bin/sbreload"]) {
        if (![NSFileManager.defaultManager fileExistsAtPath:p]) continue;
        pid_t pid;
        char *args[] = {(char *)"sbreload", NULL};
        posix_spawn(&pid, p.fileSystemRepresentation, NULL, NULL, args, environ);
        return;
    }
    exit(0);
}

static id GCObj(NSString *cls, NSString *sel) {
    Class c = NSClassFromString(cls);
    SEL s = NSSelectorFromString(sel);
    if (!c || ![c respondsToSelector:s]) return nil;
    return ((id (*)(id, SEL))objc_msgSend)(c, s);
}
static BOOL GCGetBool(id o, NSString *sel, BOOL *ok) {
    SEL s = NSSelectorFromString(sel);
    if (!o || ![o respondsToSelector:s]) { if (ok) *ok = NO; return NO; }
    if (ok) *ok = YES;
    return ((BOOL (*)(id, SEL))objc_msgSend)(o, s);
}
static void GCSetBool(id o, NSString *sel, BOOL v) {
    SEL s = NSSelectorFromString(sel);
    if (o && [o respondsToSelector:s]) ((void (*)(id, SEL, BOOL))objc_msgSend)(o, s, v);
}

static id GCRadios(void) {
    static id rp;
    if (!rp) {
        Class c = NSClassFromString(@"RadiosPreferences");
        if (c) rp = [[c alloc] init];
    }
    return rp;
}
static BOOL GCAirplane(void) { return GCGetBool(GCRadios(), @"airplaneMode", NULL); }
static void GCSetAirplane(BOOL v) {
    id r = GCRadios();
    GCSetBool(r, @"setAirplaneMode:", v);
    if ([r respondsToSelector:NSSelectorFromString(@"synchronize")]) [r performSelector:NSSelectorFromString(@"synchronize")];
}
static BOOL GCWiFi(void) { return GCGetBool(GCObj(@"SBWiFiManager", @"sharedInstance"), @"wiFiEnabled", NULL); }
static void GCSetWiFi(BOOL v) { GCSetBool(GCObj(@"SBWiFiManager", @"sharedInstance"), @"setWiFiEnabled:", v); }
static BOOL GCBluetooth(void) {
    id b = GCObj(@"BluetoothManager", @"sharedInstance");
    BOOL ok = NO; BOOL v = GCGetBool(b, @"enabled", &ok);
    return ok ? v : GCGetBool(b, @"powered", NULL);
}
static void GCSetBluetooth(BOOL v) {
    id b = GCObj(@"BluetoothManager", @"sharedInstance");
    GCSetBool(b, @"setPowered:", v);
    GCSetBool(b, @"setEnabled:", v);
}
static BOOL GCCellular(void) {
    typedef BOOL (*Fn)(void);
    Fn f = (Fn)dlsym(RTLD_DEFAULT, "CTCellularDataPlanGetIsEnabled");
    return f ? f() : NO;
}
static void GCSetCellular(BOOL v) {
    typedef void (*Fn)(BOOL);
    Fn f = (Fn)dlsym(RTLD_DEFAULT, "CTCellularDataPlanSetIsEnabled");
    if (f) f(v);
}

#pragma mark - MediaRemote

typedef void (*GCMRGetInfo)(dispatch_queue_t, void (^)(CFDictionaryRef));
typedef Boolean (*GCMRSend)(int, id);
typedef void (*GCMRRegister)(dispatch_queue_t);
typedef void (*GCMRPlaying)(dispatch_queue_t, void (^)(Boolean));

static GCMRGetInfo gcMRInfo; static GCMRSend gcMRSend; static GCMRRegister gcMRReg; static GCMRPlaying gcMRPlaying;

static void GCLoadMR(void) {
    static dispatch_once_t t;
    dispatch_once(&t, ^{
        void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_LAZY);
        if (!h) return;
        gcMRInfo = (GCMRGetInfo)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
        gcMRSend = (GCMRSend)dlsym(h, "MRMediaRemoteSendCommand");
        gcMRReg = (GCMRRegister)dlsym(h, "MRMediaRemoteRegisterForNowPlayingNotifications");
        gcMRPlaying = (GCMRPlaying)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
        if (gcMRReg) gcMRReg(dispatch_get_main_queue());
    });
}

#pragma mark - Tombol bulat kaca

@interface GCCircle : GCGlassView
@property (nonatomic, strong) UIImageView *icon;
- (instancetype)initWithSize:(CGFloat)d symbol:(NSArray<NSString *> *)sym iconSize:(CGFloat)is;
@end
@implementation GCCircle
- (instancetype)initWithSize:(CGFloat)d symbol:(NSArray<NSString *> *)sym iconSize:(CGFloat)is {
    if (!(self = [super initWithFrame:CGRectMake(0, 0, d, d)])) return nil;
    self.layer.cornerRadius = d / 2;
    _icon = [[UIImageView alloc] initWithImage:GCSymAny(sym, is, UIImageSymbolWeightSemibold)];
    _icon.tintColor = UIColor.whiteColor;
    _icon.contentMode = UIViewContentModeCenter;
    _icon.frame = self.bounds;
    _icon.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self.content addSubview:_icon];
    return self;
}
@end

#pragma mark - Halaman Media

@interface GCMediaPage : UIView
- (void)refresh;
- (void)setVisible:(BOOL)v;
@end

@implementation GCMediaPage {
    GCGlassView *_card;
    UIImageView *_art;
    UILabel *_title, *_artist, *_elapsed, *_remain;
    UIView *_track, *_fill;
    UIButton *_prev, *_play, *_next;
    MPVolumeView *_vol;
    NSTimer *_timer;
    BOOL _playing;
}
- (instancetype)initWithFrame:(CGRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    GCLoadMR();
    _card = [[GCGlassView alloc] initWithFrame:self.bounds];
    _card.maxRadius = 30;
    _card.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_card];
    UIView *c = _card.content;

    _art = [UIImageView new];
    _art.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
    _art.layer.cornerRadius = 14; _art.clipsToBounds = YES;
    _art.contentMode = UIViewContentModeScaleAspectFill;
    _art.tintColor = [UIColor colorWithWhite:1 alpha:0.7];
    [c addSubview:_art];

    _title = [UILabel new]; _title.textColor = UIColor.whiteColor;
    _title.font = [UIFont systemFontOfSize:20 weight:UIFontWeightBold];
    _artist = [UILabel new]; _artist.textColor = [UIColor colorWithWhite:1 alpha:0.65];
    _artist.font = [UIFont systemFontOfSize:15 weight:UIFontWeightMedium];
    [c addSubview:_title]; [c addSubview:_artist];

    _track = [UIView new]; _track.backgroundColor = [UIColor colorWithWhite:1 alpha:0.25];
    _track.layer.cornerRadius = 2.5;
    _fill = [UIView new]; _fill.backgroundColor = UIColor.whiteColor; _fill.layer.cornerRadius = 2.5;
    [_track addSubview:_fill]; [c addSubview:_track];
    _elapsed = [UILabel new]; _remain = [UILabel new];
    for (UILabel *l in @[_elapsed, _remain]) {
        l.textColor = [UIColor colorWithWhite:1 alpha:0.6];
        l.font = [UIFont monospacedDigitSystemFontOfSize:11 weight:UIFontWeightMedium];
        [c addSubview:l];
    }
    _remain.textAlignment = NSTextAlignmentRight;

    _prev = [self button:@"backward.fill" size:26 action:@selector(prevTapped)];
    _play = [self button:@"play.fill" size:34 action:@selector(playTapped)];
    _next = [self button:@"forward.fill" size:26 action:@selector(nextTapped)];
    [c addSubview:_prev]; [c addSubview:_play]; [c addSubview:_next];

    _vol = [[MPVolumeView alloc] initWithFrame:CGRectZero];
    _vol.showsRouteButton = NO;
    [c addSubview:_vol];
    [self setNeedsLayout];
    [self showEmpty];
    return self;
}
- (UIButton *)button:(NSString *)sym size:(CGFloat)sz action:(SEL)a {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setImage:GCSym(sym, sz, UIImageSymbolWeightBold) forState:UIControlStateNormal];
    b.tintColor = UIColor.whiteColor;
    [b addTarget:self action:a forControlEvents:UIControlEventTouchUpInside];
    return b;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height, p = 20;
    CGFloat art = MIN(96, H * 0.22);
    _art.frame = CGRectMake(p, p, art, art);
    _title.frame = CGRectMake(p + art + 14, p + art * 0.18, W - 2 * p - art - 14, 26);
    _artist.frame = CGRectMake(p + art + 14, CGRectGetMaxY(_title.frame) + 2, W - 2 * p - art - 14, 20);
    CGFloat ty = p + art + MAX(18, H * 0.06);
    _track.frame = CGRectMake(p, ty, W - 2 * p, 5);
    _elapsed.frame = CGRectMake(p, ty + 10, 70, 14);
    _remain.frame = CGRectMake(W - p - 70, ty + 10, 70, 14);
    CGFloat cy = ty + 30 + MAX(20, H * 0.07);
    _play.frame = CGRectMake(W / 2 - 32, cy, 64, 64);
    _prev.frame = CGRectMake(W / 2 - 32 - 90, cy, 64, 64);
    _next.frame = CGRectMake(W / 2 + 32 + 26, cy, 64, 64);
    _vol.frame = CGRectMake(p, MIN(H - 56, cy + 64 + MAX(18, H * 0.06)), W - 2 * p, 40);
}
- (NSString *)fmt:(double)s {
    if (!isfinite(s) || s < 0) s = 0;
    int t = (int)s;
    return [NSString stringWithFormat:@"%d:%02d", t / 60, t % 60];
}
- (void)showEmpty {
    _title.text = @"Tidak Diputar";
    _artist.text = @"";
    _art.image = GCSym(@"music.note", 34, UIImageSymbolWeightMedium);
    _art.contentMode = UIViewContentModeCenter;
    _elapsed.text = @"0:00"; _remain.text = @"-0:00";
    _fill.frame = CGRectMake(0, 0, 0, 5);
    [self setPlaying:NO];
}
- (void)setPlaying:(BOOL)p {
    _playing = p;
    [_play setImage:GCSym(p ? @"pause.fill" : @"play.fill", 34, UIImageSymbolWeightBold) forState:UIControlStateNormal];
}
- (void)refresh {
    if (!gcMRInfo) return;
    __weak GCMediaPage *w = self;
    gcMRInfo(dispatch_get_main_queue(), ^(CFDictionaryRef cf) {
        GCMediaPage *s = w;
        if (!s) return;
        NSDictionary *d = (__bridge NSDictionary *)cf;
        NSString *title = d[@"kMRMediaRemoteNowPlayingInfoTitle"];
        if (!title.length) { [s showEmpty]; return; }
        s->_title.text = title;
        s->_artist.text = d[@"kMRMediaRemoteNowPlayingInfoArtist"] ?: @"";
        NSData *art = d[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        UIImage *img = art ? [UIImage imageWithData:art] : nil;
        if (img) { s->_art.image = img; s->_art.contentMode = UIViewContentModeScaleAspectFill; }
        else { s->_art.image = GCSym(@"music.note", 34, UIImageSymbolWeightMedium); s->_art.contentMode = UIViewContentModeCenter; }
        double dur = [d[@"kMRMediaRemoteNowPlayingInfoDuration"] doubleValue];
        double el = [d[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] doubleValue];
        double rate = [d[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] doubleValue];
        NSDate *ts = d[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
        if (rate > 0 && ts) el += [NSDate.date timeIntervalSinceDate:ts] * rate;
        if (dur > 0 && el > dur) el = dur;
        s->_elapsed.text = [s fmt:el];
        s->_remain.text = dur > 0 ? [@"-" stringByAppendingString:[s fmt:dur - el]] : @"";
        CGFloat tw = s->_track.bounds.size.width;
        s->_fill.frame = CGRectMake(0, 0, dur > 0 ? tw * MIN(1, el / dur) : 0, 5);
        [s setPlaying:rate > 0];
    });
}
- (void)setVisible:(BOOL)v {
    if (v && !_timer) {
        [self refresh];
        _timer = [NSTimer scheduledTimerWithTimeInterval:1 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
    } else if (!v && _timer) {
        [_timer invalidate]; _timer = nil;
    }
}
- (void)prevTapped { if (gcMRSend) gcMRSend(5, nil); [self refreshSoon]; }
- (void)nextTapped { if (gcMRSend) gcMRSend(4, nil); [self refreshSoon]; }
- (void)playTapped { if (gcMRSend) gcMRSend(2, nil); [self setPlaying:!_playing]; [self refreshSoon]; }
- (void)refreshSoon {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self refresh]; });
}
@end

#pragma mark - Halaman Konektivitas

@interface GCTile : GCGlassView
@property (nonatomic, strong) UIImageView *icon;
@property (nonatomic, strong) UILabel *title, *sub;
@property (nonatomic, strong) UIColor *accent;
@property (nonatomic, copy) BOOL (^getState)(void);
@property (nonatomic, copy) void (^toggle)(BOOL);
@property (nonatomic, copy) void (^open)(void);
@property (nonatomic) BOOL wide;
- (void)refreshState;
@end

@implementation GCTile {
    UIView *_wash;
}
- (instancetype)initWithTitle:(NSString *)t symbols:(NSArray<NSString *> *)sym accent:(UIColor *)a wide:(BOOL)wide {
    if (!(self = [super initWithFrame:CGRectMake(0, 0, 100, 60)])) return nil;
    self.maxRadius = 24;
    self.accent = a; self.wide = wide;
    _wash = [UIView new];
    _wash.userInteractionEnabled = NO;
    _wash.alpha = 0;
    _wash.backgroundColor = a;
    [self.content addSubview:_wash];
    _icon = [[UIImageView alloc] initWithImage:GCSymAny(sym, 24, UIImageSymbolWeightSemibold)];
    _icon.tintColor = UIColor.whiteColor; _icon.contentMode = UIViewContentModeScaleAspectFit;
    _title = [UILabel new]; _title.text = t; _title.textColor = UIColor.whiteColor;
    _title.font = [UIFont systemFontOfSize:14 weight:UIFontWeightSemibold];
    _sub = [UILabel new]; _sub.textColor = [UIColor colorWithWhite:1 alpha:0.65];
    _sub.font = [UIFont systemFontOfSize:12 weight:UIFontWeightMedium];
    [self.content addSubview:_icon]; [self.content addSubview:_title]; [self.content addSubview:_sub];
    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(tapped)]];
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    _wash.frame = self.bounds;
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height;
    if (_wide) {
        _icon.frame = CGRectMake(16, (H - 28) / 2, 28, 28);
        _title.frame = CGRectMake(56, H / 2 - 17, W - 68, 18);
        _sub.frame = CGRectMake(56, H / 2 + 1, W - 68, 16);
    } else {
        _icon.frame = CGRectMake(14, 14, 28, 28);
        _title.frame = CGRectMake(14, H - 42, W - 24, 18);
        _sub.frame = CGRectMake(14, H - 24, W - 24, 16);
    }
}
- (void)refreshState {
    if (!_getState) { _sub.text = @"Buka Pengaturan"; return; }
    BOOL on = _getState();
    _sub.text = on ? @"Aktif" : @"Mati";
    [UIView animateWithDuration:0.2 animations:^{ self->_wash.alpha = on ? 0.55 : 0; }];
}
- (void)tapped {
    if (_toggle && _getState) {
        BOOL now = !_getState();
        _toggle(now);
        _sub.text = now ? @"Aktif" : @"Mati";
        [UIView animateWithDuration:0.2 animations:^{ self->_wash.alpha = now ? 0.55 : 0; }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self refreshState]; });
    } else if (_open) {
        _open();
    }
}
@end

@interface GCConnPage : UIView
- (void)setVisible:(BOOL)v;
@end

@implementation GCConnPage {
    NSArray<GCTile *> *_tiles;
    NSTimer *_timer;
}
- (instancetype)initWithFrame:(CGRect)f {
    if (!(self = [super initWithFrame:f])) return nil;
    UIColor *orange = [UIColor colorWithRed:1 green:0.58 blue:0 alpha:1];
    UIColor *blue = [UIColor colorWithRed:0.04 green:0.52 blue:1 alpha:1];
    UIColor *green = [UIColor colorWithRed:0.19 green:0.82 blue:0.35 alpha:1];

    GCTile *air = [[GCTile alloc] initWithTitle:@"Mode Pesawat" symbols:@[@"airplane"] accent:orange wide:YES];
    air.getState = ^BOOL{ return GCAirplane(); };
    air.toggle = ^(BOOL v) { GCSetAirplane(v); };

    GCTile *wifi = [[GCTile alloc] initWithTitle:@"Wi-Fi" symbols:@[@"wifi"] accent:blue wide:NO];
    wifi.getState = ^BOOL{ return GCWiFi(); };
    wifi.toggle = ^(BOOL v) { GCSetWiFi(v); };

    GCTile *drop = [[GCTile alloc] initWithTitle:@"AirDrop" symbols:@[@"dot.radiowaves.up.forward", @"dot.radiowaves.left.and.right"] accent:blue wide:NO];
    drop.open = ^{ GCOpenURL(@"prefs:root=General&path=AIRDROP_LINK"); };

    GCTile *cell = [[GCTile alloc] initWithTitle:@"Data Seluler" symbols:@[@"antenna.radiowaves.left.and.right"] accent:green wide:NO];
    cell.getState = ^BOOL{ return GCCellular(); };
    cell.toggle = ^(BOOL v) { GCSetCellular(v); };

    GCTile *bt = [[GCTile alloc] initWithTitle:@"Bluetooth" symbols:@[@"b.circle.fill", @"dot.radiowaves.left.and.right"] accent:blue wide:NO];
    bt.getState = ^BOOL{ return GCBluetooth(); };
    bt.toggle = ^(BOOL v) { GCSetBluetooth(v); };

    GCTile *hot = [[GCTile alloc] initWithTitle:@"Hotspot Pribadi" symbols:@[@"personalhotspot", @"link"] accent:green wide:YES];
    hot.open = ^{ GCOpenURL(@"prefs:root=INTERNET_TETHERING"); };

    GCTile *vpn = [[GCTile alloc] initWithTitle:@"VPN" symbols:@[@"network", @"lock.shield"] accent:blue wide:YES];
    vpn.open = ^{ GCOpenURL(@"prefs:root=General&path=VPN"); };

    _tiles = @[air, wifi, drop, cell, bt, hot, vpn];
    for (GCTile *t in _tiles) [self addSubview:t];
    return self;
}
- (void)layoutSubviews {
    [super layoutSubviews];
    CGFloat W = self.bounds.size.width, H = self.bounds.size.height, g = 10;
    CGFloat unit = (H - 4 * g) / 5.0;               // 5 baris: wide, square, square, wide, wide
    CGFloat wideH = MIN(unit * 0.8, 64), sqH = (H - 4 * g - 3 * wideH) / 2.0;
    CGFloat half = (W - g) / 2;
    CGFloat y = 0;
    _tiles[0].frame = CGRectMake(0, y, W, wideH); y += wideH + g;
    _tiles[1].frame = CGRectMake(0, y, half, sqH);
    _tiles[2].frame = CGRectMake(half + g, y, half, sqH); y += sqH + g;
    _tiles[3].frame = CGRectMake(0, y, half, sqH);
    _tiles[4].frame = CGRectMake(half + g, y, half, sqH); y += sqH + g;
    _tiles[5].frame = CGRectMake(0, y, W, wideH); y += wideH + g;
    _tiles[6].frame = CGRectMake(0, y, W, wideH);
    for (GCTile *t in _tiles) t.layer.cornerRadius = [t radiusForSize:t.frame.size];
}
- (void)refresh { for (GCTile *t in _tiles) [t refreshState]; }
- (void)setVisible:(BOOL)v {
    if (v && !_timer) {
        [self refresh];
        _timer = [NSTimer scheduledTimerWithTimeInterval:1.5 target:self selector:@selector(refresh) userInfo:nil repeats:YES];
    } else if (!v && _timer) {
        [_timer invalidate]; _timer = nil;
    }
}
@end

#pragma mark - Menu power

@interface GCPowerSheet : UIView
+ (void)presentIn:(UIView *)host;
@end

@implementation GCPowerSheet
+ (void)presentIn:(UIView *)host {
    GCPowerSheet *s = [[GCPowerSheet alloc] initWithFrame:host.bounds];
    s.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [host addSubview:s];
    [s build];
}
- (void)build {
    self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.0];
    CGFloat cw = MIN(self.bounds.size.width - 56, 300), rowH = 58;
    NSArray *items = @[
        @[@"Matikan", @"power", @0],
        @[@"Mulai Ulang", @"arrow.clockwise", @1],
        @[@"Respring", @"sparkles", @2],
        @[@"Batal", @"xmark", @3]];
    GCGlassView *card = [[GCGlassView alloc] initWithFrame:CGRectMake(0, 0, cw, rowH * items.count + 12)];
    card.maxRadius = 30;
    card.center = CGPointMake(self.bounds.size.width / 2, self.bounds.size.height / 2);
    card.layer.cornerRadius = [card radiusForSize:card.frame.size];
    card.tag = 77;
    [self addSubview:card];
    for (NSUInteger i = 0; i < items.count; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.frame = CGRectMake(6, 6 + i * rowH, cw - 12, rowH);
        b.tag = [items[i][2] integerValue];
        [b setImage:GCSym(items[i][1], 18, UIImageSymbolWeightSemibold) forState:UIControlStateNormal];
        [b setTitle:[@"  " stringByAppendingString:items[i][0]] forState:UIControlStateNormal];
        b.titleLabel.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
        b.tintColor = UIColor.whiteColor;
        [b setTitleColor:(i == 0 ? [UIColor colorWithRed:1 green:0.35 blue:0.35 alpha:1] : UIColor.whiteColor) forState:UIControlStateNormal];
        if (i == 0) b.tintColor = [UIColor colorWithRed:1 green:0.35 blue:0.35 alpha:1];
        b.contentHorizontalAlignment = UIControlContentHorizontalAlignmentLeft;
        b.contentEdgeInsets = UIEdgeInsetsMake(0, 18, 0, 0);
        [b addTarget:self action:@selector(picked:) forControlEvents:UIControlEventTouchUpInside];
        [card.content addSubview:b];
        if (i + 1 < items.count) {
            UIView *ln = [[UIView alloc] initWithFrame:CGRectMake(18, 6 + (i + 1) * rowH - 0.5, cw - 36, 0.5)];
            ln.backgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
            [card.content addSubview:ln];
        }
    }
    [self addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(bgTap:)]];
    card.alpha = 0; card.transform = CGAffineTransformMakeScale(0.9, 0.9);
    [UIView animateWithDuration:0.28 delay:0 usingSpringWithDamping:0.85 initialSpringVelocity:0.4 options:0 animations:^{
        self.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
        card.alpha = 1; card.transform = CGAffineTransformIdentity;
    } completion:nil];
}
- (void)bgTap:(UITapGestureRecognizer *)g {
    if (CGRectContainsPoint([self viewWithTag:77].frame, [g locationInView:self])) return;
    [self closeThen:nil];
}
- (void)closeThen:(void (^)(void))then {
    [UIView animateWithDuration:0.2 animations:^{
        self.backgroundColor = UIColor.clearColor;
        [self viewWithTag:77].alpha = 0;
        [self viewWithTag:77].transform = CGAffineTransformMakeScale(0.94, 0.94);
    } completion:^(BOOL f) {
        [self removeFromSuperview];
        if (then) then();
    }];
}
- (void)picked:(UIButton *)b {
    NSInteger a = b.tag;
    [self closeThen:^{
        if (a == 0) GCShutdown(NO);
        else if (a == 1) GCShutdown(YES);
        else if (a == 2) GCRespring();
    }];
}
@end

#pragma mark - Pager (tab + scroll + power)

#define GC_PAGES 3

@interface GCPager : NSObject <UIGestureRecognizerDelegate>
@property (nonatomic, weak) UIView *root;
@property (nonatomic, weak) UIView *content;
@property (nonatomic) CGRect rect;          // area modul (koordinat root), sebelum diperkecil
@property (nonatomic) CGFloat pos;          // 0..2 (kontinu)
- (void)attach:(UIView *)root;
- (void)relayout;
- (void)resetPage;
@end

@implementation GCPager {
    GCMediaPage *_media;
    GCConnPage *_conn;
    UIView *_tabBox;
    NSArray<UIButton *> *_tabs;
    GCCircle *_indicator;
    GCCircle *_power;
    UIPanGestureRecognizer *_pan;
    CGFloat _startPos;
    CADisplayLink *_link;
    CFTimeInterval _t0; CGFloat _from, _to;
    BOOL _origTouched, _hooked;
    CGRect _pageRect;
    CGPoint _contentCenter;
}

- (void)attach:(UIView *)root {
    self.root = root;
    _media = [[GCMediaPage alloc] initWithFrame:CGRectMake(0, 0, 300, 400)];
    _conn = [[GCConnPage alloc] initWithFrame:CGRectMake(0, 0, 300, 400)];
    _media.hidden = _conn.hidden = YES;
    [root addSubview:_media]; [root addSubview:_conn];

    _tabBox = [UIView new];
    _indicator = [[GCCircle alloc] initWithSize:38 symbol:@[@"circle.fill"] iconSize:1];
    _indicator.icon.hidden = YES;
    [_tabBox addSubview:_indicator];
    NSArray *syms = @[@[@"heart.fill", @"heart"], @[@"music.note"], @[@"antenna.radiowaves.left.and.right"]];
    NSMutableArray *tabs = [NSMutableArray array];
    for (NSUInteger i = 0; i < 3; i++) {
        UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
        b.tag = i;
        [b setImage:GCSymAny(syms[i], 17, UIImageSymbolWeightBold) forState:UIControlStateNormal];
        b.tintColor = UIColor.whiteColor;
        [b addTarget:self action:@selector(tabTapped:) forControlEvents:UIControlEventTouchUpInside];
        [_tabBox addSubview:b];
        [tabs addObject:b];
    }
    _tabs = tabs;
    [root addSubview:_tabBox];

    _power = [[GCCircle alloc] initWithSize:38 symbol:@[@"power"] iconSize:16];
    [_power addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(powerTapped)]];
    [root addSubview:_power];

    _pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
    _pan.delegate = self;
    _pan.cancelsTouchesInView = NO;
    [root addGestureRecognizer:_pan];
}

- (CGFloat)shrinkScale { return gcShrink && gcTabs ? 0.92 : 1.0; }

- (void)relayout {
    UIView *root = self.root;
    if (!root) return;
    CGFloat W = root.bounds.size.width, H = root.bounds.size.height;

    // area modul (diukur saat halaman asli tampil & tanpa transform saya)
    UIView *content = GCFindViewNamed(root, @"ModuleCollectionView", 0);
    self.content = content;
    if (content && _pos < 0.001) {
        CATransform3D saved = content.layer.sublayerTransform;
        content.layer.sublayerTransform = CATransform3DIdentity;
        CGRect r = CGRectZero;
        NSMutableArray *boxes = [NSMutableArray array];
        GCCollectNamed(content, @"ContentModuleContainer", 0, boxes);
        for (UIView *b in boxes) {
            if (b.hidden || b.bounds.size.width < 20) continue;
            CGRect fr = [b convertRect:b.bounds toView:root];
            r = CGRectIsEmpty(r) ? fr : CGRectUnion(r, fr);
        }
        if (CGRectIsEmpty(r) || r.size.width < 120 || r.size.height < 160) r = CGRectMake(20, 110, W - 40, H - 200);
        self.rect = r;
        _contentCenter = [content.superview convertPoint:CGPointMake(CGRectGetMidX(content.frame), CGRectGetMidY(content.frame)) toView:root];
        content.layer.sublayerTransform = saved;
    } else if (CGRectIsEmpty(self.rect)) {
        self.rect = CGRectMake(20, 110, W - 40, H - 200);
        _contentCenter = CGPointMake(W / 2, H / 2);
    }
    CGRect r = self.rect;
    CGFloat s = [self shrinkScale];
    CGPoint c = _contentCenter;
    _pageRect = CGRectMake(c.x + (r.origin.x - c.x) * s, c.y + (r.origin.y - c.y) * s, r.size.width * s, r.size.height * s);

    _media.bounds = CGRectMake(0, 0, _pageRect.size.width, _pageRect.size.height);
    _conn.bounds = _media.bounds;
    _media.center = _conn.center = CGPointMake(CGRectGetMidX(_pageRect), CGRectGetMidY(_pageRect));

    // tab di tepi kanan
    BOOL showTabs = gcTabs;
    _tabBox.hidden = !showTabs;
    CGFloat step = 46, bw = 40;
    _tabBox.frame = CGRectMake(W - bw - 2, CGRectGetMidY(_pageRect) - (step * 3) / 2, bw, step * 3);
    for (NSUInteger i = 0; i < 3; i++) _tabs[i].frame = CGRectMake(0, i * step, bw, step);
    _indicator.bounds = CGRectMake(0, 0, 38, 38);
    _indicator.layer.cornerRadius = 19;

    // tombol power
    _power.hidden = !gcPower;
    _power.center = CGPointMake(W - 18 - 19, gcPowerY + 19);

    [root bringSubviewToFront:_media]; [root bringSubviewToFront:_conn];
    [root bringSubviewToFront:_tabBox]; [root bringSubviewToFront:_power];
    for (UIView *v in root.subviews) if ([v isKindOfClass:GCPowerSheet.class]) [root bringSubviewToFront:v];
    [self applyPos:_pos];

    if (!_hooked) {
        _hooked = YES;
        // gesture dismiss bawaan menunggu pan saya gagal (supaya scroll vertikal tidak menutup CC)
        for (UIView *v = root; v && v != root.window; v = v.superview) {
            for (UIGestureRecognizer *g in v.gestureRecognizers) {
                if (g == _pan || ![g isKindOfClass:UIPanGestureRecognizer.class]) continue;
                [g requireGestureRecognizerToFail:_pan];
            }
        }
    }
}

- (void)applyPos:(CGFloat)pos {
    _pos = pos;
    CGFloat H = _pageRect.size.height, s = [self shrinkScale];
    UIView *content = self.content;
    NSArray *pages = @[[NSNull null], _media, _conn];

    // halaman asli (0)
    {
        CGFloat d = 0 - pos;
        CGFloat a = MAX(0, MIN(1, 1 - fabs(d) * 1.4));
        CATransform3D t = CATransform3DMakeTranslation(0, d * H * 0.45, 0);
        CGFloat sc = s * (1 - 0.05 * MIN(1, fabs(d)));
        t = CATransform3DScale(t, sc, sc, 1);
        if (pos > 0.001 || _origTouched) {
            content.alpha = a;
            _origTouched = pos > 0.001;
            if (!_origTouched) content.alpha = 1;
        }
        content.layer.sublayerTransform = (gcShrink && gcTabs) || pos > 0.001 ? t : CATransform3DIdentity;
        content.userInteractionEnabled = pos < 0.3;
    }
    for (NSUInteger i = 1; i < 3; i++) {
        UIView *p = pages[i];
        CGFloat d = (CGFloat)i - pos;
        CGFloat a = MAX(0, MIN(1, 1 - fabs(d) * 1.4));
        p.alpha = a;
        p.hidden = a < 0.01;
        p.transform = CGAffineTransformConcat(CGAffineTransformMakeScale(1 - 0.05 * MIN(1, fabs(d)), 1 - 0.05 * MIN(1, fabs(d))),
                                              CGAffineTransformMakeTranslation(0, d * H * 0.45));
        p.userInteractionEnabled = fabs(d) < 0.3;
    }
    [_media setVisible:fabs(pos - 1) < 0.5];
    [_conn setVisible:fabs(pos - 2) < 0.5];

    // indikator tab
    NSInteger act = (NSInteger)lround(MAX(0, MIN(2, pos)));
    CGFloat step = 46;
    _indicator.center = CGPointMake(20, MAX(0, MIN(2, pos)) * step + step / 2);
    for (NSUInteger i = 0; i < 3; i++) {
        _tabs[i].alpha = (NSInteger)i == act ? 1 : 0.55;
    }
}

- (void)animateTo:(NSInteger)page {
    page = MAX(0, MIN(GC_PAGES - 1, page));
    [_link invalidate];
    _from = _pos; _to = page; _t0 = CACurrentMediaTime();
    _link = [CADisplayLink displayLinkWithTarget:self selector:@selector(step:)];
    [_link addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
}
- (void)step:(CADisplayLink *)l {
    double t = MIN(1, (CACurrentMediaTime() - _t0) / 0.38);
    double e = 1 - pow(1 - t, 3);
    [self applyPos:_from + (_to - _from) * e];
    if (t >= 1) { [l invalidate]; _link = nil; }
}
- (void)tabTapped:(UIButton *)b { [self animateTo:b.tag]; }
- (void)resetPage {
    [_link invalidate]; _link = nil;
    [self applyPos:0];
}
- (void)powerTapped { [GCPowerSheet presentIn:self.root]; }

#pragma mark Gesture

- (BOOL)gestureRecognizer:(UIGestureRecognizer *)g shouldReceiveTouch:(UITouch *)t {
    CGPoint p = [t locationInView:self.root];
    if (!CGRectContainsPoint(CGRectInset(_pageRect, -12, -12), p)) return NO;
    for (UIView *v = t.view; v && v != self.root; v = v.superview) {
        NSString *n = NSStringFromClass([v class]);
        if ([n containsString:@"Slider"] || [v isKindOfClass:UISlider.class] || [v isKindOfClass:MPVolumeView.class]) return NO;
        if ([v isKindOfClass:GCPowerSheet.class]) return NO;
    }
    return YES;
}
- (BOOL)gestureRecognizerShouldBegin:(UIPanGestureRecognizer *)g {
    CGPoint v = [g velocityInView:self.root];
    return fabs(v.y) > fabs(v.x) * 1.3;
}
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)a shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)b { return YES; }

- (void)pan:(UIPanGestureRecognizer *)g {
    CGFloat H = MAX(200, _pageRect.size.height);
    switch (g.state) {
        case UIGestureRecognizerStateBegan:
            [_link invalidate]; _link = nil;
            _startPos = _pos;
            break;
        case UIGestureRecognizerStateChanged: {
            CGFloat ty = [g translationInView:self.root].y;
            CGFloat p = _startPos - ty / (H * 0.6);
            if (p < 0) p = p * 0.3;
            if (p > GC_PAGES - 1) p = (GC_PAGES - 1) + (p - (GC_PAGES - 1)) * 0.3;
            [self applyPos:p];
            break;
        }
        case UIGestureRecognizerStateEnded:
        case UIGestureRecognizerStateCancelled: {
            CGFloat vy = [g velocityInView:self.root].y;
            CGFloat target = _pos - vy / 1800.0;
            NSInteger page = (NSInteger)lround(target);
            if (page == (NSInteger)lround(_startPos) && fabs(vy) > 500) page += (vy < 0 ? 1 : -1);
            [self animateTo:page];
            break;
        }
        default: break;
    }
}
@end

#pragma mark - Hook Control Center

static const void *kGCPagerKey = &kGCPagerKey;

static GCPager *GCPagerFor(UIViewController *vc) {
    GCPager *p = objc_getAssociatedObject(vc, kGCPagerKey);
    if (!p) {
        p = [GCPager new];
        [p attach:vc.view];
        objc_setAssociatedObject(vc, kGCPagerKey, p, OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    }
    return p;
}

@interface CCUIModularControlCenterOverlayViewController : UIViewController
@end

%hook CCUIModularControlCenterOverlayViewController
- (void)viewDidLayoutSubviews {
    %orig;
    if (!gcMaster) return;
    GCPager *p = GCPagerFor((UIViewController *)self);
    [p relayout];
}
- (void)viewWillAppear:(BOOL)animated {
    %orig;
    if (!gcMaster) return;
    GCPager *p = GCPagerFor((UIViewController *)self);
    [p resetPage];
    [p relayout];
}
- (void)viewDidDisappear:(BOOL)animated {
    %orig;
    GCPager *p = objc_getAssociatedObject(self, kGCPagerKey);
    [p resetPage];
}
%end

static void GCPrefsChanged(CFNotificationCenterRef c, void *o, CFStringRef n, const void *obj, CFDictionaryRef u) {
    dispatch_async(dispatch_get_main_queue(), ^{ GCLoadPrefs(); });
}

%ctor {
    @autoreleasepool {
        GCLoadPrefs();
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), NULL, GCPrefsChanged,
            CFSTR("com.hasan.glasscc/prefs"), NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    }
}
