#include "../audio_bridge_common/AudioBridgeShared.h"

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <signal.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

#ifndef MAP_FAILED
#define MAP_FAILED ((void *)-1)
#endif

static volatile sig_atomic_t g_should_stop = 0;

typedef struct IVCAMDaemonConfig {
    const char *host;
    uint16_t port;
} IVCAMDaemonConfig;

static void IVCAMHandleSignal(int signo) {
    (void)signo;
    g_should_stop = 1;
}

static uint64_t IVCAMNowUS(void) {
    struct timespec ts;
    if (clock_gettime(CLOCK_MONOTONIC, &ts) != 0) {
        return 0;
    }
    return ((uint64_t)ts.tv_sec * 1000000ull) + ((uint64_t)ts.tv_nsec / 1000ull);
}

static void IVCAMLog(const char *message) {
    fprintf(stderr, "[iOSVCAMAudioBridgeDaemon] %s\n", message);
    fflush(stderr);
}

static void IVCAMLogErrno(const char *message) {
    fprintf(stderr, "[iOSVCAMAudioBridgeDaemon] %s errno=%d (%s)\n", message, errno, strerror(errno));
    fflush(stderr);
}

static void IVCAMSleepOneSecond(void) {
    struct timespec ts;
    ts.tv_sec = 1;
    ts.tv_nsec = 0;
    while (!g_should_stop && nanosleep(&ts, &ts) != 0 && errno == EINTR) {
    }
}

static uint64_t IVCAMAtomicAdd64(uint64_t *field, uint64_t amount) {
    return __atomic_add_fetch(field, amount, __ATOMIC_RELAXED);
}

static void IVCAMAtomicStore32(uint32_t *field, uint32_t value) {
    __atomic_store_n(field, value, __ATOMIC_RELEASE);
}

static void IVCAMAtomicStore64(uint64_t *field, uint64_t value) {
    __atomic_store_n(field, value, __ATOMIC_RELEASE);
}

static uint32_t IVCAMAtomicLoad32(uint32_t *field) {
    return __atomic_load_n(field, __ATOMIC_ACQUIRE);
}

static void IVCAMPublishState(IVCAMAudioBridgeSharedState *shared, uint32_t state) {
    IVCAMAtomicStore32(&shared->state, state);
    IVCAMAtomicStore64(&shared->updated_at_us, IVCAMNowUS());
}

static bool IVCAMEnsureSharedDir(void) {
    if (mkdir(IVCAM_AB_SHARED_DIR, 0755) == 0 || errno == EEXIST) {
        return true;
    }
    IVCAMLogErrno("failed to create shared directory");
    return false;
}

static IVCAMAudioBridgeSharedState *IVCAMOpenSharedState(void) {
    if (!IVCAMEnsureSharedDir()) {
        return NULL;
    }

    int fd = open(IVCAM_AB_SHARED_PATH, O_RDWR | O_CREAT, 0666);
    if (fd < 0) {
        IVCAMLogErrno("failed to open shared state");
        return NULL;
    }
    fchmod(fd, 0666);

    size_t size = IVCAMAudioBridgeSharedSize();
    if (ftruncate(fd, (off_t)size) != 0) {
        IVCAMLogErrno("failed to size shared state");
        close(fd);
        return NULL;
    }

    void *mapped = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
    close(fd);
    if (mapped == MAP_FAILED) {
        IVCAMLogErrno("failed to map shared state");
        return NULL;
    }

    IVCAMAudioBridgeSharedState *shared = (IVCAMAudioBridgeSharedState *)mapped;
    memset(shared, 0, size);
    shared->magic = IVCAM_AB_SHARED_MAGIC;
    shared->version = IVCAM_AB_SHARED_VERSION;
    shared->header_size = (uint32_t)offsetof(IVCAMAudioBridgeSharedState, ring);
    shared->total_size = (uint32_t)size;
    shared->state = IVCAM_AB_STATE_DISCONNECTED;
    shared->hook_mode = IVCAM_AB_HOOK_PASSIVE;
    shared->ring_capacity_bytes = IVCAM_AB_RING_BYTES;
    shared->format.sample_rate = IVCAM_AB_DEFAULT_SAMPLE_RATE;
    shared->format.channels = IVCAM_AB_DEFAULT_CHANNELS;
    shared->format.sample_format = IVCAM_AB_SAMPLE_FORMAT_S16LE;
    shared->format.bytes_per_sample = IVCAM_AB_BYTES_PER_SAMPLE;
    shared->format.frame_ms = IVCAM_AB_DEFAULT_FRAME_MS;
    shared->daemon_started_at_us = IVCAMNowUS();
    shared->updated_at_us = shared->daemon_started_at_us;
    IVCAMLog("AUDIO_DAEMON_SHARED_READY path=" IVCAM_AB_SHARED_PATH);
    return shared;
}

static uint32_t IVCAMParseHelloUInt(const char *hello, const char *key, uint32_t fallback) {
    if (!hello || !key) {
        return fallback;
    }

    char needle[64];
    snprintf(needle, sizeof(needle), "\"%s\":", key);
    const char *cursor = strstr(hello, needle);
    if (!cursor) {
        return fallback;
    }
    cursor += strlen(needle);
    while (*cursor == ' ' || *cursor == '\t') {
        cursor++;
    }

    char *end = NULL;
    unsigned long value = strtoul(cursor, &end, 10);
    if (end == cursor || value == 0 || value > UINT32_MAX) {
        return fallback;
    }
    return (uint32_t)value;
}

static void IVCAMApplyHello(IVCAMAudioBridgeSharedState *shared, const char *hello) {
    uint32_t sample_rate = IVCAMParseHelloUInt(hello, "sample_rate", IVCAM_AB_DEFAULT_SAMPLE_RATE);
    uint32_t channels = IVCAMParseHelloUInt(hello, "channels", IVCAM_AB_DEFAULT_CHANNELS);
    uint32_t frame_ms = IVCAMParseHelloUInt(hello, "frame_ms", IVCAM_AB_DEFAULT_FRAME_MS);

    if (!(channels == 1 || channels == 2)) {
        IVCAMAtomicAdd64(&shared->unsupported_formats, 1);
        channels = IVCAM_AB_DEFAULT_CHANNELS;
    }
    if (sample_rate == 0 || sample_rate > 192000) {
        IVCAMAtomicAdd64(&shared->unsupported_formats, 1);
        sample_rate = IVCAM_AB_DEFAULT_SAMPLE_RATE;
    }
    if (frame_ms == 0 || frame_ms > 100) {
        frame_ms = IVCAM_AB_DEFAULT_FRAME_MS;
    }

    IVCAMAtomicStore32(&shared->format.sample_rate, sample_rate);
    IVCAMAtomicStore32(&shared->format.channels, channels);
    IVCAMAtomicStore32(&shared->format.sample_format, IVCAM_AB_SAMPLE_FORMAT_S16LE);
    IVCAMAtomicStore32(&shared->format.bytes_per_sample, IVCAM_AB_BYTES_PER_SAMPLE);
    IVCAMAtomicStore32(&shared->format.frame_ms, frame_ms);
    IVCAMPublishState(shared, IVCAM_AB_STATE_STREAMING);
}

static bool IVCAMReadExact(int fd, void *buffer, size_t length) {
    uint8_t *cursor = (uint8_t *)buffer;
    size_t remaining = length;
    while (!g_should_stop && remaining > 0) {
        ssize_t n = recv(fd, cursor, remaining, 0);
        if (n <= 0) {
            return false;
        }
        cursor += (size_t)n;
        remaining -= (size_t)n;
    }
    return remaining == 0;
}

static bool IVCAMReadHelloLine(int fd, char *buffer, size_t capacity) {
    if (!buffer || capacity == 0) {
        return false;
    }
    size_t used = 0;
    while (!g_should_stop && used + 1 < capacity) {
        char c = 0;
        ssize_t n = recv(fd, &c, 1, 0);
        if (n <= 0) {
            return false;
        }
        buffer[used++] = c;
        if (c == '\n') {
            break;
        }
    }
    buffer[used] = '\0';
    return used > 0;
}

static int IVCAMConnectToBridge(const IVCAMDaemonConfig *config) {
    int fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) {
        return -1;
    }

    struct sockaddr_in addr;
    memset(&addr, 0, sizeof(addr));
    addr.sin_family = AF_INET;
    addr.sin_port = htons(config->port);
    if (inet_pton(AF_INET, config->host, &addr.sin_addr) != 1) {
        close(fd);
        errno = EINVAL;
        return -1;
    }

    if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static void IVCAMWriteRing(IVCAMAudioBridgeSharedState *shared,
                           const uint8_t *payload,
                           uint32_t payload_length,
                           const IVCAMAudioBridgeFrameHeader *header) {
    uint32_t capacity = IVCAMAtomicLoad32(&shared->ring_capacity_bytes);
    if (!payload || capacity == 0 || payload_length == 0 || payload_length > capacity) {
        IVCAMAtomicAdd64(&shared->unsupported_formats, 1);
        IVCAMPublishState(shared, IVCAM_AB_STATE_UNSUPPORTED);
        return;
    }

    uint32_t offset = IVCAMAtomicLoad32(&shared->ring_write_offset);
    uint32_t valid = IVCAMAtomicLoad32(&shared->ring_valid_bytes);
    if (offset >= capacity) {
        offset = 0;
    }
    if (valid > capacity) {
        valid = 0;
    }

    if (valid + payload_length > capacity) {
        IVCAMAtomicAdd64(&shared->overruns, 1);
        valid = capacity - payload_length;
    }

    uint32_t first = payload_length;
    if (offset + payload_length > capacity) {
        first = capacity - offset;
    }
    memcpy(shared->ring + offset, payload, first);
    if (first < payload_length) {
        memcpy(shared->ring, payload + first, payload_length - first);
    }

    uint32_t next_offset = (offset + payload_length) % capacity;
    uint32_t next_valid = valid + payload_length;
    IVCAMAtomicStore32(&shared->ring_write_offset, next_offset);
    IVCAMAtomicStore32(&shared->ring_valid_bytes, next_valid);
    IVCAMAtomicStore64(&shared->last_frame_pts_us, header->pts_us);
    IVCAMAtomicStore64(&shared->last_frame_duration_us, header->duration_us);
    IVCAMAtomicAdd64(&shared->packets_received, 1);
    IVCAMAtomicAdd64(&shared->bytes_received, payload_length);
    IVCAMAtomicAdd64(&shared->frames_received, 1);
    IVCAMAtomicAdd64(&shared->ring_write_sequence, 1);
    IVCAMPublishState(shared, IVCAM_AB_STATE_STREAMING);
}

static void IVCAMRunClient(IVCAMAudioBridgeSharedState *shared, const IVCAMDaemonConfig *config) {
    IVCAMAtomicAdd64(&shared->connect_attempts, 1);
    IVCAMPublishState(shared, IVCAM_AB_STATE_CONNECTING);

    int fd = IVCAMConnectToBridge(config);
    if (fd < 0) {
        IVCAMPublishState(shared, IVCAM_AB_STATE_DISCONNECTED);
        return;
    }

    IVCAMAtomicAdd64(&shared->connects, 1);
    IVCAMLog("AUDIO_DAEMON_LINK_READY");

    char hello[IVCAM_AB_HELLO_MAX_BYTES + 1];
    if (!IVCAMReadHelloLine(fd, hello, sizeof(hello))) {
        close(fd);
        IVCAMAtomicAdd64(&shared->disconnects, 1);
        IVCAMPublishState(shared, IVCAM_AB_STATE_DISCONNECTED);
        return;
    }
    IVCAMApplyHello(shared, hello);

    while (!g_should_stop) {
        IVCAMAudioBridgeFrameHeader header;
        if (!IVCAMReadExact(fd, &header, sizeof(header))) {
            break;
        }
        if (memcmp(header.magic, IVCAM_AB_FRAME_MAGIC, IVCAM_AB_FRAME_MAGIC_SIZE) != 0 ||
            header.payload_length == 0 ||
            header.payload_length > IVCAM_AB_MAX_PAYLOAD_BYTES) {
            IVCAMAtomicAdd64(&shared->bad_frames, 1);
            IVCAMPublishState(shared, IVCAM_AB_STATE_ERROR);
            break;
        }

        uint8_t *payload = (uint8_t *)malloc(header.payload_length);
        if (!payload) {
            IVCAMPublishState(shared, IVCAM_AB_STATE_ERROR);
            break;
        }
        bool ok = IVCAMReadExact(fd, payload, header.payload_length);
        if (ok) {
            IVCAMWriteRing(shared, payload, header.payload_length, &header);
        }
        free(payload);
        if (!ok) {
            break;
        }
    }

    close(fd);
    IVCAMAtomicAdd64(&shared->disconnects, 1);
    IVCAMPublishState(shared, IVCAM_AB_STATE_DISCONNECTED);
    IVCAMLog("AUDIO_DAEMON_LINK_CLOSED");
}

static void IVCAMPrintUsage(const char *argv0) {
    fprintf(stderr,
            "Usage: %s [--host 127.10.10.10] [--port 1936]\n"
            "Phase 1 daemon: receives IAF1 PCM and publishes passive shared state only.\n",
            argv0);
}

static bool IVCAMParseArgs(int argc, char **argv, IVCAMDaemonConfig *config) {
    config->host = IVCAM_AB_DEFAULT_HOST;
    config->port = (uint16_t)IVCAM_AB_DEFAULT_PORT;

    for (int i = 1; i < argc; i++) {
        if (strcmp(argv[i], "--help") == 0 || strcmp(argv[i], "-h") == 0) {
            IVCAMPrintUsage(argv[0]);
            return false;
        }
        if (strcmp(argv[i], "--host") == 0 && i + 1 < argc) {
            config->host = argv[++i];
            continue;
        }
        if (strcmp(argv[i], "--port") == 0 && i + 1 < argc) {
            unsigned long port = strtoul(argv[++i], NULL, 10);
            if (port == 0 || port > 65535) {
                IVCAMLog("invalid port");
                return false;
            }
            config->port = (uint16_t)port;
            continue;
        }
        IVCAMPrintUsage(argv[0]);
        return false;
    }
    return true;
}

int main(int argc, char **argv) {
    setvbuf(stdout, NULL, _IOLBF, 0);
    setvbuf(stderr, NULL, _IOLBF, 0);

    IVCAMDaemonConfig config;
    if (!IVCAMParseArgs(argc, argv, &config)) {
        return argc > 1 ? 1 : 0;
    }

    signal(SIGINT, IVCAMHandleSignal);
    signal(SIGTERM, IVCAMHandleSignal);

    IVCAMAudioBridgeSharedState *shared = IVCAMOpenSharedState();
    if (!shared) {
        return 1;
    }

    IVCAMLog("AUDIO_DAEMON_READY phase=1 replacement=off");
    while (!g_should_stop) {
        IVCAMRunClient(shared, &config);
        if (!g_should_stop) {
            IVCAMSleepOneSecond();
        }
    }

    IVCAMPublishState(shared, IVCAM_AB_STATE_STALE);
    munmap(shared, IVCAMAudioBridgeSharedSize());
    IVCAMLog("AUDIO_DAEMON_STOPPED");
    return 0;
}
