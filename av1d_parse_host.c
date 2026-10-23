/*
 * Host-only parser harness: feeds a file to mpp_parser_prepare()/mpp_parser_parse()
 * the way mpp_dec_normal.c does, with no hardware.
 *
 *   host_parse <av1|hevc|vp9> file [loops]
 *
 * IVF files are fed one frame per packet, anything else as one packet.
 * Prints "frames N valid M" where N = parse calls with a valid task and
 * M = tasks that produced an output slot. Counts are for all loops.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#include "rk_type.h"
#include "mpp_err.h"
#include "mpp_packet.h"
#include "mpp_frame.h"
#include "mpp_buf_slot.h"
#include "mpp_dec_cfg.h"
#include "kmpp_obj.h"
#include "mpp_parser.h"
#include "parser_api.h"
#include "hal_dec_task.h"
#include "mpp_packet_impl.h"
#include "av1d_syntax.h"

static unsigned char *load(const char *path, size_t *size)
{
    FILE *fp = fopen(path, "rb");
    unsigned char *buf;

    if (!fp)
        return NULL;
    fseek(fp, 0, SEEK_END);
    *size = ftell(fp);
    fseek(fp, 0, SEEK_SET);
    buf = malloc(*size);
    if (fread(buf, 1, *size, fp) != *size)
        return NULL;
    fclose(fp);
    return buf;
}

static int total_parse, total_out, total_loop_guard, total_disp, is_av1;
static struct { unsigned val; int n; } opidc[16];
static unsigned long long pp_hash = 1469598103934665603ULL, pp_hash_masked = 1469598103934665603ULL;

static unsigned long long fnv(unsigned long long h, const void *p, size_t n)
{
    const unsigned char *b = p;

    while (n--)
        h = (h ^ *b++) * 1099511628211ULL;
    return h;
}

static void hash_pp(const DXVA_PicParams_AV1 *pp)
{
    DXVA_PicParams_AV1 tmp = *pp;

    tmp.cdfs = NULL;
    tmp.cdfs_ndvc = NULL;

    pp_hash = fnv(pp_hash, &tmp, sizeof(tmp));
    tmp.coding.current_operating_point = 0;
    pp_hash_masked = fnv(pp_hash_masked, &tmp, sizeof(tmp));
}

static void count_opidc(unsigned v)
{
    int i;

    for (i = 0; i < 15 && opidc[i].n; i++)
        if (opidc[i].val == v)
            break;
    opidc[i].val = v;
    opidc[i].n++;
}

static struct { unsigned fmt; int w, h, n; } fmts[16];

static void count_fmt(MppBufSlots slots, int idx)
{
    MppFrame frame = NULL;
    unsigned fmt;
    int w, h, i;

    mpp_buf_slot_get_prop(slots, idx, SLOT_FRAME_PTR, &frame);
    if (!frame)
        return;
    fmt = mpp_frame_get_fmt(frame);
    w = mpp_frame_get_width(frame);
    h = mpp_frame_get_height(frame);
    for (i = 0; i < 15 && fmts[i].n; i++)
        if (fmts[i].fmt == fmt && fmts[i].w == w && fmts[i].h == h)
            break;
    fmts[i].fmt = fmt; fmts[i].w = w; fmts[i].h = h; fmts[i].n++;
}

static void drain(MppBufSlots frame_slots, HalDecTask *task)
{
    RK_S32 idx;

    /* what the hal/display side does: release input refs, output queue */
    for (int i = 0; i < 16; i++) {
        if (task->refer[i] >= 0)
            mpp_buf_slot_clr_flag(frame_slots, task->refer[i], SLOT_HAL_INPUT);
    }
    if (task->output >= 0)
        mpp_buf_slot_clr_flag(frame_slots, task->output, SLOT_HAL_OUTPUT);
    while (!mpp_buf_slot_dequeue(frame_slots, &idx, QUEUE_DISPLAY)) {
        total_disp++;
        mpp_buf_slot_clr_flag(frame_slots, idx, SLOT_QUEUE_USE);
    }
}


static int extra_mode;
static unsigned char extra_seq[256];
static size_t extra_seq_len;

/* Split AV1 OBUs (has_size_field set): copy all but sequence headers to out, remember the first one. */
static size_t strip_seq(const unsigned char *in, size_t len, unsigned char *out)
{
    size_t pos = 0, o = 0;

    while (pos < len) {
        unsigned char h = in[pos];
        size_t hl = 1 + ((h >> 2) & 1), sz = 0, shift = 0, n = 0;

        while (1) {
            unsigned char b = in[pos + hl + n];

            sz |= (size_t)(b & 0x7f) << shift;
            shift += 7;
            n++;
            if (!(b & 0x80))
                break;
        }
        if (((h >> 3) & 15) == 1) {
            if (!extra_seq_len) {
                size_t tl = hl + n + sz;

                memcpy(extra_seq + 4, in + pos, tl);
                extra_seq[0] = 0x81;
                extra_seq_len = 4 + tl;
            }
        } else {
            memcpy(out + o, in + pos, hl + n + sz);
            o += hl + n + sz;
        }
        pos += hl + n + sz;
    }
    return o;
}

static void feed_extra(Parser parser)
{
    MppPacket pkt = NULL;
    HalDecTask task;

    mpp_packet_init(&pkt, extra_seq, extra_seq_len);
    mpp_packet_set_flag(pkt, MPP_PACKET_FLAG_EXTRA_DATA);
    memset(&task, 0, sizeof(task));
    task.output = -1;
    task.input = -1;
    memset(task.refer, -1, sizeof(task.refer));
    mpp_parser_prepare(parser, pkt, &task);
    mpp_packet_deinit(&pkt);
}

static void feed(Parser parser, MppBufSlots frame_slots, MppBufSlots packet_slots,
                 unsigned char *data, size_t len, int eos, RK_S64 pts)
{
    MppPacket pkt = NULL;
    HalDecTask task;
    int guard = 0;

    (void)packet_slots;
    mpp_packet_init(&pkt, data, len);
    mpp_packet_set_pts(pkt, pts);
    if (eos)
        mpp_packet_set_eos(pkt);
    while (mpp_packet_get_length(pkt) > 0) {
        if (++guard > 100000) {
            fprintf(stderr, "LOOP GUARD: prepare did not consume packet (len %zu)\n",
                    mpp_packet_get_length(pkt));
            total_loop_guard++;
            break;
        }
        memset(&task, 0, sizeof(task));
        task.output = -1;
        task.input = -1;
        memset(task.refer, -1, sizeof(task.refer));
        mpp_parser_prepare(parser, pkt, &task);
        if (getenv("HP_TRACE"))
            fprintf(stderr, "prepare valid %d left %zu eos %d\n", task.valid, (size_t)mpp_packet_get_length(pkt), task.flags.eos);
        if (!task.valid)
            continue;
        mpp_parser_parse(parser, &task);
        total_parse++;
        if (is_av1 && task.valid && task.syntax.data)
            hash_pp((DXVA_PicParams_AV1 *)task.syntax.data);
        if (is_av1 && task.valid && task.syntax.data)
            count_opidc(((DXVA_PicParams_AV1 *)task.syntax.data)->coding.current_operating_point);
        if (task.valid && task.output >= 0) {
            total_out++;
            count_fmt(frame_slots, task.output);
        }
        drain(frame_slots, &task);
    }
    mpp_packet_deinit(&pkt);
}

int main(int argc, char **argv)
{
    MppDecCfg cfg_obj = NULL;
    MppDecCfgSet *cfg;
    MppBufSlots frame_slots = NULL, packet_slots = NULL;
    MppDecHwCap hw;
    ParserCfg pcfg;
    Parser parser = NULL;
    MppCodingType coding;
    unsigned char *buf;
    size_t size;
    int loops = 1;
    int extra_sent = 0;

    if (argc < 3)
        return 2;
    if (!strcmp(argv[1], "av1")) {
        coding = MPP_VIDEO_CodingAV1;
        is_av1 = 1;
    }
    else if (!strcmp(argv[1], "hevc"))
        coding = MPP_VIDEO_CodingHEVC;
    else if (!strcmp(argv[1], "vp9"))
        coding = MPP_VIDEO_CodingVP9;
    else
        return 2;
    if (argc > 3)
        loops = atoi(argv[3]);
    if (argc > 4 && !strcmp(argv[4], "extra"))
        extra_mode = 1;
    buf = load(argv[2], &size);
    if (!buf)
        return 1;

    mpp_dec_cfg_init(&cfg_obj);
    cfg = (MppDecCfgSet *)kmpp_obj_to_entry(cfg_obj);
    cfg->base.split_parse = 1;
    cfg->base.fast_parse = 0;

    mpp_buf_slot_init(&frame_slots);
    mpp_buf_slot_set_dec_cfg(frame_slots, cfg_obj);
    mpp_buf_slot_init(&packet_slots);
    mpp_buf_slot_setup(packet_slots, 2);
    mpp_slots_set_prop(packet_slots, SLOTS_CODING_TYPE, &coding);
    mpp_slots_set_prop(frame_slots, SLOTS_CODING_TYPE, &coding);

    memset(&hw, 0, sizeof(hw));
    hw.cap_core_num = 1;
    hw.cap_4k = 1;
    hw.cap_8k = 1;
    pcfg.coding = coding;
    pcfg.frame_slots = frame_slots;
    pcfg.packet_slots = packet_slots;
    pcfg.cfg = cfg;
    pcfg.hw_info = &hw;
    if (mpp_parser_init(&parser, &pcfg)) {
        fprintf(stderr, "mpp_parser_init failed\n");
        return 1;
    }

    for (int l = 0; l < loops; l++) {
        if (size > 32 && !memcmp(buf, "DKIF", 4)) {
            size_t pos = buf[6] | (buf[7] << 8);
            RK_S64 n = 0;

            while (pos + 12 <= size) {
                size_t fsz = buf[pos] | (buf[pos + 1] << 8) | (buf[pos + 2] << 16) |
                             ((size_t)buf[pos + 3] << 24);

                pos += 12;
                if (pos + fsz > size)
                    break;
                /* the packet must be writable heap data: parsers may keep pointers */
                unsigned char *copy = malloc(fsz);
                size_t plen = fsz;

                memcpy(copy, buf + pos, fsz);
                if (extra_mode) {
                    unsigned char *tmp = malloc(fsz);

                    plen = strip_seq(copy, fsz, tmp);
                    free(copy);
                    copy = tmp;
                    if (!extra_sent) {
                        feed_extra(parser);
                        extra_sent = 1;
                    }
                }
                feed(parser, frame_slots, packet_slots, copy, plen, 0, n++);
                free(copy);
                pos += fsz;
            }
        } else {
            unsigned char *copy = malloc(size);
            memcpy(copy, buf, size);
            feed(parser, frame_slots, packet_slots, copy, size, 0, 0);
            free(copy);
        }
    }
    printf("RESULT loops %d parse_tasks %d out_tasks %d displayed %d loop_guard %d\n",
           loops, total_parse, total_out, total_disp, total_loop_guard);
    printf("PPHASH %016llx masked %016llx\n", pp_hash, pp_hash_masked);
    for (int i = 0; i < 16 && opidc[i].n; i++)
        printf("OPIDC 0x%x tasks %d\n", opidc[i].val, opidc[i].n);
    for (int i = 0; i < 16 && fmts[i].n; i++)
        printf("FMT 0x%x %dx%d frames %d\n", fmts[i].fmt, fmts[i].w, fmts[i].h, fmts[i].n);
    fflush(stdout);
    return 0;
}
