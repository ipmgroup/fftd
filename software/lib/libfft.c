// libfft — FFTW-compatible C library for ICEZero FPGA
// Placeholder implementation

#include "libfft.h"
#include <stdlib.h>
#include <stdio.h>

struct fft_handle {
    int size;
    // TODO: add SPI device handle, DMA buffers, etc.
};

fft_handle_t* fft_init(int size) {
    fft_handle_t *h = calloc(1, sizeof(fft_handle_t));
    if (!h) return NULL;
    h->size = size;
    fprintf(stderr, "[libfft] init: size=%d (placeholder)\n", size);
    return h;
}

int fft_compute_forward(fft_handle_t *h, const float *in, float *out) {
    (void)h; (void)in; (void)out;
    return -1; // not implemented
}

int fft_compute_inverse(fft_handle_t *h, const float *in, float *out) {
    (void)h; (void)in; (void)out;
    return -1; // not implemented
}

int fft_get_config(fft_handle_t *h, fft_config_t *cfg) {
    if (!h || !cfg) return -1;
    cfg->size = 6; // 64-point default
    cfg->window = 1; // Hann
    return 0;
}

void fft_destroy(fft_handle_t *h) {
    free(h);
}
