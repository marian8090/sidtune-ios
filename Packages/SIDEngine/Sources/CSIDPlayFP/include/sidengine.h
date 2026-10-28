// Plain C facade over libsidplayfp, so Swift can use the emulator without C++ interop.
#ifndef SIDENGINE_H
#define SIDENGINE_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct sid_engine sid_engine;

typedef enum { SID_EMU_RESIDFP = 0, SID_EMU_SIDLITE = 1 } sid_emulation;
typedef enum { SID_CHIP_6581 = 0, SID_CHIP_8580 = 1 } sid_chip_model;
typedef enum { SID_C64_PAL = 0, SID_C64_NTSC = 1 } sid_c64_model;

typedef struct {
    sid_emulation emulation;
    sid_chip_model sid_model;
    bool force_sid_model;
    sid_c64_model c64_model;
    bool force_c64_model;
    bool digi_boost;
} sid_config;

typedef struct {
    /// Subtune numbers are 1-based.
    unsigned songs;
    unsigned start_song;
    unsigned current_song;
    /// Chips the loaded tune actually uses.
    unsigned sid_chips;
    /// 0 unknown, 1 PAL, 2 NTSC, 3 any.
    int clock;
    char format[64];
    char md5[33];
    unsigned info_count;
} sid_tune_info;

sid_engine *sid_engine_create(uint32_t sample_rate);
void sid_engine_destroy(sid_engine *e);

/// The last error, valid until the next call on this engine.
const char *sid_engine_error(const sid_engine *e);

/// KERNAL and BASIC are 8192 bytes, CHARGEN 4096. Any may be NULL. Applies from the next load.
void sid_engine_set_roms(sid_engine *e, const uint8_t *kernal, const uint8_t *basic, const uint8_t *chargen);

/// Parses and loads a tune and starts `song` (1-based; 0 = the tune's default). The data is copied.
bool sid_engine_load(sid_engine *e, const uint8_t *data, uint32_t length, unsigned song, const sid_config *config);

/// Restarts the loaded tune at `song` (1-based; 0 = default).
bool sid_engine_select_song(sid_engine *e, unsigned song);

/// Applies new emulation settings. Restarts the current song from the beginning.
bool sid_engine_configure(sid_engine *e, const sid_config *config);

/// Renders exactly `frames` interleaved stereo frames into `out` (2 * frames samples). Returns frames written, or -1 on error.
int sid_engine_render(sid_engine *e, int16_t *out, int frames);

void sid_engine_mute(sid_engine *e, unsigned chip, unsigned voice, bool muted);

/// The last values written to a chip's 32 registers. False if the chip doesn't exist.
bool sid_engine_registers(sid_engine *e, unsigned chip, uint8_t out[32]);

bool sid_engine_tune_info(const sid_engine *e, sid_tune_info *out);
const char *sid_engine_info_string(const sid_engine *e, unsigned index);

/// Emulated time since the song started, in milliseconds.
uint32_t sid_engine_time_ms(const sid_engine *e);

#ifdef __cplusplus
}
#endif

#endif
