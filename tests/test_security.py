"""Observable browser policies on the accounts API."""
import unittest
from service import app


class TestAccountHeaders(unittest.TestCase):
    def setUp(self):
        self.client = app.test_client()

    def test_security_headers_on_success_and_failure(self):
        for path, code in (("/health", 200), ("/missing", 404)):
            response = self.client.get(path, base_url="https://api.example.test")
            self.assertEqual(response.status_code, code)
            self.assertEqual(response.headers.get("X-Content-Type-Options"), "nosniff")
            self.assertIn("default-src", response.headers.get("Content-Security-Policy", ""))
            self.assertIn("max-age=", response.headers.get("Strict-Transport-Security", ""))

    def test_cors_preflight_checks_origin(self):
        for origin, expected in (("http://localhost:3000", "http://localhost:3000"),
                                 ("https://unrelated.example", None)):
            response = self.client.options("/accounts", headers={
                "Origin": origin, "Access-Control-Request-Method": "POST",
                "Access-Control-Request-Headers": "Content-Type",
            })
            self.assertEqual(response.headers.get("Access-Control-Allow-Origin"), expected)
            if expected:
                self.assertIn("POST", response.headers["Access-Control-Allow-Methods"])
