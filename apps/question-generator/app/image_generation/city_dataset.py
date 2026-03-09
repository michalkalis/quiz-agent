"""Curated city dataset for blind map questions.

Cities selected for distinctive geographic features (coast, rivers, distinctive layout).
MVP: ~30 cities across 3 difficulty levels.
"""

from typing import NamedTuple


class City(NamedTuple):
    name: str
    country: str
    lat: float
    lon: float
    difficulty: str  # easy | medium | hard
    population_millions: float


# Easy: Major world capitals, very recognizable geography
# Medium: Well-known cities with distinctive features
# Hard: Less obvious cities or tricky locations
CITIES: list[City] = [
    # Easy — major capitals with unmistakable geography
    City("London", "United Kingdom", 51.5074, -0.1278, "easy", 9.0),
    City("Tokyo", "Japan", 35.6762, 139.6503, "easy", 13.9),
    City("Cairo", "Egypt", 30.0444, 31.2357, "easy", 10.0),
    City("Paris", "France", 48.8566, 2.3522, "easy", 2.1),
    City("New York", "United States", 40.7128, -74.0060, "easy", 8.3),
    City("Sydney", "Australia", -33.8688, 151.2093, "easy", 5.3),
    City("Rio de Janeiro", "Brazil", -22.9068, -43.1729, "easy", 6.7),
    City("Rome", "Italy", 41.9028, 12.4964, "easy", 2.8),
    City("Moscow", "Russia", 55.7558, 37.6173, "easy", 12.5),
    City("Mumbai", "India", 19.0760, 72.8777, "easy", 20.7),
    # Medium — well-known cities, distinctive features
    City("Istanbul", "Turkey", 41.0082, 28.9784, "medium", 15.5),
    City("Buenos Aires", "Argentina", -34.6037, -58.3816, "medium", 3.1),
    City("Bangkok", "Thailand", 13.7563, 100.5018, "medium", 10.5),
    City("Lagos", "Nigeria", 6.5244, 3.3792, "medium", 15.4),
    City("Seoul", "South Korea", 37.5665, 126.9780, "medium", 9.7),
    City("Lima", "Peru", -12.0464, -77.0428, "medium", 10.0),
    City("Cape Town", "South Africa", -33.9249, 18.4241, "medium", 4.6),
    City("Singapore", "Singapore", 1.3521, 103.8198, "medium", 5.7),
    City("Stockholm", "Sweden", 59.3293, 18.0686, "medium", 1.0),
    City("Lisbon", "Portugal", 38.7223, -9.1393, "medium", 0.5),
    # Hard — less obvious or tricky locations
    City("Belgrade", "Serbia", 44.7866, 20.4489, "hard", 1.7),
    City("Hanoi", "Vietnam", 21.0285, 105.8542, "hard", 8.1),
    City("Nairobi", "Kenya", -1.2921, 36.8219, "hard", 4.7),
    City("Bogota", "Colombia", 4.7110, -74.0721, "hard", 7.4),
    City("Havana", "Cuba", 23.1136, -82.3666, "hard", 2.1),
    City("Reykjavik", "Iceland", 64.1466, -21.9426, "hard", 0.1),
    City("Ulaanbaatar", "Mongolia", 47.8864, 106.9057, "hard", 1.5),
    City("Casablanca", "Morocco", 33.5731, -7.5898, "hard", 3.7),
    City("Addis Ababa", "Ethiopia", 9.0250, 38.7469, "hard", 3.4),
    City("Dhaka", "Bangladesh", 23.8103, 90.4125, "hard", 22.0),
]


def get_cities_by_difficulty(difficulty: str) -> list[City]:
    """Get cities filtered by difficulty level."""
    return [c for c in CITIES if c.difficulty == difficulty]
