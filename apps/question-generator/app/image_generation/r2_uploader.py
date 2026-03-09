"""Cloudflare R2 uploader for quiz question images.

Uses boto3 S3-compatible API to upload images to Cloudflare R2.
"""

import os
from pathlib import Path
from typing import Optional

import boto3
from botocore.config import Config


def _get_r2_client():
    """Create boto3 S3 client configured for Cloudflare R2."""
    endpoint = os.environ["R2_ENDPOINT"]
    return boto3.client(
        "s3",
        endpoint_url=endpoint,
        aws_access_key_id=os.environ["R2_ACCESS_KEY_ID"],
        aws_secret_access_key=os.environ["R2_SECRET_ACCESS_KEY"],
        config=Config(signature_version="s3v4"),
        region_name="auto",
    )


def upload_image(
    local_path: str | Path,
    r2_key: str,
    content_type: Optional[str] = None,
) -> str:
    """Upload an image file to Cloudflare R2 and return its public URL.

    Args:
        local_path: Path to the local image file.
        r2_key: Object key in R2 (e.g. "silhouettes/italy.png").
        content_type: MIME type. Auto-detected from extension if not provided.

    Returns:
        Public URL of the uploaded image.
    """
    local_path = Path(local_path)
    if not local_path.exists():
        raise FileNotFoundError(f"Image file not found: {local_path}")

    if content_type is None:
        ext = local_path.suffix.lower()
        content_type = {
            ".png": "image/png",
            ".jpg": "image/jpeg",
            ".jpeg": "image/jpeg",
            ".webp": "image/webp",
        }.get(ext, "application/octet-stream")

    bucket = os.environ["R2_BUCKET"]
    client = _get_r2_client()

    client.upload_file(
        str(local_path),
        bucket,
        r2_key,
        ExtraArgs={"ContentType": content_type},
    )

    public_url = os.environ["R2_PUBLIC_URL"].rstrip("/")
    return f"{public_url}/{r2_key}"


def delete_image(r2_key: str) -> None:
    """Delete an image from R2."""
    bucket = os.environ["R2_BUCKET"]
    client = _get_r2_client()
    client.delete_object(Bucket=bucket, Key=r2_key)
