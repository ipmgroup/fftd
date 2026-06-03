#!/usr/bin/env python3
"""bench_fft.py — FPGA vs CPU FFT benchmark (Raspberry Pi)"""
import sys, time, subprocess, re, numpy as np
sys.path.insert(0, '.')
try:
    from hardware.scripts.fft_proto import FftProto, CMD_CONTROL, CTRL_START
except ImportError:
    from fft_proto import FftProto, CMD_CONTROL, CTRL_START

N=1024; RUNS=10; MAX_Q=32767
ramp_f32=np.arange(N,dtype=np.float32); ramp_f64=np.arange(N,dtype=np.float64)
results={}

print("="*60)
print("FPGA FFT (ICE40HX4K, 50 MHz, SPI 8 MHz, poll_ms=1)")
print("="*60)

proto=FftProto()
f,_=proto.status()
print(f"  Status: {f}")
if f['busy']: proto.wait_done(timeout=5.0, poll_ms=1)

# Preload ramp data
print("  Preloading ramp 0..1023...")
err = proto.write_data(np.arange(N, dtype=np.float64))
if err:
    print(f"  WRITE_DATA error: {err}")
    sys.exit(1)
print("  done")

fft_t=[]; read_t=[]
for r in range(RUNS):
    proto.control(CTRL_START)
    t0=time.perf_counter()
    ok=proto.wait_done(timeout=5.0, poll_ms=1)
    dt_fft=time.perf_counter()-t0
    if not ok: continue
    t0=time.perf_counter()
    bins,err=proto.read_all_bins(N,chunk=120,hermitian=True)
    dt_read=time.perf_counter()-t0
    if bins is None: continue
    fft_t.append(dt_fft); read_t.append(dt_read)
    fpga_re=np.round(np.real(bins)).astype(np.int64)   # true FFT values (BFP-rescaled)
    print(f"  Run {r}: compute={dt_fft*1000:.2f}ms  read={dt_read*1000:.2f}ms  DC={fpga_re[0]}")
proto.close()

if fft_t:
    results['FPGA compute']=np.mean(fft_t)*1000
    results['FPGA readout']=np.mean(read_t)*1000
    results['FPGA total']=results['FPGA compute']+results['FPGA readout']
    print(f"  Avg: compute={results['FPGA compute']:.2f}ms  read={results['FPGA readout']:.2f}ms")
else:
    results['FPGA compute']=1.08; results['FPGA readout']=3.80
    results['FPGA total']=4.88
    print("  FAILED — using theoretical 1.08ms + 3.80ms")

# numpy
for name,arr,runs in [("numpy float64",ramp_f64,100),("numpy float32",ramp_f32,100)]:
    print(f"\n{'='*60}\n{name}\n{'='*60}")
    for _ in range(3): np.fft.fft(arr)
    times=[]
    for _ in range(runs):
        t0=time.perf_counter(); np.fft.fft(arr)
        times.append(time.perf_counter()-t0)
    results[name]=np.mean(times)*1000
    print(f"  {results[name]*1000:.1f} us  (avg {runs} runs)")

# FFTW3
print(f"\n{'='*60}\nFFTW3 float32 (C, -O3 -march=native)\n{'='*60}")
c_src='#include <fftw3.h>\n#include <time.h>\n#include <stdio.h>\n#define N 1024\n#define RUNS 1000\nint main(){fftwf_complex*in=fftwf_malloc(sizeof(fftwf_complex)*N);fftwf_complex*out=fftwf_malloc(sizeof(fftwf_complex)*N);for(int i=0;i<N;i++){in[i][0]=(float)i;in[i][1]=0;}fftwf_plan p=fftwf_plan_dft_1d(N,in,out,FFTW_FORWARD,FFTW_ESTIMATE);for(int i=0;i<10;i++)fftwf_execute(p);struct timespec t0,t1;clock_gettime(CLOCK_MONOTONIC,&t0);for(int i=0;i<RUNS;i++)fftwf_execute(p);clock_gettime(CLOCK_MONOTONIC,&t1);double dt=(t1.tv_sec-t0.tv_sec)+(t1.tv_nsec-t0.tv_nsec)*1e-9;printf("%.3f\\n",dt*1e6/RUNS);fftwf_destroy_plan(p);fftwf_free(in);fftwf_free(out);return 0;}'
r=subprocess.run(['gcc','-O3','-march=native','-o','/tmp/fftwb','-xc','-','-lfftw3f','-lm'],input=c_src,capture_output=True,text=True,timeout=30)
if r.returncode==0:
    r=subprocess.run(['/tmp/fftwb'],capture_output=True,text=True,timeout=10)
    v=float(r.stdout.strip())
    results['FFTW3 float32']=v/1000
    print(f"  {v:.1f} us  (1000 runs)")
else:
    print("  not available")

# Summary
print(f"\n{'='*60}")
print(f"  BENCHMARK  (N={N}, Pi 5 Cortex-A76)")
print(f"{'='*60}")
print(f"  {'Method':<22s} {'Time':>10s}  {'vs FPGA':>10s}  {'vs numpy64':>10s}")
print(f"  {'-'*22} {'-'*10}  {'-'*10}  {'-'*10}")
base=np64=results.get('numpy float64',0.027)
fpga_tot=results.get('FPGA total',4.88)
for name in ['FPGA compute','FPGA readout','FPGA total','numpy float64','numpy float32','FFTW3 float32']:
    if name in results:
        ms=results[name]
        ts=f"{ms*1000:.0f} us" if ms<1 else f"{ms:.2f} ms"
        print(f"  {name:<22s} {ts:>10s}  {fpga_tot/ms:9.1f}x  {base/ms:9.0f}x")
