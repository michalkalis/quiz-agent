#!/usr/bin/env python3
"""Quick script to populate the database with sample questions."""

import sys
import os

# Load .env file
from dotenv import load_dotenv
load_dotenv()

sys.path.insert(0, os.path.join(os.path.dirname(__file__), 'packages/shared'))

from quiz_shared.database.chroma_client import ChromaDBClient
from quiz_shared.models.question import Question
from datetime import datetime

# Initialize ChromaDB
client = ChromaDBClient(
    collection_name="quiz_questions",
    persist_directory="./data/chromadb"
)

print("Populating database with sample questions...")

# Sample questions
questions = [
    # Geography
    Question(id="q_geo_001", question="What is the capital of France?", correct_answer="Paris",
             type="text", difficulty="easy", topic="Geography", category="general",
             alternative_answers=["paris"], created_at=datetime.now(), source="manual"),
    Question(id="q_geo_002", question="Which country has the longest coastline in the world?", correct_answer="Canada",
             type="text", difficulty="medium", topic="Geography", category="general",
             alternative_answers=["canada"], created_at=datetime.now(), source="manual"),
    Question(id="q_geo_003", question="What is the smallest country in the world?", correct_answer="Vatican City",
             type="text", difficulty="medium", topic="Geography", category="general",
             alternative_answers=["vatican", "vatican city"], created_at=datetime.now(), source="manual"),

    # History
    Question(id="q_hist_001", question="In what year did World War II end?", correct_answer="1945",
             type="text", difficulty="easy", topic="History", category="general",
             alternative_answers=["1945"], created_at=datetime.now(), source="manual"),
    Question(id="q_hist_002", question="Who was the first President of the United States?", correct_answer="George Washington",
             type="text", difficulty="easy", topic="History", category="general",
             alternative_answers=["washington", "george washington"], created_at=datetime.now(), source="manual"),
    Question(id="q_hist_003", question="In what year did the Berlin Wall fall?", correct_answer="1989",
             type="text", difficulty="medium", topic="History", category="general",
             alternative_answers=["1989"], created_at=datetime.now(), source="manual"),

    # Science
    Question(id="q_sci_001", question="What element has the chemical symbol Au?", correct_answer="Gold",
             type="text", difficulty="easy", topic="Science", category="general",
             alternative_answers=["gold"], created_at=datetime.now(), source="manual"),
    Question(id="q_sci_002", question="What is the speed of light in meters per second?", correct_answer="299,792,458",
             type="text", difficulty="hard", topic="Science", category="general",
             alternative_answers=["299792458", "approximately 300 million"], created_at=datetime.now(), source="manual"),
    Question(id="q_sci_003", question="What planet is known as the Red Planet?", correct_answer="Mars",
             type="text", difficulty="easy", topic="Science", category="general",
             alternative_answers=["mars"], created_at=datetime.now(), source="manual"),

    # Movies
    Question(id="q_mov_001", question="Who directed the movie 'Inception'?", correct_answer="Christopher Nolan",
             type="text", difficulty="medium", topic="Movies", category="general",
             alternative_answers=["nolan", "christopher nolan"], created_at=datetime.now(), source="manual"),
    Question(id="q_mov_002", question="What year was the first Toy Story movie released?", correct_answer="1995",
             type="text", difficulty="medium", topic="Movies", category="general",
             alternative_answers=["1995"], created_at=datetime.now(), source="manual"),

    # Music
    Question(id="q_mus_001", question="Which band released the album 'Abbey Road'?", correct_answer="The Beatles",
             type="text", difficulty="easy", topic="Music", category="general",
             alternative_answers=["beatles", "the beatles"], created_at=datetime.now(), source="manual"),
    Question(id="q_mus_002", question="Who is known as the King of Pop?", correct_answer="Michael Jackson",
             type="text", difficulty="easy", topic="Music", category="general",
             alternative_answers=["michael jackson", "jackson"], created_at=datetime.now(), source="manual"),

    # Sports
    Question(id="q_spt_001", question="How many players are on a soccer team on the field?", correct_answer="11",
             type="text", difficulty="easy", topic="Sports", category="general",
             alternative_answers=["eleven", "11"], created_at=datetime.now(), source="manual"),
    Question(id="q_spt_002", question="In which sport would you perform a slam dunk?", correct_answer="Basketball",
             type="text", difficulty="easy", topic="Sports", category="general",
             alternative_answers=["basketball"], created_at=datetime.now(), source="manual"),

    # Technology
    Question(id="q_tech_001", question="What does CPU stand for?", correct_answer="Central Processing Unit",
             type="text", difficulty="medium", topic="Technology", category="general",
             alternative_answers=["central processing unit"], created_at=datetime.now(), source="manual"),
    Question(id="q_tech_002", question="Who founded Microsoft?", correct_answer="Bill Gates",
             type="text", difficulty="easy", topic="Technology", category="general",
             alternative_answers=["bill gates", "gates", "bill gates and paul allen"], created_at=datetime.now(), source="manual"),
]

# Add questions to database
for q in questions:
    try:
        client.add_question(q)
        print(f"✓ Added: {q.question[:50]}...")
    except Exception as e:
        print(f"✗ Failed to add question: {e}")

# Verify
total = client.count_questions()
print(f"\n✅ Database populated with {total} questions!")
print(f"   - Easy: {client.count_questions({'difficulty': 'easy'})}")
print(f"   - Medium: {client.count_questions({'difficulty': 'medium'})}")
print(f"   - Hard: {client.count_questions({'difficulty': 'hard'})}")
