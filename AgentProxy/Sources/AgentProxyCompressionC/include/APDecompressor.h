#ifndef AP_DECOMPRESSOR_H
#define AP_DECOMPRESSOR_H
#include <stddef.h>
#include <stdint.h>
typedef struct APDecoder APDecoder;
/* 1=gzip, 2=zlib-wrapped deflate, 3=zstd. Single frame, no dictionaries.
 * Zstd window capped at 8 MiB before allocation. No raw-content logging. */
APDecoder *ap_decoder_create(int kind);
void ap_decoder_free(APDecoder *decoder);
/* in_size/out_size: capacity on entry, consumed/produced bytes on return.
 * 0=needs input/output, 1=complete, -1=sticky error. */
int ap_decoder_step(APDecoder *decoder, const uint8_t *input, size_t *in_size,
                    uint8_t *output, size_t *out_size);
int ap_decoder_complete(const APDecoder *decoder);
#endif
