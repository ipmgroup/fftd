// libfft — FFTW-compatible C library for ICEZero FPGA
// Placeholder — will be implemented in stage 5

#ifndef LIBFFT_H
#define LIBFFT_H

#include <stdint.h>
#include <stddef.h>

typedef struct fft_handle fft_handle_t;

typedef struct {
    uint8_t  size;       // FFT size (log2): 5=32, 6=64, 7=128
    uint8_t  window;     // Window type: 0=none, 1=Hann
    uint16_t reserved;
} fft_config_t;

fft_handle_t* fft_init(int size);
int           fft_compute_forward(fft_handle_t *h, const float *in, float *out);
int           fft_compute_inverse(fft_handle_t *h, const float *in, float *out);
int           fft_get_config(fft_handle_t *h, fft_config_t *cfg);
void          fft_destroy(fft_handle_t *h);

#endif // LIBFFT_H
