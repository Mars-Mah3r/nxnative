// HookLink: the launcher's Frame rate mode (DM_FRAME_MODE), one choice that sets the switches a mode needs before the host reads them. Called by the front end once the
// launcher's choices are in the environment (front_ios.m startGame). 0 or unset: the app's own settings, as HookLink 1.7 ran (60 fps, frames shown as they come).
//   1  30 fps, steady: the 30 fps cap held, one calc a drawn frame (no measured frame time, no payback steps), present snapshots (cheemu21's V17; Tyuv97G's iPhone 17 Pro runs)
//   2  30 fps + frame generation: mode 1 with MetalFX's interpolated frame between presents, shown at 60 (cheemu21's X9)
//   3  60 fps + frame generation: 60 fps with an interpolated frame between presents on a 120 Hz screen (nvn_mtl.m link_sync); a 60 Hz screen shows plain 60
// A mode is the player's explicit choice, so it replaces what an env file set for these switches, and says so in the log.
#pragma once
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
static inline void dm_frame_mode_apply(void) {
    const char *e = getenv("DM_FRAME_MODE"); int m = e ? atoi(e) : 0;
    if (m < 1 || m > 3) return;
    static const char *const names[4] = { "", "30 fps, steady", "30 fps + frame generation (shown at 60)", "60 fps + frame generation (shown at 120)" };
    static const char *const set[4][7][2] = {
        {{0}},
        {{"DM_FPS_TARGET", "30"}, {"DM_FPS_HOLD", "on"}, {"DM_FPS_PAYBACK", "off"}, {"DM_FRAME_DELTA", "0"}, {"DM_PRESENT_SNAP", "2"}, {"DM_FRAMEGEN", "0"}, {0}},
        {{"DM_FPS_TARGET", "30"}, {"DM_FPS_HOLD", "on"}, {"DM_FPS_PAYBACK", "off"}, {"DM_FRAME_DELTA", "0"}, {"DM_PRESENT_SNAP", "3"}, {"DM_FRAMEGEN", "1"}, {0}},
        {{"DM_FPS_TARGET", "60"}, {"DM_PRESENT_SNAP", "3"}, {"DM_FRAMEGEN", "1"}, {0}},
    };
    fprintf(stderr, "frame rate mode %d: %s (DM_FRAME_MODE)\n", m, names[m]);
    for (int i = 0; i < 7 && set[m][i][0]; i++) {
        const char *was = getenv(set[m][i][0]);
        if (was && strcmp(was, set[m][i][1])) fprintf(stderr, "frame rate mode: %s=%s replaces %s\n", set[m][i][0], set[m][i][1], was);
        setenv(set[m][i][0], set[m][i][1], 1);
    }
}
