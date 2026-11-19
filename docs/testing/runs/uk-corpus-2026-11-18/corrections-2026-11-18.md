# #231 batch 1 (186 uk questions in prod) — corrections decided after the independent review

IDs are prefixes of the question UUID. Source file: docs/testing/runs/uk-corpus-2026-11-18/merged-uk.json.

## Reject (duplicate fact / answer given away by a sibling / fragile)
- 651bb3fd — same "Лісова пісня written in Kutaisi" fact as 4e51335d; each question gives away the other's answer. Keep 4e51335d.
- 1cd26d88 — Baiul 1994 gold; 816408eb states it. Keep 816408eb.
- 43dd5026 — Paton bridge welded; 6bf36e1f says the Paton institute is known for welding. Keep 6bf36e1f.
- 2830029d — Orlyk constitution in Bendery; same fact as 94f572f8, mutual spoilers. Keep 94f572f8.

## Hold for a human (pending review, TestFlight only)
- d06550b7 — answer is the bare letter «Ї»; fragile for speech recognition. Native speaker tries it.
- 52b2184c — authentic 11th-century signature «АНА РЪИНА» contains ъ; already held. Leave.

## Text fixes (keep approved if the gates pass afterwards)
- aa7fd8c6 question: «…про трьох козаків, що варили куліш і грали у футбол, двох героїв…» → «…про трьох козаків, що грали у футбол і рятували наречених, двох героїв…» (stops giving away 79b7b17a's answer «Куліш»).
- ce82ec2f explanation: «…і закордонні мандрівники часто ставлять їх поруч зі станціями Москви та Стокгольма.» → «…і закордонні мандрівники часто згадують їх серед найкрасивіших станцій метро у світі.»
- 700051b8 explanation: «мумифікувалися» → «муміфікувалися».
- 80025f4c explanation: «Каспійське море тут не рахується» → «Каспійське море тут не враховують».
- 9eeff437 question: «у третьому найвищий суд» → «у третьому Верховний апеляційний суд».
- 19534368 question: «стріла завдовжки майже метр» → length as stated on the cited page (https://en.wikipedia.org/wiki/Pfeilstorch); verify the number on the page first and write it in words that read well aloud.
- 410481cf question: «першим і єдиним коронованим королем Русі» → «першим королем Русі».

## Alternative answers: remove Russian forms
- b415b52b: remove «Вена». 0ff64b23: remove «Борщев». dbbb2343: remove «Запорожжя». 53682a03: remove «Меланин». b1d9c38d: remove «папоротник».
- 483aa3e0: remove bare «Буг» (it also matches the Western Bug).

## Sources: replace (URL and excerpt must support the fact; verify the page exists and says it)
- b1d9c38d: gw2ru.com (Russian state promo site) → Ukrainian Wikipedia article on the fern flower legend / ferns.
- cec42442: kino.mail.ru → Ukrainian Wikipedia article on the cartoon «Капітошка».
- 7631de88: gufo.me (Vasmer's Russian etymological dictionary) → a Ukrainian or English source for the Persian origin of «базар» (e.g. Wikipedia / Wiktionary).
- d7dc05e7: Artemis program page → article on Yuriy Kondratyuk / lunar orbit rendezvous.
- 2dd29bde: Bruce Vilanch page → Jack Palance article (one-armed push-ups at the 1992 Oscars).
- 5b9c2c17: IMDb → Serhiy Bubka article (one Olympic gold, Seoul 1988).
