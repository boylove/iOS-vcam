#ifndef IOSVCAM_AUDIO_BRIDGE_SHARED_H
#define IOSVCAM_AUDIO_BRIDGE_SHARED_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#define IVCAM_AB_SHARED_MAGIC 0x31424149u /* IAB1 */
#define IVCAM_AB_SHARED_VERSION 1u
#define IVCAM_AB_FRAME_MAGIC "IAF1"
#define IVCAM_AB_FRAME_MAGIC_SIZE 4u

#define IVCAM_AB_DEFAULT_HOST "127.10.10.10"
#define IVCAM_AB_DEFAULT_PORT 1936u
#define IVCAM_AB_DEFAULT_SAMPLE_RATE 48000u
#define IVCAM_AB_DEFAULT_CHANNELS 1u
#define IVCAM_AB_DEFAULT_FRAME_MS 20u
#define IVCAM_AB_BYTES_PER_SAMPLE 2u
#define IVCAM_AB_SAMPLE_FORMAT_S16LE 1u

#define IVCAM_AB_SHARED_DIR "/var/tmp"
#define IVCAM_AB_SHARED_PATH IVCAM_AB_SHARED_DIR "/iOSVCAMAudioBridgeSystem.shared.bin"
#define IVCAM_AB_RING_SECONDS 2u
#define IVCAM_AB_RING_BYTES \
    (IVCAM_AB_DEFAULT_SAMPLE_RATE * IVCAM_AB_DEFAULT_CHANNELS * \
     IVCAM_AB_BYTES_PER_SAMPLE * IVCAM_AB_RING_SECONDS)
#define IVCAM_AB_MAX_PAYLOAD_BYTES 65536u
#define IVCAM_AB_HELLO_MAX_BYTES 1024u

typedef enum IVCAMAudioBridgeDaemonState {
    IVCAM_AB_STATE_DISCONNECTED = 0,
    IVCAM_AB_STATE_CONNECTING = 1,
    IVCAM_AB_STATE_STREAMING = 2,
    IVCAM_AB_STATE_STALE = 3,
    IVCAM_AB_STATE_UNSUPPORTED = 4,
    IVCAM_AB_STATE_ERROR = 5,
} IVCAMAudioBridgeDaemonState;

typedef enum IVCAMAudioBridgeHookMode {
    IVCAM_AB_HOOK_PASSIVE = 0,
    IVCAM_AB_HOOK_REPLACE_ENABLED = 1,
} IVCAMAudioBridgeHookMode;

#pragma pack(push, 1)
typedef struct IVCAMAudioBridgeFrameHeader {
    char magic[4];
    uint32_t sequence;
    uint64_t pts_us;
    uint64_t duration_us;
    uint32_t payload_length;
} IVCAMAudioBridgeFrameHeader;
#pragma pack(pop)

typedef struct IVCAMAudioBridgeFormat {
    uint32_t sample_rate;
    uint32_t channels;
    uint32_t sample_format;
    uint32_t bytes_per_sample;
    uint32_t frame_ms;
    uint32_t reserved0;
} IVCAMAudioBridgeFormat;

typedef struct IVCAMAudioBridgeSharedState {
    uint32_t magic;
    uint32_t version;
    uint32_t header_size;
    uint32_t total_size;

    uint32_t state;
    uint32_t hook_mode;
    uint32_t ring_capacity_bytes;
    uint32_t ring_write_offset;
    uint32_t ring_valid_bytes;
    uint32_t reserved0;

    IVCAMAudioBridgeFormat format;

    uint64_t daemon_started_at_us;
    uint64_t updated_at_us;
    uint64_t last_frame_pts_us;
    uint64_t last_frame_duration_us;
    uint64_t ring_write_sequence;

    uint64_t connect_attempts;
    uint64_t connects;
    uint64_t disconnects;
    uint64_t packets_received;
    uint64_t frames_received;
    uint64_t bytes_received;
    uint64_t bad_frames;
    uint64_t overruns;
    uint64_t underruns;
    uint64_t stale_reads;
    uint64_t unsupported_formats;
    uint64_t render_calls;
    uint64_t input_render_seen;
    uint64_t replacement_count;

    uint64_t reserved_counters[16];
    uint8_t ring[IVCAM_AB_RING_BYTES];
} IVCAMAudioBridgeSharedState;

static inline size_t IVCAMAudioBridgeSharedSize(void) {
    return sizeof(IVCAMAudioBridgeSharedState);
}

#ifdef __cplusplus
}
#endif

#endif /* IOSVCAM_AUDIO_BRIDGE_SHARED_H */
