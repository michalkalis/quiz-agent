// The social videos' own voice (founder 2026-11-18): the app voice (George, for Czech Josef)
// on ElevenLabs Flash v2.5, natively faster than the app (en 1.15, sk/cs 1.1;
// an artificial speed-up sounded robotic). Same texts the app reads, made
// here, cached locally by text + voice settings, never written to the app's R2.
import {execFileSync, spawnSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {existsSync, mkdirSync, readFileSync, rmSync, statSync, writeFileSync} from 'node:fs';
import path from 'node:path';
import type {Language} from '../src/types';
import {CACHE_DIR} from './paths';

/** The app's voice per language: George, and for Czech Josef, a native Czech voice
 * (founder 2026-11-19: George reading Czech sounds foreign). Same ids as the app's
 * apps/quiz-agent/app/tts/voices.py. */
export const VOICE_ID: Record<Language, string> = {en: 'JBFqnCBsd6RMkjVDRZzb', sk: 'JBFqnCBsd6RMkjVDRZzb', cs: 'RxVyXZsJK1kay0fTKgd2'};
export const VOICE_MODEL = 'eleven_flash_v2_5'; // honours voice_settings.speed (v4 Turbo ignores it)
/** Founder 2026-11-18: "na socials davaj anglictinu 1,15x, sk a cz 1,1x". */
export const VOICE_SPEED: Record<Language, number> = {en: 1.15, sk: 1.1, cs: 1.1};
// The app's loudness step (apps/quiz-agent/app/tts/service.py boost_volume):
// peak to -0.5 dBFS, then +3 dB more, so the reels sound as loud as the app.
const TARGET_PEAK_DB = -0.5;
const EXTRA_BOOST_DB = 3;

const settingsFor = (language: Language) => ({
	model_id: VOICE_MODEL,
	voice_settings: {speed: VOICE_SPEED[language]},
	// The app spells numbers out for sk/cs already; the code keeps the voice
	// from guessing the language off a first foreign word.
	...(language === 'en' ? {} : {language_code: language}),
});

const cacheFile = (text: string, language: Language) =>
	path.join(CACHE_DIR, 'voice', `${createHash('sha1').update(JSON.stringify([VOICE_ID[language], settingsFor(language), text])).digest('hex')}.mp3`);

/** A cached clip counts only when it has bytes: a write cut short (a full disk, 2026-11-19) leaves an
 * empty file, and taking it as a hit renders a reel whose question is silent. */
export const usableClip = (file: string) => existsSync(file) && statSync(file).size > 0;

/** Whether `text` is already voiced (a cache hit costs nothing, so the weekly cap does not apply). */
export const hasClip = (text: string, language: Language) => usableClip(cacheFile(text, language));

/** A clip of `text` in the social voice: from the cache, or made now (`made` = billed characters, 0 on a hit). */
export async function ownClip(text: string, language: Language): Promise<{bytes: Buffer; made: number}> {
	const file = cacheFile(text, language);
	if (usableClip(file)) return {bytes: readFileSync(file), made: 0};
	const key = process.env.ELEVENLABS_API_KEY;
	if (!key) throw new Error('ELEVENLABS_API_KEY is not set (load the root .env), or pass --app-clips');
	const res = await fetch(`https://api.elevenlabs.io/v1/text-to-speech/${VOICE_ID[language]}?output_format=mp3_44100_128`, {
		method: 'POST',
		headers: {'xi-api-key': key, 'Content-Type': 'application/json'},
		body: JSON.stringify({text, ...settingsFor(language)}),
	});
	if (!res.ok) throw new Error(`ElevenLabs ${res.status}: ${(await res.text()).slice(0, 300)}`);
	mkdirSync(path.dirname(file), {recursive: true});
	const raw = file.replace(/\.mp3$/, '.raw.mp3');
	try {
		writeFileSync(raw, Buffer.from(await res.arrayBuffer()));
		boost(raw, file);
	} catch (e) {
		rmSync(file, {force: true});
		throw e;
	}
	return {bytes: readFileSync(file), made: text.length};
}

function boost(src: string, dst: string) {
	// ffmpeg prints the volumedetect result on stderr.
	const log = spawnSync('ffmpeg', ['-hide_banner', '-i', src, '-af', 'volumedetect', '-f', 'null', '-']).stderr.toString();
	const peak = Number(/max_volume: (-?[\d.]+) dB/.exec(log)?.[1] ?? NaN);
	if (Number.isNaN(peak)) throw new Error(`no peak level measured on ${src}`);
	const gain = TARGET_PEAK_DB - peak + EXTRA_BOOST_DB;
	execFileSync('ffmpeg', ['-y', '-loglevel', 'error', '-i', src, '-af', `volume=${gain.toFixed(2)}dB`, '-b:a', '128k', dst]);
}
