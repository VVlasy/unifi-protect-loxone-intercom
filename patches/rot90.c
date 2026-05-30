/*
 * rot90.c — LD_PRELOAD shim for UniFi Doorbell Lite (G6O, Sigmastar Infinity6E).
 *
 * Rotation on this firmware is driven by "hallwayMode": the streamer reads it from
 * the IPC settings Protect pushes (ubnt::ipc::messages::VideoSettings::hallwayMode())
 * / ubnt::encoder::VideoEncoderSettings::hallwayMode(), then ProcessHallwayMode() does
 * the full, correct VPE rotation setup (port mode + swapped output dims + rotation).
 * Forcing the low-level MI_VPE_SetChannelRotation alone does NOT work (no port setup).
 *
 * So we interpose the two C++ getters and return a forced hallwayMode, letting the
 * encoder's own code path rotate properly. Sweep the value via env HALLWAY (0..3).
 *
 * Build (armv7 hard-float, camera glibc 2.30 for symbol versions; no libdl needed):
 *   arm-linux-gnueabihf-gcc -shared -fPIC -O2 -std=gnu11 -fno-stack-protector \
 *       -nostdlib -o rot90.so rot90.c camlib/libc.so.6
 */
#define _GNU_SOURCE
#include <stdlib.h>
#include <stdio.h>
#include <unistd.h>

static int hw(void)
{
    const char *e = getenv("HALLWAY");
    if (e && e[0] >= '0' && e[0] <= '3')
        return e[0] - '0';
    return 2;
}

static void lg(const char *tag, int v)
{
    FILE *f = fopen("/tmp/rot90.log", "a");
    if (f) { fprintf(f, "pid=%d %s ret=%d\n", getpid(), tag, v); fclose(f); }
}

/* int ubnt::encoder::VideoEncoderSettings::hallwayMode() const */
int _ZN4ubnt7encoder20VideoEncoderSettings11hallwayModeEv(void *self)
{
    (void)self;
    int v = hw();
    lg("enc::hallwayMode", v);
    return v;
}

/* int ubnt::ipc::messages::VideoSettings::hallwayMode() const */
int _ZN4ubnt3ipc8messages13VideoSettings11hallwayModeEv(void *self)
{
    (void)self;
    int v = hw();
    lg("ipc::hallwayMode", v);
    return v;
}

__attribute__((constructor))
static void rot_ctor(void)
{
    FILE *f = fopen("/tmp/rot90.log", "a");
    if (f) { fprintf(f, "pid=%d LOADED(hwhook HALLWAY=%d)\n", getpid(), hw()); fclose(f); }
}
