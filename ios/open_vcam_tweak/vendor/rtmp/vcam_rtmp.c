/*
 * vcam_rtmp.c - Minimal RTMP play client. See vcam_rtmp.h.
 *
 * Supports: simple handshake, chunk stream assembly (fmt 0-3 + extended
 * timestamps), inbound Set Chunk Size, window-ack replies, AMF0 command
 * encode/decode for connect/createStream/play. No TLS, no publish.
 */
#include "vcam_rtmp.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>
#include <unistd.h>
#include <errno.h>
#include <netdb.h>
#include <sys/socket.h>
#include <netinet/in.h>
#include <netinet/tcp.h>
#include <arpa/inet.h>

#define VCAM_RTMP_MAX_CSID       65600
#define VCAM_RTMP_DEFAULT_CHUNK  128
#define VCAM_RTMP_OUT_CHUNK      4096
#define VCAM_RTMP_MAX_MSG        (8 * 1024 * 1024) /* sanity cap per message */
#define VCAM_RTMP_ACK_WINDOW     2500000u

/* ------------------------------------------------------------------ */
/* Per-chunk-stream reassembly state.                                  */
/* ------------------------------------------------------------------ */
typedef struct {
    int      in_use;
    uint32_t timestamp;      /* absolute ts of current message */
    uint32_t delta;          /* last delta (for fmt 3 continuation) */
    uint32_t msg_length;     /* declared payload length */
    uint8_t  msg_type;
    uint32_t msg_stream_id;
    uint8_t *buf;            /* accumulation buffer, msg_length bytes */
    uint32_t have;           /* bytes accumulated so far */
} vcam_chunk_stream;

struct vcam_rtmp {
    char    *url;
    char     host[256];
    int      port;
    char     app[256];
    char     playpath[256];
    char     tcurl[512];

    int      fd;
    uint32_t in_chunk_size;
    uint32_t out_chunk_size;
    double   stream_id;
    uint32_t bytes_in;
    uint32_t last_ack;
    int      txn;

    vcam_chunk_stream *streams; /* indexed by csid */

    vcam_rtmp_log_cb log_cb;
    void            *log_ctx;
};

static void vcam_log(vcam_rtmp *r, const char *fmt, ...) {
    if (!r->log_cb) return;
    char msg[256];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(msg, sizeof(msg), fmt, ap);
    va_end(ap);
    r->log_cb(r->log_ctx, msg);
}

/* ------------------------------------------------------------------ */
/* URL parsing: rtmp://host[:port]/app/playpath                        */
/* ------------------------------------------------------------------ */
static int vcam_parse_url(vcam_rtmp *r, const char *url) {
    if (strncmp(url, "rtmp://", 7) != 0) return -1;
    const char *p = url + 7;
    const char *slash = strchr(p, '/');
    const char *hostend = slash ? slash : p + strlen(p);

    const char *colon = memchr(p, ':', (size_t)(hostend - p));
    size_t hostlen;
    if (colon) {
        hostlen = (size_t)(colon - p);
        r->port = atoi(colon + 1);
    } else {
        hostlen = (size_t)(hostend - p);
        r->port = 1935;
    }
    if (hostlen == 0 || hostlen >= sizeof(r->host)) return -1;
    memcpy(r->host, p, hostlen);
    r->host[hostlen] = '\0';
    if (r->port <= 0 || r->port > 65535) r->port = 1935;

    r->app[0] = '\0';
    r->playpath[0] = '\0';
    if (slash && *(slash + 1)) {
        const char *path = slash + 1;                /* "app/playpath..." */
        const char *sep = strchr(path, '/');
        if (sep) {
            size_t applen = (size_t)(sep - path);
            if (applen >= sizeof(r->app)) applen = sizeof(r->app) - 1;
            memcpy(r->app, path, applen);
            r->app[applen] = '\0';
            snprintf(r->playpath, sizeof(r->playpath), "%s", sep + 1);
        } else {
            snprintf(r->app, sizeof(r->app), "%s", path);
        }
    }

    snprintf(r->tcurl, sizeof(r->tcurl), "rtmp://%s:%d/%s",
             r->host, r->port, r->app);
    return 0;
}

/* ------------------------------------------------------------------ */
/* Socket helpers                                                      */
/* ------------------------------------------------------------------ */
static int vcam_readn(int fd, uint8_t *buf, size_t n, volatile int *stop) {
    size_t got = 0;
    while (got < n) {
        if (stop && *stop) return -2;
        ssize_t k = recv(fd, buf + got, n - got, 0);
        if (k == 0) return -1;                 /* peer closed */
        if (k < 0) {
            if (errno == EINTR) continue;
            return -1;
        }
        got += (size_t)k;
    }
    return 0;
}

static int vcam_writen(int fd, const uint8_t *buf, size_t n) {
    size_t sent = 0;
    while (sent < n) {
        ssize_t k = send(fd, buf + sent, n - sent, 0);
        if (k <= 0) {
            if (k < 0 && errno == EINTR) continue;
            return -1;
        }
        sent += (size_t)k;
    }
    return 0;
}

static int vcam_connect_tcp(vcam_rtmp *r) {
    char portstr[16];
    snprintf(portstr, sizeof(portstr), "%d", r->port);

    struct addrinfo hints, *res = NULL, *ai;
    memset(&hints, 0, sizeof(hints));
    hints.ai_family = AF_UNSPEC;
    hints.ai_socktype = SOCK_STREAM;

    if (getaddrinfo(r->host, portstr, &hints, &res) != 0 || !res) return -1;

    int fd = -1;
    for (ai = res; ai; ai = ai->ai_next) {
        fd = socket(ai->ai_family, ai->ai_socktype, ai->ai_protocol);
        if (fd < 0) continue;
        if (connect(fd, ai->ai_addr, ai->ai_addrlen) == 0) break;
        close(fd);
        fd = -1;
    }
    freeaddrinfo(res);
    if (fd < 0) return -1;

    int one = 1;
    setsockopt(fd, IPPROTO_TCP, TCP_NODELAY, &one, sizeof(one));
    r->fd = fd;
    return 0;
}

/* ------------------------------------------------------------------ */
/* Simple handshake                                                    */
/* ------------------------------------------------------------------ */
static int vcam_handshake(vcam_rtmp *r, volatile int *stop) {
    uint8_t c0c1[1 + 1536];
    c0c1[0] = 0x03;                    /* version */
    memset(c0c1 + 1, 0, 8);            /* time + zero */
    for (int i = 9; i < 1 + 1536; i++) c0c1[i] = (uint8_t)(rand() & 0xff);
    if (vcam_writen(r->fd, c0c1, sizeof(c0c1)) != 0) return -1;

    uint8_t s0[1];
    if (vcam_readn(r->fd, s0, 1, stop) != 0) return -1;
    if (s0[0] != 0x03) return -1;

    uint8_t s1[1536];
    if (vcam_readn(r->fd, s1, sizeof(s1), stop) != 0) return -1;

    /* C2 echoes S1. */
    if (vcam_writen(r->fd, s1, sizeof(s1)) != 0) return -1;

    uint8_t s2[1536];
    if (vcam_readn(r->fd, s2, sizeof(s2), stop) != 0) return -1;
    return 0;
}

/* ------------------------------------------------------------------ */
/* AMF0 encoding                                                       */
/* ------------------------------------------------------------------ */
static uint8_t *amf_num(uint8_t *p, double v) {
    *p++ = 0x00;
    uint64_t bits;
    memcpy(&bits, &v, 8);
    for (int i = 7; i >= 0; i--) *p++ = (uint8_t)(bits >> (i * 8));
    return p;
}
static uint8_t *amf_bool(uint8_t *p, int v) {
    *p++ = 0x01; *p++ = v ? 1 : 0; return p;
}
static uint8_t *amf_str(uint8_t *p, const char *s) {
    uint16_t n = (uint16_t)strlen(s);
    *p++ = 0x02; *p++ = (uint8_t)(n >> 8); *p++ = (uint8_t)(n & 0xff);
    memcpy(p, s, n); return p + n;
}
static uint8_t *amf_null(uint8_t *p) { *p++ = 0x05; return p; }
static uint8_t *amf_key(uint8_t *p, const char *s) {
    uint16_t n = (uint16_t)strlen(s);
    *p++ = (uint8_t)(n >> 8); *p++ = (uint8_t)(n & 0xff);
    memcpy(p, s, n); return p + n;
}
static uint8_t *amf_obj_end(uint8_t *p) {
    *p++ = 0x00; *p++ = 0x00; *p++ = 0x09; return p;
}

/* ------------------------------------------------------------------ */
/* Chunk sending (fmt 0 first chunk, fmt 3 continuation)               */
/* ------------------------------------------------------------------ */
static int vcam_send_message(vcam_rtmp *r, uint8_t csid, uint8_t msg_type,
                             uint32_t msg_stream_id,
                             const uint8_t *payload, uint32_t len) {
    uint8_t header[12];
    header[0] = (uint8_t)(0x00 | (csid & 0x3f));  /* fmt 0 */
    header[1] = header[2] = header[3] = 0;         /* timestamp 0 */
    header[4] = (uint8_t)(len >> 16);
    header[5] = (uint8_t)(len >> 8);
    header[6] = (uint8_t)(len);
    header[7] = msg_type;
    header[8]  = (uint8_t)(msg_stream_id);          /* LE */
    header[9]  = (uint8_t)(msg_stream_id >> 8);
    header[10] = (uint8_t)(msg_stream_id >> 16);
    header[11] = (uint8_t)(msg_stream_id >> 24);
    if (vcam_writen(r->fd, header, 12) != 0) return -1;

    uint32_t off = 0;
    uint32_t first = len < r->out_chunk_size ? len : r->out_chunk_size;
    if (first && vcam_writen(r->fd, payload, first) != 0) return -1;
    off = first;

    while (off < len) {
        uint8_t cont = (uint8_t)(0xC0 | (csid & 0x3f)); /* fmt 3 */
        if (vcam_writen(r->fd, &cont, 1) != 0) return -1;
        uint32_t n = (len - off < r->out_chunk_size) ? (len - off) : r->out_chunk_size;
        if (vcam_writen(r->fd, payload + off, n) != 0) return -1;
        off += n;
    }
    return 0;
}

static int vcam_send_set_chunk_size(vcam_rtmp *r, uint32_t size) {
    uint8_t p[4] = {
        (uint8_t)(size >> 24), (uint8_t)(size >> 16),
        (uint8_t)(size >> 8), (uint8_t)(size)
    };
    return vcam_send_message(r, 2, 0x01, 0, p, 4);
}

static int vcam_send_ack(vcam_rtmp *r, uint32_t seq) {
    uint8_t p[4] = {
        (uint8_t)(seq >> 24), (uint8_t)(seq >> 16),
        (uint8_t)(seq >> 8), (uint8_t)(seq)
    };
    return vcam_send_message(r, 2, 0x03, 0, p, 4);
}

static int vcam_send_connect(vcam_rtmp *r) {
    uint8_t buf[1024];
    uint8_t *p = buf;
    p = amf_str(p, "connect");
    p = amf_num(p, ++r->txn);
    *p++ = 0x03;                                  /* object begin */
    p = amf_key(p, "app");            p = amf_str(p, r->app);
    p = amf_key(p, "type");           p = amf_str(p, "nonprivate");
    p = amf_key(p, "flashVer");       p = amf_str(p, "LNX 9,0,124,2");
    p = amf_key(p, "tcUrl");          p = amf_str(p, r->tcurl);
    p = amf_key(p, "fpad");           p = amf_bool(p, 0);
    p = amf_key(p, "capabilities");   p = amf_num(p, 15);
    p = amf_key(p, "audioCodecs");    p = amf_num(p, 4071);
    p = amf_key(p, "videoCodecs");    p = amf_num(p, 252);
    p = amf_key(p, "videoFunction");  p = amf_num(p, 1);
    p = amf_key(p, "objectEncoding"); p = amf_num(p, 0);
    p = amf_obj_end(p);
    return vcam_send_message(r, 3, 0x14, 0, buf, (uint32_t)(p - buf));
}

static int vcam_send_create_stream(vcam_rtmp *r) {
    uint8_t buf[64];
    uint8_t *p = buf;
    p = amf_str(p, "createStream");
    p = amf_num(p, ++r->txn);
    p = amf_null(p);
    return vcam_send_message(r, 3, 0x14, 0, buf, (uint32_t)(p - buf));
}

static int vcam_send_play(vcam_rtmp *r) {
    uint8_t buf[512];
    uint8_t *p = buf;
    p = amf_str(p, "play");
    p = amf_num(p, 0);                            /* transaction id 0 */
    p = amf_null(p);
    p = amf_str(p, r->playpath);
    p = amf_num(p, -2000);                         /* live/recorded */
    /* Sent on chunk stream 8 with the media message stream id. */
    return vcam_send_message(r, 8, 0x14,
                             (uint32_t)r->stream_id, buf, (uint32_t)(p - buf));
}

/* ------------------------------------------------------------------ */
/* AMF0 decoding (only what we need to read _result)                   */
/* ------------------------------------------------------------------ */
static int amf_read_value(const uint8_t *p, const uint8_t *end,
                          double *num_out, const uint8_t **next);

static int amf_skip_object(const uint8_t *p, const uint8_t *end,
                           const uint8_t **next) {
    while (p + 2 <= end) {
        uint16_t klen = (uint16_t)((p[0] << 8) | p[1]);
        p += 2;
        if (klen == 0) {          /* end marker: 00 00 09 */
            if (p < end && *p == 0x09) p++;
            *next = p;
            return 0;
        }
        if (p + klen > end) return -1;
        p += klen;
        double dummy;
        if (amf_read_value(p, end, &dummy, &p) != 0) return -1;
    }
    return -1;
}

static int amf_read_value(const uint8_t *p, const uint8_t *end,
                          double *num_out, const uint8_t **next) {
    if (p >= end) return -1;
    uint8_t marker = *p++;
    switch (marker) {
        case 0x00: {                              /* number */
            if (p + 8 > end) return -1;
            uint64_t bits = 0;
            for (int i = 0; i < 8; i++) bits = (bits << 8) | p[i];
            double v; memcpy(&v, &bits, 8);
            if (num_out) *num_out = v;
            *next = p + 8;
            return 0;
        }
        case 0x01:                                /* boolean */
            if (p + 1 > end) return -1;
            *next = p + 1; return 0;
        case 0x02: {                              /* string */
            if (p + 2 > end) return -1;
            uint16_t n = (uint16_t)((p[0] << 8) | p[1]);
            if (p + 2 + n > end) return -1;
            *next = p + 2 + n; return 0;
        }
        case 0x03:                                /* object */
            return amf_skip_object(p, end, next);
        case 0x05:                                /* null */
        case 0x06:                                /* undefined */
            *next = p; return 0;
        case 0x08: {                              /* ecma array */
            if (p + 4 > end) return -1;
            return amf_skip_object(p + 4, end, next);
        }
        default:
            return -1;
    }
}

/* Extract the command name string (first AMF0 value). */
static int amf_command_name(const uint8_t *p, const uint8_t *end,
                            char *out, size_t outsz, const uint8_t **next) {
    if (p >= end || *p != 0x02) return -1;
    p++;
    if (p + 2 > end) return -1;
    uint16_t n = (uint16_t)((p[0] << 8) | p[1]);
    p += 2;
    if (p + n > end) return -1;
    size_t copy = n < outsz - 1 ? n : outsz - 1;
    memcpy(out, p, copy);
    out[copy] = '\0';
    *next = p + n;
    return 0;
}

/* ------------------------------------------------------------------ */
/* Message dispatch                                                    */
/* ------------------------------------------------------------------ */
static void vcam_handle_command(vcam_rtmp *r, const uint8_t *data, uint32_t len,
                                int *saw_create_result) {
    const uint8_t *p = data;
    const uint8_t *end = data + len;
    char name[64];
    const uint8_t *np;
    if (amf_command_name(p, end, name, sizeof(name), &np) != 0) return;
    p = np;

    if (strcmp(name, "_result") == 0) {
        /* skip transaction id */
        if (amf_read_value(p, end, NULL, &p) != 0) return;
        /* skip command object (null or object) */
        if (amf_read_value(p, end, NULL, &p) != 0) return;
        /* For createStream the 4th value is the stream id number. */
        double sid = 0;
        if (amf_read_value(p, end, &sid, &p) == 0 && sid > 0) {
            r->stream_id = sid;
            *saw_create_result = 1;
            vcam_log(r, "createStream _result stream_id=%d", (int)sid);
        }
    } else if (strcmp(name, "_error") == 0) {
        vcam_log(r, "server _error on command");
    } else if (strcmp(name, "onStatus") == 0) {
        vcam_log(r, "onStatus received");
    }
}

/* ------------------------------------------------------------------ */
/* Read one chunk; on message completion dispatch it.                  */
/* ------------------------------------------------------------------ */
static int vcam_read_chunk(vcam_rtmp *r, vcam_rtmp_media_cb cb, void *ctx,
                           volatile int *stop, int *saw_create_result,
                           int *play_ready) {
    uint8_t b0;
    if (vcam_readn(r->fd, &b0, 1, stop) != 0) return -1;
    uint8_t fmt = (uint8_t)(b0 >> 6);
    uint32_t csid = (uint32_t)(b0 & 0x3f);

    if (csid == 0) {
        uint8_t ext; if (vcam_readn(r->fd, &ext, 1, stop) != 0) return -1;
        csid = 64 + ext;
    } else if (csid == 1) {
        uint8_t ext[2]; if (vcam_readn(r->fd, ext, 2, stop) != 0) return -1;
        csid = 64 + ext[0] + (ext[1] << 8);
    }
    if (csid >= VCAM_RTMP_MAX_CSID) return -1;

    vcam_chunk_stream *cs = &r->streams[csid];

    uint32_t timestamp_field = 0;
    if (fmt <= 2) {
        uint8_t th[3];
        if (vcam_readn(r->fd, th, 3, stop) != 0) return -1;
        timestamp_field = (uint32_t)((th[0] << 16) | (th[1] << 8) | th[2]);
    }
    if (fmt <= 1) {
        uint8_t lh[4];
        if (vcam_readn(r->fd, lh, 3, stop) != 0) return -1;    /* length */
        cs->msg_length = (uint32_t)((lh[0] << 16) | (lh[1] << 8) | lh[2]);
        if (vcam_readn(r->fd, lh, 1, stop) != 0) return -1;    /* type */
        cs->msg_type = lh[0];
    }
    if (fmt == 0) {
        uint8_t sh[4];
        if (vcam_readn(r->fd, sh, 4, stop) != 0) return -1;    /* stream id LE */
        cs->msg_stream_id = (uint32_t)(sh[0] | (sh[1] << 8) |
                                       (sh[2] << 16) | (sh[3] << 24));
    }

    /* Extended timestamp. */
    if (fmt <= 2 && timestamp_field == 0xFFFFFF) {
        uint8_t eh[4];
        if (vcam_readn(r->fd, eh, 4, stop) != 0) return -1;
        timestamp_field = (uint32_t)((eh[0] << 24) | (eh[1] << 16) |
                                     (eh[2] << 8) | eh[3]);
    }

    /* Establish timestamp/delta on the first chunk of a message. */
    if (cs->have == 0) {
        if (fmt == 0) {
            cs->timestamp = timestamp_field;
            cs->delta = 0;
        } else if (fmt == 1 || fmt == 2) {
            cs->delta = timestamp_field;
            cs->timestamp += timestamp_field;
        } else { /* fmt 3 starting a new message: reuse last delta */
            cs->timestamp += cs->delta;
        }
    }

    if (cs->msg_length == 0 || cs->msg_length > VCAM_RTMP_MAX_MSG) return -1;

    if (!cs->buf) {
        cs->buf = (uint8_t *)malloc(cs->msg_length);
        if (!cs->buf) return -1;
        cs->have = 0;
    }

    uint32_t remaining = cs->msg_length - cs->have;
    uint32_t take = remaining < r->in_chunk_size ? remaining : r->in_chunk_size;
    if (vcam_readn(r->fd, cs->buf + cs->have, take, stop) != 0) return -1;
    cs->have += take;

    r->bytes_in += take;
    if (r->bytes_in - r->last_ack >= VCAM_RTMP_ACK_WINDOW) {
        vcam_send_ack(r, r->bytes_in);
        r->last_ack = r->bytes_in;
    }

    if (cs->have < cs->msg_length) return 0;   /* message not complete yet */

    /* Message complete. */
    uint8_t type = cs->msg_type;
    uint8_t *payload = cs->buf;
    uint32_t plen = cs->msg_length;
    uint32_t ts = cs->timestamp;

    if (type == 0x01) {                        /* Set Chunk Size */
        if (plen >= 4) {
            uint32_t sz = (uint32_t)((payload[0] << 24) | (payload[1] << 16) |
                                     (payload[2] << 8) | payload[3]);
            if (sz > 0 && sz <= VCAM_RTMP_MAX_MSG) r->in_chunk_size = sz;
        }
    } else if (type == 0x14) {                 /* AMF0 command */
        vcam_handle_command(r, payload, plen, saw_create_result);
    } else if (type == 0x08 || type == 0x09) { /* audio / video */
        if (*play_ready && cb) cb(ctx, type, ts, payload, plen);
    }
    /* types 3/4/5/6/18 etc: ignored */

    free(cs->buf);
    cs->buf = NULL;
    cs->have = 0;
    return 0;
}

/* ------------------------------------------------------------------ */
/* Public API                                                          */
/* ------------------------------------------------------------------ */
vcam_rtmp *vcam_rtmp_create(const char *url,
                            vcam_rtmp_log_cb log_cb, void *log_ctx) {
    if (!url) return NULL;
    vcam_rtmp *r = (vcam_rtmp *)calloc(1, sizeof(vcam_rtmp));
    if (!r) return NULL;
    r->url = strdup(url);
    r->fd = -1;
    r->in_chunk_size = VCAM_RTMP_DEFAULT_CHUNK;
    r->out_chunk_size = VCAM_RTMP_DEFAULT_CHUNK;
    r->stream_id = 1;
    r->txn = 0;
    r->log_cb = log_cb;
    r->log_ctx = log_ctx;
    r->streams = (vcam_chunk_stream *)calloc(VCAM_RTMP_MAX_CSID,
                                             sizeof(vcam_chunk_stream));
    if (!r->url || !r->streams || vcam_parse_url(r, url) != 0) {
        vcam_rtmp_destroy(r);
        return NULL;
    }
    return r;
}

int vcam_rtmp_run(vcam_rtmp *r, vcam_rtmp_media_cb cb, void *ctx,
                  volatile int *stop_flag) {
    if (!r) return -1;

    if (vcam_connect_tcp(r) != 0) { vcam_log(r, "tcp connect failed"); return -1; }
    if (vcam_handshake(r, stop_flag) != 0) { vcam_log(r, "handshake failed"); goto fail; }
    vcam_log(r, "handshake ok %s:%d app=%s play=%s", r->host, r->port, r->app, r->playpath);

    /* Raise our outbound chunk size, then connect. */
    if (vcam_send_set_chunk_size(r, VCAM_RTMP_OUT_CHUNK) != 0) goto fail;
    r->out_chunk_size = VCAM_RTMP_OUT_CHUNK;
    if (vcam_send_connect(r) != 0) goto fail;

    int saw_create_result = 0;
    int sent_create = 0;
    int play_ready = 0;

    /* Drive the command handshake, then stream media. */
    while (!(stop_flag && *stop_flag)) {
        if (vcam_read_chunk(r, cb, ctx, stop_flag,
                            &saw_create_result, &play_ready) != 0) {
            if (stop_flag && *stop_flag) { vcam_log(r, "stop requested"); goto stopped; }
            vcam_log(r, "read loop ended");
            goto fail;
        }

        if (!sent_create) {
            /* After connect, immediately request a stream. SRS is tolerant of
               pipelining createStream right after connect once we've read at
               least one server message. */
            if (vcam_send_create_stream(r) != 0) goto fail;
            sent_create = 1;
        } else if (saw_create_result && !play_ready) {
            if (vcam_send_play(r) != 0) goto fail;
            play_ready = 1;
            vcam_log(r, "play sent for stream %d", (int)r->stream_id);
        }
    }

stopped:
    if (r->fd >= 0) { close(r->fd); r->fd = -1; }
    return 0;
fail:
    if (r->fd >= 0) { close(r->fd); r->fd = -1; }
    return -1;
}

void vcam_rtmp_destroy(vcam_rtmp *r) {
    if (!r) return;
    if (r->fd >= 0) close(r->fd);
    if (r->streams) {
        for (uint32_t i = 0; i < VCAM_RTMP_MAX_CSID; i++) {
            if (r->streams[i].buf) free(r->streams[i].buf);
        }
        free(r->streams);
    }
    free(r->url);
    free(r);
}
