/*
 * figment: creates virtual displays on macOS and keeps them alive.
 *
 * Each display is held by its own detached figment process, through the
 * private CGVirtualDisplay API, and lasts until that process ends. The
 * display's serial number is the holder's pid and its product number is
 * the N in its name, so the other commands need no state of their own:
 * they find figment's displays by vendor number.
 */

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#include <mach-o/dyld.h>
#include <math.h>
#include <signal.h>
#include <spawn.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

extern char **environ;

/* Private CoreGraphics classes, declared as far as figment uses them. */

@class CGVirtualDisplay;

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) dispatch_queue_t queue;
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int vendorID;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int serialNum;
@property(copy, nonatomic) void (^terminationHandler)(id, CGVirtualDisplay *);
@end

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(retain, nonatomic) NSArray *modes;
@property(nonatomic) unsigned int hiDPI;
@end

@interface CGVirtualDisplay : NSObject
@property(readonly, nonatomic) unsigned int displayID;
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@end

static const unsigned int kVendor = 0xf16e;

static const struct {
    const char *name;
    unsigned int width, height;
} kPresets[] = {
    {"720p", 1280, 720},   {"1080p", 1920, 1080}, {"1440p", 2560, 1440},
    {"4k", 3840, 2160},    {"5k", 5120, 2880},    {"8k", 7680, 4320},
};

static void usage(void) {
    fprintf(stderr,
            "usage: figment start <width>x<height> | <preset> [--hidpi]\n"
            "       figment list\n"
            "       figment scale <display id> [<width>x<height>]\n"
            "       figment stop [<display id> ...]\n"
            "presets:");
    for (size_t i = 0; i < sizeof kPresets / sizeof *kPresets; i++)
        fprintf(stderr, " %s", kPresets[i].name);
    fprintf(stderr, "\n");
    exit(1);
}

static void die(const char *msg) {
    fprintf(stderr, "figment: %s\n", msg);
    exit(1);
}

static uint32_t figmentDisplays(CGDirectDisplayID *ids, uint32_t max) {
    CGDirectDisplayID all[64];
    uint32_t n = 0, found = 0;
    CGGetOnlineDisplayList(64, all, &n);
    for (uint32_t i = 0; i < n && found < max; i++)
        if (CGDisplayVendorNumber(all[i]) == kVendor) ids[found++] = all[i];
    return found;
}

static bool online(CGDirectDisplayID id) {
    CGDirectDisplayID ids[64];
    uint32_t n = figmentDisplays(ids, 64);
    for (uint32_t i = 0; i < n; i++)
        if (ids[i] == id) return true;
    return false;
}

static bool parseSize(const char *s, unsigned int *width, unsigned int *height) {
    char extra;
    return sscanf(s, "%ux%u%c", width, height, &extra) == 2 && *width && *height;
}

static CGDirectDisplayID displayArg(const char *s) {
    char *end;
    unsigned long id = strtoul(s, &end, 10);
    if (*end || !online((CGDirectDisplayID)id)) {
        fprintf(stderr, "figment: no figment display %s\n", s);
        exit(1);
    }
    return (CGDirectDisplayID)id;
}

/* Every mode of the display, with the HiDPI ones macOS hides by default. */
static NSArray *allModes(CGDirectDisplayID display) {
    NSDictionary *opts = @{(__bridge id)kCGDisplayShowDuplicateLowResolutionModes : @YES};
    return CFBridgingRelease(CGDisplayCopyAllDisplayModes(display, (__bridge CFDictionaryRef)opts));
}

/* Switches to the sharpest mode that looks like width x height. */
static void setLooksLike(CGDirectDisplayID display, size_t width, size_t height) {
    CGDisplayModeRef best = NULL;
    for (id m in allModes(display)) {
        CGDisplayModeRef mode = (__bridge CGDisplayModeRef)m;
        if (CGDisplayModeGetWidth(mode) == width && CGDisplayModeGetHeight(mode) == height &&
            (!best || CGDisplayModeGetPixelWidth(mode) > CGDisplayModeGetPixelWidth(best)))
            best = mode;
    }
    if (!best) die("the display has no such size, see figment scale <display id>");
    CGDisplayConfigRef config;
    CGBeginDisplayConfiguration(&config);
    CGConfigureDisplayWithDisplayMode(config, display, best, NULL);
    if (CGCompleteDisplayConfiguration(config, kCGConfigureForSession) != kCGErrorSuccess)
        die("macOS refused that size, try a larger one");
}

/* Runs in the detached holder: creates the display, reports its id on
 * stdout once it is online, then lives until a signal ends it. */
static int serve(unsigned int width, unsigned int height, bool hidpi) {
    unsigned int scale = hidpi ? 2 : 1;
    /* Apple's own ~110 and ~220 ppi, so macOS sizes things as usual. */
    double ppi = 110.0 * scale;

    CGVirtualDisplayDescriptor *desc = [CGVirtualDisplayDescriptor new];
    desc.queue = dispatch_get_main_queue();
    /* Numbered from 1, reusing the lowest number no display has. */
    CGDirectDisplayID ids[64];
    uint32_t n = figmentDisplays(ids, 64);
    bool taken[66] = {false};
    for (uint32_t i = 0; i < n; i++)
        if (CGDisplayModelNumber(ids[i]) <= 65) taken[CGDisplayModelNumber(ids[i])] = true;
    unsigned int number = 1;
    while (taken[number]) number++;
    desc.name = [NSString stringWithFormat:@"Figment Virtual Display %u", number];
    /* Room for the More Space sizes below, which render at 2x as well. */
    desc.maxPixelsWide = hidpi ? width * 4 / 3 : width;
    desc.maxPixelsHigh = hidpi ? height * 4 / 3 : height;
    desc.sizeInMillimeters = CGSizeMake(width / ppi * 25.4, height / ppi * 25.4);
    desc.vendorID = kVendor;
    desc.productID = number;
    desc.serialNum = (unsigned int)getpid();
    desc.terminationHandler = ^(__unused id d, __unused CGVirtualDisplay *v) { exit(0); };

    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
    if (!display || !display.displayID) die("could not create the display");

    CGVirtualDisplaySettings *settings = [CGVirtualDisplaySettings new];
    settings.hiDPI = hidpi;
    /* A HiDPI display gets a range of sizes, like a Retina panel's Larger
     * Text to More Space, which also makes Displays settings show them so. */
    NSMutableArray *list = [NSMutableArray array];
    double factors[] = {1, 2 / 3.0, 5 / 6.0, 1.2, 4 / 3.0};
    for (size_t i = 0; i < (hidpi ? 5 : 1); i++) {
        unsigned int w = (unsigned int)lround(width / scale * factors[i]) & ~1u;
        unsigned int h = (unsigned int)lround(height / scale * factors[i]) & ~1u;
        [list addObject:[[CGVirtualDisplayMode alloc] initWithWidth:w height:h refreshRate:60]];
    }
    settings.modes = list;
    if (![display applySettings:settings]) die("could not apply the display mode");

    for (int i = 0; i < 100 && !online(display.displayID); i++) usleep(20000);
    if (!online(display.displayID)) die("the display did not come online");

    /* macOS adds scaled modes of its own and may default to one of them. */
    setLooksLike(display.displayID, width / scale, height / scale);

    printf("%u\n", display.displayID);
    fflush(stdout);
    int null = open("/dev/null", O_RDWR);
    dup2(null, STDOUT_FILENO);
    dup2(null, STDERR_FILENO);

    int sigs[] = {SIGTERM, SIGINT, SIGHUP};
    for (size_t i = 0; i < sizeof sigs / sizeof *sigs; i++) {
        signal(sigs[i], SIG_IGN);
        dispatch_source_t src = dispatch_source_create(
            DISPATCH_SOURCE_TYPE_SIGNAL, sigs[i], 0, dispatch_get_main_queue());
        dispatch_source_set_event_handler(src, ^{ exit(0); });
        dispatch_resume(src);
        (void)CFBridgingRetain(src);
    }
    (void)CFBridgingRetain(display);
    dispatch_main();
}

static int start(const char *size, bool hidpi) {
    unsigned int width = 0, height = 0;
    for (size_t i = 0; i < sizeof kPresets / sizeof *kPresets; i++)
        if (!strcasecmp(size, kPresets[i].name)) {
            width = kPresets[i].width;
            height = kPresets[i].height;
        }
    if (!width && !parseSize(size, &width, &height)) usage();
    if (hidpi && (width % 2 || height % 2)) die("--hidpi needs an even width and height");

    char exe[PATH_MAX];
    uint32_t len = sizeof exe;
    if (_NSGetExecutablePath(exe, &len) != 0) die("could not find its own executable");

    int out[2];
    if (pipe(out) != 0) die("pipe failed");
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&fa, out[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&fa, out[0]);
    posix_spawn_file_actions_addclose(&fa, out[1]);
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);

    char w[16], h[16];
    snprintf(w, sizeof w, "%u", width);
    snprintf(h, sizeof h, "%u", height);
    char *argv[] = {exe, "_serve", w, h, hidpi ? "1" : "0", NULL};
    pid_t pid;
    if (posix_spawn(&pid, exe, &fa, &attr, argv, environ) != 0) die("could not start the holder");
    close(out[1]);

    char buf[32] = {0};
    ssize_t n = read(out[0], buf, sizeof buf - 1);
    if (n <= 0) return 1; /* the holder said why on stderr */
    fputs(buf, stdout);
    return 0;
}

static int list(void) {
    CGDirectDisplayID ids[64];
    uint32_t n = figmentDisplays(ids, 64);
    for (uint32_t i = 0; i < n; i++) {
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(ids[i]);
        size_t pw = CGDisplayModeGetPixelWidth(mode), ph = CGDisplayModeGetPixelHeight(mode);
        size_t w = CGDisplayModeGetWidth(mode), h = CGDisplayModeGetHeight(mode);
        CGDisplayModeRelease(mode);
        printf("%u\t%zux%zu", ids[i], pw, ph);
        if (pw != w) printf(" HiDPI (looks like %zux%zu)", w, h);
        printf("\tpid %u\n", CGDisplaySerialNumber(ids[i]));
    }
    return 0;
}

static int scale(int argc, char **argv) {
    CGDirectDisplayID display = displayArg(argv[0]);
    if (argc == 2) {
        unsigned int width, height;
        if (!parseSize(argv[1], &width, &height)) usage();
        setLooksLike(display, width, height);
        return 0;
    }
    /* The sizes at the current mode's scale and aspect ratio, smallest
     * first, current marked. */
    CGDisplayModeRef current = CGDisplayCopyDisplayMode(display);
    size_t factor = CGDisplayModeGetPixelWidth(current) / CGDisplayModeGetWidth(current);
    double aspect = (double)CGDisplayModeGetWidth(current) / CGDisplayModeGetHeight(current);
    NSMutableOrderedSet *sizes = [NSMutableOrderedSet orderedSet];
    for (id m in allModes(display)) {
        CGDisplayModeRef mode = (__bridge CGDisplayModeRef)m;
        double a = (double)CGDisplayModeGetWidth(mode) / CGDisplayModeGetHeight(mode);
        if (CGDisplayModeGetPixelWidth(mode) == CGDisplayModeGetWidth(mode) * factor &&
            fabs(a - aspect) < 0.01)
            [sizes addObject:[NSValue valueWithSize:NSMakeSize(CGDisplayModeGetWidth(mode),
                                                               CGDisplayModeGetHeight(mode))]];
    }
    NSArray *sorted = [sizes.array sortedArrayUsingComparator:^(NSValue *a, NSValue *b) {
        return [@(a.sizeValue.width * a.sizeValue.height) compare:@(b.sizeValue.width * b.sizeValue.height)];
    }];
    for (NSValue *v in sorted) {
        bool now = v.sizeValue.width == CGDisplayModeGetWidth(current) &&
                   v.sizeValue.height == CGDisplayModeGetHeight(current);
        printf("%gx%g%s\n", v.sizeValue.width, v.sizeValue.height, now ? " *" : "");
    }
    CGDisplayModeRelease(current);
    return 0;
}

static int stop(int argc, char **argv) {
    CGDirectDisplayID ids[64];
    uint32_t n = 0;
    if (argc == 0) n = figmentDisplays(ids, 64);
    for (int i = 0; i < argc && n < 64; i++) ids[n++] = displayArg(argv[i]);
    for (uint32_t i = 0; i < n; i++) kill((pid_t)CGDisplaySerialNumber(ids[i]), SIGTERM);
    for (uint32_t i = 0; i < n; i++)
        for (int t = 0; t < 100 && online(ids[i]); t++) usleep(20000);
    return 0;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) usage();
        const char *cmd = argv[1];
        if (!strcmp(cmd, "_serve") && argc == 5)
            return serve((unsigned)atoi(argv[2]), (unsigned)atoi(argv[3]), !strcmp(argv[4], "1"));
        if (!strcmp(cmd, "start") && argc >= 3 && argc <= 4) {
            bool hidpi = argc == 4;
            if (hidpi && strcmp(argv[3], "--hidpi")) usage();
            return start(argv[2], hidpi);
        }
        if (!strcmp(cmd, "list") && argc == 2) return list();
        if (!strcmp(cmd, "scale") && argc >= 3 && argc <= 4) return scale(argc - 2, argv + 2);
        if (!strcmp(cmd, "stop")) return stop(argc - 2, argv + 2);
        usage();
    }
}
