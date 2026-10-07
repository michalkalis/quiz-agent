# #191 — Hranie na pozadí (zamknutý displej, navigácia navrchu)

**Triage:** enhancement · needs-info (founder 2026-10-07: až po prvom App Store release)

## Dnešný stav

- Otázky a hodnotenie sa na pozadí prečítajú (background audio mode).
- Mikrofón sa pri odchode z appky zámerne vypína (`QuizViewModel+ScenePhase.swift`, oprava „mic stayed hot“ z 2026-07-11). Odpočty bežia ďalej; po návrate sa otvorí okno odpovede alebo sa otázka uzavrie (#171 Track H).
- Appka počas kvízu drží displej zapnutý (`ScreenAwakeController`, #108C), čiže počíta s tým, že je navrchu.

## Smer

1. **Mikrofón bežiaci celý kvíz.** iOS nedovolí mikrofón na pozadí *zapnúť*, len v nahrávaní *pokračovať*. Vstup sa musí spustiť v popredí a počas kvízu sa nevypína. Systémový indikátor nahrávania bude svietiť (čo je férové). Nahrádza to dnešné zámerné vypínanie, takže súkromie treba vyriešiť inak: mikrofón len počas aktívneho kvízu, nikdy na domovskej obrazovke ani po skončení.
2. **Súbeh s navigáciou.** Hlasové pokyny navigácie prerušia našu audio session. Dnes prerušenie zahodí rozbehnutú odpoveď (#67). Treba zvoliť: počkať a pokračovať, alebo otázku zopakovať.
3. **Rozpoznávanie reči na pozadí** (SpeechAnalyzer povely + batch STT) je NEOVERENÉ, najväčšia neznáma.
4. Voliteľne: Live Activity (otázka + odpočet na zamknutej obrazovke).
5. Voliteľne: **CarPlay**, kategória hlasových konverzačných appiek od iOS 26.4 (entitlement `com.apple.developer.carplay-voice-based-conversation`, Apple schvaľuje každú žiadosť zvlášť). Či by kvíz prešiel, je neoverené. Súvisí s #187 (tlačidlá na volante).

## Prvý krok po launchi

Spike na reálnom telefóne: spustiť kvíz → zamknúť displej / otvoriť Mapy s navigáciou → overiť, či povely aj odpovede prejdú. Až podľa výsledku navrhnúť celé riešenie.

## Zdroje

- CarPlay iOS 26.4: https://macrumors.com/2026/02/18/ios-26-4-carplay-support
- Mikrofón na pozadí: https://developer.apple.com/forums/thread/674632 · https://developer.apple.com/forums/thread/120038?page=4
