import logging
import os
from functools import lru_cache
from typing import Any

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

logger = logging.getLogger(__name__)

# Storage backend: "b2" (native API, works with Master Application Key) or "s3" (S3-compatible app key only)
STORAGE_BACKEND = os.getenv("STORAGE_BACKEND", "b2").lower()

# Backblaze B2 — Master Application Key works with native API only, not S3-compatible API
B2_KEY_ID = os.getenv("B2_KEY_ID", "09e5592e0ef2")
B2_APPLICATION_KEY = os.getenv("B2_APPLICATION_KEY", "005441aaab729b14083f7cf69d075855f2e8c3dd88")
B2_BUCKET = os.getenv("B2_BUCKET", "script-data-naranjo")

# S3-compatible settings (for AWS, MinIO, or B2 S3-compatible app keys — not the master key)
S3_ENDPOINT_URL = os.getenv("S3_ENDPOINT_URL", "https://s3.us-west-004.backblazeb2.com")
S3_ACCESS_KEY_ID = os.getenv("S3_ACCESS_KEY_ID", B2_KEY_ID)
S3_SECRET_ACCESS_KEY = os.getenv("S3_SECRET_ACCESS_KEY", B2_APPLICATION_KEY)
S3_BUCKET = os.getenv("S3_BUCKET", B2_BUCKET)
S3_REGION = os.getenv("S3_REGION", "us-west-004")

ENVIRONMENT = os.getenv("ENVIRONMENT", "production")


def sanitize_name(value: str) -> str:
    return "".join(char if char.isalnum() or char in "-_" else "_" for char in value)


def build_object_key(computer_name: str, filename: str) -> str:
    safe_name = sanitize_name(computer_name) or "unknown"
    return f"{ENVIRONMENT}/{safe_name}/files/{filename}"


@lru_cache(maxsize=1)
def get_b2_bucket():
    from b2sdk.v2 import B2Api, InMemoryAccountInfo

    info = InMemoryAccountInfo()
    b2 = B2Api(info)
    b2.authorize_account("production", B2_KEY_ID, B2_APPLICATION_KEY)
    return b2.get_bucket_by_name(B2_BUCKET)


@lru_cache(maxsize=1)
def get_s3_client():
    return boto3.client(
        "s3",
        endpoint_url=S3_ENDPOINT_URL,
        aws_access_key_id=S3_ACCESS_KEY_ID,
        aws_secret_access_key=S3_SECRET_ACCESS_KEY,
        region_name=S3_REGION,
        config=Config(
            signature_version="s3v4",
            s3={"addressing_style": "path"},
        ),
    )


def upload_json_b2(key: str, body: str) -> dict[str, Any]:
    bucket = get_b2_bucket()
    bucket.upload_bytes(
        body.encode("utf-8"),
        key,
        content_type="application/json",
    )
    return {
        "backend": "b2",
        "bucket": B2_BUCKET,
        "key": key,
        "uri": f"b2://{B2_BUCKET}/{key}",
    }


def upload_json_s3(key: str, body: str) -> dict[str, Any]:
    client = get_s3_client()
    client.put_object(
        Bucket=S3_BUCKET,
        Key=key,
        Body=body.encode("utf-8"),
        ContentType="application/json",
    )
    return {
        "backend": "s3",
        "bucket": S3_BUCKET,
        "key": key,
        "uri": f"s3://{S3_BUCKET}/{key}",
    }


def upload_json(filename: str, computer_name: str, body: str) -> dict[str, Any]:
    key = build_object_key(computer_name, filename)
    if STORAGE_BACKEND == "s3":
        return upload_json_s3(key, body)
    return upload_json_b2(key, body)


def upload_json_safe(filename: str, computer_name: str, body: str) -> tuple[dict[str, Any] | None, str | None]:
    try:
        return upload_json(filename, computer_name, body), None
    except (BotoCoreError, ClientError) as exc:
        logger.exception("S3 upload failed")
        return None, str(exc)
    except Exception as exc:
        logger.exception("Object storage upload failed")
        return None, str(exc)
