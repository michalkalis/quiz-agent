"""Default examples for prompt template."""

# 5 EXCELLENT examples with WHY explanations
EXCELLENT_EXAMPLES = """
**Example 1: Clever Wordplay**
Q: "Which writer's name is an anagram of 'I am a weakish speller'?"
A: William Shakespeare
**WHY EXCELLENT:** Combines wordplay with famous figure. Creates "aha!" moment when solved. Educational and entertaining.

**Example 2: Surprising Fact**
Q: "What temperature is the same in Celsius and Fahrenheit?"
A: -40 degrees
**WHY EXCELLENT:** Counterintuitive fact that surprises people. Mathematical elegance. Educational value.

**Example 3: Unexpected Connection**
Q: "Which spice was so prized the Dutch traded Manhattan for a tiny Indonesian island to control it?"
A: Nutmeg
**WHY EXCELLENT:** Surprising historical fact. Links familiar place (Manhattan) with unexpected answer. Teaches interesting history.

**Example 4: Scientific Wonder**
Q: "Which planet has a hexagon-shaped storm at its north pole?"
A: Saturn
**WHY EXCELLENT:** Fascinating space fact most people don't know. Visually striking. Universal appeal.

**Example 5: Biological Curiosity**
Q: "Which animal has cube-shaped feces, a feature believed to help mark territory?"
A: Wombat
**WHY EXCELLENT:** Quirky, memorable fact. Unexpected answer. Makes people laugh and learn.
"""

# 3 OK examples with WHY explanations
OK_EXAMPLES = """
**Example 1: Adequate but Predictable**
Q: "What is the capital of France?"
A: Paris
**WHY JUST OK:** Correct trivia but too common. No surprise factor. Everyone knows this. Could add interesting angle about why/how Paris became capital.

**Example 2: Basic Knowledge**
Q: "What year did World War II end?"
A: 1945
**WHY JUST OK:** Important historical fact but straightforward. Lacks engaging hook. Could frame it with surprising detail (e.g., "VJ Day was celebrated on which date?").

**Example 3: Simple Science**
Q: "How many planets are in our solar system?"
A: 8 (or 9 if including Pluto debate)
**WHY JUST OK:** Basic astronomy but could be controversial (Pluto). Lacks surprise. Could improve by asking about dwarf planets or asking "why was Pluto reclassified?"
"""

# Bad examples from user feedback (dynamic, will be populated at runtime)
BAD_EXAMPLES_TEMPLATE = """
## User-Flagged Questions (Avoid these!)

The following questions were rated poorly by users in live quizzes:

{user_bad_examples}

**Common issues:** Too easy/hard for stated difficulty, unclear wording, niche references, boring format.
"""
