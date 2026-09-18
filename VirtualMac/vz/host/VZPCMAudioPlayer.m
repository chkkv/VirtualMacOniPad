#import "VZPCMAudioPlayer.h"

#import "vz_pcm_bridge.h"

#import <AVFAudio/AVFAudio.h>

#include <errno.h>
#include <math.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/un.h>
#include <unistd.h>

// kAudioFormat flags (from CoreAudioTypes) needed to interpret the setup frame
// without pulling the full AudioToolbox headers into the app target.
enum {
    VZPCMFormatFlagIsFloat = (1U << 0),
    VZPCMFormatFlagIsNonInterleaved = (1U << 5),
};

static NSString * const VZPCMAudioPlayerErrorDomain = @"VZPCMAudioPlayer";

static NSError *VZPCMError(NSInteger code, NSString *message)
{
    return [NSError errorWithDomain:VZPCMAudioPlayerErrorDomain code:code
        userInfo:@{NSLocalizedDescriptionKey: message}];
}

// When the PCM input bridge is active the app must hold a recording-capable
// session; switching back to playback here would tear the capture engine down
// on every activation. The flag is exported by the app before the VMM starts.
static AVAudioSessionCategory VZPCMPlayerSessionCategory(void)
{
    const char *input = getenv("VZ_ALLOW_PCM_INPUT");
    return (input && input[0] == '1' && input[1] == '\0')
        ? AVAudioSessionCategoryPlayAndRecord
        : AVAudioSessionCategoryPlayback;
}

static AVAudioSessionCategoryOptions VZPCMPlayerSessionOptions(void)
{
    return VZPCMPlayerSessionCategory() == AVAudioSessionCategoryPlayAndRecord
        ? (AVAudioSessionCategoryOptionMixWithOthers |
           AVAudioSessionCategoryOptionDefaultToSpeaker)
        : 0;
}

// Append-only diagnostic log, matching the other /tmp diag logs' fopen/fchmod
// form. Called on every produce and consume so the file shows the live PCM
// backlog and drift correction alongside the rest of the device logs.
static void VZPVMLog(const char *format, ...)
{
    FILE *file = fopen("/tmp/VZPVM.log", "a");
    if (!file)
        return;
    fchmod(fileno(file), 0666);
    va_list args;
    va_start(args, format);
    vfprintf(file, format, args);
    va_end(args);
    fputc('\n', file);
    fclose(file);
}

static BOOL VZPCMReadFull(int fd, void *buffer, size_t length)
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

#pragma mark - SPSC ring buffer

// Single producer (the socket IO queue) / single consumer (the audio render
// thread). Samples are stored as planar float, one frame-major block of
// `channels` floats per frame.
//
// Frame counters are 32-bit and wrap modulo 2^32. Every comparison between
// them uses serial-number arithmetic: two values are ordered by their signed
// difference, which is exact as long as the true distance stays below 2^31
// (always true here, since the ring is only ~2^15 frames deep). This keeps the
// logic correct across the wrap instead of assuming the wrap never happens.
#define VZ_PCM_FRAC_BITS 16
#define VZ_PCM_FRAC_ONE  (1ULL << VZ_PCM_FRAC_BITS)
#define VZ_PCM_FRAC_MASK (VZ_PCM_FRAC_ONE - 1)

// Fixed-point cursor: the low VZ_PCM_FRAC_BITS hold the fractional frame, the
// next 32 bits hold the integer frame counter in the same modulo-2^32 space as
// writeFrames/readFrames, and the top bits stay zero. 2^16 parts per frame is
// ~0.32 ns at 48 kHz and keeps ratio steps exact to 1/65536.
#define VZ_PCM_CURSOR_MASK \
    (((uint64_t)0xFFFFFFFFu << VZ_PCM_FRAC_BITS) | VZ_PCM_FRAC_MASK)

// Silence cushion prepended by the producer when the ring runs dry, so the
// drift controller has room to recover instead of hitting a hard underrun.
#define VZ_PCM_PREPAD_SECONDS 0.01

// Number of VzCore blocks (4096 frames each) to blank after a fresh lock,
// expressed as audio time so it scales with the sample rate.
#define VZ_PCM_WARMUP_BLOCKS 4

// Polyphase windowed-sinc resampler. The 16-bit fractional cursor selects a
// phase in a precomputed table of Blackman-Harris windowed sinc filters, one
// set of VZ_PCM_SINC_TAPS taps per phase, so each output frame is a band-
// limited fractional-delay read instead of a two-point linear blend. Only
// VZ_PCM_SINC_PHASE_BITS of the fraction are used; the residual 1/1024-frame
// phase quantization is far below the linear interpolator's modulation error.
// An odd tap count puts the sinc centre on an integer tap, so a zero fraction
// maps exactly to the `base` sample instead of the half-sample offset an even
// count would introduce.
#define VZ_PCM_SINC_PHASE_BITS 10
#define VZ_PCM_SINC_PHASES (1u << VZ_PCM_SINC_PHASE_BITS)
#define VZ_PCM_SINC_TAPS 15
#define VZ_PCM_SINC_HALF 7

// True when `a` is ahead of `b` in the wrapping 32-bit frame space.
static inline bool VZPCMSerialAfter(uint32_t a, uint32_t b)
{
    return (int32_t)(a - b) > 0;
}

// Signed distance from b to a in the wrapping space (positive => a after b).
static inline int32_t VZPCMSerialDelta(uint32_t a, uint32_t b)
{
    return (int32_t)(a - b);
}

typedef struct {
    float *samples;          // capacityFrames * channels
    uint32_t capacityFrames; // power of two
    uint32_t mask;
    uint32_t channels;
    uint32_t wireBytesPerFrame;
    uint32_t bitsPerChannel;
    bool sourceInterleaved;
    bool sourceIsFloat;
    volatile uint32_t writeFrames; // producer-owned, published on write (mod 2^32)
    volatile uint32_t readFrames;  // consumer-owned, published on read (mod 2^32)
} VZPCMRing;

typedef struct {
    VZPCMRing *ring;
    uint32_t channels;
    uint32_t mask;
    uint64_t cursor;      // fixed-point frame position (integer part mod 2^32)
    bool cursorValid;     // false until the first lock places the cursor
    // Seconds left in the startup blanking period after a fresh lock. While
    // positive the control window does not accumulate, so the backlog
    // transient while the stream fills cannot bias the first ratio update.
    // Counted down with audio time (frameCount / sampleRate), so a paused
    // engine simply pauses it.
    double warmupRemaining;
    double targetFrames;  // desired average backlog, used for the initial cursor
    double sampleRate;    // output sample rate, so control gains are time-based
    // Integral drift controller, updated once per `controlPeriod`. The backlog
    // error is averaged over the whole window, which filters the per-block
    // sawtooth (>= one VzCore block), and the discrete 10 s update turns the
    // otherwise marginally-stable continuous integrator into a well-damped
    // first-order loop (stable while |1 - controlPeriod * ki| < 1).
    double ki;             // ratio correction per second of window-average error
    double maxCorrection;  // clamp on |ratio - 1|, bounds the pitch shift
    double controlPeriod;  // update interval in seconds
    double windowError;    // accumulated (error * dt) over the current window
    double windowElapsed;  // seconds accumulated in the current window
    // Set when the previous render block found no data. An empty ring parks the
    // cursor at the producer edge, so the backlog reads 0 (below target) even
    // though nothing is wrong; integrating that would drive ratio to the clamp
    // during silence. While stalled the integrator is frozen, and the window is
    // restarted once data returns so a stale pre-silence average cannot apply.
    bool stalled;
    double ratio;          // current consumption rate, consumer-owned
    uint32_t ratioStep;    // round(ratio * 2^16), the per-frame cursor step
    volatile uint32_t lastRatioMicro; // drift ratio * 1e6, HUD-only, atomic
} VZPCMRenderContext;

static uint32_t VZPCMNextPowerOfTwo(uint32_t value)
{
    uint32_t result = 1;
    while (result < value && result < (1u << 31))
        result <<= 1;
    return result;
}

static inline float VZPCMSampleFromBytes(const uint8_t *p, bool isFloat,
                                         uint32_t bits)
{
    if (isFloat && bits == 32) {
        float v;
        memcpy(&v, p, sizeof(v));
        return v;
    }
    if (bits == 16) {
        int16_t v;
        memcpy(&v, p, sizeof(v));
        return (float)v / 32768.0f;
    }
    if (bits == 32) {
        int32_t v;
        memcpy(&v, p, sizeof(v));
        return (float)((double)v / 2147483648.0);
    }
    if (bits == 64) {
        double v;
        memcpy(&v, p, sizeof(v));
        return (float)v;
    }
    return 0.0f;
}

// 4-term Blackman-Harris window over [0, 1]. Its sidelobes sit below -90 dB,
// so the truncated sinc's passband ripple and reconstruction error stay well
// under the linear interpolator's across the band.
static double VZPCMBlackmanHarris(double t)
{
    if (t < 0.0) t = 0.0;
    if (t > 1.0) t = 1.0;
    const double a0 = 0.35875, a1 = 0.48829, a2 = 0.14128, a3 = 0.01168;
    return a0 - a1 * cos(2.0 * M_PI * t) + a2 * cos(4.0 * M_PI * t) -
        a3 * cos(6.0 * M_PI * t);
}

// Lazily built once, then read lock-free by the render thread. Layout is
// [phase][tap]; each phase is normalized to unity DC so the output gain does
// not wobble as the fractional cursor sweeps through the table entries.
static float *g_pcmSincTable;
static dispatch_once_t g_pcmSincOnce;

static void VZPCMEnsureSincTable(void)
{
    dispatch_once(&g_pcmSincOnce, ^{
        size_t count = (size_t)VZ_PCM_SINC_PHASES * VZ_PCM_SINC_TAPS;
        float *table = calloc(count, sizeof(float));
        if (!table)
            return;
        const double center = (VZ_PCM_SINC_TAPS - 1) / 2.0;
        for (uint32_t p = 0; p < VZ_PCM_SINC_PHASES; ++p) {
            double delay = (double)p / (double)VZ_PCM_SINC_PHASES;
            double sum = 0.0;
            for (uint32_t k = 0; k < VZ_PCM_SINC_TAPS; ++k) {
                double x = (double)k - center - delay;
                double s = fabs(x) < 1e-9 ? 1.0 : sin(M_PI * x) / (M_PI * x);
                // Slide the window with the fractional delay so it stays
                // symmetric about the sinc peak; that keeps the phase linear
                // and makes the phase sets continuous across the table.
                double w = VZPCMBlackmanHarris(((double)k - delay) /
                    (double)(VZ_PCM_SINC_TAPS - 1));
                double v = s * w;
                table[(size_t)p * VZ_PCM_SINC_TAPS + k] = (float)v;
                sum += v;
            }
            if (sum != 0.0) {
                float inv = (float)(1.0 / sum);
                for (uint32_t k = 0; k < VZ_PCM_SINC_TAPS; ++k)
                    table[(size_t)p * VZ_PCM_SINC_TAPS + k] *= inv;
            }
        }
        __atomic_store_n(&g_pcmSincTable, table, __ATOMIC_RELEASE);
    });
}

// Producer side. Converts the wire samples to planar float and appends whole
// frames. When full, incoming frames are dropped so playback stays pinned to
// the live edge instead of accumulating latency; the consumer never blocks.
// Returns the number of frames actually appended (0 when the ring is full or
// the input is unusable), so callers can log real progress rather than the
// requested length.
static uint32_t VZPCMRingPush(VZPCMRing *ring, const uint8_t *data,
                              uint32_t length)
{
    if (!ring || !ring->samples || ring->channels == 0 ||
        ring->wireBytesPerFrame == 0)
        return 0;
    uint32_t frames = length / ring->wireBytesPerFrame;
    if (frames == 0)
        return 0;

    uint32_t write = __atomic_load_n(&ring->writeFrames, __ATOMIC_RELAXED);
    uint32_t read = __atomic_load_n(&ring->readFrames, __ATOMIC_ACQUIRE);
    // Serial-number guard: if the consumer's read pointer is somehow ahead of
    // write, treat the ring as empty. The wrapping comparison stays valid
    // across the 2^32 boundary.
    if (VZPCMSerialAfter(read, write))
        read = write;
    uint32_t used = write - read;
    if (used > ring->capacityFrames)
        used = ring->capacityFrames;
    uint32_t freeFrames = ring->capacityFrames - used;
    if (frames > freeFrames)
        frames = (uint32_t)freeFrames;
    if (frames == 0)
        return 0;

    uint32_t sampleBytes = ring->bitsPerChannel / 8;
    if (sampleBytes == 0)
        sampleBytes = 4;
    uint32_t channels = ring->channels;
    uint32_t mask = ring->mask;
    for (uint32_t f = 0; f < frames; ++f) {
        float *destination =
            ring->samples + (size_t)((write + f) & mask) * channels;
        for (uint32_t c = 0; c < channels; ++c) {
            size_t offset = ring->sourceInterleaved
                ? ((size_t)f * channels + c) * sampleBytes
                : ((size_t)c * frames + f) * sampleBytes;
            destination[c] = VZPCMSampleFromBytes(data + offset,
                                                  ring->sourceIsFloat,
                                                  ring->bitsPerChannel);
        }
    }
    __atomic_store_n(&ring->writeFrames, write + frames, __ATOMIC_RELEASE);
    return frames;
}

// Producer-side padding: appends whole frames of silence. Used only when the
// ring is about to run dry, so the ratio controller has a small cushion to
// recover instead of a hard underrun.
static void VZPCMRingPushSilence(VZPCMRing *ring, uint32_t frames)
{
    if (!ring || !ring->samples || ring->channels == 0)
        return;
    uint32_t write = __atomic_load_n(&ring->writeFrames, __ATOMIC_RELAXED);
    uint32_t read = __atomic_load_n(&ring->readFrames, __ATOMIC_ACQUIRE);
    // Same serial-number guard as VZPCMRingPush; see the note there.
    if (VZPCMSerialAfter(read, write))
        read = write;
    uint32_t used = write - read;
    if (used > ring->capacityFrames)
        used = ring->capacityFrames;
    uint32_t freeFrames = ring->capacityFrames - used;
    if (frames > freeFrames)
        frames = (uint32_t)freeFrames;
    if (frames == 0)
        return;
    uint32_t channels = ring->channels;
    uint32_t mask = ring->mask;
    for (uint32_t f = 0; f < frames; ++f) {
        float *destination =
            ring->samples + (size_t)((write + f) & mask) * channels;
        for (uint32_t c = 0; c < channels; ++c)
            destination[c] = 0.0f;
    }
    __atomic_store_n(&ring->writeFrames, write + frames, __ATOMIC_RELEASE);
}

// Consumer side. Fills the render block's planar float output from the ring.
// The fractional cursor plus a small ratio correction absorbs the sender's
// clock drift; missing frames become silence rather than a discontinuity.
static void VZPCMRenderFrames(VZPCMRenderContext *ctx,
                              AVAudioFrameCount frameCount,
                              AudioBufferList *outputData, BOOL *isSilence)
{
    VZPCMRing *ring = ctx->ring;
    uint32_t ringChannels = ctx->channels;
    uint32_t mask = ctx->mask;
    uint32_t outChannels = outputData->mNumberBuffers;
    uint32_t channels = ringChannels < outChannels ? ringChannels : outChannels;
    const float *samples = ring->samples;
    uint32_t write = __atomic_load_n(&ring->writeFrames, __ATOMIC_ACQUIRE);

    uint64_t cursor = ctx->cursor;
    if (!ctx->cursorValid) {
        // Place the cursor `targetFrames` behind the producer edge. Both are
        // wrapping 32-bit counters, so the subtraction is done modulo 2^32 and
        // resolves to the right distance even across the boundary.
        uint32_t target = (uint32_t)ctx->targetFrames;
        uint32_t startFrame = write - target;
        cursor = (uint64_t)startFrame << VZ_PCM_FRAC_BITS;
        // Fresh lock (first start or route rebuild): restart the controller so
        // a correction learned from the previous stream cannot slingshot the
        // freshly placed cursor.
        ctx->ratio = 1.0;
        ctx->ratioStep = (uint32_t)VZ_PCM_FRAC_ONE;
        ctx->windowError = 0.0;
        ctx->windowElapsed = 0.0;
        ctx->stalled = false;
        // Blank the first few blocks so the stream-fill transient cannot bias
        // the first ratio update. Expressed in audio time, so it scales with
        // the sample rate and pauses with the engine.
        ctx->warmupRemaining = ctx->sampleRate > 0.0
            ? VZ_PCM_WARMUP_BLOCKS * (4096.0 / ctx->sampleRate) : 0.0;
        ctx->cursorValid = true;
    }

    // Integral drift control. Accumulate the backlog error (in seconds) across
    // the window; every `controlPeriod` average it, step the consumption rate,
    // and reset the window. The window average removes the per-block sawtooth,
    // and the discrete update keeps the loop first-order stable. While stalled
    // (the previous block had no data) the backlog is meaningless, so skip the
    // whole update and hold the current ratio.
    uint32_t cursorFrame = (uint32_t)(cursor >> VZ_PCM_FRAC_BITS);
    double backlogFrames = (double)VZPCMSerialDelta(write, cursorFrame);
    if (ctx->sampleRate > 0.0 && !ctx->stalled) {
        double dt = (double)frameCount / ctx->sampleRate;
        if (ctx->warmupRemaining > 0.0) {
            // Startup blanking: keep consuming (the cursor still advances
            // below) but do not start the control window, so the transient
            // while the stream fills cannot bias the first ratio update. A
            // paused engine never reaches here, so blanking pauses too.
            ctx->warmupRemaining -= dt;
        } else {
            ctx->windowError +=
                (backlogFrames - ctx->targetFrames) / ctx->sampleRate * dt;
            ctx->windowElapsed += dt;
            if (ctx->windowElapsed >= ctx->controlPeriod) {
                double avgErrorSeconds = ctx->windowError / ctx->windowElapsed;
                ctx->ratio += ctx->ki * avgErrorSeconds;
                double off = ctx->ratio - 1.0;
                if (off >= -0.0003 && off <= 0.0003)
                    ctx->ratio = 1.0;
                else if (ctx->ratio > 1.0 + ctx->maxCorrection)
                    ctx->ratio = 1.0 + ctx->maxCorrection;
                else if (ctx->ratio < 1.0 - ctx->maxCorrection)
                    ctx->ratio = 1.0 - ctx->maxCorrection;
                ctx->windowError = 0.0;
                ctx->windowElapsed = 0.0;
                // Quantize the ratio to the cursor's fractional step once, so
                // the per-frame loop stays integer-only.
                ctx->ratioStep =
                    (uint32_t)llround(ctx->ratio * (double)VZ_PCM_FRAC_ONE);
                __atomic_store_n(&ctx->lastRatioMicro,
                                 (uint32_t)(ctx->ratio * 1000000.0),
                                 __ATOMIC_RELAXED);
            }
        }
    }

    // Clear any output channels the ring does not provide, so a channel-count
    // mismatch never leaks a previous block's samples.
    for (uint32_t c = channels; c < outChannels; ++c) {
        AudioBuffer *buffer = &outputData->mBuffers[c];
        if (buffer->mData)
            memset(buffer->mData, 0, buffer->mDataByteSize);
    }

    const float *sincTable = __atomic_load_n(&g_pcmSincTable, __ATOMIC_ACQUIRE);
    const int32_t capacity = (int32_t)ring->capacityFrames;
    uint32_t phaseShift = VZ_PCM_FRAC_BITS - VZ_PCM_SINC_PHASE_BITS;

    BOOL producedAny = NO;
    for (AVAudioFrameCount f = 0; f < frameCount; ++f) {
        uint32_t base = (uint32_t)(cursor >> VZ_PCM_FRAC_BITS);
        float fraction = (float)(cursor & VZ_PCM_FRAC_MASK) /
            (float)VZ_PCM_FRAC_ONE;
        // Signed distance from `base` up to the producer edge: the number of
        // published frames at or after `base`. Uses serial-number arithmetic,
        // so it stays correct across the 2^32 counter wrap.
        int32_t ahead = VZPCMSerialDelta(write, base);
        if (ahead <= 0) {
            // No data available: emit silence and hold the cursor at the
            // producer edge. Never advance past `write`, so the producer's
            // free-space computation stays consistent.
            for (uint32_t c = 0; c < channels; ++c) {
                float *destination = outputData->mBuffers[c].mData;
                if (destination)
                    destination[f] = 0.0f;
            }
            continue;
        }

        const float *s0 = samples + (size_t)(base & mask) * ringChannels;
        const float *s1 =
            samples + (size_t)((base + 1) & mask) * ringChannels;

        // Run the polyphase sinc only when the whole tap window is inside
        // published and not-yet-overwritten data. New or starved streams fall
        // back to linear (or zero-order hold for a single frame), so the taps
        // never read outside valid memory at the edges.
        // `ahead` is write - base, and valid data is [write-capacity, write).
        // Taps run base-VZ_PCM_SINC_HALF .. base+VZ_PCM_SINC_HALF, so the top
        // must stay strictly below `write` and the bottom must not have been
        // lapped by the producer.
        BOOL sincUsable = sincTable &&
            ahead > VZ_PCM_SINC_HALF &&
            ahead <= capacity - (VZ_PCM_SINC_HALF + 1);
        const float *coef = NULL;
        uint32_t first = base - VZ_PCM_SINC_HALF;
        if (sincUsable) {
            uint32_t phase = (uint32_t)((cursor >> phaseShift) &
                (VZ_PCM_SINC_PHASES - 1));
            coef = sincTable + (size_t)phase * VZ_PCM_SINC_TAPS;
        }

        for (uint32_t c = 0; c < channels; ++c) {
            float value;
            if (sincUsable) {
                float acc = 0.0f;
                for (uint32_t k = 0; k < VZ_PCM_SINC_TAPS; ++k) {
                    uint32_t index = (first + k) & mask;
                    acc += coef[k] * samples[(size_t)index * ringChannels + c];
                }
                value = acc;
            } else if (ahead >= 2) {
                value = s0[c] * (1.0f - fraction) + s1[c] * fraction;
            } else {
                value = s0[c];
            }
            float *destination = outputData->mBuffers[c].mData;
            if (destination)
                destination[f] = value;
        }
        cursor = (cursor + (uint64_t)ctx->ratioStep) & VZ_PCM_CURSOR_MASK;
        producedAny = YES;
    }
    // Freeze the integrator while the ring is dry, and restart its window on the
    // transition back to data so a stale pre-silence average cannot apply.
    if (producedAny) {
        if (ctx->stalled) {
            ctx->stalled = false;
            ctx->windowError = 0.0;
            ctx->windowElapsed = 0.0;
        }
    } else {
        ctx->stalled = true;
        ctx->windowError = 0.0;
        ctx->windowElapsed = 0.0;
    }
    // Publish the integer frame position, clamped so read never runs ahead of
    // the producer edge in the wrapping counter space. Keeping cursor and
    // readFrames in the same modulo-2^32 space is what makes the ordering
    // check wrapping-safe.
    uint32_t readPos = (uint32_t)(cursor >> VZ_PCM_FRAC_BITS);
    if (VZPCMSerialAfter(readPos, write)) {
        cursor = ((uint64_t)write << VZ_PCM_FRAC_BITS) |
            (cursor & VZ_PCM_FRAC_MASK);
        readPos = write;
    }
    ctx->cursor = cursor;
    __atomic_store_n(&ring->readFrames, readPos, __ATOMIC_RELEASE);
    if (isSilence && !producedAny)
        *isSilence = YES;

    VZPVMLog("[vz-pcm] consume frames=%u cursor=%u.%05u write=%u read=%u "
             "backlog=%d ratio=%.6f produced=%d",
             (unsigned)frameCount,
             (unsigned)(cursor >> VZ_PCM_FRAC_BITS),
             (unsigned)((cursor & VZ_PCM_FRAC_MASK) * 100000 /
                        VZ_PCM_FRAC_ONE),
             (unsigned)write, (unsigned)readPos,
             (int)VZPCMSerialDelta(write, readPos),
             ctx->ratio, producedAny ? 1 : 0);
}

#pragma mark - Player

@interface VZPCMAudioPlayer ()
@property(nonatomic, copy) NSString *socketPath;
@property(nonatomic, assign) int listenFD;
@property(nonatomic, assign) int clientFD;
@property(atomic, assign) BOOL running;

@property(nonatomic, assign) dispatch_queue_t ioQueue;
@property(nonatomic, assign) dispatch_queue_t stateQueue;

@property(nonatomic, retain) AVAudioEngine *engine;
@property(nonatomic, retain) AVAudioSourceNode *sourceNode;
@property(nonatomic, retain) AVAudioFormat *format;
@property(nonatomic, assign) BOOL streamConfigured;
@property(nonatomic, assign) BOOL rebuildPending;

// Published right after each ring write so the HUD shows the backlog the
// newest PCM block produced, rather than a random instant during consumption.
@property(atomic, assign) double debugQueuedMilliseconds;
@property(atomic, assign) double debugBufferFillRatio;

// C structures owned by the state queue but read lock-free by the IO queue
// (ring) and the render thread (ring + context).
@property(nonatomic, assign) VZPCMRing *ring;
@property(nonatomic, assign) VZPCMRenderContext *renderContext;
@end

@implementation VZPCMAudioPlayer

+ (NSString *)defaultSocketPath
{
    return [NSString stringWithFormat:@"/tmp/vz-pcm-%d.sock", getpid()];
}

- (instancetype)initWithSocketPath:(NSString *)socketPath
{
    if ((self = [super init])) {
        _socketPath = [socketPath copy];
        _listenFD = -1;
        _clientFD = -1;
        _ioQueue = dispatch_queue_create("com.mac.virtual.pcm-io",
                                         DISPATCH_QUEUE_SERIAL);
        _stateQueue = dispatch_queue_create("com.mac.virtual.pcm-state",
                                            DISPATCH_QUEUE_SERIAL);
    }
    return self;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // Ensure the render thread is stopped before the ring/context are freed,
    // in case the owner released us without calling -stop first.
    if (_engine)
        [_engine stop];
    if (_clientFD >= 0)
        close(_clientFD);
    if (_listenFD >= 0)
        close(_listenFD);
    if (_ring) {
        free(_ring->samples);
        free(_ring);
    }
    if (_renderContext)
        free(_renderContext);
    [_socketPath release];
    [_engine release];
    [_sourceNode release];
    [_format release];
    if (_ioQueue)
        dispatch_release(_ioQueue);
    if (_stateQueue)
        dispatch_release(_stateQueue);
    [super dealloc];
}

- (BOOL)startWithError:(NSError **)error
{
    if (self.running)
        return YES;
    if (!self.socketPath.length) {
        if (error)
            *error = VZPCMError(1, @"PCM socket path is empty");
        return NO;
    }

    int fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (fd < 0) {
        if (error)
            *error = VZPCMError(2, @"Unable to create PCM socket");
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
            *error = VZPCMError(3, @"Unable to bind PCM socket");
        return NO;
    }

    self.listenFD = fd;
    self.running = YES;
    printf("[VirtualMac] PCM hook listening on %s\n",
           self.socketPath.UTF8String);
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

    // Stop rendering while the ring is still alive, then quiesce the producer,
    // and only then free the ring/context so neither side can touch freed
    // memory.
    dispatch_sync(self.stateQueue, ^{ [self stopEngineLocked]; });
    dispatch_sync(self.ioQueue, ^{ });
    dispatch_sync(self.stateQueue, ^{ [self freeRingLocked]; });

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

    // Do not deactivate the shared session while the PCM input bridge still
    // owns a capture engine; deactivating here would silence the microphone.
    if (VZPCMPlayerSessionCategory() == AVAudioSessionCategoryPlayback) {
        [AVAudioSession.sharedInstance setActive:NO
            withOptions:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
            error:nil];
    }
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
        printf("[VirtualMac] PCM hook VMM connected\n");
        [self readLoop:client];
        close(client);
        self.clientFD = -1;
        printf("[VirtualMac] PCM hook VMM disconnected\n");
    }
}

- (void)readLoop:(int)fd
{
    while (self.running) {
        @autoreleasepool {
            struct vz_pcm_header header;
            if (!VZPCMReadFull(fd, &header, sizeof(header)))
                break;
            if (header.magic != VZ_PCM_MAGIC ||
                header.version != VZ_PCM_VERSION ||
                header.payload_length > VZ_PCM_MAX_PAYLOAD)
                break;

            if (header.type == VZ_PCM_MESSAGE_SETUP) {
                struct vz_pcm_setup setup;
                uint32_t available = header.payload_length;
                if (available < sizeof(setup) ||
                    !VZPCMReadFull(fd, &setup, sizeof(setup)))
                    break;
                // Configure synchronously: the AUDIO frames that follow are
                // pushed straight into the ring from this thread and need it to
                // exist already.
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
                    if (!VZPCMReadFull(fd, scratch, chunk))
                        return;
                    available -= (uint32_t)chunk;
                }
            } else if (header.type == VZ_PCM_MESSAGE_AUDIO) {
                uint32_t length = header.payload_length;
                if (length == 0)
                    continue;
                uint8_t *copy = malloc(length);
                if (!copy)
                    break;
                if (!VZPCMReadFull(fd, copy, length)) {
                    free(copy);
                    break;
                }
                [self pushBytes:copy length:length];
                free(copy);
            } else {
                break;
            }
        }
    }
}

// Producer entry point. Runs on the IO queue; only touches the ring through
// atomics so it never contends with the render thread or the state queue.
- (void)pushBytes:(const uint8_t *)bytes length:(uint32_t)length
{
    VZPCMRing *ring = __atomic_load_n(&_ring, __ATOMIC_ACQUIRE);
    if (!ring)
        return;
    // If the consumer already drained the ring, pad 10 ms of silence before
    // appending so this write ends at a usable peak instead of restarting from
    // zero. Steady state never triggers this (the sawtooth floor is above 0).
    BOOL paddedSilence = NO;
    if (_format && _format.sampleRate > 0.0) {
        uint32_t write = __atomic_load_n(&ring->writeFrames, __ATOMIC_ACQUIRE);
        uint32_t read = __atomic_load_n(&ring->readFrames, __ATOMIC_ACQUIRE);
        if (VZPCMSerialDelta(write, read) <= 0) {
            uint32_t silenceFrames =
                (uint32_t)(_format.sampleRate * VZ_PCM_PREPAD_SECONDS);
            VZPCMRingPushSilence(ring, silenceFrames);
            paddedSilence = YES;
        }
    }
    uint32_t writtenFrames = VZPCMRingPush(ring, bytes, length);
    [self publishDebugSnapshot:ring];

    uint32_t requestedFrames = ring->wireBytesPerFrame
        ? length / ring->wireBytesPerFrame : 0;
    uint32_t write = __atomic_load_n(&ring->writeFrames, __ATOMIC_ACQUIRE);
    uint32_t read = __atomic_load_n(&ring->readFrames, __ATOMIC_ACQUIRE);
    // Log written/requested separately: when the ring is full the request is
    // entirely dropped, so a signed backlog makes that visible.
    VZPVMLog("[vz-pcm] produce frames=%u/%u bytes=%u write=%u read=%u "
             "backlog=%d pad=%d",
             writtenFrames, requestedFrames, length,
             (unsigned)write, (unsigned)read,
             (int)VZPCMSerialDelta(write, read),
             paddedSilence ? 1 : 0);
}

// Snapshot the backlog immediately after a write. Sampling from the HUD timer
// instead would often catch the ring just after a render drain and always show
// a nearly-empty buffer, which makes the numbers useless for judging latency
// or overflow.
- (void)publishDebugSnapshot:(VZPCMRing *)ring
{
    AVAudioFormat *format = _format;
    if (!format || format.sampleRate <= 0.0)
        return;
    uint32_t write = __atomic_load_n(&ring->writeFrames, __ATOMIC_ACQUIRE);
    uint32_t read = __atomic_load_n(&ring->readFrames, __ATOMIC_ACQUIRE);
    int32_t backlog = VZPCMSerialDelta(write, read);
    double frames = backlog > 0 ? (double)backlog : 0.0;
    self.debugQueuedMilliseconds = frames / format.sampleRate * 1000.0;
    self.debugBufferFillRatio = ring->capacityFrames
        ? frames / (double)ring->capacityFrames : 0.0;
}

// Playback depth traded against latency. The target is expressed in VzCore
// blocks rather than an absolute time, so the backlog setpoint is the same
// frame count at every sample rate. The producer writes one 4096-frame block at
// a time, so the backlog sawtooth peaks half a block above its mean. Aim the
// write-time peak at one block, and add the 10 ms prepad cushion so the trough
// stays at that cushion and the padding branch never fires in steady state.
- (double)targetFramesForCurrentRouteWithSampleRate:(double)sampleRate
{
    double blockSeconds = 4096.0 / sampleRate;
    return sampleRate * (blockSeconds / 2.0 + VZ_PCM_PREPAD_SECONDS);
}

#pragma mark - Engine lifecycle (stateQueue)

- (void)configureWithSetup:(const struct vz_pcm_setup *)setup
{
    if (self.streamConfigured || !self.running)
        return;

    AVAudioCommonFormat commonFormat = (AVAudioCommonFormat)0;
    if (setup->format_flags & VZPCMFormatFlagIsFloat)
        commonFormat = AVAudioPCMFormatFloat32;
    else if (setup->bits_per_channel == 16)
        commonFormat = AVAudioPCMFormatInt16;
    else if (setup->bits_per_channel == 32)
        commonFormat = AVAudioPCMFormatInt32;
    if (commonFormat == (AVAudioCommonFormat)0 ||
        setup->sample_rate < 1.0 || setup->channels_per_frame == 0)
        return;

    uint32_t channels = setup->channels_per_frame;
    uint32_t bits = setup->bits_per_channel;
    uint32_t sampleBytes = bits / 8;
    if (sampleBytes == 0)
        sampleBytes = 4;
    bool sourceInterleaved =
        (setup->format_flags & VZPCMFormatFlagIsNonInterleaved) == 0;
    bool sourceIsFloat = (setup->format_flags & VZPCMFormatFlagIsFloat) != 0;

    AVAudioFormat *format = [[AVAudioFormat alloc]
        initWithCommonFormat:AVAudioPCMFormatFloat32
                  sampleRate:setup->sample_rate
                    channels:(AVAudioChannelCount)channels
                 interleaved:NO];
    if (!format)
        return;

    // Ring: ~500 ms of planar float, rounded up to a power of two. The render
    // side never blocks, so a deep ring only costs latency, not correctness.
    VZPCMRing *ring = calloc(1, sizeof(VZPCMRing));
    if (!ring) {
        [format release];
        return;
    }
    uint32_t capacityFrames =
        VZPCMNextPowerOfTwo((uint32_t)(setup->sample_rate * 0.2));
    if (capacityFrames < 8192)
        capacityFrames = 8192;
    ring->samples = calloc((size_t)capacityFrames * channels, sizeof(float));
    if (!ring->samples) {
        free(ring);
        [format release];
        return;
    }
    ring->capacityFrames = capacityFrames;
    ring->mask = capacityFrames - 1;
    ring->channels = channels;
    ring->bitsPerChannel = bits;
    ring->wireBytesPerFrame = sampleBytes * channels;
    ring->sourceInterleaved = sourceInterleaved;
    ring->sourceIsFloat = sourceIsFloat;

    VZPCMRenderContext *context = calloc(1, sizeof(VZPCMRenderContext));
    if (!context) {
        free(ring->samples);
        free(ring);
        [format release];
        return;
    }
    context->ring = ring;
    context->channels = channels;
    context->mask = ring->mask;
    context->cursor = 0;
    context->cursorValid = false;
    context->lastRatioMicro = 1000000u;
    context->sampleRate = setup->sample_rate;
    context->targetFrames =
        [self targetFramesForCurrentRouteWithSampleRate:setup->sample_rate];
    // Integral controller. Updated every 8 s; the loop is first-order stable
    // for controlPeriod * ki < 2, and ki = 0.05 gives a decay of 0.5 per window
    // (~14 s time constant). The correction is clamped to +/-1%, far above any
    // realistic drift, so it never colors normal playback.
    context->ki = 0.015;
    context->maxCorrection = 0.001;
    context->controlPeriod = 3.0;
    context->windowError = 0.0;
    context->windowElapsed = 0.0;
    context->ratio = 1.0;
    context->ratioStep = (uint32_t)VZ_PCM_FRAC_ONE;
    context->warmupRemaining = 0.0;

    // Build the polyphase sinc table before the render thread can need it.
    VZPCMEnsureSincTable();

    self.ring = ring;
    self.renderContext = context;
    self.format = format;

    NSError *error = nil;
    AVAudioSession *session = AVAudioSession.sharedInstance;
    [session setCategory:VZPCMPlayerSessionCategory()
                    mode:AVAudioSessionModeDefault
                 options:VZPCMPlayerSessionOptions() error:&error];
    [session setPreferredSampleRate:setup->sample_rate error:&error];
    // A short hardware IO buffer keeps the render thread responsive, which is
    // the main latency lever on local outputs; iPadOS enlarges it as needed
    // for Bluetooth or when the requested value is unsupported.
    [session setPreferredIOBufferDuration:0.002 error:&error];
    [session setActive:YES error:&error];

    if (![self createEngineLocked:&error]) {
        printf("[VirtualMac] PCM hook engine start failed: %s\n",
               error.localizedDescription.UTF8String);
        [format release];
        self.ring = NULL;
        self.renderContext = NULL;
        free(ring->samples);
        free(ring);
        free(context);
        return;
    }

    self.streamConfigured = YES;
    [format release];

    NSNotificationCenter *center = NSNotificationCenter.defaultCenter;
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

    printf("[VirtualMac] PCM hook playing %.0f Hz %u ch (%s wire, planar "
           "engine, pull)\n",
           setup->sample_rate, channels,
           sourceInterleaved ? "interleaved" : "planar");
}

- (BOOL)createEngineLocked:(NSError **)error
{
    VZPCMRenderContext *context = self.renderContext;
    if (!context || !self.format)
        return NO;

    AVAudioSourceNodeRenderBlock renderBlock =
        ^OSStatus(BOOL *isSilence, const AudioTimeStamp *timestamp,
                  AVAudioFrameCount frameCount,
                  AudioBufferList *outputData) {
        (void)timestamp;
        if (isSilence)
            *isSilence = NO;
        if (!context || !context->ring || !context->ring->samples) {
            for (uint32_t b = 0; b < outputData->mNumberBuffers; ++b) {
                if (outputData->mBuffers[b].mData)
                    memset(outputData->mBuffers[b].mData, 0,
                           outputData->mBuffers[b].mDataByteSize);
            }
            if (isSilence)
                *isSilence = YES;
            return noErr;
        }
        VZPCMRenderFrames(context, frameCount, outputData, isSilence);
        return noErr;
    };

    AVAudioSourceNode *source = [[AVAudioSourceNode alloc]
        initWithFormat:self.format renderBlock:renderBlock];
    AVAudioEngine *engine = [[AVAudioEngine alloc] init];
    @try {
        [engine attachNode:source];
        [engine connect:source to:engine.mainMixerNode format:self.format];
        [engine prepare];
        if (![engine startAndReturnError:error]) {
            [source release];
            [engine release];
            return NO;
        }
    } @catch (NSException *exception) {
        if (error) {
            *error = VZPCMError(4, exception.reason
                ?: @"PCM engine setup threw an exception");
        }
        [source release];
        [engine release];
        return NO;
    }
    self.engine = engine;
    self.sourceNode = source;
    [source release];
    [engine release];
    return YES;
}

// Stops rendering but keeps the ring/context so a rebuild resumes without
// losing buffered audio.
- (void)stopEngineLocked
{
    if (self.engine)
        [self.engine stop];
    self.sourceNode = nil;
    self.engine = nil;
    self.streamConfigured = NO;
    self.rebuildPending = NO;
}

- (void)freeRingLocked
{
    if (self.renderContext) {
        free(self.renderContext);
        self.renderContext = NULL;
    }
    if (self.ring) {
        free(self.ring->samples);
        free(self.ring);
        self.ring = NULL;
    }
    self.format = nil;
}

#pragma mark - Device changes

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

// Route changes only stop the engine's I/O; the source node and its render
// block stay valid, so restart in place first and only rebuild as a fallback.
- (void)restartEngineLocked
{
    if (!self.streamConfigured || !self.format)
        return;

    AVAudioSession *session = AVAudioSession.sharedInstance;
    NSError *error = nil;
    [session setCategory:VZPCMPlayerSessionCategory()
                    mode:AVAudioSessionModeDefault
                 options:VZPCMPlayerSessionOptions() error:&error];
    [session setActive:YES error:&error];

    // The new route may need a different amount of slack (speaker vs A2DP).
    if (self.renderContext && self.format) {
        self.renderContext->targetFrames = [self
            targetFramesForCurrentRouteWithSampleRate:self.format.sampleRate];
    }

    if (self.engine) {
        if ([self.engine isRunning])
            return;
        // Engine is stopped here, so the render thread is not running and this
        // write is safe. Resume from the current producer edge.
        if (self.renderContext)
            self.renderContext->cursorValid = false;
        if ([self.engine startAndReturnError:&error]) {
            printf("[VirtualMac] PCM hook engine restarted\n");
            return;
        }
        printf("[VirtualMac] PCM hook engine restart failed: %s; rebuilding\n",
               error.localizedDescription.UTF8String);
        [self.engine stop];
        self.sourceNode = nil;
        self.engine = nil;
    }

    if (self.renderContext)
        self.renderContext->cursorValid = false;
    if ([self createEngineLocked:&error]) {
        printf("[VirtualMac] PCM hook engine rebuilt running=%d\n",
               self.engine.isRunning);
    } else {
        printf("[VirtualMac] PCM hook engine rebuild failed: %s\n",
               error.localizedDescription.UTF8String);
    }
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

#pragma mark - Debug HUD

// debugQueuedMilliseconds and debugBufferFillRatio are synthesized from the
// snapshots published by publishDebugSnapshot: after each ring write.

- (BOOL)playing
{
    return self.engine.isRunning;
}

- (float)debugPlaybackRate
{
    VZPCMRenderContext *context =
        __atomic_load_n(&_renderContext, __ATOMIC_ACQUIRE);
    if (!context)
        return 1.0f;
    return (float)__atomic_load_n(&context->lastRatioMicro, __ATOMIC_RELAXED) /
        1000000.0f;
}

@end
