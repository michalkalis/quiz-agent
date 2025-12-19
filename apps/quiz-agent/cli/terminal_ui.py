#!/usr/bin/env python3
"""Interactive Terminal UI for Quiz Agent - uses the Quiz Agent API."""

import sys
from typing import Optional
from rich.console import Console
from rich.panel import Panel
from rich.prompt import Prompt, IntPrompt, Confirm
from rich.table import Table
from rich.progress import Progress, SpinnerColumn, TextColumn
from rich.markdown import Markdown
from rich import box

from client import QuizClient, QuizAPIError, Question, Evaluation, Participant


class QuizTerminalUI:
    """Interactive terminal interface for the Quiz Agent."""

    def __init__(self, api_url: str = "http://localhost:8002/api/v1"):
        self.console = Console()
        self.client = QuizClient(base_url=api_url)
        self.current_question: Optional[Question] = None
        self.current_participant: Optional[Participant] = None
        # Default quiz settings
        self.quiz_settings = {
            "num_questions": 10,
            "difficulty": "random",  # Will be randomized if "random" is selected
            "category": ""  # Empty means all categories
        }

    def clear_screen(self):
        """Clear the terminal screen."""
        self.console.clear()

    def show_welcome(self):
        """Display welcome screen."""
        welcome_text = """
# 🎯 Quiz Agent Terminal

Welcome to the AI-powered quiz experience!

**Features:**
- Natural language input (e.g., "Paris, but too easy")
- Smart answer evaluation with partial credit
- Adaptive difficulty (say "harder" or "easier")
- Topic preferences (say "no more geography")

**Commands:**
- `start` - Start quiz with current settings
- `settings` - Configure quiz settings
- `quit` - Exit application

**During Quiz:**
- Type your answer naturally
- `skip` - Skip current question
- `quit` - End quiz
- `harder` / `easier` - Adjust difficulty
        """

        self.console.print(Panel(
            Markdown(welcome_text),
            title="Welcome",
            border_style="cyan",
            box=box.DOUBLE
        ))
        self.console.print()

    def check_backend(self) -> bool:
        """Check if the backend API is running."""
        with Progress(
            SpinnerColumn(),
            TextColumn("[progress.description]{task.description}"),
            console=self.console,
            transient=True
        ) as progress:
            progress.add_task(description="Connecting to Quiz Agent API...", total=None)

            if self.client.check_health():
                self.console.print("✅ [green]Connected to Quiz Agent API[/green]\n")
                return True
            else:
                self.console.print("❌ [red]Cannot connect to Quiz Agent API[/red]")
                self.console.print("\n[yellow]Make sure the API is running:[/yellow]")
                self.console.print("  cd apps/quiz-agent")
                self.console.print("  python -m app.main\n")
                return False

    def show_settings(self):
        """Display current quiz settings."""
        difficulty_display = self.quiz_settings["difficulty"]
        if difficulty_display == "random":
            difficulty_display = "random (any)"
        
        category_display = self.quiz_settings["category"] if self.quiz_settings["category"] else "all"
        
        settings_text = f"""
**Current Settings:**
- Number of questions: {self.quiz_settings["num_questions"]}
- Starting difficulty: {difficulty_display}
- Category: {category_display}
        """
        
        self.console.print(Panel(
            Markdown(settings_text),
            title="Quiz Settings",
            border_style="cyan",
            box=box.ROUNDED
        ))
        self.console.print()

    def configure_settings(self):
        """Configure quiz settings interactively."""
        self.console.print("[bold cyan]Configure Quiz Settings[/bold cyan]\n")
        
        # Number of questions
        num_questions = IntPrompt.ask(
            "Number of questions",
            default=self.quiz_settings["num_questions"],
            console=self.console
        )
        self.quiz_settings["num_questions"] = num_questions
        
        # Difficulty
        difficulty = Prompt.ask(
            "Starting difficulty",
            choices=["easy", "medium", "hard", "random"],
            default=self.quiz_settings["difficulty"],
            console=self.console
        )
        self.quiz_settings["difficulty"] = difficulty
        
        # Category
        category = Prompt.ask(
            "Category (optional, leave empty for all)",
            default=self.quiz_settings["category"],
            console=self.console
        )
        self.quiz_settings["category"] = category.strip() if category else ""
        
        self.console.print("\n✅ [green]Settings saved![/green]\n")

    def start_quiz(self) -> bool:
        """Start quiz with current settings."""
        try:
            # Show current settings
            self.console.print("[bold cyan]Starting Quiz[/bold cyan]\n")
            self.show_settings()

            # Keep difficulty as-is (including "random" which will vary per question)
            difficulty = self.quiz_settings["difficulty"]
            difficulty_display = difficulty
            if difficulty == "random":
                difficulty_display = "random (varies per question)"

            # Create session
            with Progress(
                SpinnerColumn(),
                TextColumn("[progress.description]{task.description}"),
                console=self.console,
                transient=True
            ) as progress:
                progress.add_task(description="Creating quiz session...", total=None)

                session_data = self.client.create_session(
                    max_questions=self.quiz_settings["num_questions"],
                    difficulty=difficulty,
                    category=self.quiz_settings["category"] if self.quiz_settings["category"] else None
                )

            self.console.print(f"✅ [green]Session created: {self.client.session_id}[/green]")
            self.console.print(f"📝 Questions: {self.quiz_settings['num_questions']} | Difficulty: {difficulty_display}\n")

            # Start quiz
            with Progress(
                SpinnerColumn(),
                TextColumn("[progress.description]{task.description}"),
                console=self.console,
                transient=True
            ) as progress:
                progress.add_task(description="Starting quiz...", total=None)
                result = self.client.start_quiz()

            # Parse first question
            self.current_question = self.client.parse_question(result)
            self.current_participant = self.client.parse_participant(result)

            return True

        except QuizAPIError as e:
            self.console.print(f"\n❌ [red]Error: {e}[/red]\n")
            return False

    def display_question(self, question: Question, question_num: int, max_questions: int):
        """Display the current question."""
        # Create question panel
        question_text = f"\n[bold white]{question.question}[/bold white]\n"

        # Add metadata
        metadata = (
            f"[dim]Topic: {question.topic} | "
            f"Difficulty: {question.difficulty} | "
            f"Type: {question.type}[/dim]"
        )

        self.console.print(Panel(
            question_text + metadata,
            title=f"Question {question_num}/{max_questions}",
            border_style="yellow",
            box=box.ROUNDED
        ))

        # If multiple choice, show options
        if question.possible_answers:
            self.console.print("\n[bold]Options:[/bold]")
            for key, value in question.possible_answers.items():
                self.console.print(f"  [cyan]{key}[/cyan]: {value}")
            self.console.print()

    def display_evaluation(self, evaluation: Evaluation, participant: Participant):
        """Display answer evaluation results."""
        # Result emoji and color
        result_display = {
            "correct": ("✅", "green", "Correct!"),
            "partially_correct": ("⚠️", "yellow", "Partially Correct"),
            "partially_incorrect": ("⚠️", "orange1", "Partially Incorrect"),
            "incorrect": ("❌", "red", "Incorrect"),
            "skipped": ("⏭️", "dim", "Skipped")
        }

        emoji, color, text = result_display.get(
            evaluation.result,
            ("❓", "white", "Unknown")
        )

        # Create result panel
        result_text = f"{emoji} [{color}]{text}[/{color}]\n\n"
        result_text += f"Your answer: [cyan]{evaluation.user_answer}[/cyan]\n"
        result_text += f"Correct answer: [green]{evaluation.correct_answer}[/green]\n"
        result_text += f"Points: [bold]{evaluation.points:+.1f}[/bold]"

        self.console.print()
        self.console.print(Panel(
            result_text,
            title="Result",
            border_style=color,
            box=box.ROUNDED
        ))

        # Display score
        self.display_score(participant)

    def display_score(self, participant: Participant):
        """Display current score."""
        score_text = (
            f"Score: [bold cyan]{participant.score:.1f}[/bold cyan] / "
            f"{participant.answered_count} questions"
        )

        if participant.answered_count > 0:
            percentage = (participant.score / participant.answered_count) * 100
            score_text += f" ([bold]{percentage:.0f}%[/bold])"

        self.console.print(f"\n{score_text}\n")

    def display_feedback_received(self, feedback_list: list):
        """Display AI parsing feedback."""
        if not feedback_list:
            return

        self.console.print("[dim]AI understood:[/dim]")
        for feedback in feedback_list:
            self.console.print(f"  • [dim]{feedback}[/dim]")
        self.console.print()

    def get_user_input(self) -> str:
        """Get input from user."""
        return Prompt.ask("\n[bold cyan]Your answer[/bold cyan]", console=self.console)

    def ask_rating(self) -> Optional[int]:
        """Ask user to rate the question (optional)."""
        if not Confirm.ask(
            "\n[dim]Rate this question? (optional)[/dim]",
            default=False,
            console=self.console
        ):
            return None

        rating = IntPrompt.ask(
            "Rating (1=bad, 5=great)",
            choices=["1", "2", "3", "4", "5"],
            console=self.console
        )
        return rating

    def display_final_results(self, participant: Participant, max_questions: int):
        """Display final quiz results."""
        self.console.print("\n")
        self.console.print("=" * 50)
        self.console.print()

        # Create results table
        table = Table(title="🎉 Quiz Complete!", box=box.ROUNDED, show_header=False)
        table.add_row("Final Score", f"[bold cyan]{participant.score:.1f}[/bold cyan] / {max_questions}")

        percentage = (participant.score / max_questions) * 100
        table.add_row("Percentage", f"[bold]{percentage:.0f}%[/bold]")
        table.add_row("Questions Answered", str(participant.answered_count))

        self.console.print(table)
        self.console.print()

        # Performance message
        if percentage >= 80:
            self.console.print("🌟 [green bold]Excellent performance![/green bold]")
        elif percentage >= 60:
            self.console.print("👍 [yellow]Good job![/yellow]")
        else:
            self.console.print("💪 [cyan]Keep practicing![/cyan]")

        self.console.print()

    def run_quiz_loop(self) -> bool:
        """Main quiz interaction loop."""
        try:
            # Get session state for max_questions
            session_state = self.client.get_session()
            max_questions = session_state.get("max_questions", 10)
            question_number = 1

            while self.current_question:
                # Display question
                self.display_question(self.current_question, question_number, max_questions)

                # Get user input
                user_input = self.get_user_input()

                # Check for quit command
                if user_input.lower() in ["quit", "exit", "q"]:
                    if Confirm.ask("\n[yellow]Are you sure you want to quit?[/yellow]", console=self.console):
                        self.console.print("\n[dim]Thanks for playing![/dim]\n")
                        return False
                    else:
                        continue

                # Submit input to API
                with Progress(
                    SpinnerColumn(),
                    TextColumn("[progress.description]{task.description}"),
                    console=self.console,
                    transient=True
                ) as progress:
                    progress.add_task(description="Processing your answer...", total=None)
                    result = self.client.submit_input(user_input)

                # Parse response
                evaluation = self.client.parse_evaluation(result)
                self.current_participant = self.client.parse_participant(result)
                feedback_list = result.get("feedback_received", [])

                # Display results
                if evaluation:
                    self.display_evaluation(evaluation, self.current_participant)
                    self.display_feedback_received(feedback_list)

                    # Optional rating
                    rating = self.ask_rating()
                    if rating:
                        try:
                            self.client.rate_question(rating)
                            self.console.print("[dim]✓ Rating submitted[/dim]\n")
                        except QuizAPIError:
                            pass  # Silent fail for ratings

                # Get next question
                next_question = self.client.parse_question(result)

                # Check if quiz is complete
                session_data = result.get("session", {})
                phase = session_data.get("phase", "")

                if phase == "finished" or not next_question:
                    # Quiz complete
                    self.display_final_results(self.current_participant, max_questions)
                    return True

                self.current_question = next_question
                question_number += 1

                # Pause before next question
                self.console.print("[dim]Press Enter for next question...[/dim]", end="")
                input()
                self.clear_screen()

            return True

        except QuizAPIError as e:
            self.console.print(f"\n❌ [red]Error: {e}[/red]\n")
            return False
        except KeyboardInterrupt:
            self.console.print("\n\n[yellow]Quiz interrupted[/yellow]\n")
            return False

    def run_command_loop(self):
        """Main command loop before starting quiz."""
        while True:
            command = Prompt.ask(
                "\n[bold cyan]Command[/bold cyan]",
                choices=["start", "settings", "quit", "help"],
                default="start",
                console=self.console
            )
            
            if command == "start":
                if self.start_quiz():
                    # Run quiz loop
                    self.run_quiz_loop()
                    # Cleanup after quiz
                    try:
                        self.client.delete_session()
                    except QuizAPIError:
                        pass  # Silent fail on cleanup
                    # Return to command loop
                    self.console.print("\n[dim]Returning to main menu...[/dim]\n")
                else:
                    # Failed to start, stay in command loop
                    continue
                    
            elif command == "settings":
                self.configure_settings()
                
            elif command == "help":
                self.show_welcome()
                
            elif command == "quit":
                self.console.print("\n[yellow]Goodbye![/yellow]\n")
                return

    def run(self):
        """Main entry point for the terminal UI."""
        try:
            self.clear_screen()
            self.show_welcome()

            # Check backend connection
            if not self.check_backend():
                sys.exit(1)

            # Show current settings
            self.show_settings()

            # Run command loop
            self.run_command_loop()

        except KeyboardInterrupt:
            self.console.print("\n\n[yellow]Goodbye![/yellow]\n")
            sys.exit(0)


def main():
    """Entry point for the terminal client."""
    import argparse

    parser = argparse.ArgumentParser(description="Quiz Agent Terminal Client")
    parser.add_argument(
        "--api-url",
        default="http://localhost:8002/api/v1",
        help="Quiz Agent API URL (default: http://localhost:8002/api/v1)"
    )

    args = parser.parse_args()

    ui = QuizTerminalUI(api_url=args.api_url)
    ui.run()


if __name__ == "__main__":
    main()
