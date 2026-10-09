/*
 * figment: creates virtual displays on macOS and keeps them alive.
 *
 * Each display is held by its own detached figment process, through the
 * private CGVirtualDisplay API, and lasts until that process ends. The
 * display's serial number is the holder's pid, so list and stop need no
 * state of their own: they find figment's displays by vendor number.
 */

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>

#include <mach-o/dyld.h>
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

/* Runs in the detached holder: creates the display, reports its id on
 * stdout once it is online, then lives until a signal ends it. */
static int serve(unsigned int width, unsigned int height, bool hidpi) {
    unsigned int scale = hidpi ? 2 : 1;
    /* Apple's own ~110 and ~220 ppi, so macOS sizes things as usual. */
    double ppi = 110.0 * scale;

    CGVirtualDisplayDescriptor *desc = [CGVirtualDisplayDescriptor new];
    desc.queue = dispatch_get_main_queue();
    desc.name = [NSString stringWithFormat:@"figment %ux%u%s", width, height,
                                           hidpi ? " HiDPI" : ""];
    desc.maxPixelsWide = width;
    desc.maxPixelsHigh = height;
    desc.sizeInMillimeters = CGSizeMake(width / ppi * 25.4, height / ppi * 25.4);
    desc.vendorID = kVendor;
    desc.productID = 1;
    desc.serialNum = (unsigned int)getpid();
    desc.terminationHandler = ^(__unused id d, __unused CGVirtualDisplay *v) { exit(0); };

    CGVirtualDisplay *display = [[CGVirtualDisplay alloc] initWithDescriptor:desc];
    if (!display || !display.displayID) die("could not create the display");

    CGVirtualDisplaySettings *settings = [CGVirtualDisplaySettings new];
    settings.hiDPI = hidpi;
    settings.modes = @[ [[CGVirtualDisplayMode alloc] initWithWidth:width / scale
                                                             height:height / scale
                                                        refreshRate:60] ];
    if (![display applySettings:settings]) die("could not apply the display mode");

    for (int i = 0; i < 100 && !online(display.displayID); i++) usleep(20000);
    if (!online(display.displayID)) die("the display did not come online");

    /* macOS adds scaled modes of its own and may default to one of them. */
    NSDictionary *opts = @{(__bridge id)kCGDisplayShowDuplicateLowResolutionModes : @YES};
    NSArray *modes = CFBridgingRelease(
        CGDisplayCopyAllDisplayModes(display.displayID, (__bridge CFDictionaryRef)opts));
    for (id m in modes) {
        CGDisplayModeRef mode = (__bridge CGDisplayModeRef)m;
        if (CGDisplayModeGetPixelWidth(mode) == width && CGDisplayModeGetPixelHeight(mode) == height &&
            CGDisplayModeGetWidth(mode) == width / scale) {
            if (CGDisplaySetDisplayMode(display.displayID, mode, NULL) != kCGErrorSuccess)
                die("macOS refused that mode, try a larger size");
            break;
        }
    }

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
    char extra;
    for (size_t i = 0; i < sizeof kPresets / sizeof *kPresets; i++)
        if (!strcasecmp(size, kPresets[i].name)) {
            width = kPresets[i].width;
            height = kPresets[i].height;
        }
    if (!width && (sscanf(size, "%ux%u%c", &width, &height, &extra) != 2 || !width || !height))
        usage();
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

static int stop(int argc, char **argv) {
    CGDirectDisplayID ids[64];
    uint32_t n;
    if (argc == 0) {
        n = figmentDisplays(ids, 64);
    } else {
        n = 0;
        for (int i = 0; i < argc && n < 64; i++) {
            char *end;
            unsigned long id = strtoul(argv[i], &end, 10);
            if (*end || !online((CGDirectDisplayID)id)) {
                fprintf(stderr, "figment: no figment display %s\n", argv[i]);
                return 1;
            }
            ids[n++] = (CGDirectDisplayID)id;
        }
    }
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
        if (!strcmp(cmd, "stop")) return stop(argc - 2, argv + 2);
        usage();
    }
}
