"""Generate country silhouette images from Natural Earth data.

Uses GeoPandas + matplotlib to render black silhouettes on white background.
All silhouettes are scale-normalized to fit an 800x800 canvas.
"""

import io
from pathlib import Path
from typing import Optional

import geopandas as gpd
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt
from shapely.geometry import MultiPolygon, Polygon

# Countries with distinctive enough shapes for a silhouette quiz.
# Tuples of (Natural Earth NAME, difficulty, metropolitan_only).
# metropolitan_only=True excludes overseas territories (e.g. France, USA).
SILHOUETTE_COUNTRIES: list[tuple[str, str, bool]] = [
    # Easy — iconic shapes
    ("Italy", "easy", True),
    ("Japan", "easy", True),
    ("India", "easy", True),
    ("Australia", "easy", False),
    ("United Kingdom", "easy", True),
    ("Chile", "easy", False),
    ("New Zealand", "easy", False),
    ("Greece", "easy", True),
    ("Norway", "easy", True),
    ("Cuba", "easy", False),
    ("Sri Lanka", "easy", False),
    ("Madagascar", "easy", False),
    # Medium — recognizable with some thought
    ("France", "medium", True),
    ("Brazil", "medium", False),
    ("Mexico", "medium", False),
    ("Germany", "medium", True),
    ("Turkey", "medium", True),
    ("Thailand", "medium", True),
    ("Argentina", "medium", False),
    ("Sweden", "medium", True),
    ("Finland", "medium", True),
    ("South Korea", "medium", False),
    ("Vietnam", "medium", False),
    ("Pakistan", "medium", False),
    ("Iran", "medium", False),
    ("Peru", "medium", False),
    ("Colombia", "medium", False),
    ("Egypt", "medium", False),
    ("Spain", "medium", True),
    ("Portugal", "medium", True),
    ("Iceland", "medium", False),
    ("Indonesia", "medium", False),
    ("Philippines", "medium", False),
    # Hard — less distinctive but recognizable for geography buffs
    ("Poland", "hard", True),
    ("Romania", "hard", True),
    ("Ukraine", "hard", True),
    ("Saudi Arabia", "hard", False),
    ("South Africa", "hard", False),
    ("Nigeria", "hard", False),
    ("Kenya", "hard", False),
    ("Ethiopia", "hard", False),
    ("Tanzania", "hard", False),
    ("China", "hard", True),
    ("Russia", "hard", True),
    ("Canada", "hard", False),
    ("United States of America", "hard", True),
    ("Mongolia", "hard", False),
    ("Kazakhstan", "hard", False),
    ("Algeria", "hard", False),
    ("Libya", "hard", False),
    ("Morocco", "hard", False),
    ("Myanmar", "hard", False),
    ("Cambodia", "hard", False),
    ("Nepal", "hard", False),
    ("Bangladesh", "hard", False),
    ("Croatia", "hard", True),
    ("Afghanistan", "hard", False),
]

# Bounding box of each country's main landmass (for metropolitan filtering).
# Only needed for countries with distant overseas territories.
_METRO_BOUNDS: dict[str, tuple[float, float, float, float]] = {
    # (min_lon, min_lat, max_lon, max_lat)
    "France": (-5.5, 41.0, 10.0, 51.5),
    "United States of America": (-130.0, 24.0, -65.0, 50.0),
    "United Kingdom": (-11.0, 49.0, 2.5, 61.0),
    "Spain": (-10.0, 35.0, 5.0, 44.0),
    "Portugal": (-10.0, 36.5, -6.0, 42.5),
    "Italy": (6.5, 35.5, 19.0, 47.5),
    "Greece": (19.0, 34.5, 30.0, 42.0),
    "Norway": (4.0, 57.0, 32.0, 72.0),
    "Turkey": (25.5, 35.5, 45.0, 42.5),
    "Germany": (5.5, 47.0, 15.5, 55.5),
    "Sweden": (10.5, 55.0, 24.5, 69.5),
    "Finland": (19.5, 59.5, 31.7, 70.5),
    "Thailand": (97.0, 5.5, 106.0, 21.0),
    "South Korea": (124.5, 33.0, 130.0, 39.0),
    "Croatia": (13.0, 42.0, 19.5, 46.6),
    "China": (73.0, 18.0, 135.5, 54.0),
    "Russia": (27.0, 41.0, 190.0, 82.0),
    "Japan": (127.0, 30.0, 146.0, 46.0),
    "India": (68.0, 6.5, 97.5, 36.0),
}


def _load_countries() -> gpd.GeoDataFrame:
    """Load Natural Earth 110m country boundaries."""
    world = gpd.read_file(
        "https://naciscdn.org/naturalearth/110m/cultural/ne_110m_admin_0_countries.zip"
    )
    # Normalize column name — the 110m dataset uses uppercase "NAME"
    if "NAME" in world.columns and "name" not in world.columns:
        world = world.rename(columns={"NAME": "name"})
    return world


def _filter_metropolitan(geometry, country_name: str) -> Polygon | MultiPolygon:
    """Filter out overseas territories, keeping only the metropolitan area."""
    if country_name not in _METRO_BOUNDS:
        return geometry

    min_lon, min_lat, max_lon, max_lat = _METRO_BOUNDS[country_name]
    bbox = Polygon([
        (min_lon, min_lat),
        (max_lon, min_lat),
        (max_lon, max_lat),
        (min_lon, max_lat),
    ])
    clipped = geometry.intersection(bbox)
    if clipped.is_empty:
        return geometry
    return clipped


def generate_silhouette(
    country_name: str,
    metropolitan_only: bool = True,
    size: int = 800,
    output_path: Optional[str | Path] = None,
) -> bytes:
    """Generate a black silhouette PNG for a country.

    The silhouette is scale-normalized to fill an 800x800 canvas.

    Args:
        country_name: Natural Earth country name.
        metropolitan_only: If True, exclude overseas territories.
        size: Canvas size in pixels (square).
        output_path: If provided, also save to this path.

    Returns:
        PNG image bytes.
    """
    world = _load_countries()
    country = world[world["name"] == country_name]
    if country.empty:
        raise ValueError(f"Country not found in Natural Earth data: {country_name}")

    geometry = country.geometry.values[0]
    if metropolitan_only:
        geometry = _filter_metropolitan(geometry, country_name)

    # Create figure with no axes/borders
    dpi = 100
    fig, ax = plt.subplots(1, 1, figsize=(size / dpi, size / dpi), dpi=dpi)
    ax.set_aspect("equal")
    ax.axis("off")
    fig.patch.set_facecolor("white")

    # Plot silhouette
    if isinstance(geometry, (Polygon, MultiPolygon)):
        gdf = gpd.GeoDataFrame(geometry=[geometry])
        gdf.plot(ax=ax, color="black", edgecolor="black", linewidth=0.5)
    else:
        gpd.GeoDataFrame(geometry=[geometry]).plot(
            ax=ax, color="black", edgecolor="black", linewidth=0.5
        )

    # Tight layout with small padding
    ax.margins(0.05)
    fig.tight_layout(pad=0.5)

    # Render to bytes
    buf = io.BytesIO()
    fig.savefig(buf, format="png", facecolor="white", bbox_inches="tight", dpi=dpi)
    plt.close(fig)
    buf.seek(0)
    image_bytes = buf.read()

    if output_path:
        output_path = Path(output_path)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_bytes(image_bytes)

    return image_bytes


def generate_labeled_silhouette(
    country_name: str,
    metropolitan_only: bool = True,
    size: int = 800,
    output_path: Optional[str | Path] = None,
) -> bytes:
    """Generate a labeled silhouette (for the reveal screen).

    Shows the country outline with name label below.
    """
    world = _load_countries()
    country = world[world["name"] == country_name]
    if country.empty:
        raise ValueError(f"Country not found: {country_name}")

    geometry = country.geometry.values[0]
    if metropolitan_only:
        geometry = _filter_metropolitan(geometry, country_name)

    dpi = 100
    fig, ax = plt.subplots(1, 1, figsize=(size / dpi, size / dpi), dpi=dpi)
    ax.set_aspect("equal")
    ax.axis("off")
    fig.patch.set_facecolor("white")

    gdf = gpd.GeoDataFrame(geometry=[geometry])
    gdf.plot(ax=ax, color="#333333", edgecolor="#333333", linewidth=0.5)

    # Add country name
    centroid = geometry.centroid
    ax.text(
        centroid.x,
        geometry.bounds[1] - (geometry.bounds[3] - geometry.bounds[1]) * 0.08,
        country_name,
        ha="center",
        va="top",
        fontsize=18,
        fontweight="bold",
        color="#333333",
    )

    ax.margins(0.05)
    fig.tight_layout(pad=0.5)

    buf = io.BytesIO()
    fig.savefig(buf, format="png", facecolor="white", bbox_inches="tight", dpi=dpi)
    plt.close(fig)
    buf.seek(0)
    image_bytes = buf.read()

    if output_path:
        output_path = Path(output_path)
        output_path.parent.mkdir(parents=True, exist_ok=True)
        output_path.write_bytes(image_bytes)

    return image_bytes
