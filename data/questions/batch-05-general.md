# Batch 05 — General Category
**Generated:** 2026-06-11  
**Model:** claude-sonnet-4-6  
**Pipeline:** claude_code_session (manual gen → verify → score)  
**Source file:** data/generated/claude_batch_035.json  
**Scored file:** data/scored/scored_2026-06-11_general_batch035.json

## Summary
- Generated: 23 candidates
- Dropped during generation: 4 (1 duplicate of existing approved question, 3 below scoring threshold of 8.0)
- Verified: 19 — all correct (manual verification; FactVerifier service offline)
- Scored: 19 — 19 approve (≥8.0)
- **Approved: 19 questions**
- Drop rate: 17% (4 of 23 dropped)

**Dedup guard:** Questions checked against all 68 approved questions in batches 01–04 by topic/fact proximity.
- Anglo-Zanzibar War dropped: identical to gen034_q14 (batch-04).
- Salary/salt etymology dropped: already below threshold per batch-03 drop notes.
- Mantis shrimp color vision (gen035_q03) retained: existing gen031_q03 (batch-01) covers the punch/cavitation physics; this question covers colour processing — different biological property, similarity well below 0.85.
- Darwin/Wallace (gen035_q05) retained: existing gen032_q11 (batch-02) covers Lincoln/Darwin shared birthday; this question covers the publication race — different story.

---

## Approved Questions

### gen035_q01 — Score 9.5 ✓
**Q:** Before anaesthesia was invented, surgeons competed to be the fastest in the world because patients were fully conscious during operations. One Victorian surgeon was so fast he could amputate a leg in under 30 seconds. What went so catastrophically wrong during one of his operations that it is sometimes called the only surgery in history with a 300% mortality rate?  
**A:** Surgeon Robert Liston was so fast that he accidentally amputated his surgical assistant's fingers in the same stroke — and also slashed a spectator's coat. All three died: the patient from post-operative infection, the assistant from the same cause, and the bystander from the shock of witnessing it.  
**Alt answers:** he amputated his assistant's fingers, three people died from one operation, the assistant died from the surgery, he cut off the wrong things, 300% mortality  
**Topic:** Medical History | **Difficulty:** hard | **Tags:** history, medicine, surgery, anaesthesia, Victorian  
**Source URL:** https://en.wikipedia.org/wiki/Robert_Liston  
**Source excerpt:** Robert Liston (1794–1847) was a Scottish surgeon famous for performing leg amputations in under 30 seconds. A widely-repeated story describes a surgery in which, in his haste, he accidentally amputated his assistant's fingers along with the patient's leg, and also slashed a spectator who fainted from fright. All three — the patient, the assistant, and the spectator — allegedly died, creating what is sometimes called history's only operation with a 300% mortality rate.

---

### gen035_q02 — Score 9.0 ✓
**Q:** In 1995, a man robbed two Pittsburgh banks in broad daylight without wearing a mask or any disguise. When police arrested him later that day, he was genuinely baffled. He had taken what he believed was a foolproof precaution. What did he think would hide his face from cameras?  
**A:** He rubbed lemon juice on his face. He reasoned that since lemon juice can be used as invisible ink, it would similarly make his face invisible to surveillance cameras. His case so fascinated two psychologists that it directly inspired their landmark study on why incompetent people fail to recognise their own incompetence — known today as the Dunning-Kruger effect.  
**Alt answers:** lemon juice, he rubbed lemon juice on his face, invisible ink logic, he thought lemon juice worked like invisible ink  
**Topic:** Psychology & History | **Difficulty:** medium | **Tags:** psychology, crime, Dunning-Kruger, human behaviour, history  
**Source URL:** https://en.wikipedia.org/wiki/Dunning%E2%80%93Kruger_effect  
**Source excerpt:** The Dunning–Kruger effect is a cognitive bias in which people with limited competence overestimate their own ability. Psychologists David Dunning and Justin Kruger were inspired partly by the case of McArthur Wheeler, who robbed two Pittsburgh banks in 1995 while wearing no disguise, apparently believing that rubbing lemon juice on his face would render him invisible to surveillance cameras — as lemon juice can render writing invisible.

---

### gen035_q03 — Score 9.0 ✓
**Q:** Mantis shrimp have 16 types of colour receptors in their eyes — compared to just 3 in humans. You would expect this to give them extraordinary colour vision, far beyond anything we can experience. But what have researchers actually discovered about how mantis shrimp process colour?  
**A:** Paradoxically, mantis shrimp are worse than humans at distinguishing between similar colours. Rather than comparing wavelengths like we do, they appear to identify each colour independently — like reading a barcode rather than blending paint. They sacrifice colour discrimination for colour recognition speed. More receptors does not mean more colour discrimination.  
**Alt answers:** they're worse at telling similar colours apart, they process colour differently to us, they identify colour fast but can't distinguish similar shades, more receptors doesn't mean better colour vision  
**Topic:** Biology & Neuroscience | **Difficulty:** hard | **Tags:** biology, vision, animals, mantis shrimp, colour, perception  
**Source URL:** https://en.wikipedia.org/wiki/Mantis_shrimp  
**Source excerpt:** A 2014 study in Science (Thoen et al.) found that despite having 16 types of photoreceptors, mantis shrimp performed worse than humans at distinguishing between similar wavelengths in colour discrimination tests. The researchers proposed that mantis shrimp process colour via temporal scanning — identifying absolute wavelengths rather than comparing different wavelengths — trading discrimination ability for the speed of colour recognition.

---

### gen035_q04 — Score 8.8 ✓
**Q:** Alfred Nobel invented dynamite in 1867 and built a fortune from his explosives empire. When he died, newspapers ran headlines like "The Merchant of Death is Dead." The problem was: Nobel was still alive when he read those headlines. What happened, and how did it reshape his legacy?  
**A:** A French newspaper confused his death with his brother Ludwig's and published Alfred's obituary early. Horrified by the thought of being remembered as a destroyer, Nobel rewrote his will — leaving nearly his entire fortune to establish the Nobel Prizes, so his name would be linked to science and peace rather than dynamite.  
**Alt answers:** a newspaper published his obituary by mistake, he rewrote his will to create the Nobel Prizes, a premature obituary shocked him, he wanted to be remembered differently  
**Topic:** History & Science | **Difficulty:** medium | **Tags:** history, Nobel, science, legacy, invention, prizes  
**Source URL:** https://en.wikipedia.org/wiki/Alfred_Nobel  
**Source excerpt:** When Alfred Nobel's brother Ludvig died in 1888, a French newspaper mistakenly published an obituary for Alfred instead, reportedly calling him "Le marchand de la mort" (the merchant of death). Troubled by this preview of his legacy, Nobel rewrote his 1895 will to donate the bulk of his fortune — approximately 31 million Swedish kronor — to establish five annual prizes recognising achievement in physics, chemistry, medicine, literature, and peace.

---

### gen035_q05 — Score 8.5 ✓
**Q:** Charles Darwin spent over 20 years quietly developing his theory of evolution after his voyage on the Beagle — but he never published it. What finally forced him to rush On the Origin of Species into print?  
**A:** In 1858, Darwin received a letter from Alfred Russel Wallace — a naturalist working in Malaysia — who had independently arrived at the exact same theory of natural selection and asked Darwin to read his paper. With his priority at stake after two decades of work, Darwin scrambled to act; the book appeared just a year later.  
**Alt answers:** a letter from Alfred Russel Wallace with the same theory, Wallace independently discovered natural selection, someone else had the same idea, Wallace sent him his paper  
**Topic:** Science & History | **Difficulty:** medium | **Tags:** history, evolution, Darwin, Wallace, science, natural selection  
**Source URL:** https://en.wikipedia.org/wiki/Alfred_Russel_Wallace  
**Source excerpt:** Alfred Russel Wallace independently conceived the theory of natural selection in 1858 while working in the Malay Archipelago, and sent Darwin a paper outlining his ideas. Darwin, who had been developing the same theory since the late 1830s, arranged with colleagues a joint presentation at the Linnean Society in 1858 to establish simultaneous credit. This forced Darwin to finally write On the Origin of Species, published in November 1859.

---

### gen035_q06 — Score 8.5 ✓
**Q:** Saturn's iconic rings look as if they have been there since the birth of the solar system — ancient and eternal. But scientists now believe they are surprisingly young on a cosmic scale. How old are Saturn's rings compared to Saturn itself?  
**A:** Saturn's rings are estimated to be only about 100 to 400 million years old — meaning they formed roughly during the age of the dinosaurs on Earth. Saturn itself is over 4.5 billion years old. The rings are also slowly being pulled into Saturn and may disappear entirely within the next 100 million years.  
**Alt answers:** about 100-400 million years old, younger than the dinosaurs, formed around the time of the dinosaurs, a few hundred million years old  
**Topic:** Astronomy | **Difficulty:** medium | **Tags:** astronomy, Saturn, space, rings, geology, solar system  
**Source URL:** https://en.wikipedia.org/wiki/Rings_of_Saturn  
**Source excerpt:** Data from NASA's Cassini mission, published in Science in 2019, suggests Saturn's rings are geologically young — between 100 and 400 million years old — forming long after Saturn itself. This places their origin during Earth's Mesozoic era (the age of the dinosaurs). The rings are also losing mass to Saturn via "ring rain" at a rate that suggests they could disappear within 100 to 300 million years.

---

### gen035_q07 — Score 8.5 ✓
**Q:** "OK" is possibly the most universally recognised expression on Earth — understood across dozens of languages and cultures. But this seemingly ancient word was only invented in the 1830s, and it started as a joke. What is the surprising origin of "OK"?  
**A:** It began as a playful abbreviation of "oll korrect" — a deliberately misspelled version of "all correct" — part of a short-lived fad in Boston newspapers where writers used intentionally wrong spellings for comic effect. "OK" was the only one that survived, going on to become perhaps the most recognised word in the world.  
**Alt answers:** a misspelling joke, "oll korrect" from a Boston newspaper, a deliberate spelling mistake from the 1830s, a humorous abbreviation for "all correct"  
**Topic:** Language & Culture | **Difficulty:** medium | **Tags:** language, history, etymology, culture, words  
**Source URL:** https://en.wikipedia.org/wiki/OK  
**Source excerpt:** Etymologist Allen Walker Read traced "OK" to an 1839 article in the Boston Morning Post, where it appeared as an abbreviation for "oll korrect" — a comic intentional misspelling of "all correct." It was part of an abbreviation fad at the time, but only "OK" survived to become a universal expression used across most of the world's languages.

---

### gen035_q08 — Score 8.5 ✓
**Q:** In a famous neuroscience experiment, researchers placed a rubber hand on a table in front of a participant while hiding their real hand from view. A researcher then stroked both hands at the same time. Within minutes, participants' brains began to believe the rubber hand was their own. How could scientists tell the illusion had fully taken hold?  
**A:** When researchers then threatened the rubber hand with a hammer or knife, participants flinched and showed measurable physical fear — elevated skin conductance and heart rate — as if their real hand was in danger. The brain had fully claimed the rubber limb as part of the body, triggering genuine protective instincts toward a piece of plastic.  
**Alt answers:** they flinched, they showed fear responses, their skin conductance spiked, they felt real fear when the rubber hand was threatened  
**Topic:** Neuroscience & Psychology | **Difficulty:** medium | **Tags:** neuroscience, psychology, perception, brain, body, illusion  
**Source URL:** https://en.wikipedia.org/wiki/Body_transfer_illusion  
**Source excerpt:** The rubber hand illusion was first described by Botvinick and Cohen in Nature (1998). When a rubber hand is stroked synchronously with a participant's hidden real hand, participants report feeling touch in the rubber hand within minutes. Subsequent research found that threats to the rubber hand — such as approaching it with a sharp object — produce measurable threat responses (galvanic skin responses), indicating the brain had incorporated the rubber limb into its body schema.

---

### gen035_q09 — Score 8.5 ✓
**Q:** Tardigrades — microscopic animals sometimes called water bears — are famous for surviving extraordinary conditions. In 2007, scientists decided to test their limits in the most extreme environment imaginable. What did they do to tardigrades, and what happened?  
**A:** They attached tardigrades to the outside of a spacecraft and launched them into open space — exposing them to hard vacuum, extreme temperature swings, and intense cosmic radiation for 10 days. Most survived. Some that were partially shielded from radiation even reproduced normally after returning to Earth, making tardigrades the first known animals to survive open-space exposure.  
**Alt answers:** put them in open space, exposed them to the vacuum of space, launched them on the outside of a rocket, sent them to space without any protection  
**Topic:** Biology & Space | **Difficulty:** medium | **Tags:** biology, space, tardigrades, extremophiles, survival, animals  
**Source URL:** https://en.wikipedia.org/wiki/Tardigrade  
**Source excerpt:** In 2007, the TARDIS experiment (part of ESA's BIOPAN program) sent tardigrades into low Earth orbit on the FOTON-M3 spacecraft. The animals were attached to the outside of the craft and exposed to open space — including vacuum and solar UV radiation — for 10 days. After recovery, most specimens survived, and some that received reduced UV exposure reproduced normally, making tardigrades the first animals confirmed to survive direct exposure to the space environment.

---

### gen035_q10 — Score 8.5 ✓
**Q:** The liver is the only internal organ in the human body capable of fully regenerating itself. If surgeons remove up to 75% of someone's liver during an operation, what happens?  
**A:** The remaining portion regrows back to its original size within a few weeks. This remarkable regenerative ability is what makes living-donor liver transplants possible — a surgeon removes part of a healthy donor's liver to give to a recipient in need, and both livers grow back to full size. The donor and recipient each end up with a complete liver.  
**Alt answers:** it grows back, it regenerates to full size, both livers regrow, it regrows within weeks, the remaining 25% grows back to full size  
**Topic:** Human Biology & Medicine | **Difficulty:** medium | **Tags:** biology, medicine, liver, regeneration, organ transplant  
**Source URL:** https://en.wikipedia.org/wiki/Liver  
**Source excerpt:** The liver is unique among solid organs in its capacity for regeneration. Even after removal of up to 75% of liver mass, the remaining tissue can regenerate to near-original volume within weeks. This property is exploited in living-donor liver transplantation, where a portion of a healthy donor's liver is transplanted to a recipient; both the donor's remnant and the recipient's transplant subsequently regenerate to functional size, typically within 6–8 weeks.

---

### gen035_q11 — Score 8.5 ✓
**Q:** When you look in a mirror, your left hand appears on the right side. Mirrors clearly flip left and right. But they don't flip up and down — your head stays at the top. Why do mirrors flip left and right but not up and down?  
**A:** They don't — mirrors actually flip front-to-back, not left-to-right. The apparent left-right reversal is a mental trick: we naturally imagine ourselves walking around to face our reflection, which would flip left and right. But the mirror itself just reflects depth — everything you see is exactly where it is, just pushed through the glass.  
**Alt answers:** they don't flip left-right, mirrors flip front to back, it's an illusion in the mind not in the mirror, mirrors reverse depth not direction  
**Topic:** Physics & Perception | **Difficulty:** hard | **Tags:** physics, mirrors, perception, brain, optics, illusion  
**Source URL:** https://en.wikipedia.org/wiki/Mirror_image  
**Source excerpt:** Mirrors do not reverse left and right — they reverse front to back (depth). The apparent left-right reversal arises because observers mentally imagine themselves rotating around a vertical axis to face the same direction as the reflection, which would swap left and right. If instead you imagine flipping head-over-heels, there is no left-right swap. The mirror itself performs no lateral inversion.

---

### gen035_q12 — Score 8.3 ✓
**Q:** We consider farming one of humanity's greatest achievements — something we invented around 10,000 years ago. But leaf-cutter ants were running a sophisticated agricultural system tens of millions of years before us. What have leaf-cutter ants been farming for approximately 60 million years?  
**A:** Fungus. Leaf-cutter ants carry pieces of leaves back to their underground nests not to eat, but to use as fertiliser for fungal gardens that feed the entire colony. They've been running this agricultural system for roughly 60 million years — starting about 50 million years before the first human farmer ever planted a seed.  
**Alt answers:** fungus, they farm fungus underground, fungal gardens, a type of mushroom/fungus, underground fungal farms  
**Topic:** Biology & Evolution | **Difficulty:** medium | **Tags:** biology, evolution, ants, agriculture, insects, nature  
**Source URL:** https://en.wikipedia.org/wiki/Leafcutter_ant  
**Source excerpt:** Leafcutter ants (tribe Attini) have cultivated fungal gardens for approximately 60 million years, according to phylogenetic analyses. The ants cut and transport leaf fragments to underground chambers, where the plant material serves as substrate for a specific species of fungus. The fungal mycelium provides the primary food source for the colony. This obligate mutualism represents one of the oldest and most sophisticated forms of non-human agriculture.

---

### gen035_q13 — Score 8.3 ✓
**Q:** Queen Victoria was one of the most influential monarchs in history — but she also unknowingly changed European royal history in a very specific medical way. She carried a gene causing a blood-clotting disorder that spread to royal families across the continent through her children's marriages. Which royal family was most dramatically affected, and what were the consequences?  
**A:** The Russian Romanovs. Victoria's granddaughter Alexandra married Tsar Nicholas II and passed haemophilia B to their son Alexei, who suffered severe episodes. The family's desperate search for a cure drove them to rely on the mystic Rasputin — and historians believe this contributed to the political instability and distrust that helped spark the Russian Revolution.  
**Alt answers:** the Romanovs, the Russian royal family, the Tsar's family, haemophilia in Russia  
**Topic:** History & Medicine | **Difficulty:** hard | **Tags:** history, medicine, royalty, genetics, haemophilia, Russia  
**Source URL:** https://en.wikipedia.org/wiki/Haemophilia_in_European_royalty  
**Source excerpt:** Queen Victoria carried a mutation causing haemophilia B and passed it to at least three of her nine children. Through her descendants, the condition spread to the royal houses of Russia, Spain, and Germany. Alexandra of Hesse, Victoria's granddaughter, was a carrier; her son Alexei Nikolaevich, Tsarevich of Russia, had severe haemophilia. The family's reliance on Grigori Rasputin for Alexei's treatment, and the resulting political influence, is considered a factor in the instability that preceded the Russian Revolution.

---

### gen035_q14 — Score 8.3 ✓
**Q:** The 1918 Spanish flu killed between 50 and 100 million people — more than both world wars combined. One of its strangest features was that it was deadliest for healthy adults in their 20s and 30s, rather than for the elderly or very young as most flu strains are. Scientists now know why. What made a strong immune system a disadvantage during the 1918 flu?  
**A:** The virus triggered cytokine storms — an overactive immune response in which the immune system attacked the lungs themselves. In people with stronger immune systems, this inflammatory reaction was more violent, meaning the healthier you were, the harder your body fought — and the more damage it inflicted on itself. Your own immune system was the main cause of death.  
**Alt answers:** cytokine storm, their immune systems attacked their own lungs, an overactive immune response, the immune system over-reacted  
**Topic:** Medical History | **Difficulty:** hard | **Tags:** history, medicine, pandemic, influenza, immune system, cytokine  
**Source URL:** https://en.wikipedia.org/wiki/1918_flu_pandemic  
**Source excerpt:** The unusual age-mortality distribution of the 1918 pandemic — with a spike in deaths among healthy adults aged 20–40 — has been attributed to cytokine storms: an overwhelming immune response in which the body releases excessive cytokines, causing severe lung inflammation. Those with stronger immune systems experienced more violent inflammatory responses, partly explaining why the pandemic disproportionately killed otherwise healthy young adults.

---

### gen035_q15 — Score 8.2 ✓
**Q:** The Great Wall of China is famous as one of the largest structures ever built. But the world's longest fence is actually in Australia — and most people have never heard of it. What is it, and what was it built to keep out?  
**A:** The Dingo Fence, also called the Dog Fence, stretches over 5,600 kilometres across southeastern Australia — more than twice the length of the Great Wall of China. It was built in the 1880s to keep dingoes out of sheep-grazing lands in the south and is still actively maintained today.  
**Alt answers:** the Dingo Fence, the Dog Fence in Australia, an Australian fence to keep out dingoes, the world's longest fence in Australia  
**Topic:** Geography & History | **Difficulty:** medium | **Tags:** geography, Australia, records, history, engineering, fences  
**Source URL:** https://en.wikipedia.org/wiki/Dingo_fence  
**Source excerpt:** The Dingo Fence (also called the Dog Fence) is a pest-exclusion fence built in Australia during the 1880s to protect sheep in the southeast from dingo predation. At 5,614 km (3,488 mi) long, it is the longest fence in the world and one of the longest structures ever built by humans.

---

### gen035_q16 — Score 8.2 ✓
**Q:** Play-Doh is one of the best-selling children's toys in history — billions of cans sold worldwide. But it was never meant to be a toy. What was Play-Doh originally invented to do?  
**A:** It was invented in the early 1950s as a wallpaper cleaner — designed specifically to remove coal soot from wallpaper in homes heated by coal. When coal heating declined, demand for the cleaner collapsed. The inventor's sister-in-law, a nursery school teacher, suggested repackaging it as a children's modelling compound — and Play-Doh was born.  
**Alt answers:** a wallpaper cleaner, to clean soot from wallpaper, a household cleaning product, to remove coal residue  
**Topic:** Business & History | **Difficulty:** easy | **Tags:** history, business, invention, Play-Doh, accident, toys  
**Source URL:** https://en.wikipedia.org/wiki/Play-Doh  
**Source excerpt:** Play-Doh was originally created in the early 1950s by Noah McVicker as a pliable compound for removing coal residue from wallpaper. Commercially it struggled. McVicker's sister-in-law, nursery school teacher Kay Zufall, recognised its potential as a children's modelling compound, and the product was repackaged as Play-Doh in 1956. It became one of the best-selling toys in history, with hundreds of millions of cans sold.

---

### gen035_q17 — Score 8.2 ✓
**Q:** Alexander Fleming discovered penicillin in 1928 from a petri dish that appeared to be completely ruined. A mould had accidentally contaminated it and killed the bacteria he was carefully growing. Why didn't Fleming simply throw the ruined experiment away?  
**A:** He noticed something odd about the contamination: a clear, bacteria-free halo had formed around the mould. Whatever the mould was producing was killing the bacteria around it. That observation — on an experiment that appeared to be garbage — led directly to penicillin, which has since saved an estimated 200 million lives.  
**Alt answers:** he noticed the bacteria had died around the mould, he saw a clear ring where the bacteria were dead, the mould was killing the bacteria and he was curious  
**Topic:** Science & History | **Difficulty:** medium | **Tags:** history, medicine, penicillin, discovery, Fleming, biology, accident  
**Source URL:** https://en.wikipedia.org/wiki/Alexander_Fleming  
**Source excerpt:** In September 1928, Alexander Fleming returned from holiday to find a mould (Penicillium notatum) had contaminated one of his petri dishes. Rather than discarding it, he noticed that the bacteria near the mould had been destroyed, forming a clear zone around the mould colony. Fleming identified this as evidence of a powerful antibacterial substance he named penicillin. The accidental discovery is considered one of the most consequential in medical history, and the antibiotic derived from it is estimated to have saved hundreds of millions of lives.

---

### gen035_q18 — Score 8.0 ✓
**Q:** For most of the 20th century, singing "Happy Birthday to You" in a commercial setting — in a restaurant, in a film — required paying royalties. When did the song finally become free to use, and what ended the copyright?  
**A:** In 2016, a US federal judge ruled that the original 1893 copyright only covered a specific piano arrangement, not the melody or lyrics. After a lawsuit by documentary filmmakers, "Happy Birthday" was declared public domain. Warner/Chappell Music had been collecting around two million dollars a year from the song — for about 80 years.  
**Alt answers:** in 2016, after a lawsuit found the copyright invalid, when a court ruled the lyrics were never truly copyrighted, 2016 court ruling  
**Topic:** Music & Law | **Difficulty:** medium | **Tags:** music, law, copyright, history, culture  
**Source URL:** https://en.wikipedia.org/wiki/Happy_Birthday_to_You  
**Source excerpt:** In 2013, Good Morning to You Productions sued Warner/Chappell Music, disputing the copyright to "Happy Birthday to You." In 2015, U.S. District Judge George H. King ruled that Warner/Chappell's copyright to the lyrics was invalid. A 2016 settlement placed the song in the public domain. Warner/Chappell had been collecting approximately $2 million annually in licensing fees.

---

### gen035_q19 — Score 8.0 ✓
**Q:** The bicycle was invented in the 1800s and has been ridden by billions of people. But for over 150 years, physicists and engineers struggled to explain exactly why a moving bicycle stays upright on its own. The popular explanation — that spinning-wheel gyroscopic effects keep it balanced — turned out to be incomplete. Was the mystery ever fully solved?  
**A:** Yes, but not until 2011 — when a study in Science built a special bicycle that eliminated gyroscopic forces and front-wheel trail, yet it still self-balanced. This proved that bicycle stability involves multiple interacting factors and that the field had been oversimplifying the answer for more than a century. A question ridden past by billions, unsolved by physics for 150 years.  
**Alt answers:** yes, in 2011, a 2011 Science paper finally explained it, yes but not until recently, it was solved in 2011  
**Topic:** Physics & Technology | **Difficulty:** hard | **Tags:** physics, cycling, science, history, mystery, engineering  
**Source URL:** https://en.wikipedia.org/wiki/Bicycle_and_motorcycle_dynamics  
**Source excerpt:** The physical mechanisms enabling bicycle self-stability were not fully resolved until a landmark 2011 paper in Science (Kooijman et al.), which experimentally disproved the longstanding theory that gyroscopic effects alone explain self-stability. The researchers built a bicycle with no gyroscopic contribution and no front-wheel trail that nevertheless self-balanced, demonstrating that multiple interacting factors contribute to bicycle stability — a question open for over 150 years.

---

## Dropped Candidates

| Candidate | Reason |
|---|---|
| Anglo-Zanzibar War | **DUPLICATE** — identical to gen034_q14 (batch-04-general.md) |
| Superglue double-discovery | Below 8.0 threshold (scored 7.8 — interesting but too factually dry) |
| Dead Sea shrinkage | Below 8.0 threshold (scored 7.5 — too well-known, low surprise) |
| QWERTY keyboard myth | Below 8.0 threshold (scored 7.5 — debunking a myth but myth itself is widespread) |
