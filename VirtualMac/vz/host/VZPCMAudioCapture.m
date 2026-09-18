#import "VZPCMAudioCapture.h"

#import "vz_pcm_bridge.h"

#import <AVFAudio/AVFAudio.h>

#include <errno.h>
#include <math.h>
#include <pthread.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <unistd.h>

// kAudioFormat flags (from CoreAudioTypes) needed to build the wire format
// without pulling the full AudioToolbox headers into the app target.
enum {
    VZPCMCaptureFormatFlagIsFloat = (1U << 0),
    VZPCMCaptureFormatFlagIsNonInterleaved = (1U << 5),
};

static NSString * const VZPCMCaptureErrorDomain = @"VZPCMAudioCapture";

static NSError *VZPCMCaptureError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:VZPCMCaptureErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

static BOOL VZPCMCaptureReadFull(int fd, void *buffer, size_t length)
{
    uint8_t *cursor = buffer;
    while (length > 0) {
        ssize_t count = read(fd, cursor, length);
        if (count > 0) {
            cursor += count;
            length -= (size_t)count;
            continue;
        }
        if (count < 0 && errno == EINTR)
            continue;
        return NO;
    }
    return YES;
}

// The wire format the VMM's AudioQueue input asked for. Captured audio is
// converted and packed into exactly these fields.
typedef struct {
    double sampleRate;
    uint32_t channels;
    uint32_t bits;
    uint32_t bytesPerFrame;
    bool isFloat;
    bool interleaved;
} VZPCMCaptureFormat;

static float VZPCMCaptureSample(float * const *planes,
                                uint32_t sourceChannels,
                                uint32_t targetChannels, uint32_t frame,
                                uint32_t channel)
{
    if (sourceChannels == targetChannels)
        return planes[channel][frame];
    if (sourceChannels == 1)
        return planes[0][frame];
    if (targetChannels == 1) {
        float sum = 0.0f;
        for (uint32_t c = 0; c < sourceChannels; ++c)
            sum += planes[c][frame];
        return sum / (float)sourceChannels;
    }
    if (channel < sourceChannels)
        return planes[channel][frame];
    return 0.0f;
}

static void VZPCMCaptureEncode(float * const *planes,
                               uint32_t sourceChannels, uint32_t frames,
                               const VZPCMCaptureFormat *format,
                               uint8_t *destination)
{
    uint32_t channels = format->channels;
    uint32_t sampleBytes = format->bits / 8;
    if (sampleBytes == 0)
        sampleBytes = 4;
    for (uint32_t frame = 0; frame < frames; ++frame) {
        for (uint32_t channel = 0; channel < channels; ++channel) {
            float value = VZPCMCaptureSample(planes, sourceChannels, channels,
                                             frame, channel);
            size_t offset = format->interleaved
                ? ((size_t)frame * channels + channel) * sampleBytes
                : ((size_t)channel * frames + frame) * sampleBytes;
            uint8_t *out = destination + offset;
            if (format->isFloat && format->bits == 32) {
                memcpy(out, &value, sizeof(value));
            } else if (format->bits == 16) {
                float clamped = value < -1.0f ? -1.0f
                    : (value > 1.0f ? 1.0f : value);
                int16_t sample = (int16_t)lrintf(clamped * 32767.0f);
                memcpy(out, &sample, sizeof(sample));
            } else if (format->bits == 32) {
                double clamped = value < -1.0 ? -1.0
                    : (value > 1.0 ? 1.0 : (double)value);
                int32_t sample = (int32_t)llround(clamped * 2147483647.0);
                memcpy(out, &sample, sizeof(sample));
            } else {
                memset(out, 0, sampleBytes);
            }
        }
    }
}

#pragma mark - Capture

@interface VZPCMAudioCapture () {
    pthread_mutex_t _writeLock;
}
@property(nonatomic, copy) NSString *socketPath;
@property(nonatomic, assign) int listenFD;
@property(nonatomic, assign) int clientFD;
@property(atomic, assign) BOOL running;

@property(nonatomic, assign) dispatch_queue_t ioQueue;
@property(nonatomic, assign) dispatch_queue_t stateQueue;

@property(nonatomic, retain) AVAudioEngine *engine;
@property(nonatomic, retain) AVAudioConverter *converter;
@property(nonatomic, retain) AVAudioFormat *converterOutputFormat;
@property(nonatomic, assign) BOOL streamConfigured;
@property(nonatomic, assign) BOOL rebuildPending;
@property(nonatomic, assign) VZPCMCaptureFormat wireFormat;
@end

@implementation VZPCMAudioCapture

+ (NSString *)defaultSocketPath
{
    return [NSString stringWithFormat:@"/tmp/vz-pcm-in-%d.sock", getpid()];
}

- (instancetype)initWithSocketPath:(NSString *)socketPath
{
    if ((self = [super init])) {
        _socketPath = [socketPath copy];
        _listenFD = -1;
        _clientFD = -1;
        _ioQueue = dispatch_queue_create("com.mac.virtual.pcm-in-io",
                                         DISPATCH_QUEUE_SERIAL);
        _stateQueue = dispatch_queue_create("com.mac.virtual.pcm-in-state",
                                            DISPATCH_QUEUE_SERIAL);
        pthread_mutex_init(&_writeLock, NULL);
    }
    return self;
}

- (void)dealloc
{
    [self stop];
    [_socketPath release];
    [_engine release];
    [_converter release];
    [_converterOutputFormat release];
    if (_ioQueue)
        dispatch_release(_ioQueue);
    if (_stateQueue)
        dispatch_release(_stateQueue);
    pthread_mutex_destroy(&_writeLock);
    [super dealloc];
}

- (BOOL)startWithError:(NSError **)error
{
    if (self.running)
        return YES;
    if (!self.socketPath.length) {
        if (error)
            *error = VZPCMCaptureError(1, @"PCM input socket path is empty");
        return NO;
    }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        if (error)
            *error = VZPCMCaptureError(2, @"Unable to create PCM input socket");
        return NO;
    }

    struct sockaddr_un address;
    memset(&address, 0, sizeof(address));
    address.sun_family = AF_UNIX;
    snprintf(address.sun_path, sizeof(address.sun_path), "%s",
             self.socketPath.fileSystemRepresentation);
    unlink(address.sun_path);

    if (bind(fd, (struct sockaddr *)&address, sizeof(address)) != 0 ||
        listen(fd, 1) != 0) {
        close(fd);
        if (error)
            *error = VZPCMCaptureError(3, @"Unable to bind PCM input socket");
        return NO;
    }

    self.listenFD = fd;
    self.running = YES;
    dispatch_async(self.ioQueue, ^{ [self acceptLoop]; });
    return YES;
}

- (void)stop
{
    if (!self.running && self.listenFD < 0 && self.clientFD < 0)
        return;
    self.running = NO;

    if (self.clientFD >= 0)
        shutdown(self.clientFD, SHUT_RDWR);
    if (self.listenFD >= 0)
        shutdown(self.listenFD, SHUT_RDWR);

    [[NSNotificationCenter defaultCenter] removeObserver:self];

    dispatch_sync(self.stateQueue, ^{
        [self stopEngineLocked];
        [self notifyCaptureState:NO];
    });
    dispatch_sync(self.ioQueue, ^{ });

    if (self.clientFD >= 0) {
        close(self.clientFD);
        self.clientFD = -1;
    }
    if (self.listenFD >= 0) {
        close(self.listenFD);
        self.listenFD = -1;
    }
    if (self.socketPath.length)
        unlink(self.socketPath.fileSystemRepresentation);
}

#pragma mark - Socket IO (ioQueue)

- (void)acceptLoop
{
    while (self.running && self.listenFD >= 0) {
        int client = accept(self.listenFD, NULL, NULL);
        if (client < 0) {
            if (errno == EINTR)
                continue;
            break;
        }
        if (!self.running) {
            close(client);
            break;
        }
        self.clientFD = client;
        int rcvbuf = 256 * 1024;
        setsockopt(client, SOL_SOCKET, SO_RCVBUF, &rcvbuf, sizeof(rcvbuf));
        [self readLoop:client];
        close(client);
        self.clientFD = -1;
        dispatch_sync(self.stateQueue, ^{
            [self stopEngineLocked];
            [self notifyCaptureState:NO];
        });
    }
}

- (void)readLoop:(int)fd
{
    while (self.running) {
        @autoreleasepool {
            struct vz_pcm_header header;
            if (!VZPCMCaptureReadFull(fd, &header, sizeof(header)))
                break;
            if (header.magic != VZ_PCM_MAGIC ||
                header.version != VZ_PCM_VERSION ||
                header.payload_length > VZ_PCM_MAX_PAYLOAD)
                break;

            if (header.type == VZ_PCM_MESSAGE_SETUP_IN) {
                struct vz_pcm_setup setup;
                uint32_t available = header.payload_length;
                if (available < sizeof(setup) ||
                    !VZPCMCaptureReadFull(fd, &setup, sizeof(setup)))
                    break;
                dispatch_sync(self.stateQueue, ^{
                    @autoreleasepool {
                        [self configureWithSetup:&setup];
                    }
                });
                available -= (uint32_t)sizeof(setup);
                uint8_t scratch[256];
                while (available > 0) {
                    size_t chunk = available < sizeof(scratch)
                        ? available : sizeof(scratch);
                    if (!VZPCMCaptureReadFull(fd, scratch, chunk))
                        return;
                    available -= (uint32_t)chunk;
                }
            } else {
                // Only SETUP_IN is expected from the VMM; skip unknown payloads.
                uint32_t remaining = header.payload_length;
                uint8_t scratch[256];
                while (remaining > 0) {
                    size_t chunk = remaining < sizeof(scratch)
                        ? remaining : sizeof(scratch);
                    if (!VZPCMCaptureReadFull(fd, scratch, chunk))
                        return;
                    remaining -= (uint32_t)chunk;
                }
            }
        }
    }
}

// Frames the tap produced. Runs on the audio thread; the write is a short
// local AF_UNIX write guarded by a mutex.
- (void)sendFrameType:(uint16_t)type bytes:(const void *)bytes
              length:(uint32_t)length
{
    int fd = self.clientFD;
    if (fd < 0 || !self.running)
        return;
    if (length > VZ_PCM_MAX_PAYLOAD)
        length = VZ_PCM_MAX_PAYLOAD;

    pthread_mutex_lock(&_writeLock);
    struct vz_pcm_header header;
    header.magic = VZ_PCM_MAGIC;
    header.version = VZ_PCM_VERSION;
    header.type = type;
    header.payload_length = length;

    // Two writes keep the header and payload contiguous in the stream without
    // copying the whole payload onto the stack.
    uint8_t headerBytes[sizeof(header)];
    memcpy(headerBytes, &header, sizeof(header));
    const uint8_t *pieces[2] = { headerBytes, (const uint8_t *)bytes };
    size_t lengths[2] = { sizeof(header), length };
    int ok = 1;
    for (int piece = 0; piece < 2 && ok; ++piece) {
        size_t sent = 0;
        while (sent < lengths[piece]) {
            ssize_t written = write(fd, pieces[piece] + sent,
                                    lengths[piece] - sent);
            if (written > 0) {
                sent += (size_t)written;
                continue;
            }
            if (written < 0 && errno == EINTR)
                continue;
            ok = 0;
            break;
        }
    }
    pthread_mutex_unlock(&_writeLock);
}

#pragma mark - Engine lifecycle (stateQueue)

- (void)configureWithSetup:(const struct vz_pcm_setup *)setup
{
    if (!self.running)
        return;
    if (setup->sample_rate < 1.0 || setup->channels_per_frame == 0 ||
        setup->bits_per_channel == 0)
        return;

    VZPCMCaptureFormat wire;
    memset(&wire, 0, sizeof(wire));
    wire.sampleRate = setup->sample_rate;
    wire.channels = setup->channels_per_frame;
    wire.bits = setup->bits_per_channel;
    wire.isFloat = (setup->format_flags & VZPCMCaptureFormatFlagIsFloat) != 0;
    wire.interleaved =
        (setup->format_flags & VZPCMCaptureFormatFlagIsNonInterleaved) == 0;
    uint32_t sampleBytes = wire.bits / 8;
    if (sampleBytes == 0)
        sampleBytes = 4;
    wire.bytesPerFrame = sampleBytes * wire.channels;

    // A repeated SETUP_IN means the guest rebuilt its input queue (host default
    // device or route change). Rebuild capture with the new format.
    [self stopEngineLocked];
    self.wireFormat = wire;
    [self startEngineLocked];
}

// Builds the capture engine from self.wireFormat. Also used to recover after a
// device change or interruption, so it must be safe to call repeatedly.
- (void)startEngineLocked
{
    VZPCMCaptureFormat wire = self.wireFormat;
    if (!self.running || wire.sampleRate < 1.0 || wire.channels == 0)
        return;

    NSError *error = nil;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    [session setCategory:AVAudioSessionCategoryPlayAndRecord
                    mode:AVAudioSessionModeDefault
                 options:AVAudioSessionCategoryOptionMixWithOthers |
                         AVAudioSessionCategoryOptionDefaultToSpeaker
                   error:&error];
    [session setPreferredSampleRate:wire.sampleRate error:&error];
    [session setPreferredIOBufferDuration:0.002 error:&error];
    if (![session setActive:YES error:&error])
        return;

    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    AVAudioInputNode *input = engine.inputNode;
    AVAudioFormat *inputFormat = [input outputFormatForBus:0];
    if (!inputFormat || inputFormat.channelCount == 0) {
        [engine release];
        return;
    }

    AVAudioConverter *converter = nil;
    AVAudioFormat *converterOutput = nil;
    BOOL needsConversion =
        inputFormat.sampleRate != wire.sampleRate ||
        inputFormat.commonFormat != AVAudioPCMFormatFloat32 ||
        inputFormat.isInterleaved;
    if (needsConversion) {
        converterOutput = [[AVAudioFormat alloc]
            initWithCommonFormat:AVAudioPCMFormatFloat32
                      sampleRate:wire.sampleRate
                        channels:inputFormat.channelCount
                     interleaved:NO];
        converter = converterOutput
            ? [[AVAudioConverter alloc] initFromFormat:inputFormat
                                              toFormat:converterOutput]
            : nil;
        if (!converter) {
            [converterOutput release];
            [engine release];
            return;
        }
    }

    self.converter = converter;
    self.converterOutputFormat = converterOutput;
    [converterOutput release];
    [converter release];

    __block VZPCMAudioCapture *capture = self;
    [input installTapOnBus:0 bufferSize:4096 format:inputFormat
                     block:^(AVAudioPCMBuffer *buffer, AVAudioTime *when) {
        (void)when;
        [capture handleInputBuffer:buffer];
    }];

    @try {
        [engine prepare];
        if (![engine startAndReturnError:&error]) {
            [input removeTapOnBus:0];
            [engine release];
            return;
        }
    } @catch (__unused NSException *exception) {
        [input removeTapOnBus:0];
        [engine release];
        return;
    }

    self.engine = engine;
    [engine release];
    self.streamConfigured = YES;
    [self notifyCaptureState:YES];

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
    [center removeObserver:self];
    [center addObserver:self
               selector:@selector(handleEngineConfigurationChange:)
                   name:AVAudioEngineConfigurationChangeNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(handleInterruption:)
                   name:AVAudioSessionInterruptionNotification
                 object:nil];
    [center addObserver:self
               selector:@selector(handleMediaServicesReset:)
                   name:AVAudioSessionMediaServicesWereResetNotification
                 object:nil];
}

- (void)stopEngineLocked
{
    if (self.engine) {
        [self.engine.inputNode removeTapOnBus:0];
        [self.engine stop];
    }
    self.engine = nil;
    self.converter = nil;
    self.converterOutputFormat = nil;
    self.streamConfigured = NO;
}

// Reports capture start/stop to the owner. Runs on the state queue.
- (void)notifyCaptureState:(BOOL)capturing
{
    void (^handler)(BOOL) = self.captureStateHandler;
    if (handler)
        handler(capturing);
}

#pragma mark - Device changes

- (void)restartEngineLocked
{
    if (!self.streamConfigured || !self.running)
        return;
    [self stopEngineLocked];
    [self startEngineLocked];
}

- (void)handleEngineConfigurationChange:(NSNotification *)notification
{
    (void)notification;
    dispatch_async(self.stateQueue, ^{
        @autoreleasepool {
            if (!self.streamConfigured || self.rebuildPending)
                return;
            self.rebuildPending = YES;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                          200 * NSEC_PER_MSEC),
                           self.stateQueue, ^{
                self.rebuildPending = NO;
                [self restartEngineLocked];
            });
        }
    });
}

- (void)handleInterruption:(NSNotification *)notification
{
    dispatch_async(self.stateQueue, ^{
        @autoreleasepool {
            if (!self.streamConfigured)
                return;
            NSNumber *type = notification.userInfo[
                AVAudioSessionInterruptionTypeKey];
            if (type.unsignedIntegerValue ==
                AVAudioSessionInterruptionTypeBegan) {
                if (self.engine)
                    [self.engine pause];
                return;
            }
            NSNumber *options = notification.userInfo[
                AVAudioSessionInterruptionOptionKey];
            if (options.unsignedIntegerValue &
                AVAudioSessionInterruptionOptionShouldResume)
                [self restartEngineLocked];
        }
    });
}

- (void)handleMediaServicesReset:(NSNotification *)notification
{
    (void)notification;
    dispatch_async(self.stateQueue, ^{
        @autoreleasepool {
            if (self.streamConfigured)
                [self restartEngineLocked];
        }
    });
}

// Audio thread. Converts the captured buffer to the wire sample rate and packs
// it to the requested format, then hands it to the socket writer.
- (void)handleInputBuffer:(AVAudioPCMBuffer *)buffer
{
    @autoreleasepool {
    if (!self.running || !self.streamConfigured || buffer.frameLength == 0)
        return;

    AVAudioPCMBuffer *source = buffer;
    if (self.converter && self.converterOutputFormat) {
        AVAudioFrameCount capacity = (AVAudioFrameCount)(
            (double)buffer.frameLength * self.converterOutputFormat.sampleRate /
                buffer.format.sampleRate + 64.0);
        if (capacity < buffer.frameLength)
            capacity = buffer.frameLength;
        AVAudioPCMBuffer *converted = [[AVAudioPCMBuffer alloc]
            initWithPCMFormat:self.converterOutputFormat
                frameCapacity:capacity];
        if (!converted)
            return;
        __block AVAudioPCMBuffer *input = buffer;
        __block BOOL consumed = NO;
        NSError *error = nil;
        AVAudioConverterOutputStatus status = [self.converter
            convertToBuffer:converted error:&error
            withInputFromBlock:^AVAudioBuffer *(AVAudioPacketCount count,
                                                 AVAudioConverterInputStatus
                                                     *outStatus) {
                (void)count;
                if (consumed) {
                    *outStatus = AVAudioConverterInputStatus_NoDataNow;
                    return nil;
                }
                consumed = YES;
                *outStatus = AVAudioConverterInputStatus_HaveData;
                return input;
            }];
        if (status == AVAudioConverterOutputStatus_Error ||
            converted.frameLength == 0) {
            [converted release];
            return;
        }
        source = [converted autorelease];
    }

    uint32_t frames = (uint32_t)source.frameLength;
    uint32_t sourceChannels = (uint32_t)source.format.channelCount;
    float * const *planes = source.floatChannelData;
    if (!planes || sourceChannels == 0)
        return;

    uint32_t payload = frames * self.wireFormat.bytesPerFrame;
    if (payload == 0 || payload > VZ_PCM_MAX_PAYLOAD)
        return;
    uint8_t *bytes = malloc(payload);
    if (!bytes)
        return;
    VZPCMCaptureEncode(planes, sourceChannels, frames, &_wireFormat, bytes);
    [self sendFrameType:VZ_PCM_MESSAGE_AUDIO_IN bytes:bytes length:payload];
    free(bytes);
    }
}

@end
