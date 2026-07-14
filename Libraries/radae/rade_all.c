/*
 * rade_all.c - Unity build file for the RADE C library (V1 + V2).
 *
 * This file #includes all RADE C source files into a single compilation unit.
 * This approach ensures all symbols are compiled and linked into the app,
 * since Xcode's project tools may not always add files to the target's
 * "Compile Sources" build phase.
 *
 * The individual .c files exist on disk in the same directory but are NOT
 * added to the Xcode project's compile sources to avoid duplicate symbols.
 */

/* Neural network primitives - rade_nnet.c is compiled separately by Xcode
   as its own compilation unit, so we do NOT #include it here. */

/* Neural network weight data
   (V1 encoder ~24MB + decoder ~23MB, V2 encoder ~23MB + decoder ~37MB,
    V2 sync ~0.2MB) */
#include "rade_enc_data.c"
#include "rade_dec_data.c"
#include "rade_enc_v2_data.c"
#include "rade_dec_v2_data.c"
#include "rade_sync_data.c"

/* FFT library */
#include "kiss_fft.c"
#include "kiss_fftr.c"

/* DSP utilities */
#include "rade_dsp.c"

/* OFDM modems (V1 and V2) */
#include "rade_ofdm.c"
#include "rade_v2_ofdm.c"

/* Bandpass filter */
#include "rade_bpf.c"

/* Acquisition (V1 pilot detection) and V2 neural sync */
#include "rade_acq.c"
#include "rade_sync.c"

/* Encoders and decoders
   The generated encoder/decoder sources each define file-local helpers with
   colliding names (e.g. conv1_cond_init). In a unity build they collide, so
   rename each subsequent copy. */
#include "rade_enc.c"
#define conv1_cond_init dec_conv1_cond_init
#include "rade_dec.c"
#undef conv1_cond_init
#define conv1_cond_init enc_v2_conv1_cond_init
#include "rade_enc_v2.c"
#undef conv1_cond_init
#define conv1_cond_init dec_v2_conv1_cond_init
#include "rade_dec_v2.c"
#undef conv1_cond_init

/* Transmitters and receivers (V1 and V2) */
#include "rade_tx.c"
#include "rade_rx.c"
#include "rade_tx_v2.c"
#include "rade_rx_v2.c"

/* Top-level API (V1/V2 dispatch via RADE_MODE_V2) */
#include "rade_api.c"
