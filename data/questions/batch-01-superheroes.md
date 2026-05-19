# Batch 01 — Superheroes Category
**Generated:** 2026-05-19  
**Model:** claude-opus-4-7  
**Pipeline:** claude_code_session (manual gen → manual verify → score)  
**Source file:** data/generated/claude_batch_034.json  
**Scored file:** data/scored/scored_2026-05-19_superheroes_batch034.json

## Summary
- Generated: 14 candidates
- Dropped during generation: 4 (score < 8.0 on engagement dimensions)
- Verified: 10 — all correct; spot-checked 3 numeric/historical claims via WebFetch (Stan Lee 1989 cameo, Watchmen on Time 100, Death of Superman sales); corrected Q8 phrasing "in a week" → accurate "shipped 2.5M day one, ultimately 6M+" before import
- Scored: 10 — 8 approve (≥8.0), 2 revise (Watchmen flat framing, Marvel rebrand hard to retell)
- **Approved: 8 questions** → local ChromaDB (0 duplicates)
- Drop rate: 43% (6 of 14 dropped at generation+scoring+revise stages)
- **Local ChromaDB after import: 34 superheroes (target 30 — EXCEEDED)**

---

## Approved Questions

### q_13988b7e5720 — Score 8.8 ✓
**Q:** The first description of Superman's powers in 1938 didn't include flight — comics said he could 'leap tall buildings in a single bound.' Flight was added in 1941 because animators making the first Superman cartoons found jumping awkward to draw. True or false?  
**A:** True  
**Alt answers:** true, yes, correct  
**Topic:** Superheroes | **Difficulty:** medium | **Tags:** superman, comic-origins, behind-the-scenes  
**Source URL:** https://en.wikipedia.org/wiki/Superman  
**Source excerpt:** Superman's early adventures of the 1930s and 1940s saw him simply leap great distances rather than fly. Flight was introduced by Fleischer Studios' 1941 animated shorts.

---

### q_f3c5962e2899 — Score 8.6 ✓
**Q:** For decades only one name appeared as Batman's creator on every comic, film, and TV show — yet a writer named Bill Finger actually invented the cowl, cape, secret identity, and even the name Bruce Wayne. Whose name was officially credited alone until 2015?  
**A:** Bob Kane  
**Alt answers:** bob kane, robert kane, robert kahn  
**Topic:** Comic Creators | **Difficulty:** hard | **Tags:** batman, comic-creators, behind-the-scenes  
**Source URL:** https://en.wikipedia.org/wiki/Bill_Finger  
**Source excerpt:** Bill Finger was the uncredited co-creator of Batman. DC finally added 'Batman created by Bob Kane with Bill Finger' starting with Gotham (2014) and Batman v Superman (2016).

---

### q_4aa781f18458 — Score 8.4 ✓
**Q:** Stan Lee's publisher Martin Goodman initially rejected Spider-Man in 1962 with three objections: nobody likes spiders, teenagers can only be sidekicks, and people don't want personal problems in superhero stories. Spider-Man only got published when Lee buried him in the final issue of which doomed Marvel series in 1962?  
**A:** Amazing Fantasy  
**Alt answers:** amazing fantasy, amazing fantasy #15, amazing adult fantasy  
**Topic:** Marvel | **Difficulty:** hard | **Tags:** spider-man, marvel-history, origin-stories  
**Source URL:** https://en.wikipedia.org/wiki/Amazing_Fantasy  
**Source excerpt:** Spider-Man's first appearance was in Amazing Fantasy #15 (August 1962), the final issue of an anthology series slated for cancellation.

---

### q_3ad3f83998c1 — Score 8.4 ✓
**Q:** The line that ended the very first Marvel Cinematic Universe film — 'I am Iron Man,' breaking decades of secret-identity tradition in superhero stories — wasn't in the script. Robert Downey Jr. ad-libbed it on set, and director Jon Favreau fought Marvel executives to keep it in the final cut. True or false?  
**A:** True  
**Alt answers:** true, yes, correct  
**Topic:** MCU | **Difficulty:** easy | **Tags:** iron-man, mcu, improv  
**Source URL:** https://en.wikipedia.org/wiki/Iron_Man_(2008_film)  
**Source excerpt:** The film's final line, 'I am Iron Man,' was improvised by Robert Downey Jr. and kept in the final cut at Favreau's insistence.

---

### q_d185ee4c2cba — Score 8.2 ✓
**Q:** In 1954 a psychiatrist named Fredric Wertham published a moral-panic bestseller arguing comics were turning kids into criminals — Batman and Robin promoted homosexuality, Wonder Woman promoted bondage. The book triggered government hearings and forced the comics industry to self-censor under the 'Comics Code Authority' for decades. What was the book called?  
**A:** Seduction of the Innocent  
**Alt answers:** seduction of the innocent, seduction of innocent  
**Topic:** Comics History | **Difficulty:** hard | **Tags:** comics-history, censorship, comics-code  
**Source URL:** https://en.wikipedia.org/wiki/Seduction_of_the_Innocent  
**Source excerpt:** Seduction of the Innocent (1954) by Fredric Wertham contributed to a moral panic that led publishers to adopt the self-censoring Comics Code Authority.

---

### q_64552d7277d2 — Score 8.2 ✓
**Q:** Stan Lee appeared in every Marvel Cinematic Universe film from Iron Man (2008) until his death in 2018 — but his very first on-screen cameo was in a 1989 TV movie where he played a stern-faced juror sitting in the jury box. Which superhero was on trial?  
**A:** The Incredible Hulk  
**Alt answers:** incredible hulk, hulk, the hulk, bruce banner  
**Topic:** Marvel | **Difficulty:** hard | **Tags:** stan-lee, hulk, behind-the-scenes  
**Source URL:** https://en.wikipedia.org/wiki/The_Trial_of_the_Incredible_Hulk  
**Source excerpt:** Stan Lee made a cameo appearance as the jury foreman in the dream sequence of The Trial of the Incredible Hulk (1989).

---

### q_9609f9af2893 — Score 8.0 ✓
**Q:** DC's original Captain Marvel — a kid who shouts a magic word and turns into a caped superhero — outsold Superman comics in the 1940s. After Marvel Comics trademarked the name 'Captain Marvel' in 1967, DC could still publish the character but had to use the magic word itself as the title on every cover. What's the word?  
**A:** Shazam  
**Alt answers:** shazam, shazam!  
**Topic:** Superheroes | **Difficulty:** medium | **Tags:** captain-marvel, shazam, comics-history  
**Source URL:** https://en.wikipedia.org/wiki/Captain_Marvel_(DC_Comics)  
**Source excerpt:** DC Comics could not use the name 'Captain Marvel' on the cover of any product, since Marvel Comics had trademarked the name in 1967. DC titled its original Captain Marvel comic Shazam! starting 1973.

---

### q_4f9e2dda4611 — Score 8.0 ✓
**Q:** In late 1992 DC Comics shipped 2.5 million copies of a single issue on day one and ultimately sold over 6 million — making it the bestselling comic of the year. The cover was solid black, broken only by one torn red symbol. What was the event inside?  
**A:** The Death of Superman  
**Alt answers:** death of superman, superman's death, death of superman by doomsday, superman dies  
**Topic:** DC | **Difficulty:** medium | **Tags:** superman, dc, comic-records  
**Source URL:** https://en.wikipedia.org/wiki/The_Death_of_Superman  
**Source excerpt:** The issue brought in $30 million on its first day and ultimately sold more than six million copies, making it the bestselling comic of 1992.

---

## Revise (not imported)

### q_034_07 — Score 7.4 → revise
**Q:** Alan Moore's 1986–87 limited series became the only graphic novel ever named to Time Magazine's list of the 100 best English-language novels since 1923...  
**Issue:** Flat ending ("What's the series called?") — Watchmen as title lookup too straightforward. Consider reformulating around the milestone itself.

### q_034_09 — Score 7.4 → revise
**Q:** Marvel Comics didn't start as 'Marvel.' The company was called Timely Comics from 1939 then Atlas Comics in the 1950s...  
**Issue:** Three company names hard to retell; "which title" ending plain. Consider anchoring on the specific business reason for the rebrand.
