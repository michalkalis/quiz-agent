"""Generate blind map images using Cartopy.

Renders unlabeled maps with a red marker at the target city location.
Zoom level controls difficulty (zoomed out = easy, zoomed in = hard).
"""

import io
from pathlib import Path
from typing import Optional

import cartopy.crs as ccrs
import cartopy.feature as cfeature
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt

# Zoom extent in degrees around the city center, by difficulty
_ZOOM_DEGREES = {
    "easy": 40.0,    # Shows large region / continent context
    "medium": 15.0,  # Shows country / region
    "hard": 5.0,     # Shows only city surroundings
}

# Professional color palette
_LAND_COLOR = "#f0f0f0"
_OCEAN_COLOR = "#e6f2ff"
_BORDER_COLOR = "#cccccc"
_COASTLINE_COLOR = "#aaaaaa"
_RIVER_COLOR = "#b3d1ff"
_MARKER_COLOR = "#ff0000"


def generate_blind_map(
    city_name: str,
    lat: float,
    lon: float,
    difficulty: str = "medium",
    size: int = 800,
    output_path: Optional[str | Path] = None,
) -> bytes:
    """Generate a blind map PNG with a red marker at the city location.

    Args:
        city_name: City name (for file naming, not rendered on map).
        lat: Latitude of the city.
        lon: Longitude of the city.
        difficulty: Controls zoom level (easy/medium/hard).
        size: Canvas size in pixels (square).
        output_path: If provided, also save to this path.

    Returns:
        PNG image bytes.
    """
    zoom = _ZOOM_DEGREES.get(difficulty, _ZOOM_DEGREES["medium"])

    dpi = 100
    fig = plt.figure(figsize=(size / dpi, size / dpi), dpi=dpi)
    ax = fig.add_subplot(1, 1, 1, projection=ccrs.PlateCarree())

    # Set extent around city
    ax.set_extent([
        lon - zoom, lon + zoom,
        lat - zoom * 0.75, lat + zoom * 0.75,
    ], crs=ccrs.PlateCarree())

    # Add map features (no labels)
    ax.add_feature(cfeature.OCEAN, facecolor=_OCEAN_COLOR, edgecolor="none")
    ax.add_feature(cfeature.LAND, facecolor=_LAND_COLOR, edgecolor="none")
    ax.add_feature(cfeature.COASTLINE, edgecolor=_COASTLINE_COLOR, linewidth=0.8)
    ax.add_feature(cfeature.BORDERS, edgecolor=_BORDER_COLOR, linewidth=0.5)
    ax.add_feature(cfeature.RIVERS, edgecolor=_RIVER_COLOR, linewidth=0.4)
    ax.add_feature(cfeature.LAKES, facecolor=_OCEAN_COLOR, edgecolor=_COASTLINE_COLOR, linewidth=0.4)

    # Red marker
    ax.plot(
        lon, lat,
        marker="o",
        markersize=12,
        markerfacecolor=_MARKER_COLOR,
        markeredgecolor="white",
        markeredgewidth=2,
        transform=ccrs.PlateCarree(),
        zorder=10,
    )

    ax.set_frame_on(False)
    fig.tight_layout(pad=0)

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


def generate_labeled_map(
    city_name: str,
    lat: float,
    lon: float,
    difficulty: str = "medium",
    size: int = 800,
    output_path: Optional[str | Path] = None,
) -> bytes:
    """Generate a labeled map with city name (for the reveal screen)."""
    zoom = _ZOOM_DEGREES.get(difficulty, _ZOOM_DEGREES["medium"])

    dpi = 100
    fig = plt.figure(figsize=(size / dpi, size / dpi), dpi=dpi)
    ax = fig.add_subplot(1, 1, 1, projection=ccrs.PlateCarree())

    ax.set_extent([
        lon - zoom, lon + zoom,
        lat - zoom * 0.75, lat + zoom * 0.75,
    ], crs=ccrs.PlateCarree())

    ax.add_feature(cfeature.OCEAN, facecolor=_OCEAN_COLOR, edgecolor="none")
    ax.add_feature(cfeature.LAND, facecolor=_LAND_COLOR, edgecolor="none")
    ax.add_feature(cfeature.COASTLINE, edgecolor=_COASTLINE_COLOR, linewidth=0.8)
    ax.add_feature(cfeature.BORDERS, edgecolor=_BORDER_COLOR, linewidth=0.5)
    ax.add_feature(cfeature.RIVERS, edgecolor=_RIVER_COLOR, linewidth=0.4)
    ax.add_feature(cfeature.LAKES, facecolor=_OCEAN_COLOR, edgecolor=_COASTLINE_COLOR, linewidth=0.4)

    # Red marker
    ax.plot(
        lon, lat,
        marker="o",
        markersize=12,
        markerfacecolor=_MARKER_COLOR,
        markeredgecolor="white",
        markeredgewidth=2,
        transform=ccrs.PlateCarree(),
        zorder=10,
    )

    # City name label
    ax.text(
        lon, lat - zoom * 0.08,
        city_name,
        transform=ccrs.PlateCarree(),
        ha="center",
        va="top",
        fontsize=14,
        fontweight="bold",
        color="#333333",
        bbox=dict(boxstyle="round,pad=0.3", facecolor="white", edgecolor="#cccccc", alpha=0.9),
        zorder=11,
    )

    ax.set_frame_on(False)
    fig.tight_layout(pad=0)

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
