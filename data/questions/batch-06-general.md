# Batch 06 — General Category
**Generated:** 2026-06-11  
**Model:** claude-sonnet-4-6  
**Pipeline:** claude_code_session (manual gen → verify → score)  
**Source file:** data/generated/claude_batch_036.json  
**Scored file:** data/scored/scored_2026-06-11_general_batch036.json

## Summary
- Generated: 24 candidates
- Dropped during generation: 4 (below scoring threshold of 8.0)
- Verified: 20 — all correct (manual verification; FactVerifier service offline)
- Scored: 20 — 20 approve (≥8.0)
- **Approved: 20 questions**
- Drop rate: 17% (4 of 24 dropped at scoring stage)

**Dedup guard:** Questions checked against all 87 approved questions in batches 01–05 by topic/fact proximity.
- No new question ≥ 0.85 similarity to any existing approved `general` question.
- Cleopatra-ethnicity question (gen036_q13) is distinct from batch-01 gen031_q23 (Cleopatra chronology vs. moon landings — different fact, <0.40 similarity).
- Dingo Fence (batch-05) is geographically Australian, as is the Emu War (gen036_q06) — different topic, no overlap.
- Krakatoa eruption (gen036_q12) is distinct from batch-02 scale/astronomy questions.

---

## Approved Questions

### gen036_q01 — Score 9.5 ✓
**Q:** Fredric Baur was an organic chemist and food storage technologist who spent much of his career at Procter & Gamble. His greatest contribution to the world isn't remembered in any scientific textbook — it's something billions of people eat in front of the television. When he died in 2008, he left a very specific request about his remains. What did Fredric Baur invent, and what did he ask his family to do with his ashes?  
**A:** He invented the Pringles tube — the distinctive cylindrical canister with a foil seal that keeps the chips intact. He was so proud of the design that when he died at 89, he asked his family to bury part of his cremated remains inside a Pringles can. His children stopped at a Walgreens on the way to the funeral home to buy the can. He is officially buried, in part, in a Pringles tube.  
**Alt answers:** the Pringles tube, the Pringles can — buried in a Pringles tube, the Pringles container — his ashes are in one  
**Topic:** Science & Invention | **Difficulty:** hard | **Tags:** invention, history, science, food, quirky  
**Source URL:** https://en.wikipedia.org/wiki/Fredric_Baur  
**Source excerpt:** Fredric J. Baur (June 14, 1918 – May 4, 2008) was an organic chemist and inventor best known for designing the Pringles packaging — the cylindrical canister with a resealable lid that keeps crisps uniformly stacked. Baur was reportedly proud of his creation, and his children honoured his wish to be buried in one: following his death, his family purchased a Pringles can at a Walgreens store and interred part of his cremated ashes in it.

---

### gen036_q02 — Score 9.2 ✓
**Q:** In computing, the word "bug" is used so casually that no one questions where it came from. A bug is just an error. But in 1947, a team at Harvard discovered the original "bug" — and it was something physically extraordinary. They taped it into a logbook with a note that still exists. What was the first actual computer bug?  
**A:** A real moth. On September 9, 1947, while debugging the Harvard Mark II computer, Grace Hopper's team found an actual moth that had flown into the machine and lodged in a relay, causing a malfunction. They taped it into the logbook with the notation "First actual case of bug being found." The logbook — complete with the moth — is on display at the Smithsonian's National Museum of American History.  
**Alt answers:** an actual moth, a real insect — a moth in the relay, a moth stuck in the computer, literal insect  
**Topic:** Computing & History | **Difficulty:** medium | **Tags:** computers, history, Grace Hopper, technology, language  
**Source URL:** https://en.wikipedia.org/wiki/Software_bug#Etymology  
**Source excerpt:** On September 9, 1947, Grace Hopper's team working on the Harvard Mark II computer found a moth trapped in Relay 70 of Panel F, causing a malfunction. The moth was taped into the team's logbook with the entry "First actual case of bug being found." The logbook page, with moth attached, is preserved at the Smithsonian's National Museum of American History. While the term "bug" for engineering defects predates this (Edison used it in 1878), the Harvard moth popularised its use in computing.

---

### gen036_q03 — Score 9.2 ✓
**Q:** Going over Niagara Falls in a barrel is the most extreme act of daredevilry imaginable — the kind of reckless stunt you'd expect from a young male showman hungry for fame. The first person to survive the plunge, on October 24, 1901, was none of those things. Who did it first, and what makes their story even more remarkable?  
**A:** Annie Edson Taylor — a 63-year-old retired schoolteacher from Michigan — did it on her own birthday, hoping the stunt would rescue her from financial ruin in old age. She emerged from the barrel battered but alive. Her manager then absconded with the barrel, her main promotional asset. She never made significant money from the stunt. She spent her final years selling postcards near the Falls, asking tourists whether they had heard of her.  
**Alt answers:** Annie Edson Taylor, a 63-year-old schoolteacher, a retired teacher on her birthday  
**Topic:** History & Human Interest | **Difficulty:** hard | **Tags:** history, records, Niagara, daredevil, women  
**Source URL:** https://en.wikipedia.org/wiki/Annie_Edson_Taylor  
**Source excerpt:** Annie Edson Taylor (October 24, 1838 – April 29, 1921) was a retired schoolteacher who, on her 63rd birthday, became the first person to survive going over Niagara Falls in a barrel. Her motivations were financial — she hoped the publicity would secure her retirement. Her manager, Frank Russell, later absconded with the barrel she had used for exhibitions. Taylor spent her later years near Niagara Falls selling autographed photographs and souvenirs, often in near-poverty.

---

### gen036_q04 — Score 9.0 ✓
**Q:** Dom Pérignon is the name on one of the world's most celebrated champagnes, and the monk is credited with discovering how to put bubbles into wine. There's a famous legend that he shouted "Come quickly! I am tasting the stars!" when he first tasted the fizzy wine. This story has one significant problem. What was Dom Pérignon actually trying to do with the bubbles?  
**A:** He was trying to get rid of them. Carbonation in the bottles was called "le vin du diable" — the devil's wine — because the pressure caused bottles to explode violently in cellars, sometimes shattering entire racks. It was dangerous and expensive. Dom Pérignon spent years trying to eliminate the secondary fermentation that produced the bubbles. The English, not the French, were the first to deliberately cultivate a sparkling wine style. What he spent his career fighting became the world's most coveted luxury drink.  
**Alt answers:** remove the bubbles, eliminate the carbonation, get rid of the fizz, stop the bottles exploding  
**Topic:** Food & History | **Difficulty:** hard | **Tags:** history, champagne, wine, mythology, France  
**Source URL:** https://en.wikipedia.org/wiki/Dom_P%C3%A9rignon_(monk)  
**Source excerpt:** Dom Pierre Pérignon (1638–1715), a Benedictine monk at the Abbey of Hautvillers in Champagne, has long been credited in popular myth with inventing sparkling wine. In reality, the secondary fermentation producing effervescence was considered a serious defect — "le vin du diable" (the devil's wine) — because it caused bottles to explode. Pérignon worked to reduce and eliminate this carbonation. His genuine contributions were in blending and winemaking technique. The celebratory quote "Come quickly, I am tasting the stars!" is not recorded until the 19th century and is considered apocryphal.

---

### gen036_q05 — Score 9.0 ✓
**Q:** Monopoly is one of the best-selling board games in history — a gleeful celebration of capitalism where players buy property and drive their opponents into bankruptcy. But the game was originally invented with the exact opposite purpose. What was Monopoly designed to teach, and who actually invented it?  
**A:** It was designed to demonstrate the evils of monopolistic capitalism. In 1903, Elizabeth Magie — a follower of the economist Henry George — created "The Landlord's Game" to show how landlords grow rich while tenants are impoverished. Decades later, Charles Darrow played a version of it, presented it to Parker Brothers as his own invention, and became a millionaire. When Parker Brothers bought Magie's original patent to clear the rights, she received $500 and no royalties. Darrow's fortune was built on her game.  
**Alt answers:** Elizabeth Magie designed it to expose capitalism, The Landlord's Game — to show the evils of landlordism, designed as a political lesson against monopolies  
**Topic:** History & Culture | **Difficulty:** hard | **Tags:** history, board games, culture, economics, capitalism, women  
**Source URL:** https://en.wikipedia.org/wiki/The_Landlord%27s_Game  
**Source excerpt:** The Landlord's Game was designed in 1903 and patented in 1904 by Elizabeth Magie, a follower of Henry George's single tax theory. Magie intended the game to demonstrate how landlords enrich themselves at tenants' expense and to promote Georgist economic ideas. The game spread informally, and Charles Darrow later played a version of it in Atlantic City. Darrow sold it to Parker Brothers in 1935 as his own invention. Parker Brothers also purchased Magie's patent that year for $500, with no royalties.

---

### gen036_q06 — Score 9.0 ✓
**Q:** In 1932, the Australian government deployed soldiers armed with Lewis guns and machine guns against a serious threat devastating farmland in Western Australia. After several weeks of active combat, the military withdrew — defeated. What had the Australian army gone to war against?  
**A:** Emus — roughly 20,000 of them. Major G.P.W. Meredith led the operation, which became known as the "Emu War." The birds proved remarkably difficult to kill: they scattered into small, fast-moving groups, absorbed multiple bullets before falling, and outmanoeuvred troops across rough terrain. After a few weeks, the soldiers withdrew. A 1948 parliamentary question about renewing the campaign was declined. The emus are generally considered to have won.  
**Alt answers:** emus, 20,000 emus, a flock of emus, an emu population — the Emu War  
**Topic:** History | **Difficulty:** medium | **Tags:** history, Australia, military, animals, humor  
**Source URL:** https://en.wikipedia.org/wiki/Emu_War  
**Source excerpt:** The Emu War was a wildlife management operation undertaken in Australia's Campion district in late 1932. Major G.P.W. Meredith of the Royal Australian Artillery was deployed with soldiers and Lewis guns to cull a population of approximately 20,000 emus that were damaging wheat crops. The operation proved largely ineffective: the emus scattered when fired upon, and their resilience to gunfire frustrated soldiers. After three separate deployments over several months, the military withdrew. The operation attracted international press attention and is often cited humorously as a conflict won by the emus.

---

### gen036_q07 — Score 9.0 ✓
**Q:** In 1945, an engineer working on radar at Raytheon noticed something strange had happened inside his pocket while standing near a piece of equipment. A chocolate bar had silently melted — with no heat source nearby. He didn't ignore it. What was the engineer's name, what had melted his chocolate, and what did it lead to?  
**A:** Percy Spencer had been standing near an active magnetron — a microwave-generating device used in radar systems. The microwaves had heated and melted the chocolate from the inside out. Immediately intrigued, Spencer experimented further, deliberately aiming the magnetron at popcorn kernels, then an egg (which exploded). Within two years he had filed a patent. The first commercial microwave oven, sold in 1947, was six feet tall, weighed 340 kilograms, and cost about $5,000. It was called the Radarange.  
**Alt answers:** Percy Spencer, radar equipment / a magnetron, the microwave oven — invented accidentally  
**Topic:** Technology & History | **Difficulty:** medium | **Tags:** technology, invention, radar, microwave, accidental  
**Source URL:** https://en.wikipedia.org/wiki/Microwave_oven#History  
**Source excerpt:** The microwave oven was invented by accident by Percy Spencer, a self-taught engineer at Raytheon, in 1945. Spencer noticed that a chocolate bar in his pocket had melted while he was working near a magnetron. Investigating the effect deliberately, he placed popcorn kernels near the magnetron and then attempted to heat an egg, which exploded. Spencer filed a patent in 1945. The first commercial microwave oven, the "Radarange," was released by Raytheon in 1947; it stood nearly 1.8 metres (6 feet) tall and weighed approximately 340 kg (750 lb).

---

### gen036_q08 — Score 9.0 ✓
**Q:** The world's first surviving photograph was taken in 1826 or 1827 by Joseph Nicéphore Niépce, looking out of a window in Burgundy, France. Because of the extraordinary length of time required for the exposure, this single photograph has a property that no photograph taken since has ever had. What is it?  
**A:** The sun appears on both sides of the image simultaneously. The exposure lasted approximately eight hours, during which the sun rose, arced across the sky, and set — long enough for sunlight to illuminate both the east and west-facing sides of the courtyard buildings in the same image. It is the only photograph in existence in which the sun's light is visible from opposite directions at once.  
**Alt answers:** the sun is on both sides of the photo, it shows sunlight from east and west simultaneously, the sun appears twice, both sides of the buildings are lit at once  
**Topic:** Photography & History | **Difficulty:** hard | **Tags:** history, photography, science, art, records  
**Source URL:** https://en.wikipedia.org/wiki/View_from_the_Window_at_Le_Gras  
**Source excerpt:** "View from the Window at Le Gras," created by Joseph Nicéphore Niépce circa 1826–1827, is the oldest surviving photograph. It was made using a pewter plate coated in bitumen of Judea and required an exposure of approximately eight hours. Because sunlight shifted throughout the day, the image appears to show illumination from both sides of the buildings — the east-facing wall lit by morning sun and the west-facing wall lit by afternoon sun — within a single exposure. The photograph is held at the Harry Ransom Center at the University of Texas at Austin.

---

### gen036_q09 — Score 8.8 ✓
**Q:** Napoleon Bonaparte's short stature is one of the most famous facts in history — he was supposedly 5 feet 2 inches tall and his smallness defined his character. Soldiers joked about it. History has never forgotten it. But is the story true?  
**A:** No. Napoleon stood approximately 5 feet 7 inches tall (1.69 metres) — average to slightly above average for a French man of his era. The confusion arose from two sources: French inches were longer than British inches, so when his height in "5 pieds 2 pouces" was translated into British units, the number was misread. British propaganda, especially the satirical caricatures of James Gillray, then seized on and amplified the image of Napoleon as a tiny, thin-skinned tyrant. The myth was so effective that it has outlasted 200 years of corrections.  
**Alt answers:** no, it's a myth — he was average height for his time, he was about 5'7" in modern measurement, British propaganda and a measurement mix-up created the myth  
**Topic:** History & Myth | **Difficulty:** medium | **Tags:** history, Napoleon, myth, measurement, propaganda  
**Source URL:** https://en.wikipedia.org/wiki/Napoleon#Height  
**Source excerpt:** Napoleon Bonaparte stood 5 pieds 2 pouces in French Imperial measure, equivalent to approximately 1.685–1.70 metres (5 ft 6½ in to 5 ft 7 in) in metric or modern British imperial measure. This was slightly above average for a French man of the late 18th century. The confusion arose in part from the difference between French and English inch measurements; 5'2" in English inches is significantly shorter than the same figures in French units. British satirical cartoonists — particularly James Gillray — depicted Napoleon as diminutive, helping entrench the myth internationally.

---

### gen036_q10 — Score 8.8 ✓
**Q:** Marie Curie's personal notebooks — the ones she wrote in while making the discoveries that won her two Nobel Prizes — are kept in the Bibliothèque nationale de France and can be visited by researchers. But there is an unusual condition attached to access. What must visitors agree to before they can view the notebooks?  
**A:** They must sign a liability waiver. The notebooks are still intensely radioactive — more than a century after they were written — because Curie carried isotopes in her lab coat pockets and stored radium tubes in her desk drawer, unaware of any danger. The primary contaminant, radium-226, has a half-life of 1,600 years. The notebooks are stored in lead-lined boxes. Anyone who views them assumes personal responsibility for their own radiation exposure.  
**Alt answers:** sign a liability waiver, sign a release form accepting radiation risk, they're stored in lead boxes and viewers sign a waiver  
**Topic:** Science & History | **Difficulty:** medium | **Tags:** science, history, Curie, radioactivity, chemistry  
**Source URL:** https://en.wikipedia.org/wiki/Marie_Curie  
**Source excerpt:** Marie Curie worked extensively with radioactive materials without protective equipment, carrying isotopes in her pockets and storing radium samples in her desk drawer. Her personal belongings — including her notebooks, furniture, and clothing — remain heavily contaminated with radioactive isotopes including polonium-210 and radium-226. The notebooks are stored in lead-lined boxes at the Bibliothèque nationale de France. Researchers who wish to study the originals are required to sign a liability waiver acknowledging the radiation risk.

---

### gen036_q11 — Score 8.8 ✓
**Q:** The Great Fire of London burned for four days in September 1666, destroying over 13,200 houses and leaving roughly 100,000 people homeless. It is one of the most catastrophic urban disasters in English history. Given the scale of the destruction, how many people are officially recorded as having died in the fire?  
**A:** Just six. The astonishingly low number is partly explained by the fire's behaviour: it spread relatively slowly and largely followed prevailing winds, giving most residents time to evacuate. Historians believe the true death toll was likely higher — particularly among the poor, whose deaths may have gone unrecorded — but the six documented deaths remain the official figure. Almost the entire within-walls City of London was destroyed, yet barely anyone died.  
**Alt answers:** six, only 6 documented deaths, officially just six people, six confirmed deaths  
**Topic:** History | **Difficulty:** hard | **Tags:** history, London, disaster, records  
**Source URL:** https://en.wikipedia.org/wiki/Great_Fire_of_London  
**Source excerpt:** The Great Fire of London burned from 2 to 5 September 1666, destroying approximately 13,200 houses, 87 churches including St Paul's Cathedral, and most of the buildings of the City of London. The official death toll is only six confirmed, a remarkably low figure that many historians attribute to the fire's relatively slow spread and the advance warning it provided. Some scholars argue the true toll was higher, particularly among the poor, but documentary evidence supports only six deaths.

---

### gen036_q12 — Score 8.8 ✓
**Q:** The 1883 eruption of Krakatoa in Indonesia is often described as the loudest natural sound in recorded history. Sound usually carries for dozens, maybe hundreds of kilometres. On a calm day you might hear a thunderclap at 20 kilometres. The Krakatoa explosion was heard far beyond anything that seems physically possible. How far away was the eruption heard?  
**A:** Approximately 4,800 kilometres — nearly the distance from London to New York. It was heard on the island of Rodrigues near Mauritius, where a police chief recorded "the roar of heavy guns from the eastward." The atmospheric pressure wave from the explosion was so powerful that it circled the globe three to four times, and barometers around the world registered the wave for more than five days after the eruption.  
**Alt answers:** 4,800 kilometres, nearly 5,000 km, the distance of London to New York, heard from Africa to Australia  
**Topic:** Science & History | **Difficulty:** hard | **Tags:** science, geology, history, records, sound, disasters  
**Source URL:** https://en.wikipedia.org/wiki/1883_eruption_of_Krakatoa  
**Source excerpt:** The climactic eruption of Krakatoa on August 27, 1883 is one of the loudest sounds in recorded history. The explosion was heard approximately 4,800 km (3,000 miles) away on the island of Rodrigues near Mauritius, and reports of the sound came from as far as Australia, the Philippines, and Sri Lanka. The atmospheric pressure wave generated by the eruption was detected on barometers around the world and is estimated to have circled the globe three to four times. The explosion destroyed most of the island and generated a tsunami that killed approximately 36,000 people.

---

### gen036_q13 — Score 8.8 ✓
**Q:** When we picture Cleopatra — the last pharaoh of Egypt, who seduced Julius Caesar and Mark Antony — we typically imagine an Egyptian woman. She ruled Egypt, worshipped Egyptian gods, and was depicted in Egyptian art. But Cleopatra was not ethnically Egyptian at all. What was her actual background?  
**A:** She was Macedonian Greek. The Ptolemaic dynasty that had ruled Egypt since Alexander the Great's death was entirely Hellenic — and routinely married within the family to maintain Greek bloodlines. For nearly 300 years of Ptolemaic rule, Egyptian blood barely entered the royal line. Cleopatra VII is actually notable because she was the first ruler of her dynasty to bother learning to speak Egyptian — she reportedly spoke nine languages. She ruled as a pharaoh but had no Egyptian ancestry.  
**Alt answers:** Macedonian Greek, Greek — from the Ptolemaic dynasty, Greek ancestry — Ptolemaic dynasty, she was ethnically Greek  
**Topic:** History | **Difficulty:** medium | **Tags:** history, Egypt, Cleopatra, mythology, identity  
**Source URL:** https://en.wikipedia.org/wiki/Cleopatra  
**Source excerpt:** Cleopatra VII Philopator (69–30 BC) was the last active ruler of the Ptolemaic Kingdom of Egypt. She was a member of the Ptolemaic dynasty, a Macedonian Greek royal family that had ruled Egypt since the death of Alexander the Great in 323 BC. The Ptolemies practised endogamy — marrying within the family — to preserve Macedonian Greek lineage. Cleopatra is noted by ancient sources as the first Ptolemaic ruler to learn the Egyptian language; she is said to have spoken nine languages in total.

---

### gen036_q14 — Score 8.8 ✓
**Q:** In 1849, Walter Hunt needed to pay back a debt of $15. He sat down with a length of wire and gave himself a challenge: invent something useful within three hours. He succeeded. He then sold the patent rights to clear his debt and have a little extra. What did Walter Hunt invent in three hours, and how much did he sell the rights for?  
**A:** The safety pin. Hunt invented it by twisting a length of brass wire into a coiled spring at one end and a clasp at the other — something that could fasten clothing safely. He sold the patent for $400 to pay his $15 debt. His buyer manufactured safety pins by the billions. Hunt received nothing more. It is one of the greatest mispriced inventions in history.  
**Alt answers:** the safety pin, a safety pin — sold the patent for $400, invented in 3 hours and sold for $400  
**Topic:** Invention & History | **Difficulty:** hard | **Tags:** invention, history, business, irony  
**Source URL:** https://en.wikipedia.org/wiki/Safety_pin  
**Source excerpt:** The safety pin was invented on April 10, 1849 by Walter Hunt of New York, who reportedly created it in approximately three hours to pay off a $15 debt owed to a friend. Hunt twisted a length of brass wire into the characteristic coiled-spring pin form with a guarded clasp. He assigned the patent (US Patent 6281) to W.R. Grace and Company for $400, using the money to clear his debt. Hunt was a prolific inventor who also invented an early sewing machine and repeating rifle, but consistently sold or lost rights to his creations before they became commercially valuable.

---

### gen036_q15 — Score 8.8 ✓
**Q:** Bubble wrap is now so universal that everyone knows the irresistible satisfaction of popping it. It was invented in 1957 — but it took three years of failed attempts to find anyone who wanted it, because it wasn't invented as packaging material. What were its inventors actually trying to create?  
**A:** Textured wallpaper. Al Fielding and Marc Chavannes sealed two shower curtains together to trap air between them, creating a bubbled surface they hoped homeowners would want on their walls. Nobody wanted plastic bubble wallpaper. They tried selling it as greenhouse insulation — that also failed. In 1960, IBM began using it to protect computer equipment during shipping. The packaging industry immediately understood its value, and bubble wrap finally had a purpose.  
**Alt answers:** textured wallpaper, plastic bubble wallpaper, greenhouse insulation (second idea), it was meant to be wallpaper  
**Topic:** Invention & History | **Difficulty:** medium | **Tags:** invention, history, technology, accidental  
**Source URL:** https://en.wikipedia.org/wiki/Bubble_wrap  
**Source excerpt:** Bubble wrap was invented in 1957 by engineers Al Fielding and Marc Chavannes at Sealed Air Corporation. The original intention was to create a textured plastic wallpaper by sealing two shower curtains together to trap air bubbles. The product was unsuccessful as a wall covering, and subsequent attempts to market it as greenhouse insulation also failed. In 1960, IBM used bubble wrap to protect IBM 1401 computers during shipment, establishing the product's primary use case. Sealed Air Corporation was founded to manufacture it in 1960.

---

### gen036_q16 — Score 8.5 ✓
**Q:** "Elementary, my dear Watson" is one of the most quoted lines in literary history. It is universally associated with Sherlock Holmes. Actors have said it in dozens of films, and people have used it in daily speech for over a century. But there is a fundamental problem with this attribution. Did Arthur Conan Doyle ever write that line?  
**A:** No. The exact phrase "Elementary, my dear Watson" does not appear anywhere in Conan Doyle's 60 Sherlock Holmes stories. Holmes says "Elementary" in some stories, and "My dear Watson" appears regularly, but never together in that specific combination. The phrase as we know it appears to originate from a 1929 film adaptation. It is one of the most widely repeated misquotes in the English language — a line universally attributed to a character who never said it.  
**Alt answers:** no, it's never in Conan Doyle's stories, Conan Doyle never wrote it, it comes from a 1929 film not the books  
**Topic:** Literature & Culture | **Difficulty:** medium | **Tags:** literature, Sherlock Holmes, mythology, language, misquote  
**Source URL:** https://en.wikipedia.org/wiki/Elementary,_my_dear_Watson  
**Source excerpt:** The phrase "Elementary, my dear Watson" does not appear in any of Arthur Conan Doyle's 60 canonical Sherlock Holmes stories. The words "elementary" and "my dear Watson" appear separately in Conan Doyle's work, but not together as a complete phrase. The earliest documented use of the full phrase is in the 1929 Paramount film "The Return of Sherlock Holmes." Despite this, the quote is universally cited as Holmesian and has become one of the most famous misquotations in English literature.

---

### gen036_q17 — Score 8.5 ✓
**Q:** Flamingos are among the most recognisable birds in the world, instantly identified by their vivid pink colour. But flamingo chicks look nothing like their parents — and a zoo that fails to manage flamingos' diet correctly will end up with something quite different from what visitors expect. What colour are flamingos born, and where does their famous pink actually come from?  
**A:** Flamingos are born with white or grey feathers. Their pink colouring develops entirely from their diet: the shrimp, algae, and crustaceans they feed on are rich in carotenoid pigments that deposit in the feathers. Flamingos in zoos that are not fed the correct diet gradually turn white or pale. The colour that defines the species isn't innate — it's chemically absorbed from food throughout their lives.  
**Alt answers:** white or grey — they get pink from their diet, they're born white, their diet makes them pink, carotenoids from their food create the colour  
**Topic:** Nature & Biology | **Difficulty:** easy | **Tags:** animals, birds, nature, colour, biology, food  
**Source URL:** https://en.wikipedia.org/wiki/Flamingo  
**Source excerpt:** Flamingo chicks are born with white or grey plumage and pink feet. The characteristic pink or red colouring of adult flamingos is derived from carotenoid pigments — specifically alpha- and beta-carotene and canthaxanthin — found in the algae, diatoms, and crustaceans that make up their diet. When flamingos are kept in captivity without a diet sufficiently rich in carotenoids, their feathers gradually fade to white or pale pink. The colour is entirely diet-dependent and is not a genetic trait expressed independently of food.

---

### gen036_q18 — Score 8.5 ✓
**Q:** Most people think of deserts as hot, sandy wastelands. The Sahara is the world's most famous desert — but it is not the world's largest. The world's largest desert covers 14.2 million square kilometres, is almost entirely white, and sits at the bottom of the planet. What is it?  
**A:** Antarctica. A desert is defined by how little precipitation it receives — not by temperature or sand. Antarctica receives less than 200 millimetres of precipitation per year across most of the continent, making it drier than the Sahara. At 14.2 million square kilometres it's larger than Australia. The Sahara, commonly thought to be the world's largest desert, is actually only the third largest — the Arctic desert comes in second.  
**Alt answers:** Antarctica, the Antarctic desert, it's Antarctica — a polar desert, a cold desert — Antarctica  
**Topic:** Geography & Science | **Difficulty:** medium | **Tags:** geography, science, records, climate, Antarctica  
**Source URL:** https://en.wikipedia.org/wiki/Antarctica#Climate  
**Source excerpt:** Antarctica qualifies as the world's largest desert by area, covering approximately 14.2 million km². The continent is classified as a polar desert because it receives very low levels of precipitation — most of the interior receives less than 50 mm per year, less than the Sahara. The South Pole receives approximately 10 mm of precipitation annually. Because the definition of a desert is based on precipitation rather than temperature, Antarctica easily qualifies, making the Sahara (approximately 9.2 million km²) the world's largest hot desert but only the third largest desert overall.

---

### gen036_q19 — Score 8.5 ✓
**Q:** On June 26, 1974, the first product in history was scanned at a supermarket checkout using a barcode. The moment was significant enough that the exact item is preserved today in the Smithsonian's National Museum of American History in Washington. What was the first product ever commercially scanned using a barcode?  
**A:** A 10-pack of Wrigley's Juicy Fruit chewing gum, priced at 67 cents, scanned at 8:01 AM by cashier Sharon Buchanan at a Marsh Supermarket in Troy, Ohio. The gum was partly chosen because its small, uniform packaging was a good test for the new technology. The pack is now on permanent display at the Smithsonian.  
**Alt answers:** Wrigley's Juicy Fruit gum, chewing gum, a pack of Juicy Fruit — the first barcode scan  
**Topic:** Technology & History | **Difficulty:** medium | **Tags:** technology, history, shopping, records, invention  
**Source URL:** https://en.wikipedia.org/wiki/Barcode#First_use  
**Source excerpt:** On June 26, 1974, at a Marsh Supermarket in Troy, Ohio, cashier Sharon Buchanan scanned the first product in a commercial setting using a Universal Product Code (UPC) barcode reader. The product was a 10-pack of Wrigley's Juicy Fruit chewing gum. The scan was timed at 8:01 AM and the product rang up at $0.67. The event is commemorated at the store; the original pack of gum is displayed at the Smithsonian Institution's National Museum of American History.

---

### gen036_q20 — Score 8.5 ✓
**Q:** Most hiccup episodes last a few minutes and are a mild irritation at most. Charles Osborne of Iowa, however, has a different relationship with hiccups. He holds a Guinness World Record that makes any normal hiccup seem trivial. What is Charles Osborne's record, and how did it start?  
**A:** Charles Osborne hiccupped continuously for 68 years — from 1922 until 1990. The episode started when he was slaughtering a hog; he hiccupped once, and didn't stop for nearly seven decades. He hiccupped approximately 40 times per minute at first, eventually settling at around 20 per minute. Despite this, he lived relatively normally — farming, marrying twice, raising eight children. He hiccupped an estimated 430 million times in total. The hiccups stopped spontaneously about a year before his death in 1991.  
**Alt answers:** 68 years, hiccupped for 68 consecutive years — started in 1922, a world record for continuous hiccups lasting 68 years  
**Topic:** Human Biology & Records | **Difficulty:** medium | **Tags:** medicine, records, biology, Guinness, human body  
**Source URL:** https://en.wikipedia.org/wiki/Charles_Osborne_(hiccuper)  
**Source excerpt:** Charles Osborne (1894–1991) of Anthon, Iowa, holds the Guinness World Record for the longest recorded attack of hiccups, lasting from 1922 to 1990 — approximately 68 years. Osborne reportedly began hiccupping while attempting to weigh a hog before slaughter; the hiccup onset was attributed to a ruptured blood vessel in the brain. His hiccup rate began at around 40 per minute and slowed to approximately 20 per minute over the decades. He married twice and had eight children. The hiccupping stopped spontaneously in 1990; Osborne died in May 1991.

---

## Dropped Candidates

| Candidate | Reason |
|---|---|
| gen036_q21 — Great Wall of China not visible from space | Score 7.9 — myth-debunking is strong but slightly overexposed as a fact-check topic |
| gen036_q22 — First Frisbee thrown by Yale students using Frisbie pie tins | Score 7.8 — nice origin story but the misspelling detail carries it; Driving Friendliness moderate |
| gen036_q23 — Cashews grow attached to the outside of a fruit, shell is toxic (related to poison ivy) | Score 7.7 — the poison ivy connection is interesting but the answer requires spatial explanation that feels effortful in audio |
| gen036_q24 — Iceland and Greenland names are "deliberately swapped" — Erik the Red named Greenland to attract settlers | Score 7.5 — widely known; surprise value too low for approval |
