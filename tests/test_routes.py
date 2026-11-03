"""
Account API Service Test Suite

Test cases can be run with the following:
  nosetests -v --with-spec --spec-color
  coverage report -m
"""
import os
import logging
from unittest import TestCase
from tests.factories import AccountFactory
from service.common import status  # HTTP Status Codes
from service.models import db, Account, init_db
from service.routes import app

DATABASE_URI = os.getenv(
    "DATABASE_URI", "postgresql://postgres:postgres@localhost:5432/postgres"
)

BASE_URL = "/accounts"


######################################################################
#  T E S T   C A S E S
######################################################################
class TestAccountService(TestCase):
    """Account Service Tests"""

    @classmethod
    def setUpClass(cls):
        """Run once before all tests"""
        app.config["TESTING"] = True
        app.config["DEBUG"] = False
        app.config["SQLALCHEMY_DATABASE_URI"] = DATABASE_URI
        app.logger.setLevel(logging.CRITICAL)
        init_db(app)

    @classmethod
    def tearDownClass(cls):
        """Runs once before test suite"""

    def setUp(self):
        """Runs before each test"""
        db.session.query(Account).delete()  # clean up the last tests
        db.session.commit()

        self.client = app.test_client()

    def tearDown(self):
        """Runs once after each test case"""
        db.session.remove()

    ######################################################################
    #  H E L P E R   M E T H O D S
    ######################################################################

    def _create_accounts(self, count):
        """Factory method to create accounts in bulk"""
        accounts = []
        for _ in range(count):
            account = AccountFactory()
            response = self.client.post(BASE_URL, json=account.serialize())
            self.assertEqual(
                response.status_code,
                status.HTTP_201_CREATED,
                "Could not create test Account",
            )
            new_account = response.get_json()
            account.id = new_account["id"]
            accounts.append(account)
        return accounts

    ######################################################################
    #  A C C O U N T   T E S T   C A S E S
    ######################################################################

    def test_index(self):
        """It should get 200_OK from the Home Page"""
        response = self.client.get("/")
        self.assertEqual(response.status_code, status.HTTP_200_OK)

    def test_health(self):
        """It should be healthy"""
        resp = self.client.get("/health")
        self.assertEqual(resp.status_code, 200)
        data = resp.get_json()
        self.assertEqual(data["status"], "OK")

    def test_create_account(self):
        """It should Create a new Account"""
        account = AccountFactory()
        response = self.client.post(
            BASE_URL,
            json=account.serialize(),
            content_type="application/json"
        )
        self.assertEqual(response.status_code, status.HTTP_201_CREATED)

        # Make sure location header is set
        location = response.headers.get("Location", None)
        self.assertIsNotNone(location)

        # Check the data is correct
        new_account = response.get_json()
        self.assertEqual(new_account["name"], account.name)
        self.assertEqual(new_account["email"], account.email)
        self.assertEqual(new_account["address"], account.address)
        self.assertEqual(new_account["phone_number"], account.phone_number)
        self.assertEqual(new_account["date_joined"], str(account.date_joined))

    def test_bad_request(self):
        """It should not Create an Account when sending the wrong data"""
        response = self.client.post(BASE_URL, json={"name": "not enough data"})
        self.assertEqual(response.status_code, status.HTTP_400_BAD_REQUEST)

    def test_unsupported_media_type(self):
        """It should not Create an Account when sending the wrong media type"""
        account = AccountFactory()
        response = self.client.post(
            BASE_URL,
            json=account.serialize(),
            content_type="test/html"
        )
        self.assertEqual(response.status_code, status.HTTP_415_UNSUPPORTED_MEDIA_TYPE)

    # ADD YOUR TEST CASES HERE ...

    def test_follow_create_location_to_read_account(self):
        account = AccountFactory()
        response = self.client.post(BASE_URL, json=account.serialize())
        location = response.headers["Location"]
        found = self.client.get(location)
        self.assertEqual(found.status_code, 200)
        self.assertEqual(found.get_json(), response.get_json())

    def test_list_empty_and_populated(self):
        empty = self.client.get(BASE_URL)
        self.assertEqual((empty.status_code, empty.get_json()), (200, []))
        saved = self._create_accounts(2)
        self.assertEqual({row["id"] for row in self.client.get(BASE_URL).get_json()},
                         {account.id for account in saved})

    def test_unknown_account(self):
        data = AccountFactory().serialize()
        for method in (self.client.get, self.client.put):
            response = method(f"{BASE_URL}/999999", json=data)
            self.assertEqual(response.status_code, 404)

    def test_update_is_persistent_and_preserves_identifier(self):
        old, other = self._create_accounts(2)
        payload = dict(old.serialize(), address="44 Test Street", id=other.id)
        path = f"{BASE_URL}/{old.id}"
        response = self.client.put(path, json=payload)
        self.assertEqual(response.status_code, 200)
        updated = self.client.get(path).get_json()
        self.assertEqual(updated["id"], old.id)
        self.assertEqual(updated["address"], "44 Test Street")
        self.assertEqual(self.client.get(f"{BASE_URL}/{other.id}").get_json(), other.serialize())

    def test_rejected_update_leaves_account_intact(self):
        old, = self._create_accounts(1)
        path = f"{BASE_URL}/{old.id}"
        before = old.serialize()
        for data in ({"name": "partial write"}, dict(before, date_joined="invalid"), []):
            self.assertEqual(self.client.put(path, json=data).status_code, 400)
            self.assertEqual(self.client.get(path).get_json(), before)
        self.assertEqual(self.client.put(path, data="text", content_type="text/plain").status_code, 415)

    def test_delete_only_requested_account(self):
        old, other = self._create_accounts(2)
        path = f"{BASE_URL}/{old.id}"
        response = self.client.delete(path)
        self.assertEqual((response.status_code, response.data), (204, b""))
        self.assertEqual(self.client.get(path).status_code, 404)
        self.assertEqual(self.client.delete(path).status_code, 204)
        self.assertEqual(self.client.get(f"{BASE_URL}/{other.id}").status_code, 200)

    def test_disallowed_method_returns_json_error(self):
        response = self.client.patch(BASE_URL, json={})
        self.assertEqual(response.status_code, 405)
        self.assertEqual(response.get_json()["status"], 405)

    def test_require_only_mandatory_fields(self):
        data = {"name": "Example", "email": "sample@example.test", "address": "Training Street"}
        response = self.client.post(BASE_URL, json=data)
        self.assertEqual(response.status_code, 201)
        self.assertIsNone(response.get_json()["phone_number"])
        stored = self.client.get(response.headers["Location"]).get_json()
        self.assertEqual(stored["date_joined"], response.get_json()["date_joined"])
