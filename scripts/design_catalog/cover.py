"""The catalog cover (components/Cover/preview.html), drawn only from tokens."""

from __future__ import annotations

USED = ("action", "ink", "blue", "liveAccent", "accentPrimary", "bg", "muted", "radius-cta", "radius-card")


def cover_html(tokens: dict) -> str:
    names = {t["name"] for fam in ("color", "radius") for t in tokens[fam]["tokens"]}
    missing = [n for n in USED if n not in names]
    if missing:
        raise ValueError(f"cover uses tokens that no longer exist: {missing}")
    # Six level-meter pills cut out of the pink slab: the app listens, so its
    # mark is a voice level. Heights are a fixed rhythm, not data.
    pills = "".join(
        f'<rect class="ground" x="{560 + i * 24}" y="{144 - h // 2}" width="12" height="{h}" rx="6"/>' for i, h in enumerate((48, 96, 144, 80, 120, 56))
    )
    return f"""<!-- @dsCard height=288 -->
<div class="cover">
<style>
.cover{{position:relative;width:960px;height:288px;background:var(--bg);overflow:hidden}}
.cover svg{{position:absolute;inset:0}}
.cover .pink{{fill:var(--action)}} .cover .ink{{fill:var(--ink)}} .cover .blue{{fill:var(--blue)}}
.cover .teal{{fill:var(--liveAccent)}} .cover .violet{{fill:var(--accentPrimary)}} .cover .ground{{fill:var(--bg)}}
.cover .r-cta{{rx:var(--radius-cta)}} .cover .r-card{{rx:var(--radius-card)}}
.cover .name{{position:absolute;left:48px;bottom:56px;max-width:440px;margin:0;font-family:var(--font-display);font-size:120px;line-height:.92;color:var(--ink);font-weight:400}}
.cover .tag{{position:absolute;left:50px;bottom:28px;max-width:440px;margin:0;font-family:var(--font-body);font-size:14px;color:var(--muted)}}
</style>
<svg width="960" height="288" viewBox="0 0 960 288" aria-hidden="true">
<!-- blocks: pink 192x320 slab (brand, primary action), blue 192x112 (secondary), teal 96x96 disc (listening), violet 80x96 (selection), ink 192x48 pill bleeding off the bottom
     arrangement: one tall pink slab bleeding off top and bottom, satellites stacked to its right on a 16px gap
     pattern: pills, because the system is soft with large radii (radius-cta 32) and voice-first: six level-meter pills cut from the slab
     scales: space-md 16 gaps, radius-cta on slab and pill, radius-card on tiles, pills rx = half width -->
<rect class="pink r-cta" x="528" y="-32" width="192" height="352"/>
{pills}
<rect class="blue r-card" x="736" y="24" width="192" height="112"/>
<rect class="teal" x="736" y="152" width="96" height="96" rx="48"/>
<rect class="violet r-card" x="848" y="152" width="80" height="96"/>
<rect class="ink r-cta" x="736" y="264" width="192" height="48"/>
</svg>
<p class="name">Trubbo</p>
<p class="tag">Hands-free trivia, read at a glance and played by voice.</p>
</div>
"""
