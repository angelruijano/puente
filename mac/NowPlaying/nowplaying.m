// Lector de "Ahora suena" para Puente.
// macOS 15.4+ solo deja usar MediaRemote a procesos de Apple: por eso esta biblioteca se carga
// dentro de /usr/bin/perl (firmado por Apple) y se comunica por stdin/stdout con líneas JSON.
//
//  stdout: {"t":"np","title","artist","album","duration","elapsed","rate","playing","app","appName","artKey","art"(base64, solo si cambió)}
//          {"t":"np","none":true}
//  stdin:  {"c":"toggle"|"play"|"pause"|"next"|"prev"} {"c":"seek","to":s}
#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#include <dlfcn.h>

typedef void (*GetInfoFn)(dispatch_queue_t, void (^)(NSDictionary *));
typedef void (*GetPidFn)(dispatch_queue_t, void (^)(int));
typedef void (*GetPlayingFn)(dispatch_queue_t, void (^)(BOOL));
typedef BOOL (*SendCmdFn)(int, NSDictionary *);
typedef void (*SetElapsedFn)(double);

static GetInfoFn getInfo; static GetPidFn getPid; static GetPlayingFn getPlaying;
static SendCmdFn sendCmd; static SetElapsedFn setElapsed;
static NSString *lastSig = nil, *lastArtKey = nil;
static dispatch_queue_t q;

static void emit(NSDictionary *d) {
    NSData *j = [NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
    if (!j) return;
    fwrite(j.bytes, 1, j.length, stdout); fputc('\n', stdout); fflush(stdout);
}

static NSData *shrinkArt(NSData *art) {
    NSImage *img = [[NSImage alloc] initWithData:art];
    if (!img) return art;
    CGFloat s = MIN(1.0, 512.0 / MAX(img.size.width, img.size.height));
    NSInteger w = (NSInteger)round(img.size.width * s), h = (NSInteger)round(img.size.height * s);
    NSBitmapImageRep *rep = [[NSBitmapImageRep alloc] initWithBitmapDataPlanes:NULL pixelsWide:w pixelsHigh:h
        bitsPerSample:8 samplesPerPixel:4 hasAlpha:YES isPlanar:NO colorSpaceName:NSDeviceRGBColorSpace bytesPerRow:0 bitsPerPixel:0];
    [NSGraphicsContext saveGraphicsState];
    [NSGraphicsContext setCurrentContext:[NSGraphicsContext graphicsContextWithBitmapImageRep:rep]];
    [img drawInRect:NSMakeRect(0, 0, w, h)];
    [NSGraphicsContext restoreGraphicsState];
    return [rep representationUsingType:NSBitmapImageFileTypeJPEG properties:@{NSImageCompressionFactor: @0.85}] ?: art;
}

static void poll(void) {
    getPid(q, ^(int pid) { getPlaying(q, ^(BOOL playing) { getInfo(q, ^(NSDictionary *info) {
        if (!info || !info[@"kMRMediaRemoteNowPlayingInfoTitle"]) {
            if (![lastSig isEqual:@"none"]) { lastSig = @"none"; lastArtKey = nil; emit(@{@"t": @"np", @"none": @YES}); }
            return;
        }
        NSString *title = [info[@"kMRMediaRemoteNowPlayingInfoTitle"] description] ?: @"";
        NSString *artist = [info[@"kMRMediaRemoteNowPlayingInfoArtist"] description] ?: @"";
        NSString *album = [info[@"kMRMediaRemoteNowPlayingInfoAlbum"] description] ?: @"";
        double duration = [info[@"kMRMediaRemoteNowPlayingInfoDuration"] doubleValue];
        double elapsed = [info[@"kMRMediaRemoteNowPlayingInfoElapsedTime"] doubleValue];
        double rate = [info[@"kMRMediaRemoteNowPlayingInfoPlaybackRate"] doubleValue];
        NSDate *ts = info[@"kMRMediaRemoteNowPlayingInfoTimestamp"];
        if (ts && rate > 0) elapsed += [[NSDate date] timeIntervalSinceDate:ts] * rate;

        NSRunningApplication *app = [NSRunningApplication runningApplicationWithProcessIdentifier:pid];
        NSString *bundle = app.bundleIdentifier ?: @"", *appName = app.localizedName ?: @"";
        NSData *art = info[@"kMRMediaRemoteNowPlayingInfoArtworkData"];
        NSString *artKey = art ? [NSString stringWithFormat:@"%lu-%lu", (unsigned long)art.length, (unsigned long)art.hash] : @"";

        long bucket = rate > 0 ? (long)(elapsed / 10) : 0; // resincroniza la posición cada ~10 s
        NSString *sig = [NSString stringWithFormat:@"%@|%@|%@|%.0f|%d|%@|%@|%ld", title, artist, album, duration, playing, bundle, artKey, bucket];
        if ([sig isEqual:lastSig]) return;
        lastSig = sig;

        NSMutableDictionary *m = [@{@"t": @"np", @"title": title, @"artist": artist, @"album": album,
            @"duration": @(duration), @"elapsed": @(elapsed), @"rate": @(rate), @"playing": @(playing),
            @"app": bundle, @"appName": appName, @"artKey": artKey} mutableCopy];
        if (art && ![artKey isEqual:lastArtKey]) { m[@"art"] = [shrinkArt(art) base64EncodedStringWithOptions:0]; lastArtKey = artKey; }
        else if (!art) lastArtKey = nil;
        emit(m);
    }); }); });
}

static void readCommands(void) {
    char *line = NULL; size_t cap = 0; ssize_t n;
    while ((n = getline(&line, &cap, stdin)) > 0) {
        NSDictionary *c = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:line length:n] options:0 error:nil];
        NSString *cmd = [c isKindOfClass:[NSDictionary class]] ? c[@"c"] : nil;
        if ([cmd isEqual:@"toggle"]) sendCmd(2, nil);
        else if ([cmd isEqual:@"play"]) sendCmd(0, nil);
        else if ([cmd isEqual:@"pause"]) sendCmd(1, nil);
        else if ([cmd isEqual:@"next"]) sendCmd(4, nil);
        else if ([cmd isEqual:@"prev"]) sendCmd(5, nil);
        else if ([cmd isEqual:@"seek"]) setElapsed([c[@"to"] doubleValue]);
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), q, ^{ lastSig = nil; poll(); });
    }
    exit(0); // Puente se cerró
}

// Punto de entrada con firma de XSUB de perl (argumentos ignorados)
void puente_nowplaying(void *perl, void *cv) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MediaRemote.framework/MediaRemote", RTLD_NOW);
    getInfo = (GetInfoFn)dlsym(h, "MRMediaRemoteGetNowPlayingInfo");
    getPid = (GetPidFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationPID");
    getPlaying = (GetPlayingFn)dlsym(h, "MRMediaRemoteGetNowPlayingApplicationIsPlaying");
    sendCmd = (SendCmdFn)dlsym(h, "MRMediaRemoteSendCommand");
    setElapsed = (SetElapsedFn)dlsym(h, "MRMediaRemoteSetElapsedTime");
    if (!getInfo || !getPid || !getPlaying || !sendCmd || !setElapsed) { emit(@{@"t": @"error", @"d": @"MediaRemote no disponible"}); exit(1); }

    q = dispatch_queue_create("np", DISPATCH_QUEUE_SERIAL);
    dispatch_source_t timer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, q);
    dispatch_source_set_timer(timer, DISPATCH_TIME_NOW, 1 * NSEC_PER_SEC, 100 * NSEC_PER_MSEC);
    dispatch_source_set_event_handler(timer, ^{ poll(); });
    dispatch_resume(timer);
    dispatch_async(dispatch_get_global_queue(0, 0), ^{ readCommands(); });
    emit(@{@"t": @"ready"});
    CFRunLoopRun();
}
