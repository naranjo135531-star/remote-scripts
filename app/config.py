import os

ENVIRONMENT = os.getenv("ENVIRONMENT", "production")
ADMIN_ENABLED = ENVIRONMENT == "local"

ADMIN_AUTH_USER = "cnfa3ffw"
ADMIN_AUTH_PASSWORD = "1d1o2nd1082nd"
