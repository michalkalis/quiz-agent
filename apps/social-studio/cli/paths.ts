import path from 'node:path';
import {fileURLToPath} from 'node:url';

export const APP_DIR = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
/** whisper.cpp + model + fetched rows/clips. Gitignored. */
export const CACHE_DIR = path.join(APP_DIR, '.cache');
/** Clips are copied here so the composition can load them via staticFile. Gitignored. */
export const PUBLIC_AUDIO_DIR = path.join(APP_DIR, 'public', 'audio');
