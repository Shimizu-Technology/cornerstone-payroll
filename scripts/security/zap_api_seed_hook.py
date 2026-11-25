"""OWASP ZAP baseline hook that seeds employee API endpoints for passive scanning.

The employee API does not emit HTML hyperlinks for ZAP's spider to follow, so
scanning `/up` alone misses the JSON and empty-404 employee portal responses.
This hook visits read-only public, auth, employee portal, and dropped-admin
paths after ZAP finishes tuning so the passive scanner inspects real status
codes, JSON error bodies, and security headers (`Cache-Control: no-store`,
`X-Content-Type-Options: nosniff`, CORS, HSTS in production).
"""

from __future__ import annotations

from urllib.parse import urlsplit

SEED_PATHS = (
    "/up",
    "/health/dependencies",
    "/api/v1/public/tenant_branding?host=unknown.example.test",
    "/api/v1/auth/me",
    "/api/v1/auth/view_as",
    "/api/v1/employee/links",
    "/api/v1/employee/context",
    "/api/v1/employee/help",
    "/api/v1/employee/profile",
    "/api/v1/employee/statements",
    "/api/v1/employee/tax_forms",
    "/api/v1/employee/delivery_consents",
)

_TARGET_ORIGIN: str | None = None


def zap_started(zap, target: str) -> None:  # noqa: ARG001
    global _TARGET_ORIGIN
    parts = urlsplit(target)
    _TARGET_ORIGIN = f"{parts.scheme}://{parts.netloc}"


def zap_tuned(zap) -> None:
    if not _TARGET_ORIGIN:
        return
    for path in SEED_PATHS:
        zap.urlopen(f"{_TARGET_ORIGIN}{path}")
