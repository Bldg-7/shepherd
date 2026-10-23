#include "include/APDecompressor.h"
#include "vendor/zstd.h"
#include <zlib.h>
#include <stdlib.h>
#include <limits.h>

struct APDecoder {
    int kind, initialized, done, failed;
    z_stream z;
    ZSTD_DStream *zs;
};
void ap_decoder_free(APDecoder *d) {
    if (!d) return;
    if (d->zs) ZSTD_freeDStream(d->zs);
    if (d->initialized && d->kind != 3) inflateEnd(&d->z);
    free(d);
}
APDecoder *ap_decoder_create(int kind) {
    if (kind < 1 || kind > 3) return NULL;
    APDecoder *d = calloc(1, sizeof(*d));
    if (!d) return NULL;
    d->kind = kind;
    if (kind == 3) {
        d->zs = ZSTD_createDStream();
        if (!d->zs || ZSTD_isError(ZSTD_initDStream(d->zs)) ||
            ZSTD_isError(ZSTD_DCtx_setParameter(d->zs, ZSTD_d_windowLogMax, 23))) {
            ap_decoder_free(d); return NULL;
        }
    } else if (inflateInit2(&d->z, kind == 1 ? 31 : 15) != Z_OK) {
        ap_decoder_free(d); return NULL;
    }
    d->initialized = 1;
    return d;
}
int ap_decoder_step(APDecoder *d, const uint8_t *input, size_t *in_size,
                    uint8_t *output, size_t *out_size) {
    if (!d || !in_size || !out_size) return -1;
    size_t available = *in_size, capacity = *out_size;
    *in_size = 0; *out_size = 0;
    if (d->failed || !capacity || (available && !input) || !output) return -1;
    if (d->done) {
        if (available) { d->failed = 1; return -1; }
        return 1;
    }
    if (d->kind == 3) {
        ZSTD_inBuffer in = { input, available, 0 };
        ZSTD_outBuffer out = { output, capacity, 0 };
        size_t result = ZSTD_decompressStream(d->zs, &out, &in);
        if (ZSTD_isError(result)) { d->failed = 1; return -1; }
        *in_size = in.pos; *out_size = out.pos; d->done = result == 0;
    } else {
        if (available > UINT_MAX || capacity > UINT_MAX) { d->failed = 1; return -1; }
        d->z.next_in = (Bytef *)input; d->z.avail_in = (uInt)available;
        d->z.next_out = output; d->z.avail_out = (uInt)capacity;
        int result = inflate(&d->z, Z_NO_FLUSH);
        if (result != Z_OK && result != Z_BUF_ERROR && result != Z_STREAM_END) {
            d->failed = 1; return -1;
        }
        *in_size = available - d->z.avail_in; *out_size = capacity - d->z.avail_out;
        d->done = result == Z_STREAM_END;
        /* No caller-owned buffer pointers survive the synchronous step. */
        d->z.next_in = NULL; d->z.next_out = NULL;
    }
    if (d->done && *in_size != available) { d->failed = 1; return -1; }
    return d->done ? 1 : 0;
}
int ap_decoder_complete(const APDecoder *d) {
    return d && d->done && !d->failed;
}
