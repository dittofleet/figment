/*
 * figment: creates virtual displays on macOS and keeps them alive.
 *
 * Each display is held by its own detached figment process, through the
 * private CGVirtualDisplay API, and lasts until that process ends. The
 * display's serial number is the holder's pid and its product number is
 * the N in its name, so the other commands need no state of their own:
 * they find figment's displays by vendor number. The only files are a
 * LaunchAgent per display, which brings it back at login until stopped.
 */

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <IOKit/pwr_mgt/IOPMLib.h>

#include <ctype.h>
#include <err.h>
#include <libproc.h>
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
@property(readonly, nonatomic) unsigned int width;
@property(readonly, nonatomic) unsigned int height;
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
            "usage: figment start <width>x<height> | <preset> [--hidpi | --no-hidpi] [--hz <rate>]\n"
            "       figment list\n"
            "       figment scale <display id> [<width>x<height>]\n"
            "       figment stop [<display id> ...]\n"
            "presets:");
    for (size_t i = 0; i < sizeof kPresets / sizeof *kPresets; i++)
        fprintf(stderr, " %s", kPresets[i].name);
    fprintf(stderr, "\n");
    exit(1);
}

enum { kMaxDisplays = 64 };

static uint32_t figmentDisplays(CGDirectDisplayID ids[kMaxDisplays]) {
    CGDirectDisplayID all[kMaxDisplays];
    uint32_t n = 0, found = 0;
    CGGetOnlineDisplayList(kMaxDisplays, all, &n);
    for (uint32_t i = 0; i < n; i++)
        if (CGDisplayVendorNumber(all[i]) == kVendor) ids[found++] = all[i];
    return found;
}

static bool online(CGDirectDisplayID id) {
    CGDirectDisplayID ids[kMaxDisplays];
    uint32_t n = figmentDisplays(ids);
    for (uint32_t i = 0; i < n; i++)
        if (ids[i] == id) return true;
    return false;
}

/* Waits up to 2 seconds for the display to come online or go away. */
static bool waitOnline(CGDirectDisplayID id, bool want) {
    for (int i = 0; i < 100; i++) {
        if (online(id) == want) return true;
        usleep(20000);
    }
    return false;
}

/* <width>x<height>, up to 5 digits each. */
static bool parseSize(const char *s, unsigned int *width, unsigned int *height) {
    char *x, *end;
    if (!isdigit(s[0])) return false;
    unsigned long w = strtoul(s, &x, 10);
    if (*x != 'x' || !isdigit(x[1]) || x - s > 5) return false;
    unsigned long h = strtoul(x + 1, &end, 10);
    if (*end || end - x > 6 || !w || !h) return false;
    *width = (unsigned int)w;
    *height = (unsigned int)h;
    return true;
}

static CGDirectDisplayID displayArg(const char *s) {
    char *end;
    unsigned long id = strtoul(s, &end, 10);
    if (*end || !online((CGDirectDisplayID)id)) errx(1, "no figment display %s", s);
    return (CGDirectDisplayID)id;
}

/* Every mode of the display, with the HiDPI ones macOS hides by default. */
static NSArray *allModes(CGDirectDisplayID display) {
    NSDictionary *opts = @{(__bridge id)kCGDisplayShowDuplicateLowResolutionModes : @YES};
    return CFBridgingRelease(CGDisplayCopyAllDisplayModes(display, (__bridge CFDictionaryRef)opts));
}

/* Switches to the sharpest mode that looks like width x height. */
static void setLooksLike(CGDirectDisplayID display, size_t width, size_t height) {
    id bestMode = nil; /* strong, so it outlives the mode list */
    for (id m in allModes(display)) {
        CGDisplayModeRef mode = (__bridge CGDisplayModeRef)m;
        if (CGDisplayModeGetWidth(mode) == width && CGDisplayModeGetHeight(mode) == height &&
            (!bestMode || CGDisplayModeGetPixelWidth(mode) >
                              CGDisplayModeGetPixelWidth((__bridge CGDisplayModeRef)bestMode)))
            bestMode = m;
    }
    if (!bestMode) errx(1, "the display has no such size, see figment scale <display id>");
    CGDisplayModeRef best = (__bridge CGDisplayModeRef)bestMode;
    CGDisplayModeRef current = CGDisplayCopyDisplayMode(display);
    if (!current) errx(1, "the display went away");
    bool already = CGDisplayModeGetWidth(current) == width && CGDisplayModeGetHeight(current) == height &&
                   CGDisplayModeGetPixelWidth(current) == CGDisplayModeGetPixelWidth(best);
    CGDisplayModeRelease(current);
    if (already) return;
    CGDisplayConfigRef config;
    if (CGBeginDisplayConfiguration(&config) != kCGErrorSuccess) errx(1, "could not configure the display");
    if (CGConfigureDisplayWithDisplayMode(config, display, best, NULL) != kCGErrorSuccess ||
        CGCompleteDisplayConfiguration(config, kCGConfigureForSession) != kCGErrorSuccess) {
        CGCancelDisplayConfiguration(config);
        errx(1, "macOS refused that size, try a larger one");
    }
}

static NSString *agentLabel(unsigned int number) {
    return [NSString stringWithFormat:@"dev.figment.%u", number];
}

static NSURL *loginAgent(unsigned int number) {
    NSString *path = [NSString stringWithFormat:@"~/Library/LaunchAgents/%@.plist", agentLabel(number)];
    return [NSURL fileURLWithPath:path.stringByExpandingTildeInPath];
}

/* Runs in the holder, spawned by start or by launchd at login: creates
 * display `number`, reports its id on stdout once it is online, then lives
 * until it is killed. */
static int serve(unsigned int width, unsigned int height, bool hidpi, unsigned int number, unsigned int hz) {
    unsigned int scale = hidpi ? 2 : 1;
    /* Apple's own ~110 and ~220 ppi, so macOS sizes things as usual. */
    double ppi = 110.0 * scale;

    CGVirtualDisplayDescriptor *desc = [CGVirtualDisplayDescriptor new];
    desc.queue = dispatch_get_main_queue();
    CGDirectDisplayID ids[kMaxDisplays];
    uint32_t n = figmentDisplays(ids);
    for (uint32_t i = 0; i < n; i++)
        if (CGDisplayModelNumber(ids[i]) == number) errx(1, "display number %u is taken", number);
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
    if (!display || !display.displayID) errx(1, "could not create the display");

    CGVirtualDisplaySettings *settings = [CGVirtualDisplaySettings new];
    settings.hiDPI = hidpi;
    /* A HiDPI display gets a range of sizes, like a Retina panel's Larger
     * Text to More Space, which also makes Displays settings show them so. */
    NSMutableArray *list = [NSMutableArray array];
    double factors[] = {1, 2 / 3.0, 5 / 6.0, 1.2, 4 / 3.0};
    for (size_t i = 0; i < (hidpi ? 5 : 1); i++) {
        unsigned int w = (unsigned int)lround(width / scale * factors[i]) & ~1u;
        unsigned int h = (unsigned int)lround(height / scale * factors[i]) & ~1u;
        [list addObject:[[CGVirtualDisplayMode alloc] initWithWidth:w height:h refreshRate:hz]];
    }
    settings.modes = list;
    if (![display applySettings:settings]) errx(1, "could not apply the display mode");

    if (!waitOnline(display.displayID, true)) errx(1, "the display did not come online");

    /* macOS adds scaled modes of its own and may default to one of them. */
    CGVirtualDisplayMode *first = list[0];
    setLooksLike(display.displayID, first.width, first.height);

    printf("%u\n", display.displayID);
    fflush(stdout);
    int null = open("/dev/null", O_RDWR);
    dup2(null, STDOUT_FILENO);
    dup2(null, STDERR_FILENO);

    (void)CFBridgingRetain(display);
    dispatch_main();
}

/* hidpi is 1 or 0, or -1 to decide by size. */
static int start(const char *size, int hidpi, unsigned int hz) {
    unsigned int width = 0, height = 0;
    for (size_t i = 0; i < sizeof kPresets / sizeof *kPresets; i++)
        if (!strcasecmp(size, kPresets[i].name)) {
            width = kPresets[i].width;
            height = kPresets[i].height;
        }
    if (!width && !parseSize(size, &width, &height)) usage();
    /* Other sizes are untested, and a tiny display crashed WindowServer. */
    if (width < 720 || height < 720 || (uint64_t)width * height > 7680 * 4320)
        errx(1, "sizes go from 720 pixels a side up to 8K's pixel count");
    if (width % 2 || height % 2) errx(1, "the width and height need to be even");
    /* The rates tested to work. */
    if (hz != 30 && hz != 60 && hz != 120 && hz != 144 && hz != 240)
        errx(1, "the rate can be 30, 60, 120, 144 or 240");
    /* From the smallest Retina Mac screen up, 2880x1800, like real panels. */
    if (hidpi < 0) hidpi = width >= 2880;

    char exe[PATH_MAX];
    uint32_t len = sizeof exe;
    if (_NSGetExecutablePath(exe, &len) != 0) errx(1, "could not find its own executable");

    /* Numbered from 1, skipping the numbers of running displays and of those
     * set to come back at login. */
    CGDirectDisplayID ids[kMaxDisplays];
    uint32_t count = figmentDisplays(ids);
    unsigned int number = 0;
    bool taken;
    do {
        number++;
        taken = [loginAgent(number) checkResourceIsReachableAndReturnError:nil];
        for (uint32_t i = 0; i < count; i++)
            if (CGDisplayModelNumber(ids[i]) == number) taken = true;
    } while (taken);

    int out[2];
    if (pipe(out) != 0) errx(1, "pipe failed");
    posix_spawn_file_actions_t fa;
    posix_spawn_file_actions_init(&fa);
    posix_spawn_file_actions_addopen(&fa, STDIN_FILENO, "/dev/null", O_RDONLY, 0);
    posix_spawn_file_actions_adddup2(&fa, out[1], STDOUT_FILENO);
    posix_spawn_file_actions_addclose(&fa, out[0]);
    posix_spawn_file_actions_addclose(&fa, out[1]);
    posix_spawnattr_t attr;
    posix_spawnattr_init(&attr);
    posix_spawnattr_setflags(&attr, POSIX_SPAWN_SETSID);

    char w[16], h[16], num[16], rate[16];
    snprintf(w, sizeof w, "%u", width);
    snprintf(h, sizeof h, "%u", height);
    snprintf(num, sizeof num, "%u", number);
    snprintf(rate, sizeof rate, "%u", hz);
    char *argv[] = {exe, "_serve", w, h, hidpi ? "1" : "0", num, rate, NULL};
    pid_t pid;
    if (posix_spawn(&pid, exe, &fa, &attr, argv, environ) != 0) errx(1, "could not start the holder");
    close(out[1]);

    char buf[32] = {0};
    ssize_t n = read(out[0], buf, sizeof buf - 1);
    if (n <= 0) return 1; /* the holder said why on stderr */
    fputs(buf, stdout);

    /* The display is up, so have launchd bring it back at every login. */
    NSMutableArray *args = [NSMutableArray array];
    for (char **a = argv; *a; a++) [args addObject:@(*a)];
    NSDictionary *agent = @{
        @"Label" : agentLabel(number),
        @"ProgramArguments" : args,
        @"RunAtLoad" : @YES,
        @"LimitLoadToSessionType" : @"Aqua",
    };
    NSURL *url = loginAgent(number);
    [NSFileManager.defaultManager createDirectoryAtURL:url.URLByDeletingLastPathComponent
                           withIntermediateDirectories:YES
                                            attributes:nil
                                                 error:nil];
    if (![agent writeToURL:url error:nil]) {
        warnx("the display is up, but could not set it to come back at login");
        return 1;
    }
    return 0;
}

static int list(void) {
    CGDirectDisplayID ids[kMaxDisplays];
    uint32_t n = figmentDisplays(ids);
    for (uint32_t i = 0; i < n; i++) {
        CGDisplayModeRef mode = CGDisplayCopyDisplayMode(ids[i]);
        size_t pw = CGDisplayModeGetPixelWidth(mode), ph = CGDisplayModeGetPixelHeight(mode);
        size_t w = CGDisplayModeGetWidth(mode), h = CGDisplayModeGetHeight(mode);
        double hz = CGDisplayModeGetRefreshRate(mode);
        CGDisplayModeRelease(mode);
        printf("%u\t%zux%zu", ids[i], pw, ph);
        if (pw != w) printf(" HiDPI (looks like %zux%zu)", w, h);
        printf(" %g Hz\tpid %u\n", hz, CGDisplaySerialNumber(ids[i]));
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
    if (!current) errx(1, "the display went away");
    size_t factor = CGDisplayModeGetPixelWidth(current) / CGDisplayModeGetWidth(current);
    double aspect = (double)CGDisplayModeGetWidth(current) / CGDisplayModeGetHeight(current);
    NSMutableSet *sizes = [NSMutableSet set];
    for (id m in allModes(display)) {
        CGDisplayModeRef mode = (__bridge CGDisplayModeRef)m;
        double a = (double)CGDisplayModeGetWidth(mode) / CGDisplayModeGetHeight(mode);
        if (CGDisplayModeGetPixelWidth(mode) == CGDisplayModeGetWidth(mode) * factor &&
            fabs(a - aspect) < 0.01)
            [sizes addObject:[NSValue valueWithSize:NSMakeSize(CGDisplayModeGetWidth(mode),
                                                               CGDisplayModeGetHeight(mode))]];
    }
    NSArray *sorted = [sizes.allObjects sortedArrayUsingComparator:^(NSValue *a, NSValue *b) {
        return [@(a.sizeValue.width) compare:@(b.sizeValue.width)];
    }];
    for (NSValue *v in sorted) {
        bool now = v.sizeValue.width == CGDisplayModeGetWidth(current) &&
                   v.sizeValue.height == CGDisplayModeGetHeight(current);
        printf("%gx%g%s\n", v.sizeValue.width, v.sizeValue.height, now ? " *" : "");
    }
    CGDisplayModeRelease(current);
    return 0;
}

/* Stops a display coming back at login. */
static bool forget(NSURL *agent) {
    NSError *error;
    if ([NSFileManager.defaultManager removeItemAtURL:agent error:&error] ||
        error.code == NSFileNoSuchFileError)
        return true;
    warnx("could not remove %s", agent.path.UTF8String);
    return false;
}

static int stop(int argc, char **argv) {
    int status = 0;
    CGDirectDisplayID ids[kMaxDisplays];
    uint32_t n = 0;
    if (argc == 0) {
        n = figmentDisplays(ids);
        /* All of them, including displays that were ended some other way. */
        NSURL *dir = loginAgent(0).URLByDeletingLastPathComponent;
        for (NSURL *url in [NSFileManager.defaultManager contentsOfDirectoryAtURL:dir
                                                       includingPropertiesForKeys:nil
                                                                          options:0
                                                                            error:nil])
            if ([url.lastPathComponent hasPrefix:@"dev.figment."] && !forget(url)) status = 1;
    }
    for (int i = 0; i < argc && n < kMaxDisplays; i++) ids[n++] = displayArg(argv[i]);
    for (uint32_t i = 0; i < n; i++) {
        if (!forget(loginAgent(CGDisplayModelNumber(ids[i])))) status = 1;
        /* The serial is the holder's pid, but it reads as 0 once the display
         * is gone, and kill(0) would hit this process group. Only figments. */
        pid_t pid = (pid_t)CGDisplaySerialNumber(ids[i]);
        char name[64];
        if (pid > 1 && proc_name(pid, name, sizeof name) > 0 && !strcmp(name, getprogname()))
            kill(pid, SIGTERM);
    }
    /* While the screen sleeps, macOS holds off removing displays until there
     * is user activity, so declare some, like caffeinate -u. */
    IOPMAssertionID activity;
    if (n) IOPMAssertionDeclareUserActivity(CFSTR("figment stop"), kIOPMUserActiveLocal, &activity);
    for (uint32_t i = 0; i < n; i++)
        if (!waitOnline(ids[i], false)) {
            warnx("display %u is still there", ids[i]);
            status = 1;
        }
    return status;
}

int main(int argc, char **argv) {
    @autoreleasepool {
        if (argc < 2) usage();
        const char *cmd = argv[1];
        if (!strcmp(cmd, "_serve") && argc == 7)
            return serve((unsigned)atoi(argv[2]), (unsigned)atoi(argv[3]), !strcmp(argv[4], "1"),
                         (unsigned)atoi(argv[5]), (unsigned)atoi(argv[6]));
        if (!strcmp(cmd, "start") && argc >= 3) {
            int hidpi = -1;
            unsigned int hz = 60;
            for (int i = 3; i < argc; i++) {
                if (!strcmp(argv[i], "--hidpi")) hidpi = 1;
                else if (!strcmp(argv[i], "--no-hidpi")) hidpi = 0;
                else if (!strcmp(argv[i], "--hz") && i + 1 < argc) {
                    char *end;
                    hz = (unsigned)strtoul(argv[++i], &end, 10);
                    if (*end) usage();
                } else usage();
            }
            return start(argv[2], hidpi, hz);
        }
        if (!strcmp(cmd, "list") && argc == 2) return list();
        if (!strcmp(cmd, "scale") && argc >= 3 && argc <= 4) return scale(argc - 2, argv + 2);
        if (!strcmp(cmd, "stop")) return stop(argc - 2, argv + 2);
        usage();
    }
}
