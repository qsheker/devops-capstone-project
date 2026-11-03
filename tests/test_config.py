"""Verify the settings contract used by the Kubernetes database deployment."""
import os
from pathlib import Path
from runpy import run_path
from unittest import TestCase
from unittest.mock import patch


class TestDatabaseSettings(TestCase):
    def test_separate_database_settings_when_uri_is_unset(self):
        env = {"DATABASE_USER": "demo", "DATABASE_PASSWORD": "sample",
               "DATABASE_HOST": "postgres-service", "DATABASE_NAME": "accounts"}
        config_file = Path(__file__).resolve().parents[1] / "service" / "config.py"
        with patch.dict(os.environ, env, clear=True):
            settings = run_path(str(config_file))
        self.assertEqual(settings["SQLALCHEMY_DATABASE_URI"],
                         "postgresql://demo:sample@postgres-service:5432/accounts")
