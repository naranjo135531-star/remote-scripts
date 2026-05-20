import os
from functools import lru_cache
from typing import Any

import boto3
from botocore.config import Config
from botocore.exceptions import BotoCoreError, ClientError

# S3-compatible object storage — defaults target Backblaze B2; override for AWS, MinIO, etc.
S3_ENDPOINT_URL = os.getenv("S3_ENDPOINT_URL", "https://s3.us-west-004.backblazeb2.com")
S3_ACCESS_KEY_ID = os.getenv("S3_ACCESS_KEY_ID", "09e5592e0ef2")
S3_SECRET_ACCESS_KEY = os.getenv("S3_SECRET_ACCESS_KEY", "005441aaab729b14083f7cf69d075855f2e8c3dd88")
S3_BUCKET = os.getenv("S3_BUCKET", "script-data-naranjo")
S3_REGION = os.getenv("S3_REGION", "us-west-004")
ENVIRONMENT = os.getenv("ENVIRONMENT", "production")


def sanitize_name(value: str) -> str:
    return "".join(char if char.isalnum() or char in "-_" else "_" for char in value)


def build_object_key(computer_name: str, filename: str) -> str:
    safe_name = sanitize_name(computer_name) or "unknown"
    return f"{ENVIRONMENT}/{safe_name}/files/{filename}"


@lru_cache(maxsize=1)
def get_s3_client():
    return boto3.client(
        "s3",
        endpoint_url=S3_ENDPOINT_URL,
        aws_access_key_id=S3_ACCESS_KEY_ID,
        aws_secret_access_key=S3_SECRET_ACCESS_KEY,
        region_name=S3_REGION,
        config=Config(signature_version="s3v4"),
    )


def upload_json(filename: str, computer_name: str, body: str) -> dict[str, Any]:
    key = build_object_key(computer_name, filename)
    client = get_s3_client()
    client.put_object(
        Bucket=S3_BUCKET,
        Key=key,
        Body=body.encode("utf-8"),
        ContentType="application/json",
    )
    return {
        "bucket": S3_BUCKET,
        "key": key,
        "uri": f"s3://{S3_BUCKET}/{key}",
    }


def upload_json_safe(filename: str, computer_name: str, body: str) -> dict[str, Any] | None:
    try:
        return upload_json(filename, computer_name, body)
    except (BotoCoreError, ClientError):
        return None
