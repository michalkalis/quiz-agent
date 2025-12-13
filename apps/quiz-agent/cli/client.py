"""Quiz Agent API Client - handles all HTTP communication with the backend."""

import requests
from typing import Optional, Dict, Any, List
from dataclasses import dataclass


@dataclass
class Question:
    """Represents a quiz question."""
    id: str
    question: str
    type: str
    difficulty: str
    topic: str
    category: str
    possible_answers: Optional[Dict[str, str]] = None


@dataclass
class Evaluation:
    """Represents answer evaluation result."""
    user_answer: str
    result: str  # "correct", "partially_correct", "partially_incorrect", "incorrect", "skipped"
    points: float
    correct_answer: str


@dataclass
class Participant:
    """Represents a quiz participant."""
    participant_id: str
    user_id: str
    display_name: str
    score: float
    answered_count: int
    is_host: bool
    is_ready: bool


class QuizAPIError(Exception):
    """Custom exception for Quiz API errors."""
    pass


class QuizClient:
    """Client for interacting with the Quiz Agent API."""

    def __init__(self, base_url: str = "http://localhost:8002/api/v1"):
        self.base_url = base_url
        self.session_id: Optional[str] = None
        self.participant_id: Optional[str] = None

    def check_health(self) -> bool:
        """Check if the API is running and healthy."""
        try:
            response = requests.get(f"{self.base_url}/health", timeout=2)
            return response.status_code == 200
        except requests.exceptions.RequestException:
            return False

    def create_session(
        self,
        max_questions: int = 10,
        difficulty: str = "medium",
        user_id: Optional[str] = None,
        category: Optional[str] = None,
        ttl_minutes: int = 30
    ) -> Dict[str, Any]:
        """Create a new quiz session."""
        payload = {
            "max_questions": max_questions,
            "difficulty": difficulty,
            "mode": "single",
            "ttl_minutes": ttl_minutes
        }

        if user_id:
            payload["user_id"] = user_id
        if category:
            payload["category"] = category

        try:
            response = requests.post(f"{self.base_url}/sessions", json=payload)
            response.raise_for_status()
            data = response.json()

            self.session_id = data["session_id"]
            if data.get("participants"):
                self.participant_id = data["participants"][0]["participant_id"]

            return data
        except requests.exceptions.RequestException as e:
            raise QuizAPIError(f"Failed to create session: {e}")

    def start_quiz(self) -> Dict[str, Any]:
        """Start the quiz and get the first question."""
        if not self.session_id:
            raise QuizAPIError("No active session. Create a session first.")

        try:
            response = requests.post(
                f"{self.base_url}/sessions/{self.session_id}/start",
                json={}
            )
            response.raise_for_status()
            return response.json()
        except requests.exceptions.RequestException as e:
            raise QuizAPIError(f"Failed to start quiz: {e}")

    def submit_input(self, user_input: str) -> Dict[str, Any]:
        """
        Submit user input (answer, command, or natural language).
        The AI will parse it and handle accordingly.
        """
        if not self.session_id:
            raise QuizAPIError("No active session. Create a session first.")

        payload = {"input": user_input}
        if self.participant_id:
            payload["participant_id"] = self.participant_id

        try:
            response = requests.post(
                f"{self.base_url}/sessions/{self.session_id}/input",
                json=payload
            )
            response.raise_for_status()
            return response.json()
        except requests.exceptions.RequestException as e:
            raise QuizAPIError(f"Failed to submit input: {e}")

    def rate_question(self, rating: int, feedback_text: Optional[str] = None) -> Dict[str, Any]:
        """Rate the current question (1-5 stars)."""
        if not self.session_id:
            raise QuizAPIError("No active session. Create a session first.")

        payload = {"rating": rating}
        if self.participant_id:
            payload["participant_id"] = self.participant_id
        if feedback_text:
            payload["feedback_text"] = feedback_text

        try:
            response = requests.post(
                f"{self.base_url}/sessions/{self.session_id}/rate",
                json=payload
            )
            response.raise_for_status()
            return response.json()
        except requests.exceptions.RequestException as e:
            raise QuizAPIError(f"Failed to rate question: {e}")

    def get_session(self) -> Dict[str, Any]:
        """Get current session state."""
        if not self.session_id:
            raise QuizAPIError("No active session. Create a session first.")

        try:
            response = requests.get(f"{self.base_url}/sessions/{self.session_id}")
            response.raise_for_status()
            return response.json()
        except requests.exceptions.RequestException as e:
            raise QuizAPIError(f"Failed to get session: {e}")

    def delete_session(self) -> Dict[str, Any]:
        """Delete the current session."""
        if not self.session_id:
            raise QuizAPIError("No active session.")

        try:
            response = requests.delete(f"{self.base_url}/sessions/{self.session_id}")
            response.raise_for_status()
            result = response.json()

            # Clear session data
            self.session_id = None
            self.participant_id = None

            return result
        except requests.exceptions.RequestException as e:
            raise QuizAPIError(f"Failed to delete session: {e}")

    def transcribe_audio(self, audio_file_path: str) -> Dict[str, Any]:
        """Transcribe audio file to text using Whisper API."""
        try:
            with open(audio_file_path, 'rb') as audio_file:
                files = {'audio': audio_file}
                response = requests.post(f"{self.base_url}/voice/transcribe", files=files)
                response.raise_for_status()
                return response.json()
        except requests.exceptions.RequestException as e:
            raise QuizAPIError(f"Failed to transcribe audio: {e}")

    def submit_voice(self, audio_file_path: str) -> Dict[str, Any]:
        """Transcribe audio and submit as answer in one step."""
        if not self.session_id:
            raise QuizAPIError("No active session. Create a session first.")

        try:
            with open(audio_file_path, 'rb') as audio_file:
                files = {'audio': audio_file}
                data = {}
                if self.participant_id:
                    data['participant_id'] = self.participant_id

                response = requests.post(
                    f"{self.base_url}/voice/submit/{self.session_id}",
                    files=files,
                    data=data
                )
                response.raise_for_status()
                return response.json()
        except requests.exceptions.RequestException as e:
            raise QuizAPIError(f"Failed to submit voice: {e}")

    @staticmethod
    def parse_question(data: Dict[str, Any]) -> Optional[Question]:
        """Parse question data from API response."""
        question_data = data.get("current_question")
        if not question_data:
            return None

        return Question(
            id=question_data["id"],
            question=question_data["question"],
            type=question_data["type"],
            difficulty=question_data["difficulty"],
            topic=question_data["topic"],
            category=question_data["category"],
            possible_answers=question_data.get("possible_answers")
        )

    @staticmethod
    def parse_evaluation(data: Dict[str, Any]) -> Optional[Evaluation]:
        """Parse evaluation data from API response."""
        eval_data = data.get("evaluation")
        if not eval_data:
            return None

        return Evaluation(
            user_answer=eval_data["user_answer"],
            result=eval_data["result"],
            points=eval_data["points"],
            correct_answer=eval_data["correct_answer"]
        )

    @staticmethod
    def parse_participant(data: Dict[str, Any]) -> Optional[Participant]:
        """Parse participant data from session response."""
        session_data = data.get("session", data)
        participants = session_data.get("participants", [])

        if not participants:
            return None

        p = participants[0]  # Get first participant (single player mode)
        return Participant(
            participant_id=p["participant_id"],
            user_id=p["user_id"],
            display_name=p["display_name"],
            score=p["score"],
            answered_count=p["answered_count"],
            is_host=p["is_host"],
            is_ready=p["is_ready"]
        )
