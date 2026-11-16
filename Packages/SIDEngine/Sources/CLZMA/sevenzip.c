// Streaming 7z extraction on top of the LZMA SDK. The SDK's own SzArEx_Extract unpacks a whole solid block into one buffer
// (355 MB for HVSC) and doesn't accept the two-coder BCJ2 layout HVSC's archive uses, so the SDK only parses the header here
// and each block is decoded through a chain of pull stages instead.

#include "sevenzip.h"

#include <errno.h>
#include <fcntl.h>
#include <limits.h>
#include <pthread.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/stat.h>
#include <unistd.h>

#include "7z.h"
#include "7zCrc.h"
#include "Bcj2.h"
#include "CpuArch.h"
#include "Lzma2Dec.h"
#include "LzmaDec.h"
#include "Ppmd7.h"

#define METHOD_COPY 0
#define METHOD_LZMA2 0x21
#define METHOD_LZMA 0x30101
#define METHOD_PPMD 0x30401
#define METHOD_BCJ2 0x303011B

#define IO_BUF (1 << 16)
#define MAP_THRESHOLD ((size_t)16 << 20)
#define MAX_MAPS 8
// BCJ2's call, jump and range-coder streams are read whole. They are small next to the main stream (67 KB for HVSC).
#define MAX_SIDE_STREAM ((size_t)256 << 20)

// MARK: Allocation

typedef struct {
    ISzAlloc vt;
    char temp_dir[PATH_MAX];
    struct { void *ptr; size_t size; int fd; } maps[MAX_MAPS];
} big_alloc;

static void *alloc_small(ISzAllocPtr p, size_t size) { (void)p; return size ? malloc(size) : NULL; }
static void free_small(ISzAllocPtr p, void *address) { (void)p; free(address); }
static const ISzAlloc small_alloc = { alloc_small, free_small };

// Large blocks (LZMA dictionaries, the PPMd model) live in a shared mapping of an unlinked temp file. The kernel can write those
// pages back to disk under pressure, so they don't count as dirty memory the way 340 MiB of malloc would.
static void *alloc_big(ISzAllocPtr p, size_t size) {
    big_alloc *a = Z7_CONTAINER_FROM_VTBL(p, big_alloc, vt);
    if (size == 0) return NULL;
    if (size >= MAP_THRESHOLD && a->temp_dir[0]) {
        for (int i = 0; i < MAX_MAPS; i++) {
            if (a->maps[i].ptr) continue;
            char path[PATH_MAX];
            snprintf(path, sizeof path, "%s/sidtune-7z-XXXXXX", a->temp_dir);
            int fd = mkstemp(path);
            if (fd < 0) break;
            unlink(path);
            if (ftruncate(fd, (off_t)size) != 0) { close(fd); break; }
            void *ptr = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0);
            if (ptr == MAP_FAILED) { close(fd); break; }
            a->maps[i].ptr = ptr;
            a->maps[i].size = size;
            a->maps[i].fd = fd;
            return ptr;
        }
    }
    return malloc(size);
}

static void free_big(ISzAllocPtr p, void *address) {
    big_alloc *a = Z7_CONTAINER_FROM_VTBL(p, big_alloc, vt);
    if (!address) return;
    for (int i = 0; i < MAX_MAPS; i++) {
        if (a->maps[i].ptr != address) continue;
        munmap(address, a->maps[i].size);
        close(a->maps[i].fd);
        a->maps[i].ptr = NULL;
        return;
    }
    free(address);
}

// MARK: Archive

typedef struct {
    ISeekInStream vt;
    int fd;
    Int64 pos;
} file_in;

struct sz_archive {
    CSzArEx db;
    int fd;
    file_in in;
    CLookToRead2 look;
    big_alloc big;
    char error[256];
};

static void set_error(sz_archive *a, const char *format, ...) {
    if (a->error[0]) return; // keep the first, most specific message
    va_list args;
    va_start(args, format);
    vsnprintf(a->error, sizeof a->error, format, args);
    va_end(args);
}

static const char *describe(SRes res) {
    switch (res) {
    case SZ_ERROR_DATA: return "the archive is damaged";
    case SZ_ERROR_MEM: return "not enough memory";
    case SZ_ERROR_CRC: return "a checksum doesn't match, so the archive is damaged";
    case SZ_ERROR_UNSUPPORTED: return "the archive uses a feature SIDtune can't read";
    case SZ_ERROR_INPUT_EOF: return "the archive is incomplete";
    case SZ_ERROR_NO_ARCHIVE: return "it isn't a 7z archive";
    case SZ_ERROR_ARCHIVE: return "the archive's header is damaged";
    case SZ_ERROR_READ: return "the file couldn't be read";
    default: return "the archive couldn't be read";
    }
}

static SRes file_read(ISeekInStreamPtr p, void *buf, size_t *size) {
    file_in *f = Z7_CONTAINER_FROM_VTBL(p, file_in, vt);
    if (*size == 0) return SZ_OK;
    ssize_t n = pread(f->fd, buf, *size, f->pos);
    if (n < 0) { *size = 0; return SZ_ERROR_READ; }
    *size = (size_t)n;
    f->pos += n;
    return SZ_OK;
}

static SRes file_seek(ISeekInStreamPtr p, Int64 *pos, ESzSeek origin) {
    file_in *f = Z7_CONTAINER_FROM_VTBL(p, file_in, vt);
    Int64 base = 0;
    if (origin == SZ_SEEK_CUR) base = f->pos;
    else if (origin == SZ_SEEK_END) {
        struct stat st;
        if (fstat(f->fd, &st) != 0) return SZ_ERROR_READ;
        base = st.st_size;
    }
    f->pos = base + *pos;
    *pos = f->pos;
    return SZ_OK;
}

static pthread_once_t crc_once = PTHREAD_ONCE_INIT;
static void make_crc_table(void) { CrcGenerateTable(); }

sz_archive *sz_open(const char *path, const char *temp_dir, char *error, size_t error_size) {
    pthread_once(&crc_once, make_crc_table);
    sz_archive *a = calloc(1, sizeof *a);
    if (!a) { snprintf(error, error_size, "not enough memory"); return NULL; }
    a->big.vt.Alloc = alloc_big;
    a->big.vt.Free = free_big;
    if (temp_dir) snprintf(a->big.temp_dir, sizeof a->big.temp_dir, "%s", temp_dir);
    a->fd = open(path, O_RDONLY);
    if (a->fd < 0) {
        snprintf(error, error_size, "%s", strerror(errno));
        free(a);
        return NULL;
    }
    a->in.vt.Read = file_read;
    a->in.vt.Seek = file_seek;
    a->in.fd = a->fd;
    LookToRead2_CreateVTable(&a->look, False);
    a->look.buf = malloc(IO_BUF);
    a->look.bufSize = IO_BUF;
    a->look.realStream = &a->in.vt;
    LookToRead2_INIT(&a->look)
    SzArEx_Init(&a->db);
    SRes res = a->look.buf ? SzArEx_Open(&a->db, &a->look.vt, &small_alloc, &small_alloc) : SZ_ERROR_MEM;
    if (res != SZ_OK) {
        snprintf(error, error_size, "%s", describe(res));
        sz_close(a);
        return NULL;
    }
    return a;
}

void sz_close(sz_archive *a) {
    if (!a) return;
    SzArEx_Free(&a->db, &small_alloc);
    free(a->look.buf);
    if (a->fd >= 0) close(a->fd);
    free(a);
}

uint32_t sz_count(const sz_archive *a) { return a->db.NumFiles; }
bool sz_is_dir(const sz_archive *a, uint32_t i) { return SzArEx_IsDir(&a->db, i); }
uint64_t sz_size(const sz_archive *a, uint32_t i) { return SzArEx_GetFileSize(&a->db, i); }

size_t sz_name(const sz_archive *a, uint32_t index, char *buffer, size_t size) {
    size_t units = SzArEx_GetFileNameUtf16(&a->db, index, NULL);
    UInt16 stack[512];
    UInt16 *name = units <= 512 ? stack : malloc(units * sizeof(UInt16));
    if (!name) return 0;
    SzArEx_GetFileNameUtf16(&a->db, index, name);
    size_t out = 0;
    for (size_t i = 0; i + 1 < units; i++) {
        uint32_t c = name[i];
        if (c >= 0xD800 && c < 0xDC00 && i + 2 < units && name[i + 1] >= 0xDC00 && name[i + 1] < 0xE000) {
            c = 0x10000 + ((c - 0xD800) << 10) + (name[++i] - 0xDC00);
        }
        uint8_t bytes[4];
        size_t n;
        if (c < 0x80) { bytes[0] = (uint8_t)c; n = 1; }
        else if (c < 0x800) { bytes[0] = 0xC0 | (c >> 6); bytes[1] = 0x80 | (c & 0x3F); n = 2; }
        else if (c < 0x10000) { bytes[0] = 0xE0 | (c >> 12); bytes[1] = 0x80 | ((c >> 6) & 0x3F); bytes[2] = 0x80 | (c & 0x3F); n = 3; }
        else { bytes[0] = 0xF0 | (c >> 18); bytes[1] = 0x80 | ((c >> 12) & 0x3F); bytes[2] = 0x80 | ((c >> 6) & 0x3F); bytes[3] = 0x80 | (c & 0x3F); n = 4; }
        for (size_t k = 0; k < n; k++, out++) if (out + 1 < size) buffer[out] = (char)bytes[k];
    }
    if (size) buffer[out < size ? out : size - 1] = 0;
    if (name != stack) free(name);
    return out + 1 <= size ? out : out + 1;
}

// MARK: Stages
//
// Each coder in a block is a stage that pulls bytes from its inputs. read() returns the number of bytes written (0 at the
// end of the coder's output) or -1 after calling set_error.

typedef struct stage stage;
struct stage {
    ptrdiff_t (*read)(stage *s, uint8_t *buf, size_t size);
    void (*destroy)(stage *s);
    sz_archive *archive;
};

static void stage_free(stage *s) { if (s) s->destroy(s); }

static ptrdiff_t read_full(stage *s, uint8_t *buf, size_t size) {
    size_t done = 0;
    while (done < size) {
        ptrdiff_t n = s->read(s, buf + done, size - done);
        if (n < 0) return -1;
        if (n == 0) break;
        done += (size_t)n;
    }
    return (ptrdiff_t)done;
}

typedef struct {
    stage base;
    UInt64 pos, end;
    size_t at, len;
    uint8_t buf[IO_BUF];
} pack_stage;

static ptrdiff_t pack_read(stage *s, uint8_t *buf, size_t size) {
    pack_stage *p = (pack_stage *)s;
    if (p->at == p->len) {
        UInt64 left = p->end - p->pos;
        if (left == 0) return 0;
        size_t want = left < IO_BUF ? (size_t)left : IO_BUF;
        ssize_t n = pread(s->archive->fd, p->buf, want, (off_t)p->pos);
        if (n <= 0) { set_error(s->archive, "the archive is incomplete"); return -1; }
        p->pos += (UInt64)n;
        p->at = 0;
        p->len = (size_t)n;
    }
    size_t n = p->len - p->at < size ? p->len - p->at : size;
    memcpy(buf, p->buf + p->at, n);
    p->at += n;
    return (ptrdiff_t)n;
}

static void plain_destroy(stage *s) { free(s); }

static stage *pack_new(sz_archive *a, UInt64 start, UInt64 size) {
    pack_stage *p = calloc(1, sizeof *p);
    if (!p) { set_error(a, "not enough memory"); return NULL; }
    p->base = (stage){ pack_read, plain_destroy, a };
    p->pos = start;
    p->end = start + size;
    return &p->base;
}

typedef struct {
    stage base;
    stage *in;
    UInt64 left;
} copy_stage;

static ptrdiff_t copy_read(stage *s, uint8_t *buf, size_t size) {
    copy_stage *c = (copy_stage *)s;
    if (c->left == 0) return 0;
    if (size > c->left) size = (size_t)c->left;
    ptrdiff_t n = c->in->read(c->in, buf, size);
    if (n == 0) { set_error(s->archive, "the archive is incomplete"); return -1; }
    if (n > 0) c->left -= (UInt64)n;
    return n;
}

static void copy_destroy(stage *s) { stage_free(((copy_stage *)s)->in); free(s); }

// LZMA and LZMA2 share the dictionary handling; LZMA2 wraps a CLzmaDec.
typedef struct {
    stage base;
    stage *in;
    bool lzma2;
    CLzmaDec lzma;
    CLzma2Dec lzma2dec;
    Byte *dic;
    SizeT dic_size;
    SizeT read_pos;
    UInt64 produced, out_size;
    size_t in_at, in_len;
    bool in_end;
    uint8_t in_buf[IO_BUF];
} lzma_stage;

static CLzmaDec *lzma_dec(lzma_stage *l) { return l->lzma2 ? &l->lzma2dec.decoder : &l->lzma; }

static ptrdiff_t lzma_read(stage *s, uint8_t *buf, size_t size) {
    lzma_stage *l = (lzma_stage *)s;
    CLzmaDec *d = lzma_dec(l);
    for (;;) {
        if (l->read_pos < d->dicPos) {
            size_t n = d->dicPos - l->read_pos < size ? d->dicPos - l->read_pos : size;
            memcpy(buf, d->dic + l->read_pos, n);
            l->read_pos += n;
            return (ptrdiff_t)n;
        }
        if (l->produced == l->out_size) return 0;
        if (d->dicPos == d->dicBufSize) { d->dicPos = 0; l->read_pos = 0; }
        if (l->in_at == l->in_len && !l->in_end) {
            ptrdiff_t n = l->in->read(l->in, l->in_buf, IO_BUF);
            if (n < 0) return -1;
            l->in_at = 0;
            l->in_len = (size_t)n;
            l->in_end = n == 0;
        }
        UInt64 left = l->out_size - l->produced;
        SizeT room = d->dicBufSize - d->dicPos;
        SizeT limit = d->dicPos + (left < room ? (SizeT)left : room);
        ELzmaFinishMode finish = left <= room ? LZMA_FINISH_END : LZMA_FINISH_ANY;
        SizeT in_size = l->in_len - l->in_at;
        SizeT before = d->dicPos;
        ELzmaStatus status;
        SRes res = l->lzma2
            ? Lzma2Dec_DecodeToDic(&l->lzma2dec, limit, l->in_buf + l->in_at, &in_size, finish, &status)
            : LzmaDec_DecodeToDic(&l->lzma, limit, l->in_buf + l->in_at, &in_size, finish, &status);
        l->in_at += in_size;
        l->produced += d->dicPos - before;
        if (res != SZ_OK) { set_error(s->archive, "%s", describe(res)); return -1; }
        if (d->dicPos == before && in_size == 0 && (l->in_end || status == LZMA_STATUS_FINISHED_WITH_MARK)) {
            set_error(s->archive, "the archive is incomplete");
            return -1;
        }
    }
}

static void lzma_destroy(stage *s) {
    lzma_stage *l = (lzma_stage *)s;
    LzmaDec_FreeProbs(lzma_dec(l), &small_alloc);
    ISzAlloc_Free(&s->archive->big.vt, l->dic);
    stage_free(l->in);
    free(l);
}

static stage *lzma_new(sz_archive *a, stage *in, bool lzma2, const Byte *props, unsigned props_size, UInt64 out_size) {
    UInt32 dict;
    if (lzma2) {
        if (props_size != 1 || props[0] > 40) { set_error(a, "the archive uses a feature SIDtune can't read"); return NULL; }
        dict = props[0] == 40 ? 0xFFFFFFFF : (UInt32)(2 | (props[0] & 1)) << (props[0] / 2 + 11);
    } else {
        if (props_size != 5) { set_error(a, "the archive uses a feature SIDtune can't read"); return NULL; }
        dict = GetUi32(props + 1);
    }
    lzma_stage *l = calloc(1, sizeof *l);
    if (!l) { set_error(a, "not enough memory"); return NULL; }
    l->base = (stage){ lzma_read, lzma_destroy, a };
    l->in = in;
    l->lzma2 = lzma2;
    l->out_size = out_size;
    LzmaDec_CONSTRUCT(&l->lzma)
    Lzma2Dec_CONSTRUCT(&l->lzma2dec)
    // The dictionary only needs to cover the output, which is smaller than the declared window for small archives.
    UInt64 want = out_size < dict ? out_size : dict;
    l->dic_size = want ? (SizeT)want : 1;
    l->dic = ISzAlloc_Alloc(&a->big.vt, l->dic_size);
    SRes res = !l->dic ? SZ_ERROR_MEM
        : lzma2 ? Lzma2Dec_AllocateProbs(&l->lzma2dec, props[0], &small_alloc)
                : LzmaDec_AllocateProbs(&l->lzma, props, props_size, &small_alloc);
    if (res != SZ_OK) {
        set_error(a, "%s", describe(res));
        l->in = NULL;
        lzma_destroy(&l->base);
        return NULL;
    }
    CLzmaDec *d = lzma_dec(l);
    d->dic = l->dic;
    d->dicBufSize = l->dic_size;
    if (lzma2) Lzma2Dec_Init(&l->lzma2dec); else LzmaDec_Init(&l->lzma);
    return &l->base;
}

typedef struct {
    IByteIn vt;
    stage *in;
    size_t at, len;
    bool end;
    uint8_t buf[IO_BUF];
} byte_in;

static Byte byte_in_read(IByteInPtr p) {
    byte_in *b = Z7_CONTAINER_FROM_VTBL(p, byte_in, vt);
    if (b->at == b->len) {
        ptrdiff_t n = b->end ? 0 : b->in->read(b->in, b->buf, IO_BUF);
        if (n <= 0) { b->end = true; return 0; }
        b->at = 0;
        b->len = (size_t)n;
    }
    return b->buf[b->at++];
}

typedef struct {
    stage base;
    CPpmd7 ppmd;
    bool allocated;
    byte_in bytes;
    UInt64 left;
} ppmd_stage;

static ptrdiff_t ppmd_read(stage *s, uint8_t *buf, size_t size) {
    ppmd_stage *p = (ppmd_stage *)s;
    if (p->left == 0) return 0;
    if (size > p->left) size = (size_t)p->left;
    for (size_t i = 0; i < size; i++) {
        int sym = Ppmd7z_DecodeSymbol(&p->ppmd);
        if (sym < 0 || p->bytes.end) { set_error(s->archive, "the archive is damaged"); return -1; }
        buf[i] = (uint8_t)sym;
    }
    p->left -= size;
    if (p->left == 0 && !Ppmd7z_RangeDec_IsFinishedOK(&p->ppmd.rc.dec)) {
        set_error(s->archive, "the archive is damaged");
        return -1;
    }
    return (ptrdiff_t)size;
}

static void ppmd_destroy(stage *s) {
    ppmd_stage *p = (ppmd_stage *)s;
    if (p->allocated) Ppmd7_Free(&p->ppmd, &s->archive->big.vt);
    stage_free(p->bytes.in);
    free(p);
}

static stage *ppmd_new(sz_archive *a, stage *in, const Byte *props, unsigned props_size, UInt64 out_size) {
    if (props_size != 5) { set_error(a, "the archive uses a feature SIDtune can't read"); return NULL; }
    unsigned order = props[0];
    UInt32 mem = GetUi32(props + 1);
    if (order < PPMD7_MIN_ORDER || order > PPMD7_MAX_ORDER || mem < PPMD7_MIN_MEM_SIZE || mem > PPMD7_MAX_MEM_SIZE) {
        set_error(a, "the archive uses a feature SIDtune can't read");
        return NULL;
    }
    ppmd_stage *p = calloc(1, sizeof *p);
    if (!p) { set_error(a, "not enough memory"); return NULL; }
    p->base = (stage){ ppmd_read, ppmd_destroy, a };
    p->bytes.vt.Read = byte_in_read;
    p->bytes.in = in;
    p->left = out_size;
    Ppmd7_Construct(&p->ppmd);
    if (!Ppmd7_Alloc(&p->ppmd, mem, &a->big.vt)) {
        set_error(a, "not enough memory");
        p->bytes.in = NULL; // the caller still owns `in`
        ppmd_destroy(&p->base);
        return NULL;
    }
    p->allocated = true;
    Ppmd7_Init(&p->ppmd, order);
    p->ppmd.rc.dec.Stream = &p->bytes.vt;
    if (!Ppmd7z_RangeDec_Init(&p->ppmd.rc.dec)) {
        set_error(a, "the archive is damaged");
        p->bytes.in = NULL;
        ppmd_destroy(&p->base);
        return NULL;
    }
    return &p->base;
}

typedef struct {
    stage base;
    stage *main;
    CBcj2Dec dec;
    Byte *side[3];
    UInt64 left;
    bool main_end;
    uint8_t main_buf[IO_BUF];
} bcj2_stage;

static ptrdiff_t bcj2_read(stage *s, uint8_t *buf, size_t size) {
    bcj2_stage *b = (bcj2_stage *)s;
    if (b->left == 0) return 0;
    if (size > b->left) size = (size_t)b->left;
    b->dec.dest = buf;
    b->dec.destLim = buf + size;
    for (;;) {
        SRes res = Bcj2Dec_Decode(&b->dec);
        if (res != SZ_OK) { set_error(s->archive, "%s", describe(res)); return -1; }
        if (b->dec.dest == b->dec.destLim) break;
        if (b->dec.state != BCJ2_STREAM_MAIN || b->main_end) {
            set_error(s->archive, "the archive is damaged");
            return -1;
        }
        ptrdiff_t n = b->main->read(b->main, b->main_buf, IO_BUF);
        if (n < 0) return -1;
        if (n == 0) { b->main_end = true; continue; }
        b->dec.bufs[BCJ2_STREAM_MAIN] = b->main_buf;
        b->dec.lims[BCJ2_STREAM_MAIN] = b->main_buf + n;
    }
    b->left -= size;
    return (ptrdiff_t)size;
}

static void bcj2_destroy(stage *s) {
    bcj2_stage *b = (bcj2_stage *)s;
    for (int i = 0; i < 3; i++) free(b->side[i]);
    stage_free(b->main);
    free(b);
}

/// `inputs` are main, call, jump and range coder, in BCJ2's input order. The bcj2 stage takes ownership of all four.
static stage *bcj2_new(sz_archive *a, stage *inputs[4], const UInt64 sizes[4], UInt64 out_size) {
    bcj2_stage *b = calloc(1, sizeof *b);
    if (!b) {
        for (int i = 0; i < 4; i++) stage_free(inputs[i]);
        set_error(a, "not enough memory");
        return NULL;
    }
    b->base = (stage){ bcj2_read, bcj2_destroy, a };
    b->main = inputs[0];
    b->left = out_size;
    Bcj2Dec_Init(&b->dec);
    bool ok = true;
    for (int i = 0; i < 3; i++) {
        stage *in = inputs[i + 1];
        UInt64 size = sizes[i + 1];
        if (ok && size > MAX_SIDE_STREAM) { set_error(a, "the archive uses a feature SIDtune can't read"); ok = false; }
        if (ok) {
            b->side[i] = malloc(size ? (size_t)size : 1);
            if (!b->side[i]) { set_error(a, "not enough memory"); ok = false; }
        }
        if (ok && read_full(in, b->side[i], (size_t)size) != (ptrdiff_t)size) {
            set_error(a, "the archive is incomplete");
            ok = false;
        }
        stage_free(in);
        if (ok) {
            b->dec.bufs[i + 1] = b->side[i];
            b->dec.lims[i + 1] = b->side[i] + size;
        }
    }
    b->dec.bufs[BCJ2_STREAM_MAIN] = b->dec.lims[BCJ2_STREAM_MAIN] = b->main_buf;
    if (!ok) { bcj2_destroy(&b->base); return NULL; }
    return &b->base;
}

// MARK: Blocks

typedef struct {
    sz_archive *archive;
    CSzFolder folder;
    const Byte *props_base;
    const UInt64 *unpack_sizes;
    UInt32 pack_index;
    UInt32 in_base[SZ_NUM_CODERS_IN_FOLDER_MAX];
} block;

static UInt64 input_size(block *b, UInt32 in_index);

static stage *coder_stage(block *b, UInt32 coder);

static stage *input_stage(block *b, UInt32 in_index) {
    for (UInt32 i = 0; i < b->folder.NumBonds; i++) {
        if (b->folder.Bonds[i].InIndex == in_index) return coder_stage(b, b->folder.Bonds[i].OutIndex);
    }
    const CSzAr *ar = &b->archive->db.db;
    for (UInt32 k = 0; k < b->folder.NumPackStreams; k++) {
        if (b->folder.PackStreams[k] != in_index) continue;
        UInt64 start = ar->PackPositions[b->pack_index + k];
        UInt64 end = ar->PackPositions[b->pack_index + k + 1];
        return pack_new(b->archive, b->archive->db.dataPos + start, end - start);
    }
    set_error(b->archive, "the archive's header is damaged");
    return NULL;
}

static UInt64 input_size(block *b, UInt32 in_index) {
    for (UInt32 i = 0; i < b->folder.NumBonds; i++) {
        if (b->folder.Bonds[i].InIndex == in_index) return b->unpack_sizes[b->folder.Bonds[i].OutIndex];
    }
    const CSzAr *ar = &b->archive->db.db;
    for (UInt32 k = 0; k < b->folder.NumPackStreams; k++) {
        if (b->folder.PackStreams[k] == in_index) return ar->PackPositions[b->pack_index + k + 1] - ar->PackPositions[b->pack_index + k];
    }
    return 0;
}

static stage *coder_stage(block *b, UInt32 index) {
    sz_archive *a = b->archive;
    const CSzCoderInfo *c = &b->folder.Coders[index];
    const Byte *props = b->props_base + c->PropsOffset;
    UInt64 out_size = b->unpack_sizes[index];
    UInt32 base = b->in_base[index];
    switch (c->MethodID) {
    case METHOD_COPY:
    case METHOD_LZMA:
    case METHOD_LZMA2:
    case METHOD_PPMD: {
        if (c->NumStreams != 1) break;
        stage *in = input_stage(b, base);
        if (!in) return NULL;
        stage *s;
        if (c->MethodID == METHOD_COPY) {
            copy_stage *cs = calloc(1, sizeof *cs);
            if (!cs) { stage_free(in); set_error(a, "not enough memory"); return NULL; }
            cs->base = (stage){ copy_read, copy_destroy, a };
            cs->in = in;
            cs->left = out_size;
            return &cs->base;
        }
        s = c->MethodID == METHOD_PPMD ? ppmd_new(a, in, props, c->PropsSize, out_size)
                                       : lzma_new(a, in, c->MethodID == METHOD_LZMA2, props, c->PropsSize, out_size);
        if (!s) stage_free(in);
        return s;
    }
    case METHOD_BCJ2: {
        if (c->NumStreams != 4) break;
        stage *inputs[4] = { NULL };
        UInt64 sizes[4];
        for (UInt32 i = 0; i < 4; i++) {
            sizes[i] = input_size(b, base + i);
            inputs[i] = input_stage(b, base + i);
            if (!inputs[i]) {
                for (UInt32 k = 0; k < i; k++) stage_free(inputs[k]);
                return NULL;
            }
        }
        return bcj2_new(a, inputs, sizes, out_size);
    }
    default:
        break;
    }
    set_error(a, "the archive uses a compression method SIDtune can't read (%X)", (unsigned)c->MethodID);
    return NULL;
}

static stage *block_stage(sz_archive *a, UInt32 f) {
    const CSzAr *ar = &a->db.db;
    block b = { .archive = a };
    CSzData sd;
    sd.Data = ar->CodersData + ar->FoCodersOffsets[f];
    sd.Size = ar->FoCodersOffsets[f + 1] - ar->FoCodersOffsets[f];
    if (SzGetNextFolderItem(&b.folder, &sd) != SZ_OK) {
        set_error(a, "the archive uses a feature SIDtune can't read");
        return NULL;
    }
    b.props_base = ar->CodersData + ar->FoCodersOffsets[f];
    b.unpack_sizes = ar->CoderUnpackSizes + ar->FoToCoderUnpackSizes[f];
    b.pack_index = ar->FoStartPackStreamIndex[f];
    UInt32 next = 0;
    for (UInt32 c = 0; c < b.folder.NumCoders; c++) {
        b.in_base[c] = next;
        next += b.folder.Coders[c].NumStreams;
    }
    return coder_stage(&b, b.folder.UnpackStream);
}

int sz_extract(sz_archive *a, const bool *wanted, sz_file_callback callback, void *context, char *error, size_t error_size) {
    a->error[0] = 0;
    const CSzArEx *db = &a->db;
    uint8_t *buf = NULL;
    size_t cap = 0;
    int result = 0;
    for (UInt32 f = 0; f < db->db.NumFolders && result == 0; f++) {
        UInt32 first = db->FolderToFile[f], last = db->FolderToFile[f + 1];
        bool any = false;
        for (UInt32 i = first; i < last; i++) any |= db->FileToFolder[i] == f && wanted[i];
        if (!any) continue;
        stage *s = block_stage(a, f);
        if (!s) { result = -1; break; }
        for (UInt32 i = first; i < last && result == 0; i++) {
            if (db->FileToFolder[i] != f) continue;
            UInt64 size64 = SzArEx_GetFileSize(db, i);
            if (size64 > SIZE_MAX / 2) { set_error(a, "an entry is too large"); result = -1; break; }
            size_t size = (size_t)size64;
            if (wanted[i]) {
                if (size > cap) {
                    uint8_t *grown = realloc(buf, size);
                    if (!grown) { set_error(a, "not enough memory"); result = -1; break; }
                    buf = grown;
                    cap = size;
                }
                if (read_full(s, buf, size) != (ptrdiff_t)size) { set_error(a, "the archive is incomplete"); result = -1; break; }
                if (SzBitWithVals_Check(&db->CRCs, i) && CrcCalc(buf, size) != db->CRCs.Vals[i]) {
                    set_error(a, "%s", describe(SZ_ERROR_CRC));
                    result = -1;
                    break;
                }
                if (callback(context, i, buf, size) != 0) result = 1;
            } else {
                uint8_t skip[IO_BUF];
                while (size > 0) {
                    size_t n = size < IO_BUF ? size : IO_BUF;
                    if (read_full(s, skip, n) != (ptrdiff_t)n) { set_error(a, "the archive is incomplete"); result = -1; break; }
                    size -= n;
                }
            }
        }
        stage_free(s);
    }
    free(buf);
    if (result < 0) snprintf(error, error_size, "%s", a->error[0] ? a->error : "the archive couldn't be read");
    return result;
}
