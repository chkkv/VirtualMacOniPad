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

// Live buffer state for the on-screen debug HUD.
@property(readonly) double debugQueuedMilliseconds;
@property(readonly) double debugBufferFillRatio;
@property(readonly) float debugPlaybackRate;

@end

NS_ASSUME_NONNULL_END
