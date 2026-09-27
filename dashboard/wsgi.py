"""Production WSGI entrypoint for the EpicVM dashboard."""

try:
    from .app import app, _init_users_db, dash_optimizer
except ImportError:  # pragma: no cover - direct WSGI import from /app
    from app import app, _init_users_db, dash_optimizer


try:
    _init_users_db()
except Exception:
    app.logger.exception("dashboard database initialization failed")


try:
    dash_optimizer.start_background_loop()
except Exception:
    app.logger.exception("dashboard optimizer startup failed")
