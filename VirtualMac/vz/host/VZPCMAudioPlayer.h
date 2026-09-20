#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Hosts the AF_UNIX PCM Hook socket and plays the PCM frames the VMM forwards.
// Only the standard AVFoundation playback APIs are used, so iPadOS keeps full
// ownership of routing, volume, interruptions and backgrounding.
@interface VZPCMAudioPlayer : NSObject

// A per-process socket path under /tmp; the VMM receives it through
// VZ_PCM_SOCKET.
+ (NSString *)defaultSocketPath;

- (instancetype)initWithSocketPath:(NSString *)socketPath;

// Creates the listening socket and starts accepting the VMM connection.
- (BOOL)startWithError:(NSError **)error;
- (void)stop;

@property(atomic, readonly) BOOL running;

// True while the playback engine is actually rendering. Used by the input
// bridge to decide whether the shared audio session may be deactivated after
// capture stops.
@property(atomic, readonly) BOOL playing;

// Invoked on the state queue when playback starts (YES) or stops (NO). The
// engine is only created once audio actually arrives and is torn down again
// after a short idle period, so an idle output graph does not keep
// mediaserverd awake. The app uses this to release the shared audio session
// once neither playback nor capture needs it.
@property(nonatomic, copy, nullable) void (^playbackStateHandler)(BOOL playing);

@end

NS_ASSUME_NONNULL_END
