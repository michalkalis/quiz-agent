"""First-party product analytics (issue #51) — events land in our own Postgres."""

from .recorder import AnalyticsRecorder, AppVersionMiddleware, app_version_var

__all__ = ["AnalyticsRecorder", "AppVersionMiddleware", "app_version_var"]
