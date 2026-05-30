// FFTW compatibility header
// Maps FFTW plan types to libfft equivalents (future)

#ifndef FFTW_COMPAT_H
#define FFTW_COMPAT_H

#include "libfft.h"

// FFTW-compatible type aliases
#define fftw_plan      fft_handle_t*
#define fftw_complex   float[2]

// Planned wrappers (not yet implemented)
// fftw_plan fftw_plan_dft_1d(int n, fftw_complex *in, fftw_complex *out, int sign, unsigned flags);
// void      fftw_execute(const fftw_plan p);
// void      fftw_destroy_plan(fftw_plan p);

#endif
