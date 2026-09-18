#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Hosts the AF_UNIX microphone-input socket and captures PCM for the VMM.
//
// The app owns the microphone through the standard AVFoundation input stack, so
// iPadOS keeps full ownership of routing, permissions, interruptions and
// backgrounding. The VMM's AudioQueue input hook connects, announces the stream
// format it wants with a SETUP_IN message, and the app streams AUDIO_IN frames
// captured and converted to that format.
@interface VZPCMAudioCapture : NSObject

// A per-process socket path under /tmp; the VMM receives it through
// VZ_PCM_INPUT_SOCKET.
+ (NSString *)defaultSocketPath;

- (instancetype)initWithSocketPath:(NSString *)socketPath;

// Creates the listening socket and starts accepting the VMM connection.
- (BOOL)startWithError:(NSError **)error;
- (void)stop;

@property(atomic, readonly) BOOL running;

// Invoked on the capture state queue when capture starts (YES) or stops (NO).
// The app uses it to release the shared audio session once the guest stops
// recording, so mediaserverd is not kept awake by an idle capture graph.
@property(nonatomic, copy, nullable) void (^captureStateHandler)(BOOL capturing);

@end

NS_ASSUME_NONNULL_END
