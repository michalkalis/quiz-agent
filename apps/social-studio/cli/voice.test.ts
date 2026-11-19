import assert from 'node:assert/strict';
import {mkdtempSync, writeFileSync} from 'node:fs';
import {tmpdir} from 'node:os';
import path from 'node:path';
import {test} from 'node:test';
import {usableClip} from './voice';

// An empty clip left by a failed write must count as missing, so the next render makes it
// again instead of publishing a reel whose question has no voice (2026-11-19).
test('an empty cached clip is not a hit', () => {
	const dir = mkdtempSync(path.join(tmpdir(), 'voice-'));
	const empty = path.join(dir, 'empty.mp3');
	writeFileSync(empty, '');
	assert.equal(usableClip(empty), false);
	assert.equal(usableClip(path.join(dir, 'missing.mp3')), false);
	const real = path.join(dir, 'real.mp3');
	writeFileSync(real, Buffer.from([0xff, 0xfb, 0x90]));
	assert.equal(usableClip(real), true);
});
