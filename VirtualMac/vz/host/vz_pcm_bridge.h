#ifndef VZ_PCM_BRIDGE_H
#define VZ_PCM_BRIDGE_H

// Wire protocol between the VMM (producer) and the Virtual Mac app (player).
//
// The app hosts an AF_UNIX stream socket; the VMM connects to it when the PCM
// Hook setting is on. The VMM first sends one SETUP message describing the
// AudioQueue stream format, then a sequence of AUDIO messages carrying raw
// interleaved/planar PCM. All fields are host-endian because both endpoints run
// on the same device.

#include <stdint.h>

#define VZ_PCM_DEFAULT_SOCKET "/tmp/vz-pcm.sock"
// Input runs on its own socket, mirroring the output one but with the roles
// reversed: the app listens, the VMM connects, the VMM first sends SETUP_IN
// with the capture format it needs, then the app streams AUDIO_IN frames.
#define VZ_PCM_DEFAULT_INPUT_SOCKET "/tmp/vz-pcm-in.sock"
#define VZ_PCM_MAGIC 0x565a5043U
#define VZ_PCM_VERSION 1U
#define VZ_PCM_MAX_PAYLOAD (1U << 20)

enum vz_pcm_message_type {
    VZ_PCM_MESSAGE_SETUP = 1,
    VZ_PCM_MESSAGE_AUDIO = 2,
    // VMM -> app: the AudioQueue input format the guest backend wants. The app
    // configures its capture and replies with AUDIO_IN frames in this format.
    VZ_PCM_MESSAGE_SETUP_IN = 3,
    // App -> VMM: raw captured PCM in the format announced by SETUP_IN.
    VZ_PCM_MESSAGE_AUDIO_IN = 4,
};

struct vz_pcm_header {
    uint32_t magic;
    uint16_t version;
    uint16_t type;
    uint32_t payload_length;
};

struct vz_pcm_setup {
    double sample_rate;
    uint32_t format_id;
    uint32_t format_flags;
    uint32_t bytes_per_packet;
    uint32_t frames_per_packet;
    uint32_t bytes_per_frame;
    uint32_t channels_per_frame;
    uint32_t bits_per_channel;
};

#endif
