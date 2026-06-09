#!/usr/bin/env node
/*
 * Patch the vendored Fusseldieb bridge's half-duplex ducking.
 *
 * Stock behaviour (index.js attachHalfDuplexDucking):
 *   - TALK_DETECT(set)=250  -> near-default sensitivity; over a VPN/softphone the
 *     caller's background/comfort noise keeps tripping it.
 *   - on talk start: channels.mute(ext, 'in')   -> HARD MUTE of doorbell->caller
 *   - on talk stop:  channels.unmute(ext, 'in')
 *   Net effect: doorbell audio chops in and out -> "I can barely hear the door".
 *
 * Patched behaviour (still half-duplex, but gentle + "sticky" like a walkie-talkie):
 *   - TALK_DETECT threshold from env DUCK_TALK_THRESHOLD (default 500) -> engages on
 *     real speech; lower = more sensitive / clamps sooner on speech onset.
 *   - duck = attenuate audio sent TO the caller via VOLUME(TX) on the caller channel
 *     by DUCK_ATTEN_DB (default -5), instead of muting. You still hear the door.
 *   - un-duck = VOLUME(TX)=0, but only after DUCK_HOLD_MS (default 700, was a
 *     hard-coded 250) of detected silence -> stays clamped through the gaps between
 *     words/sentences so echo can't burst through the open windows.
 *
 * Idempotent: re-running detects the patch markers and no-ops.
 */
const fs = require('fs');

const file = process.argv[2] || '/app/index.js';
let s = fs.readFileSync(file, 'utf8');

if (s.includes('/* DUCK_PATCH */')) {
  console.log('duck patch already applied — skipping');
  process.exit(0);
}

const repl = [
  // 1) Env-tunable talk-detect threshold (was a hard-coded '250').
  [
    "value: '250',",
    "value: (process.env.DUCK_TALK_THRESHOLD || '500'), /* DUCK_PATCH */",
  ],
  // 2) Duck ON: soft attenuate the caller's downlink instead of hard-muting it.
  [
    "client.channels.mute({ channelId: s.ext.id, direction: 'in' }).catch(() => { });",
    "client.channels.setChannelVar({ channelId: winnerChannel.id, variable: 'VOLUME(TX)', value: (process.env.DUCK_ATTEN_DB || '-5') }).catch(() => { }); /* DUCK_PATCH */",
  ],
  // 3) Duck OFF: restore full volume (first occurrence = onTalkStop handler).
  [
    "client.channels.unmute({ channelId: s.ext.id, direction: 'in' }).catch(() => { });",
    "client.channels.setChannelVar({ channelId: winnerChannel.id, variable: 'VOLUME(TX)', value: '0' }).catch(() => { }); /* DUCK_PATCH */",
  ],
  // 4) Un-duck HOLD: keep ducked for DUCK_HOLD_MS after talk stops (was 250ms), so
  //    short pauses between words don't snap the doorbell back to full volume and
  //    leak echo. The `}, 250);` is unique to the un-duck setTimeout (verified).
  [
    "}, 250);",
    "}, Number(process.env.DUCK_HOLD_MS || 700));",
  ],
];

for (const [from, to] of repl) {
  if (!s.includes(from)) {
    console.error('PATCH FAILED: expected snippet not found:\n  ' + from);
    process.exit(1);
  }
  s = s.replace(from, to); // first occurrence only — intentional for #3
}

fs.writeFileSync(file, s);
console.log('duck patch applied');
