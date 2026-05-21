import os


def _env_bool(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


ENVIRONMENT = os.getenv("ENVIRONMENT", "production")
ADMIN_ENABLED = _env_bool("ENABLED_ADMIN_PANEL")

ADMIN_AUTH_USER = "cnfa3ffw"
ADMIN_AUTH_PASSWORD = "1d1o2nd1082nd"
