// The reel marks the MCQ option the voice is reading. If an option's start is
// timed wrong, the viewer sees option B marked while the voice still reads A
// (the 2026-W45 Czech panelák reel). Real whisper output for that clip: number
// words came back as digits ("Dva: Asi třetina" → "2, asi 3").
import assert from 'node:assert/strict';
import {test} from 'node:test';
import {alignTimes, type Spoken} from './align';

const TEXT = 'Zhruba jaká část obyvatel Česka dnes bydlí v panelácích? Jedna: Asi desetina. Dva: Asi třetina. Tři: Asi polovina. Čtyři: Asi dvě třetiny.';
const TOKENS: [string, number, number][] = [["�",60,70],["�",70,140],["r",140,210],["uba",210,420],[",",420,550],["jak",550,920],["á",920,990],["č",990,1060],["ást",1060,1350],["ob",1350,1490],["iv",1490,1630],["at",1630,1780],["el",1780,1910],["č",1910,2050],["es",2050,2190],["ka",2190,2330],["d",2330,2390],["nes",2390,2620],["b",2620,2680],["yd",2680,2820],["l",2820,2890],["í",2890,3020],["v",3020,3100],["panel",3100,3490],["á",3490,3600],["ci",3600,3740],["ích",3740,4030],[".",4030,4400],["Jed",4400,4900],["na",4900,5070],[",",5070,5740],["asi",5740,5780],["10",5780,6550],[",",6550,7150],["2",7150,7220],[",",7220,7480],["asi",7480,7940],["3",7940,8290],[",",8290,8560],["3",8560,9230],[",",9230,9310],["asi",9310,10030],["pol",10030,10100],["ov",10100,10300],["ina",10300,10700],[",",10700,10950],["4",10950,11470],[",",11470,11640],["asi",11640,12380],["2",12380,12440],[",",12440,12710],["3",12710,13110],[".",13110,13600]];
const spoken: Spoken[] = TOKENS.map(([text, startMs, endMs]) => ({text, startMs, endMs}));

test('each option is marked from the moment the voice says its label', () => {
	const labels = ['Jedna:', 'Dva:', 'Tři:', 'Čtyři:'].map((l) => TEXT.indexOf(l));
	// Label starts in the transcript: "Jed" 4400, "2" 7150, the second "3" 8560 (the first is "třetina"), "4" 10950.
	assert.deepEqual(alignTimes(TEXT, spoken, labels, 'cs'), [4400, 7150, 8560, 10950]);
});

test('the last option stops being marked when the voice stops', () => {
	assert.deepEqual(alignTimes(TEXT, spoken, [TEXT.length], 'cs'), [13600]);
});
