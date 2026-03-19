#!/usr/bin/env python3
"""Apply suggested fixes to needs_fix questions and produce import-ready JSON.

Reads report files for fixes, matches to enriched files for full question data,
applies corrections, and outputs a single importable file.

Usage:
    python scripts/apply_fixes.py
"""

import json
import hashlib
import glob
from pathlib import Path
from copy import deepcopy


VERIFICATION_DIR = Path("data/verification")
OUTPUT = VERIFICATION_DIR / "import_fixed.json"


def generate_id(question: dict) -> str:
    topic = question.get("topic", "unknown").lower().replace(" ", "_")
    text_hash = hashlib.sha256(question["question"].encode()).hexdigest()[:12]
    return f"q_{topic}_{text_hash}"


def find_enriched_question(question_text: str) -> dict | None:
    """Find a question in enriched files by its text."""
    for path in VERIFICATION_DIR.glob("enriched_*.json"):
        with open(path) as f:
            data = json.load(f)
        questions = data if isinstance(data, list) else data.get("questions", [])
        for q in questions:
            if q["question"] == question_text:
                return deepcopy(q)
    return None


# Each fix is a function that takes the enriched question dict and returns the fixed version
FIXES = {
    # Fix #1: Escher - rework question
    "Which Dutch artist drew a lithograph of an endless staircase": lambda q: {
        **q,
        "question": "Which Dutch artist created lithographs of impossible structures like endless staircases and perpetual waterfalls, inspiring mathematicians and architects alike?",
        "correct_answer": "M. C. Escher",
        "alternative_answers": ["Escher", "MC Escher", "Maurits Cornelis Escher"],
    },
    # Fix #2: Thorium - fix "mischievous" to "thunder"
    "Which element is named after a mischievous Norse god": lambda q: {
        **q,
        "question": "Which element is named after the Norse god of thunder?",
    },
    # Fix #3: Flammable - they're synonyms, not antonyms
    "What common English word becomes its own antonym when prefixed": lambda q: {
        **q,
        "question": 'Which English word confusingly keeps the same meaning even when you add the prefix "in-", despite "in-" usually meaning "not"?',
        "correct_answer": "Flammable",
        "alternative_answers": ["inflammable", "flammable / inflammable"],
    },
    # Fix #4: Newton - scientist, not athlete
    "Which athlete's name is also a unit of measurement in physics": lambda q: {
        **q,
        "question": "Which famous scientist's surname is also an SI unit of force in physics?",
    },
    # Fix #5: Olive oil - remove "only substance" claim
    "In the ancient Greek Olympics, athletes competed completely naked. What was the": lambda q: {
        **q,
        "question": "In the ancient Greek Olympics, athletes competed completely naked. What substance did they rub all over their bodies before competing?",
    },
    # Fix #6: Microwave - candy bar not chocolate bar
    "The microwave oven was invented entirely by accident in 1945": lambda q: {
        **q,
        "correct_answer": "A candy bar",
        "alternative_answers": ["candy bar", "chocolate bar", "peanut cluster bar", "Mr. Goodbar"],
    },
    # Fix #7: Smartphone vs Apollo - 100 million not 100,000
    "Your smartphone has more computing power than the computers that guided Apollo": lambda q: {
        **q,
        "correct_answer": "About 100 million times",
        "alternative_answers": ["100 million times", "a hundred million times"],
    },
    # Fix #8: Wood frog - ice between cells, not inside
    "One North American frog survives winter by letting its body freeze": lambda q: {
        **q,
        "question": q["question"].replace("ice forming inside its cells", "ice crystals forming between its cells"),
        "alternative_answers": [a for a in q.get("alternative_answers", []) if a.lower() != "glycerol"],
    },
    # Fix #9: Goalkeeper goal - 96 metres
    "In football (soccer), a goalkeeper once scored a goal from inside his own": lambda q: {
        **q,
        "correct_answer": "About 96 metres",
        "alternative_answers": ["96 metres", "95 metres", "96.01 metres"],
    },
    # Fix #10: SpaceX landing attempts - complex, just soften
    "SpaceX lands its rocket boosters vertically after launch": lambda q: {
        **q,
        "correct_answer": "About 20",
        "alternative_answers": ["20", "over 20", "around 20"],
    },
    # Fix #11: Apollo vs Instagram - fix ratio
    "The entire codebase for the Apollo 11 moon landing guidance computer was about 1": lambda q: {
        **q,
        "correct_answer": "About 7 times",
        "alternative_answers": ["7 times", "about 5 times", "5 times"],
    },
    # Fix #12: Gallium - not "common" metal
    "Which common metal has such a low melting point": lambda q: {
        **q,
        "question": "Which metal has such a low melting point that it will literally melt if you hold it in your hand?",
    },
    # Fix #13: Modern pentathlon - horse riding replaced
    "Which Olympic sport requires athletes to compete in five completely different di": lambda q: {
        **q,
        "question": "Which Olympic sport traditionally required athletes to compete in five disciplines — fencing, swimming, horse riding, running, and shooting — before horse riding was replaced in 2024?",
    },
    # Fix #14: Machiavellian - fictional literary source, not character
    "Which of these words does NOT come from a fictional literary character": lambda q: {
        **q,
        "question": q["question"].replace("fictional literary character", "a work of fiction"),
    },
    # Fix #15: Nerd etymology - soften the claim
    "Which common English word — now used to describe someone intensely studious": lambda q: {
        **q,
        "question": q["question"].replace(
            "first appeared in print as a made-up creature",
            "is believed to have first appeared in print as a made-up creature"
        ) if "first appeared in print" in q["question"] else q["question"],
    },
    # Fix #16: Star Wars blaster - hammer not wrench
    "The sound designers of the original Star Wars created the iconic blaster": lambda q: {
        **q,
        "question": q["question"].replace("with a wrench", "with a hammer") if "with a wrench" in q["question"] else q["question"],
    },
    # Fix #17: Wilhelm Scream - soften count
    "The 'Wilhelm Scream'": lambda q: {
        **q,
        "question": q["question"].replace("over 400 films and TV shows", "hundreds of films and TV shows") if "over 400" in q["question"] else q["question"],
    },
    # Fix #18: LEGO precision - 10 micrometres not 2
    "What children's toy, made of interlocking plastic bricks": lambda q: {
        **q,
        "question": q["question"].replace("2 micrometres", "10 micrometres"),
    },
    # Fix #19: Amazon plume - update source excerpt only (question/answer OK)
    "The Amazon River discharges so much fresh water": lambda q: {
        **q,
        "source_excerpt": "The Amazon's freshwater plume extends about 400 km from the river mouth and is 100-200 km wide, significantly reducing ocean salinity far from shore.",
    },
    # Fix #20: Tour de France - fix comparison
    "The Tour de France is one of sport's most gruelling endurance events": lambda q: {
        **q,
        "question": "The Tour de France is one of sport's most gruelling endurance events. Riders cover roughly 3,400 km over three weeks. That's closest to the straight-line distance from Paris to which city: Rome, Moscow, or Cairo?",
        "correct_answer": "Cairo",
        "alternative_answers": ["cairo", "Paris to Cairo"],
    },
    # Fix #21: ARPANET - remove nuclear war myth
    "The internet was originally developed as a military communication network design": lambda q: {
        **q,
        "question": "The internet traces its origins to a US Department of Defense research project from the late 1960s that linked university and research computers. What was the name of this predecessor to the internet?",
    },
    # Fix #22: Pixar RenderMan - answer is wrong
    "Pixar's 1995 film Toy Story was the first feature-length computer-animated film": lambda q: {
        **q,
        "question": "Pixar's 1995 film Toy Story was the first feature-length computer-animated film. The rendering software Pixar developed was also used for visual effects in earlier live-action films. What is this software called?",
        "correct_answer": "RenderMan",
        "alternative_answers": ["Pixar RenderMan", "PhotoRealistic RenderMan", "PRMan"],
    },
    # Fix #23: Kubrick moon landing - fix framing
    "Stanley Kubrick directed 2001: A Space Odyssey": lambda q: {
        **q,
        "question": "A persistent conspiracy theory claims that the director of 2001: A Space Odyssey was recruited by NASA to fake a famous historical event in a TV studio. Who was the filmmaker, and what event do conspiracy theorists claim he faked?",
        "correct_answer": "Stanley Kubrick — the Apollo 11 Moon landing",
        "alternative_answers": ["Kubrick", "Stanley Kubrick", "the Moon landing", "Apollo 11"],
    },
    # Fix #24: Orwell 1984 - acknowledge uncertainty
    "George Orwell finished writing his famous novel in 1948": lambda q: {
        **q,
        "question": "A popular theory says the title of George Orwell's dystopian novel '1984' was created by a simple transformation of 1948, the year he finished writing. What transformation does the theory suggest?",
    },
    # Fix #25: Genghis Khan Y-chromosome - add qualifier
    "Genetic studies suggest that roughly 1 in every 200 men": lambda q: {
        **q,
        "question": "A widely cited 2003 genetic study suggested that roughly 1 in every 200 men alive today could be a direct descendant of one historical conqueror. Who is this conqueror?",
    },
    # Fix #26: PNG languages - fix false Africa premise
    "There is a country in Africa where over 800 languages": lambda q: {
        **q,
        "question": "One country on Earth has over 840 languages spoken within its borders — more than any other nation. Is it Nigeria, the Democratic Republic of Congo, or Papua New Guinea?",
    },
    # Fix #27: Apollo/Instagram duplicate (batch 013) - same as #11
    # This is a duplicate question, skip it

    # Fix #28: Wizard of Oz - MGM not Warner Bros
    "Warner Bros. nearly rejected": lambda q: {
        **q,
        "question": q["question"].replace("Warner Bros.", "MGM executives"),
    },
}


def match_fix(question_text: str) -> callable | None:
    """Find a fix function that matches this question text."""
    for prefix, fix_fn in FIXES.items():
        if question_text.startswith(prefix):
            return fix_fn
    return None


def main():
    # Collect all needs_fix questions from reports
    needs_fix = []
    for path in sorted(VERIFICATION_DIR.glob("report_*.json")):
        with open(path) as f:
            report = json.load(f)
        for q in report["questions"]:
            if q["verdict"] == "needs_fix":
                needs_fix.append(q)

    print(f"Found {len(needs_fix)} needs_fix questions\n")

    fixed = []
    skipped = []
    seen_texts = set()

    for q in needs_fix:
        q_text = q["question"]

        # Skip duplicates
        if q_text[:80] in seen_texts:
            skipped.append(f"Duplicate: {q_text[:60]}...")
            continue
        seen_texts.add(q_text[:80])

        # Find in enriched files
        enriched = find_enriched_question(q_text)
        if not enriched:
            skipped.append(f"Not found in enriched: {q_text[:60]}...")
            continue

        # Find and apply fix
        fix_fn = match_fix(q_text)
        if not fix_fn:
            skipped.append(f"No fix defined: {q_text[:60]}...")
            continue

        result = fix_fn(enriched)
        # Handle case where fix returns the dict directly (not wrapped)
        if isinstance(result, dict):
            fixed_q = result
        else:
            fixed_q = enriched

        # Ensure ID exists
        if not fixed_q.get("id"):
            fixed_q["id"] = generate_id(fixed_q)

        # Mark as approved since we manually fixed it
        fixed_q["review_status"] = "approved"

        fixed.append(fixed_q)
        print(f"  Fixed: {q_text[:70]}...")

    print(f"\nFixed: {len(fixed)}")
    if skipped:
        print(f"Skipped: {len(skipped)}")
        for s in skipped:
            print(f"  - {s}")

    # Write output
    with open(OUTPUT, "w", encoding="utf-8") as f:
        json.dump(fixed, f, indent=2, ensure_ascii=False)

    print(f"\nWritten to: {OUTPUT}")
    print(f"\nNext step:")
    print(f"  python apps/quiz-agent/import_questions.py \\")
    print(f"    --questions-file {OUTPUT} \\")
    print(f"    --admin-key $ADMIN_API_KEY \\")
    print(f"    --api-url https://quiz-agent-api.fly.dev \\")
    print(f"    --force")


if __name__ == "__main__":
    main()
