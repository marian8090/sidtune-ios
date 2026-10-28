#include "sidengine.h"

#include <cstring>
#include <memory>
#include <string>
#include <vector>

#include "sidplayfp/SidConfig.h"
#include "sidplayfp/SidInfo.h"
#include "sidplayfp/SidTune.h"
#include "sidplayfp/SidTuneInfo.h"
#include "sidplayfp/sidplayfp.h"
#include "builders/residfp-builder/residfp.h"
#include "builders/sidlite-builder/sidlite.h"

namespace {
// About 5 ms of C64 time per step, as in libsidplayfp's demo.
constexpr unsigned CYCLES_PER_STEP = 5000;
// libsidplayfp picks a random power-on delay by default (seeded from the clock). A fixed one makes a tune render the
// same samples every time, which the seek cache, exports and tests rely on.
constexpr uint_least16_t POWER_ON_DELAY = SidConfig::MAX_POWER_ON_DELAY / 2;
}

struct sid_engine {
    uint32_t sampleRate;
    sidplayfp player;
    std::unique_ptr<ReSIDfpBuilder> residfp { new ReSIDfpBuilder("SIDtune") };
    std::unique_ptr<SIDLiteBuilder> sidlite { new SIDLiteBuilder("SIDtune") };
    std::unique_ptr<SidTune> tune;
    std::vector<uint8_t> data;
    sid_config config {};
    std::vector<int16_t> mixBuffer;
    std::vector<int16_t> pending;
    size_t pendingPos = 0;
    std::vector<uint8_t> kernal, basic, chargen;
    std::string error;
    bool loaded = false;

    explicit sid_engine(uint32_t rate) : sampleRate(rate) {}

    bool fail(const char *message) {
        error = message ? message : "unknown error";
        return false;
    }

    bool start(unsigned song) {
        loaded = false;
        pending.clear();
        pendingPos = 0;
        if (!tune) return fail("no tune loaded");
        tune->selectSong(song);

        SidConfig cfg;
        cfg.frequency = sampleRate;
        cfg.samplingMethod = SidConfig::RESAMPLE_INTERPOLATE;
        cfg.sidEmulation = config.emulation == SID_EMU_SIDLITE ? static_cast<sidbuilder *>(sidlite.get()) : residfp.get();
        cfg.defaultSidModel = config.sid_model == SID_CHIP_8580 ? SidConfig::MOS8580 : SidConfig::MOS6581;
        cfg.forceSidModel = config.force_sid_model;
        cfg.defaultC64Model = config.c64_model == SID_C64_NTSC ? SidConfig::NTSC : SidConfig::PAL;
        cfg.forceC64Model = config.force_c64_model;
        cfg.digiBoost = config.digi_boost;
        cfg.powerOnDelay = POWER_ON_DELAY;

        player.setRoms(kernal.empty() ? nullptr : kernal.data(), basic.empty() ? nullptr : basic.data(),
                       chargen.empty() ? nullptr : chargen.data());
        if (!player.config(cfg)) return fail(player.error());
        if (!player.load(tune.get())) return fail(player.error());
        player.initMixer(true);
        mixBuffer.resize(player.getBufSize(CYCLES_PER_STEP) + 16);
        loaded = true;
        return true;
    }
};

static void copyRom(std::vector<uint8_t> &dst, const uint8_t *src, size_t size) {
    if (src) dst.assign(src, src + size);
    else dst.clear();
}

extern "C" {

sid_engine *sid_engine_create(uint32_t sample_rate) { return new sid_engine(sample_rate); }

void sid_engine_destroy(sid_engine *e) { delete e; }

const char *sid_engine_error(const sid_engine *e) { return e->error.c_str(); }

void sid_engine_set_roms(sid_engine *e, const uint8_t *kernal, const uint8_t *basic, const uint8_t *chargen) {
    copyRom(e->kernal, kernal, 8192);
    copyRom(e->basic, basic, 8192);
    copyRom(e->chargen, chargen, 4096);
}

bool sid_engine_load(sid_engine *e, const uint8_t *data, uint32_t length, unsigned song, const sid_config *config) {
    e->loaded = false;
    e->data.assign(data, data + length);
    e->tune.reset(new SidTune(e->data.data(), length));
    if (!e->tune->getStatus()) {
        const bool ok = e->fail(e->tune->statusString());
        e->tune.reset();
        return ok;
    }
    e->config = *config;
    return e->start(song);
}

bool sid_engine_select_song(sid_engine *e, unsigned song) { return e->start(song); }

bool sid_engine_configure(sid_engine *e, const sid_config *config) {
    e->config = *config;
    if (!e->tune) return true;
    return e->start(e->tune->getInfo()->currentSong());
}

int sid_engine_render(sid_engine *e, int16_t *out, int frames) {
    if (!e->loaded) {
        e->fail("no tune loaded");
        return -1;
    }
    const size_t wanted = static_cast<size_t>(frames) * 2;
    size_t written = 0;
    while (written < wanted) {
        const size_t available = e->pending.size() - e->pendingPos;
        if (available > 0) {
            const size_t n = std::min(available, wanted - written);
            std::memcpy(out + written, e->pending.data() + e->pendingPos, n * sizeof(int16_t));
            e->pendingPos += n;
            written += n;
            continue;
        }
        const int produced = e->player.play(CYCLES_PER_STEP);
        if (produced < 0) {
            e->fail(e->player.error());
            return -1;
        }
        const unsigned mixed = produced > 0 ? e->player.mix(e->mixBuffer.data(), produced) : 0;
        e->pending.assign(e->mixBuffer.begin(), e->mixBuffer.begin() + mixed);
        e->pendingPos = 0;
    }
    return frames;
}

void sid_engine_mute(sid_engine *e, unsigned chip, unsigned voice, bool muted) { e->player.mute(chip, voice, muted); }

bool sid_engine_registers(sid_engine *e, unsigned chip, uint8_t out[32]) { return e->player.getSidStatus(chip, out); }

bool sid_engine_tune_info(const sid_engine *e, sid_tune_info *out) {
    if (!e->tune) return false;
    const SidTuneInfo *info = e->tune->getInfo();
    std::memset(out, 0, sizeof(*out));
    out->songs = info->songs();
    out->start_song = info->startSong();
    out->current_song = info->currentSong();
    out->sid_chips = e->loaded ? e->player.installedSIDs() : static_cast<unsigned>(info->sidChips());
    switch (info->clockSpeed()) {
    case SidTuneInfo::CLOCK_PAL: out->clock = 1; break;
    case SidTuneInfo::CLOCK_NTSC: out->clock = 2; break;
    case SidTuneInfo::CLOCK_ANY: out->clock = 3; break;
    default: out->clock = 0; break;
    }
    std::strncpy(out->format, info->formatString(), sizeof(out->format) - 1);
    char md5[SidTune::MD5_LENGTH + 1] = {};
    if (const_cast<SidTune *>(e->tune.get())->createMD5New(md5)) std::strncpy(out->md5, md5, sizeof(out->md5) - 1);
    out->info_count = info->numberOfInfoStrings();
    return true;
}

const char *sid_engine_info_string(const sid_engine *e, unsigned index) {
    if (!e->tune) return "";
    const SidTuneInfo *info = e->tune->getInfo();
    return index < info->numberOfInfoStrings() ? info->infoString(index) : "";
}

uint32_t sid_engine_time_ms(const sid_engine *e) { return e->player.timeMs(); }

}
