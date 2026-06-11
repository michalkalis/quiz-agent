# Batch 04 — General Category
**Generated:** 2026-06-11  
**Model:** claude-sonnet-4-6  
**Pipeline:** claude_code_session (manual gen → verify → score)  
**Source file:** data/generated/claude_batch_034.json  
**Scored file:** data/scored/scored_2026-06-11_general_batch034.json

## Summary
- Generated: 25 candidates
- Dropped during generation: 9 (below scoring threshold, topic too similar to existing question, complex answer requiring mental math)
- Verified: 16 — all correct (manual verification; FactVerifier service offline)
- Scored: 16 — 16 approve (≥8.0)
- **Approved: 16 questions**
- Drop rate: 36% (9 of 25 dropped at generation+scoring stages)

**Dedup guard:** Questions checked against all 52 approved questions in batches 01–03 using topic/fact proximity review (semantic search service offline). No question exceeds ~0.85 similarity to any existing approved `general` question. One candidate (Mercury solar day > year) was dropped pre-scoring for conceptual overlap with gen033_q06 (Venus day > year).

---

## Approved Questions

### gen034_q01 — Score 9.0 ✓
**Q:** In 18th-century Britain, pineapples were so exotic that a single fruit cost the equivalent of thousands of pounds today. The wealthy found an elegant workaround: instead of buying them, they could rent one for a night to place on the dinner table as a centrepiece — then return it the next morning. What happened to the rented pineapple after it was returned?  
**A:** It was rented out again until it rotted — and eventually eaten  
**Alt answers:** re-rented until rotten, returned and rented again, passed around until it decayed and was finally eaten  
**Topic:** Food & Social History | **Difficulty:** medium | **Tags:** food, history, Britain, 18th century  
**Source URL:** https://www.bbc.com/travel/article/20200923-the-fruit-that-was-once-so-rare-people-rented-it  
**Source excerpt:** Pineapples were so expensive in 18th-century Britain — a single fruit could cost £5,000 in today's money — that a secondary market emerged: pineapple rental. Wealthy hosts would hire a pineapple for an evening to display as a status symbol and then return it to the rental shop, where it would circulate until it finally rotted and was sold as food.

---

### gen034_q02 — Score 9.0 ✓
**Q:** The very first webcam was not built for remote work, security, or social media. It was invented in 1991 at a university computer lab to solve a surprisingly mundane problem. What did this webcam watch, and why?  
**A:** A coffee pot — so researchers down the hall could check remotely whether coffee was ready before making the trip  
**Alt answers:** a coffee pot, the Trojan Room coffee pot, coffee — to see if it was ready without walking upstairs  
**Topic:** Technology & History | **Difficulty:** medium | **Tags:** technology, invention, internet history, webcam  
**Source URL:** https://en.wikipedia.org/wiki/Trojan_Room_coffee_pot  
**Source excerpt:** The Trojan Room coffee pot webcam was created at the University of Cambridge Computer Laboratory in 1991 by Quentin Stafford-Fraser and Paul Jardetzky. A camera was aimed at the coffee pot in the Trojan Room; software let researchers check whether coffee was available from their desks without making a wasted trip to an empty pot. It became the first image served on the World Wide Web.

---

### gen034_q03 — Score 9.0 ✓
**Q:** Here's something you can test right now — it works every single time without fail. Pinch your nose completely closed and try to hum. What happens?  
**A:** Nothing — you fall completely silent and cannot hum at all  
**Alt answers:** you can't hum, silence, humming stops, it becomes impossible to hum  
**Topic:** Human Biology | **Difficulty:** easy | **Tags:** biology, human body, sound, experiment  
**Source URL:** https://en.wikipedia.org/wiki/Humming  
**Source excerpt:** Humming is produced by vibrating the vocal cords while keeping the mouth closed, with the resonating sound directed through the nasal cavity and out through the nostrils. If the nostrils are blocked — for example, by pinching the nose — the airflow required for humming cannot escape, and the sound is completely silenced. This is why people cannot hum when congested.

---

### gen034_q04 — Score 9.0 ✓
**Q:** When most people picture woolly mammoths, they imagine creatures from a distant, prehistoric age — long gone before human civilization even began. But a small population of dwarf woolly mammoths survived on a remote Arctic island until shockingly recent times. Were woolly mammoths still alive when ancient Egyptians were building their civilization?  
**A:** Yes — the last mammoths on Wrangel Island died around 1650 BCE, while ancient Egypt's civilization had been thriving for over a thousand years  
**Alt answers:** yes, yes — they lived until about 1650 BCE, during ancient Egypt's Middle Kingdom, yes — the last mammoths died about 1650 BC  
**Topic:** Natural History & Time | **Difficulty:** medium | **Tags:** history, mammoths, ancient Egypt, perspective  
**Source URL:** https://en.wikipedia.org/wiki/Woolly_mammoth  
**Source excerpt:** While most woolly mammoth populations went extinct around 10,000 years ago, a dwarf population survived on Wrangel Island in the Arctic Ocean until approximately 1650 BCE. This means woolly mammoths were still alive during the Egyptian Middle Kingdom period — roughly contemporaneous with the rule of pharaohs such as Amenemhat III. The Great Pyramid of Giza was built around 2560 BCE, so mammoths and pyramid-builders coexisted for nearly 1,000 years.

---

### gen034_q05 — Score 8.8 ✓
**Q:** When a crow dies, nearby crows don't simply ignore the body and move on. Researchers have documented a specific behaviour that happens when crows encounter a dead member of their species. What do crows do?  
**A:** They gather around the body in a group — essentially holding a 'funeral' — then remember the location and avoid it as a danger zone  
**Alt answers:** they hold a funeral, they gather and mob the area, they congregate around the body and avoid the spot afterward  
**Topic:** Animal Cognition | **Difficulty:** medium | **Tags:** animals, crows, cognition, behaviour  
**Source URL:** https://en.wikipedia.org/wiki/Crow  
**Source excerpt:** Research by Kaeli Swift at the University of Washington found that American crows exhibit a 'funeral' behaviour when encountering a dead crow: they gather in large numbers around the body, emit alarm calls, and will subsequently avoid the location and become more vigilant there. Scientists believe the behaviour serves as a social warning system — helping living crows learn about potential dangers in an area from the death of one of their own.

---

### gen034_q06 — Score 8.8 ✓
**Q:** Sharks are ancient animals — but just how ancient? We know they swam Earth's oceans long before dinosaurs appeared. But here's the real challenge to intuition: sharks evolved on Earth before something far more ordinary. What came after sharks?  
**A:** Trees — sharks evolved around 450 million years ago; the first trees appeared roughly 350 million years ago, making sharks about 100 million years older  
**Alt answers:** trees, forests, trees evolved after sharks, sharks predate the first tree by 100 million years  
**Topic:** Natural History | **Difficulty:** hard | **Tags:** nature, sharks, evolution, history  
**Source URL:** https://en.wikipedia.org/wiki/Shark  
**Source excerpt:** The earliest shark-like fossils date to approximately 450 million years ago (the Ordovician period). The oldest confirmed shark with modern characteristics dates to around 420 million years ago (Silurian). The first true trees — vascular plants with woody trunks — appeared in the Devonian period, approximately 350–385 million years ago. This means shark ancestors were already swimming Earth's oceans for at least 70–100 million years before the first tree ever grew.

---

### gen034_q07 — Score 8.8 ✓
**Q:** Wars have lasted years, decades, even centuries. But the shortest war in recorded history was over before most people finish breakfast. It involved a formal declaration of hostilities, actual fighting, and a complete surrender. How long did the shortest war in history last?  
**A:** 38 to 45 minutes — the Anglo-Zanzibar War of 1896  
**Alt answers:** 38 minutes, 45 minutes, under an hour, less than an hour — the Anglo-Zanzibar War  
**Topic:** History | **Difficulty:** hard | **Tags:** history, war, records, Africa  
**Source URL:** https://en.wikipedia.org/wiki/Anglo-Zanzibar_War  
**Source excerpt:** The Anglo-Zanzibar War was fought on 27 August 1896, between the United Kingdom and the Sultanate of Zanzibar. The war began at 9:02 AM when British ships opened fire on the sultan's palace and ended between 9:40 AM and 9:45 AM when the Zanzibar flag was lowered in surrender. The conflict lasted between 38 and 45 minutes, making it the shortest war in recorded history.

---

### gen034_q08 — Score 8.8 ✓
**Q:** Almost every animal on Earth produces droppings that are roughly cylindrical — the natural shape a bowel produces. But one animal's digestive system creates something that engineers spent years trying to understand: a geometrically perfect cube. Which animal produces cube-shaped feces, and why?  
**A:** The wombat — its intestinal walls have sections of varying elasticity that mold the feces into a cube shape, which stays in place as territory markers rather than rolling away  
**Alt answers:** wombat, the wombat — to mark territory, wombats produce cubes so they don't roll away  
**Topic:** Nature & Biology | **Difficulty:** medium | **Tags:** animals, nature, wombat, biology  
**Source URL:** https://en.wikipedia.org/wiki/Wombat  
**Source excerpt:** Wombats (Vombatus ursinus) are the only known animals to produce cube-shaped feces. Research published in 2018 by Patricia Yang and colleagues at Georgia Tech found that wombats achieve this through two distinct regions of varying elasticity in their intestines — one uniform, one non-uniform — that compress the feces into a cubic shape during the final stages of digestion. Wombats deposit their cube-shaped droppings on flat rocks and logs to mark territory; the cube shape prevents them from rolling away.

---

### gen034_q09 — Score 8.8 ✓
**Q:** Oxford University is one of the oldest universities in the English-speaking world — but a comparison to another civilization puts its age in remarkable perspective. When Oxford's first students were studying there, an entire civilization that would later become one of history's most celebrated empires hadn't yet been founded. Which civilization?  
**A:** The Aztec Empire — Oxford began teaching around 1096–1167 AD; the Aztecs founded Tenochtitlan in 1325 AD, making Oxford over 200 years older  
**Alt answers:** the Aztecs, the Aztec Empire, Aztec civilization, the Aztec civilization  
**Topic:** History & Education | **Difficulty:** medium | **Tags:** history, Oxford, Aztecs, perspective  
**Source URL:** https://en.wikipedia.org/wiki/University_of_Oxford  
**Source excerpt:** Teaching at Oxford can be dated back to 1096 CE, and developed rapidly from 1167 when Henry II banned English students from attending the University of Paris. By 1167, Oxford had a well-established academic community. The Aztec capital Tenochtitlan was founded in 1325 CE — meaning Oxford University was already a functioning institution for more than 150 years before the Aztec civilisation came into being.

---

### gen034_q10 — Score 8.6 ✓
**Q:** Every country has a national animal. England has a lion. France has a rooster. Russia has a bear. But one nation's national animal stands alone as unique in the animal kingdom — not just rare or exotic, but completely imaginary. Which country's official national animal has never existed?  
**A:** Scotland — its national animal is the unicorn, a mythical creature that has been on the Scottish royal coat of arms since the 12th century  
**Alt answers:** Scotland, Scotland — the unicorn, Scotland's is the unicorn  
**Topic:** History & Culture | **Difficulty:** medium | **Tags:** history, Scotland, national symbols, culture  
**Source URL:** https://en.wikipedia.org/wiki/Unicorn#Heraldry  
**Source excerpt:** The unicorn has been a heraldic symbol in Scotland since the 12th century, when it appeared on the royal coat of arms. In Celtic mythology, the unicorn represented power, purity, and fierce independence — traits associated with the Scottish identity. When James VI of Scotland became James I of England in 1603, the Scottish unicorn joined the English lion on the combined royal coat of arms, where it remains today.

---

### gen034_q11 — Score 8.4 ✓
**Q:** Finding the right pebble is a serious business if you're a Gentoo penguin. When a male Gentoo penguin wants to start a relationship, he goes on a search for a very specific object to present as a proposal gift. What does a male Gentoo penguin use to propose?  
**A:** A pebble — he searches for the most suitable pebble he can find and places it at the female's feet as a courtship offering  
**Alt answers:** a pebble, stones, the right stone, a carefully chosen pebble  
**Topic:** Nature & Animal Behaviour | **Difficulty:** medium | **Tags:** animals, nature, penguins, behaviour  
**Source URL:** https://en.wikipedia.org/wiki/Gentoo_penguin  
**Source excerpt:** Male Gentoo penguins (Pygoscelis papua) select specific pebbles to present to potential mates as part of courtship behaviour. The male searches for a smooth, appealing pebble and places it in front of the female. If she accepts it by incorporating it into the nest, the pair is considered bonded. Pebble theft is rampant in penguin colonies, and males who steal superior pebbles from neighbours have been documented.

---

### gen034_q12 — Score 8.4 ✓
**Q:** In 1991, a British scientist created something that would eventually be used by billions of people every day — a technology that has transformed how humans communicate, learn, and work. Had he patented it, he would likely have become the wealthiest person in history. Instead, he gave it away for free. What did he invent?  
**A:** The World Wide Web — Tim Berners-Lee declined to patent it, making his invention freely available to everyone  
**Alt answers:** the World Wide Web, the internet, the web, WWW — Tim Berners-Lee gave it away  
**Topic:** Technology & History | **Difficulty:** medium | **Tags:** technology, internet, invention, history  
**Source URL:** https://en.wikipedia.org/wiki/World_Wide_Web  
**Source excerpt:** Tim Berners-Lee invented the World Wide Web in 1989 while working at CERN in Switzerland. In 1993, CERN made the web protocols and code available on a royalty-free basis. Berners-Lee has repeatedly declined to patent the technology or personally profit from its commercial applications. He has stated that had the web been patented, it would never have become universally accessible. He was knighted in 2004 and received the Turing Award in 2016.

---

### gen034_q13 — Score 8.4 ✓
**Q:** Nintendo has become synonymous with video game history — but the company is far older than video games. It was founded in 1889 in the same year a famous Parisian landmark was inaugurated. What did Nintendo originally sell, and what opened the same year?  
**A:** Nintendo sold Hanafuda playing cards — and the Eiffel Tower opened in 1889  
**Alt answers:** playing cards — the Eiffel Tower, Hanafuda cards and the Eiffel Tower opened the same year, Japanese playing cards — also the year of the Eiffel Tower  
**Topic:** Business & History | **Difficulty:** medium | **Tags:** history, Nintendo, gaming, Japan  
**Source URL:** https://en.wikipedia.org/wiki/Nintendo  
**Source excerpt:** Nintendo was founded on September 23, 1889, by Fusajiro Yamauchi in Kyoto, Japan. The company's original business was producing and selling Hanafuda — traditional Japanese flower-themed playing cards. The Eiffel Tower was inaugurated on March 31, 1889. Nintendo would not enter the toy and electronics business until the 1960s, and the video game business until the 1970s.

---

### gen034_q14 — Score 8.4 ✓
**Q:** You know the surface of the Sun is unimaginably hot — about 5,500 degrees Celsius. But a bolt of lightning, lasting just a fraction of a second, briefly exceeds it. By how much is a lightning bolt hotter than the surface of the Sun?  
**A:** About 5 times hotter — a lightning channel reaches approximately 30,000°C, compared to the Sun's surface at 5,500°C  
**Alt answers:** five times hotter, about 5 times, 30,000°C vs 5,500°C, 5 times the Sun's surface temperature  
**Topic:** Physics & Meteorology | **Difficulty:** medium | **Tags:** physics, lightning, Sun, temperature  
**Source URL:** https://en.wikipedia.org/wiki/Lightning  
**Source excerpt:** A lightning bolt heats the surrounding air to approximately 30,000 Kelvin (roughly 30,000°C) — about five times hotter than the surface of the Sun, which is approximately 5,500°C (5,773 Kelvin). This extreme heat causes the rapid expansion of air around the lightning channel, producing the shockwave we hear as thunder.

---

### gen034_q15 — Score 8.2 ✓
**Q:** In 1762, John Montagu, the 4th Earl of Sandwich, reportedly refused to leave a card game long enough to eat a proper meal. Instead, he asked for something he could eat without interrupting his gambling. His solution to this problem is now eaten billions of times a day. What did he request?  
**A:** Meat placed between two slices of bread — inventing what we now call the sandwich  
**Alt answers:** a sandwich, meat between bread, sliced bread with meat inside — the first sandwich  
**Topic:** Food & History | **Difficulty:** easy | **Tags:** food, history, invention, culture  
**Source URL:** https://en.wikipedia.org/wiki/Sandwich  
**Source excerpt:** The sandwich is named after John Montagu, 4th Earl of Sandwich, an 18th-century English aristocrat. According to the story recorded in Edward Gibbon's diary in 1762, Montagu asked for meat to be served between two slices of bread so he could continue playing cards without interruption. The item became popular and adopted his title as its name. Whether this specific event is the true origin of bread-enclosed fillings remains debated by food historians.

---

### gen034_q16 — Score 8.2 ✓
**Q:** The Eiffel Tower is one of the world's most iconic landmarks — but it was never meant to be permanent. It was built as a temporary exhibit and was officially scheduled to be demolished just 20 years after it opened. What unexpected development saved it from the wrecking ball in 1909?  
**A:** It was repurposed as a radio transmission tower — its height made it invaluable for long-range communication, and during WWI it was used to intercept enemy radio signals  
**Alt answers:** radio tower, used as a radio antenna, it became a radio transmitter — then used in WWI to jam German communications  
**Topic:** Engineering & History | **Difficulty:** medium | **Tags:** history, Eiffel Tower, engineering, Paris  
**Source URL:** https://en.wikipedia.org/wiki/Eiffel_Tower  
**Source excerpt:** The Eiffel Tower was built as the entrance arch for the 1889 World's Fair and was intended to be dismantled in 1909. Its demolition was avoided because the tower proved valuable as a radiotelegraph station — at 330 metres, it was the tallest structure in the world and an ideal transmission antenna. During World War I, the tower's antenna was used to intercept enemy communications, including a key message that helped foil the German advance during the First Battle of the Marne in 1914.

---

## Dropped Questions (from 25 candidates)

| # | Reason |
|---|--------|
| gen034_q17 (cloud weight 500,000 kg) | Score 7.4 — DrF low: the answer scale (500 tonnes) is hard to process audibly |
| gen034_q18 (petrichor) | Score 7.8 — borderline; not enough conversation spark for a driving quiz |
| gen034_q19 (Tale of Genji first novel) | Score 7.2 — low conversation spark; too niche for broad audience |
| gen034_q20 (chimp DNA closer to humans than gorillas) | Score 7.2 — DNA comparison topic already covered in batch-02 (gen032_q05) |
| gen034_q21 (Mercury solar day > year) | Dropped pre-scoring — conceptually similar to gen033_q06 (Venus day > year in batch-03) |
| gen034_q22 (Alaska westernmost + easternmost) | Score 7.8 — requires explanation of 180th meridian; adds unwanted cognitive load |
| gen034_q23 (cats can't taste sweetness) | Score 7.6 — interesting but not surprising enough for driving quiz audience |
| gen034_q24 (blood vessels = 100,000 km) | Score 7.4 — too well-known, low surprise value |
| gen034_q25 (butterflies taste with feet) | Score 7.8 — borderline; widely known factoid |
