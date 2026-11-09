# The Legend of Zelda: Ocarina of Time (0400486024DEC000): the rewriter's patches of this game's own code. dm/tools/patch_nso.py loads every profile's patches.py;
# MATCH_FRAME_STEP as described there ("Registered patches"). Patches of Nintendo SDK module builds are in dm/tools/sdk_patches.py
from nso_asm import ADRP, B

# The game's frame ratio. Once a frame the function at main+0x6e6be0 (v131072, ModuleSystem::moduleCalc_ by the name of its job) divides its base rate (60.0, or 30.0 while
# bit 0 of [x21+0x24f] is set) by the int frame rate at [x21+0x2c8] (fdiv s8,s1,s0 at +0xe4) and hands the result to the time object (main+0x3b4e300: ratio at +0x10, 1 / ratio
# at +0x14, ratio / 60 at +0x18, the step in seconds, round(60 / ratio) at +0x1c), which the game steps by; the frame's own time never enters it, so a frame that takes two
# vsyncs at rate 60 plays at half speed. The stub gives the ratio the host's step instead: step × base / 60, and counts the vsyncs stepped. Until the host has decided a step,
# and at fps_target 0, the division runs. s0 and x16 / x17 are free there (s0 is written again on every path before it is read; the function uses neither x16 nor x17); s1 keeps
# the base rate and x21 the framework.
# Why × base / 60 and not the step alone (PR #1996 read base 30 as a cutscene rate and took the step, twice the speed there): the ratio's unit is 1/60 s whatever the base
# (the time object's +0x18 is ratio × 1/60, the constant at main+0x3e4066c). Base 30 is the framework's half rate: bit 0 of its +0x24f is that mode and bit 1 flips each pass of
# its frame function (main+0x346c680); with both set the draw and the present return at once (main+0x2cb020, main+0x40cd20) while the calc tree runs (main+0x2cabd0). So it
# calcs twice a drawn frame, this function among them, and each calc takes half the frame's step: 30 / 30 = 1 twice a 30 fps frame on the console, step / 2 twice here. The
# vsyncs are counted once a drawn frame, at the calc that is drawn (bit 1 clear).
# Lichii (a GPL emulator; only the fact was taken) found the division (its notes: main+0x6E6CC4, 60 / [x21+0x2C8])
def frame_step(ctx):
    here, emit, fs_site, fs_put, FS_STATE_OFF, base = ctx.here, ctx.emit, ctx.site, ctx.put, ctx.state, ctx.base
    site = base + 0xe4
    fs_site(site, '2818201e')   # fdiv s8,s1,s0
    start = here()
    ORIG, COUNTED, n = 24, 13, [0]   # the original division is word 24 of the stub, the ratio starts at word 13 (both checked below); n counts the words emitted
    def put(w): emit(w); n[0] += 1
    def cbz_w17_orig(): return 0x34000000 | (((ORIG - n[0]) & 0x7FFFF) << 5) | 17   # from this word to word ORIG
    put(ADRP(16, here(), FS_STATE_OFF))
    put(0xb9400211)             # ldr w17,[x16]          target fps (0 = off)
    put(cbz_w17_orig())         # cbz w17,orig
    put(0xb9402211)             # ldr w17,[x16,#0x20]    step in vsyncs
    put(cbz_w17_orig())         # cbz w17,orig           not decided yet
    put(0x1e230220)             # ucvtf s0,w17
    put(0x39493eb0)             # ldrb w16,[x21,#0x24f]  the framework's half-rate bits
    put(0x37000000 | 1 << 19 | ((COUNTED - n[0]) & 0x3FFF) << 5 | 16)   # tbnz w16,#1,ratio: the calc of a half-rate frame that is not drawn; its vsyncs are counted at the drawn one
    put(ADRP(16, here(), FS_STATE_OFF))
    for w in (0xf9401a10,   # ldr x16,[x16,#0x30]
              0x8b110210):  # add x16,x16,x17
        put(w)
    put(ADRP(17, here(), FS_STATE_OFF))
    put(0xf9001a30)             # str x16,[x17,#0x30]    vsyncs stepped
    assert n[0] == COUNTED, f'frame_step: the ratio starts at word {n[0]}, the tbnz goes to word {COUNTED}'
    for w in (0x1e210808,   # fmul s8,s0,s1          step × base rate
              0x52a84e10,   # mov w16,#0x42700000    60.0
              0x1e270200,   # fmov s0,w16
              0x1e201908):  # fdiv s8,s8,s0          / 60
        put(w)
    # Never below the measured frame time: with the hold off (DM_FPS_HOLD off) or past the longest step, a frame that ran long still moves the game by its real time
    # (state +0x38, seconds, the host's mean of recent present intervals; 0 at the target; +0x3c marks a main that reads it). From PR #1543, found by gunvalk (Lichii PR #216).
    # The host takes what this adds to the step off its debt (nvn_fstep_moved), or the step paid the same time back again: 9% fast at frames of 1.8 vsyncs with the hold off.
    # Every branch target above is computed: with these words inserted, main's fixed offsets (+13, +11) landed inside this block, and an iPhone 18 Pro Max faulted at
    # x17 + 0x3c with x17 = 0 on the first frame, before the host had decided a step. The page is taken again into x16, PR #1543's own sequence: in rewritten code x17 does
    # not survive a store
    put(ADRP(16, here(), FS_STATE_OFF))
    for w in (0x52800031,   # mov w17,#1
              0xb9003e11,   # str w17,[x16,#0x3c]    this main reads the frame time
              0xbd403a00,   # ldr s0,[x16,#0x38]     seconds; 0 = at the target
              0x1e210800,   # fmul s0,s0,s1          × base rate
              0x1e204908):  # fmax s8,s8,s0
        put(w)
    put(B(here(), site + 4))
    assert n[0] == ORIG, f'frame_step: the original division is word {n[0]}, the cbz branches go to word {ORIG}'
    emit(0x1e201828); emit(B(here(), site + 4))   # orig: fdiv s8,s1,s0; back
    fs_put(site, [B(site, start)], 'frame ratio: the host\'s step × base rate / 60 (never below the measured frame time) instead of base rate / the game\'s frame rate (state page target fps; 0 = the game\'s ratio)')
    dynamic_resolution(ctx)
    wide_view(ctx)
    half_rate(ctx)

# The game's dynamic resolution (game__gfx__DynamicResolutionParam: LoadThreshold, ReduceCounterMax, IncreaseCounterMax and a list of levels, each a ResolutionReduceScale and a
# Priority; on v131072 levels 0..9 at 0.75..0.333 of 2048x1152, 1536x864 to 683x384). Its update (main+0x805aa0) reads the frame's GPU load (about 0.2 ms a unit) into +0x8, subtracts
# its small model of the fixed costs and divides the rest by the square of the current scale: it takes the rest of the frame's cost to grow with the pixel count, as on the Switch 2
# its constants were tuned for. The level function (main+0x8065e0) adds that back times each level's scale squared and returns the best level under the threshold (+0x10, 83 = about
# 16.4 ms). On Apple GPUs this game's cost hardly depends on the resolution (mesh, compute and the upscaler's fixed 2048x1152 dominate): 683x384 cost 14.3 ms and 1536x864 14.7 ms on
# an M4 Pro, yet at 683x384 the extrapolation put 1536x864 at about 300 units against the 83 it allows, so the controller sat at its floor for good (game note, Dynamic resolution).
# The stub replaces the level function. With DM_DYNAMIC_RESOLUTION 0 (the default; state +0x40 0) it returns 0: full resolution. With 1 it climbs on what was measured at each
# level, with no model of how the cost grows: one level down when the load (+0x8) has been over the threshold for 8 calls in a row, and that level is marked as not fitting; one level
# up when the load fits and the level above was never measured, fitted when it was last measured, or was measured more than 600 calls (about 10 s) ago; else the current level
# (+0x174). Nothing is decided or recorded until a level has held 8 calls: the load is read a few frames late, so before that it may be the previous level's. The 8 calls over in a
# row keep a single slow frame, or the first frames at a new size (its render targets), from marking a level that fits (on the full library at level 1: one burst to 90 against loads
# of 77-80 at levels 2 and 1). The game's counters still pace the steps (down after ReduceCounterMax frames, up after IncreaseCounterMax); its level count (+0x1a0) is the floor.
# The memory is in the state page: +0x200 calls, +0x204 the last call's level, +0x208 calls at it, +0x20c calls over in a row, +0x210 the load measured at each level (16 floats),
# +0x250 the call it was measured at (0 = never). Run against a model of the update (a level moves after the stub asked 5 times up or 2 times down; the load two frames late): a load
# of 70 at every level climbs from the floor to full size in 9 steps, as does Ocarina's measured 72-80 with a spike every 37 frames and a burst after each change; a load that grows
# with the pixel count settles at the highest level that fits and tries the one above once per 600 calls; a scene that gets lighter climbs again, a heavier one steps down.
# The function is a leaf: x2..x11, x16, x17 and s0..s2 are free, w0 its only result (the original also stores its predicted cost at +0x18, which only it and the update's own
# decision read). The update's fingerprint is required too: +0x8 and +0x174 are its fields
drs_controller = (   # drs_stub.s, assembled with clang; x0 the controller, x16 the state page (the ADRP before it)
    0xb9404211, 0x35000071, 0x2a1f03e0, 0xd65f03c0,                                                   # off (state +0x40 0): level 0
    0xbd400800, 0xbd401001, 0xb9417402, 0xb941a003, 0x7100005f, 0x1a9fa042, 0x528001e9, 0x6b09005f,   # load, threshold, level (0..15), count
    0x1a89d042, 0xb9420204, 0x11000484, 0xb9020204, 0xb9420605, 0xb9420a06, 0x6b0200bf, 0x1a8617e6,   # calls + 1; calls at this level
    0xb9020602, 0xb9020a06, 0x35000046, 0xb9020e1f, 0x91084207, 0x91094208, 0x710020df, 0x5400040b,   # a new level: none over; under 8 calls: stay
    0x1e212000, 0x540001ad, 0xb9420e0b, 0x1100056b, 0xb9020e0b, 0x7100217f, 0x5400032b,               # over: under 8 in a row, stay
    0xbc2258e0, 0xb8225904, 0x51000469, 0x1100044a, 0x6b09015f, 0x1a89d140, 0xd65f03c0,               # 8 in a row: record it, down one (to the floor)
    0xb9020e1f, 0xbc2258e0, 0xb8225904, 0x34000182, 0x51000449, 0xb869590a, 0x340000ea, 0x4b0a008a,   # fits: record it; at 0 stay; the level above's record
    0x7109615f, 0x54000088, 0xbc6958e2, 0x1e212040, 0x540000aa, 0x2a0903e0, 0xd65f03c0,               # never, stale or fitting: up one
    0x2a1f03e0, 0xd65f03c0, 0x2a0203e0, 0xd65f03c0)                                                   # 0; or stay
def dynamic_resolution(ctx):
    here, emit, fs_site, fs_put, FS_STATE_OFF = ctx.here, ctx.emit, ctx.site, ctx.put, ctx.state
    site = ctx.others.get('dynamic resolution')
    if site is None or ctx.others.get('dynamic resolution update') is None: return   # not both found in this build (a red line from the locator): the game's own dynamic resolution
    fs_site(site, '017c40bd')   # ldr s1,[x0,#0x7c]
    start = here(); emit(ADRP(16, here(), FS_STATE_OFF))
    for w in drs_controller: emit(w)
    fs_put(site, [B(site, start)], 'dynamic resolution level: 0 (full resolution), or with state +0x40 (DM_DYNAMIC_RESOLUTION) a climb on the load measured at each level')
    ctx.capabilities.add('DYNAMIC_RESOLUTION')

# Wide view (DM_WIDE_VIEW, a launcher setting): the game sizes its output from fixed constants, so a screen wider than 16:9 shows bars. These stubs take the widths from the state page,
# written at each start from the screen's shape (loader.c), so the view widens and nothing stretches, and 0 there (16:9, or the setting off) runs the game's own constant. Sites from
# nxnative PR 1460 by vladbondarenko97, which cut them at build time; v131072 only, by the frame-ratio function's address. Each stub writes only the register the constant loads
wide_sites = [(0x1202ee0, 0xD2814008, 0x100, 8, 'graphics setup output width'), (0x31f39f4, 0xD2814008, 0x100, 8, 'docked render width'),
              (0x31f3a00, 0xD280F008, 0x104, 8, 'handheld render width'), (0xecbc80, 0x52A8A409, 0x108, 9, 'output width as a float')]
def wide_view(ctx):
    if ctx.base != 0x6e6be0: return
    here, emit, fs_site, fs_put, FS_STATE_OFF = ctx.here, ctx.emit, ctx.site, ctx.put, ctx.state
    for site, orig, off, rd, what in wide_sites:
        fs_site(site, orig.to_bytes(4, 'little').hex())
        start = here(); emit(ADRP(rd, here(), FS_STATE_OFF))
        emit(0xB9400000 | (off // 4) << 10 | rd << 5 | rd)      # ldr w<rd>,[x<rd>,#off]
        emit(0x35000040 | rd)                                   # cbnz w<rd>,the branch back
        emit(orig); emit(B(here(), site + 4))
        fs_put(site, [B(site, start)], f'wide view: {what} from the state page (0: the game\'s own)')
    # The output resolution table (main+0x3f58540, read here by the display mode, a leaf ending in ret: x9..x11 are free): each entry's width from its height and the screen's ratio
    site = 0x112c604
    fs_site(site, '287968f8')   # ldr x8,[x9,x8,lsl #3]: width in the low word, height in the high one
    start = here(); emit(0xF8687928); emit(ADRP(9, here(), FS_STATE_OFF))
    for w in (0xB9410D2A, 0x340000EA, 0xD360FD0B, 0x9B0B7D4A, 0x9142014A, 0xD354FD4A, 0xD37CED4A, 0xB3407D48): emit(w)   # ratio (16.16); if 0 skip; height * ratio, to a multiple of 16; width
    emit(B(here(), site + 4))
    fs_put(site, [B(site, start)], 'wide view: output resolution table width from its height')
    # The 3D view: the render targets follow the wider size, but the game's cameras keep a 16:9 aspect, so the picture was stretched. sead::PerspectiveProjection::doUpdateMatrix (main+0x3485cc0, a
    # leaf: vtable main+0x4bf8c70 slot 11; near +0x98, far +0x9c, tan of the half angle +0xac, aspect +0xb0) gives a 16:9 projection (within 0.01) the picture's ratio (state +0x110, float; 0 = off)
    # and stores it, so what reads the aspect back agrees with the matrix: the vertical angle stays and the sides show more. Every 16:9 projection takes it: sead's default near 1 / far 10000
    # (main+0xea5480) is the shape the game's own cameras keep, and leaving it at 16:9 left the picture stretched on the phone. Views of another ratio (cube maps, shadow maps) stay as they are.
    # The state page counts the matrices built (+0x120) and widened (+0x124) and keeps the last other ratio seen (+0x128), for the log (hle_nvn.c). x9, x16, s2..s4 and the flags are free at the entry
    site = 0x3485cc0
    fs_site(site, '0084552d')   # ldp s0,s1,[x0,#0xac]
    start = here(); emit(0x2D558400); emit(ADRP(16, here(), FS_STATE_OFF))
    for w in (0xB9412209, 0x11000529, 0xB9012209,                                                   # +0x120 += 1
              0xBD411202, 0x1E202048, 0x54000240,                                                   # ldr s2,[x16,#0x110]; fcmp s2,#0; b.eq back
              0x5291C729, 0x72A7FC69, 0x1E270123, 0x1E233823, 0x1E20C063, 0x529AE149, 0x72A78469, 0x1E270124, 0x1E242060, 0x540000EA,   # |aspect - 16/9| >= 0.01: b.ge other
              0x1E204041, 0xBD00B001,                                                               # fmov s1,s2; str s1,[x0,#0xb0]
              0xB9412609, 0x11000529, 0xB9012609, 0x14000002,                                       # +0x124 += 1; b back
              0xBD012A01):                                                                          # other: str s1,[x16,#0x128]
        emit(w)
    emit(B(here(), site + 4))
    fs_put(site, [B(site, start)], 'wide view: a 16:9 camera takes the picture\'s ratio (the sides show more, nothing stretched)')
    # The game's code holds copies of that matrix code (getProjectionMatrix main+0x23b910 checks the vtable slot and builds it in place), so the stub above was never reached: the phone's log
    # counted 0 projections in 1,200 frames. The ratio is changed where the game sets it instead: each store of a perspective projection's aspect (+0xb0, with its changed flag +8) whose value is
    # 16:9 (within 2 ulps of 1920/1080) stores the picture's ratio when wide view is on. Viewport ratios of the camera list (main+0x3b50988, +0x3b50b50, +0x28e72a4), sead's set (main+0xea4b20, the
    # aspect in s8) and constructor (main+0x3485c64, s3), and the game's cameras' own parameter (+0x140: main+0x4c533c, +0x2e1bb6c, +0x2e1c7d0). x16 and x17 are dead at each site (a call or a
    # write follows) and the test is cbnz, as two sites carry live flags. Each site counts its passes at state +0x130 + 4 * index and the widened ones at +0x124, for the log (hle_nvn.c)
    for k, (site, orig, n) in enumerate(((0x3485c64, 0xBD00B003, 3), (0xEA4B20, 0x2D15A260, 8), (0x4C533C, 0xBD00B280, 0), (0x653BD4, 0xBD00B100, 0), (0x6545F4, 0xBD00B340, 0),
                                         (0x28E72A4, 0xBD00B100, 0), (0x2DD7164, 0xBD00B2C0, 0), (0x2E1BB6C, 0xBD00B2E0, 0), (0x2E1C7D0, 0xBD00B2A0, 0), (0x3B50988, 0xBD00B000, 0),
                                         (0x3B50B50, 0xBD00B300, 0))):
        fs_site(site, orig.to_bytes(4, 'little').hex())
        c = (0x130 + 4 * k) // 4
        start = here(); emit(ADRP(16, here(), FS_STATE_OFF))
        if site in (0x4C533C, 0x2E1BB6C, 0x2E1C7D0):
            # The game's cameras' own aspect parameter (+0x140, copied from +0xc8): the phone's log showed main+0x4c533c storing it every frame and never 16:9, so whatever it holds is
            # scaled by the picture's ratio over 16:9 (state +0x114, float; 0 = off) and the value it came with is kept at +0x128 for the log. s1 is written or a call follows at each site
            for w in (0xB9400211 | c << 10, 0x11000631, 0xB9000211 | c << 10, 0xBD012A00,      # this site's passes += 1; +0x128 = the aspect as the game set it
                      0xB9411611, 0x34000011 | 6 << 5, 0x1E270221, 0x1E210800,                  # w17 = the scale, 0: store as is; s1 = scale; s0 *= s1
                      0xB9412611, 0x11000631, 0xB9012611, orig):                                 # widened += 1; the game's store
                emit(w)
            emit(B(here(), site + 4))
            fs_put(site, [B(site, start)], f'wide view: the game camera\'s aspect parameter is scaled by the picture\'s ratio over 16:9 (site {k})')
            continue
        for w in (0xB9400211 | c << 10, 0x11000631, 0xB9000211 | c << 10,                    # this site's passes += 1
                  0x1E260011 | n << 5, 0x52800010 | 0x8E37 << 5, 0x72A00010 | 0x3FE3 << 5,      # w17 = the aspect's bits; w16 = 16:9's bits - 2
                  0x4B100231, 0x53027E31, 0x35000011 | 8 << 5):                                  # (w17 - w16) >> 2 != 0: not 16:9, store as is
            emit(w)
        emit(ADRP(16, here(), FS_STATE_OFF))
        for w in (0xB9411211, 0x34000011 | 5 << 5, 0x1E270220 | n,                              # ratio (+0x110), 0: store as is; s<n> = ratio
                  0xB9412611, 0x11000631, 0xB9012611, orig):                                     # widened += 1; the game's store
            emit(w)
        emit(B(here(), site + 4))
        fs_put(site, [B(site, start)], f'wide view: a 16:9 camera aspect set here takes the picture\'s ratio (site {k})')
# The framework's half rate, asked for by the host. Some of this game counts calcs, not time: the timeline that fires its subtitles (PlaySubtitleWithVoice trigger events) and
# its movie player, which takes one picture a calc (the limit at the player's +0x20 is 1 for the creation argument the game passes, main+0x3b5c55c). The frame ratio above
# moves what reads the time object by real time, so below 60 fps the two fall apart: on an iPhone at 33 fps with the player let take two pictures a calc, the opening's
# picture kept time and "However, there was one particular boy..." came up 98 s into it, over the nightmare's castle gate; at 53 fps the narration was over by 61 s, over
# Link asleep. The game's own answer to a frame of two vsyncs is its half rate: two calcs a drawn frame (bit 0 of the framework's +0x24f; frame_step's note), 60 calcs a second
# at 30 fps. It asks for it once a calc from bit 0 of [ModuleSystem+0xa30]: 2 (enter) or 1 (leave) into the framework's +0x24e (main+0x650ea4..0x650eb4, v131072; the frame
# function main+0x346c680 acts on it at the end of a pass, and while the mode is on the request is written only at the calc that is drawn). The stub ORs the host's ask into that
# bit: state +0x44, 1 while the host holds 2 vsyncs or more under DM_FPS_HALF_RATE=1 (hle_nvn.c fstep_tick). x16 and x17 are free there (the function uses x16 only as a
# local temporary far from the site, x17 nowhere).
def half_rate(ctx):
    here, emit, fs_site, fs_put, FS_STATE_OFF = ctx.here, ctx.emit, ctx.site, ctx.put, ctx.state
    f = ctx.others.get('half rate request')
    if f is None: return   # not found in this build (a red line from the locator): the game's own choice
    site = f + 0x1a4
    fs_site(site, '68324ab9')   # ldr w8,[x19,#0xa30]
    start = here()
    emit(0xb94a3268)                        # ldr w8,[x19,#0xa30]   the game's own flags
    emit(ADRP(16, here(), FS_STATE_OFF))
    emit(0xb9404610)                        # ldr w16,[x16,#0x44]   the host's ask, 0 or 1
    emit(0x2a100108)                        # orr w8,w8,w16
    emit(B(here(), site + 4))
    fs_put(site, [B(site, start)], 'half rate request: the game\'s own flag or the host\'s ask (state +0x44, DM_FPS_HALF_RATE)')
    ctx.capabilities.add('HALF_RATE')

MATCH_FRAME_STEP = {'main': [
    {'name': 'frame ratio from the host\'s step', 'size': 0x9b4, 'fingerprints': ['6ae2aff5344d14568e4dbaf93455e2d8278384bf892ed6c6eca87fef98fbcd1d'], 'stub': frame_step,   # v131072 main+0x6e6be0
     'others': {'dynamic resolution': {'size': 0x294, 'fingerprints': ['7af6ceb0aedf8e0c17dc08ce17fcd6a7cba6d394a0d09e3b504c6d668dc418e7']},   # v131072 main+0x8065e0
                'dynamic resolution update': {'size': 0xb24, 'fingerprints': ['5a423697838976baf286cffa5e2ceef0d4e037abbcd9d371e90e9e702d61b3d4']},   # main+0x805aa0
                'half rate request': {'size': 0x938, 'fingerprints': ['cf27987b41456695ce0447d7b711f9a4f2d6424d4f3c04744252ca2cfb47dc2c']}}},   # main+0x650d00
]}

# Movie pictures: no cut. The movies are AV1 at 60 pictures a second (Event/Movie/*.webm, no sound track: the opening's Dm_Kokiri_0000 is 9,254 pictures, 154.2 s), and the
# player takes one picture a calc (main+0x3b5ca60 clamps to its limit at +0x20, 1 + (the creation argument >= 2) at main+0x3b5d084; the game passes 1). A cut that made the
# limit 2 (cinc w8,w28,ge → add w8,w28,#1) kept the picture's time at 33 fps on an iPhone (9,254 pictures in about 156 s, against 262 s) and left the subtitles behind it, which
# count calcs as the player did: worse to watch than a movie that is slow as a whole. The half rate above keeps both in step
BINDING = [
    {'what': 'wide view: output and render widths from the state page', 'now': 'build', 'goal': 'game', 'purpose': 'rendering',
     'why': "the game's own size constants, at fixed addresses of v131072; a function-matched rule could carry them over the game's updates"},
    {'what': 'half rate request: the game\'s own flag or the host\'s ask', 'now': 'game', 'goal': 'game', 'purpose': 'frame rate',
     'why': "the game's own half-rate request, found by its function's fingerprint on any build that keeps the function; switchable (DM_FPS_HALF_RATE)",
     'checked': 'v131072 main: one function with this fingerprint, the site, the request byte and the frame function that acts on it read by disassembly (2026-11-09)'},
    {'what': 'frame ratio from the host\'s step', 'now': 'game', 'goal': 'game', 'purpose': 'frame rate',
     'why': "the game's own frame-ratio division, found by its function's fingerprint on any build that keeps the function",
     'checked': 'v131072 main: one function with this fingerprint, the site and its free registers read by disassembly (2026-11-08)'},
    {'what': 'dynamic resolution: full size, or a climb on the load measured at each level', 'now': 'game', 'goal': 'game', 'purpose': 'rendering',
     'why': "the game's own dynamic-resolution level function and update, found by their functions' fingerprints on any build that keeps both; switchable (DM_DYNAMIC_RESOLUTION)",
     'checked': 'v131072 main: one function with each fingerprint (the level function a leaf, x2..x11 / x16 / x17 / s0..s2 free), its callers, the update and the controller fields read by disassembly, the fields read in play (2026-11-08); the climb run natively against a model of the update and in play to full size (2026-11-09)'},
]
