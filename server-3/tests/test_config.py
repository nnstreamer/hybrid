import base64
import json
import os
import sys
import unittest

ROOT_DIR = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir))
sys.path.insert(0, ROOT_DIR)

from server3 import config as cfg  # noqa: E402


class ConfigTests(unittest.TestCase):
    def test_ohttp_bundle_deterministic(self) -> None:
        seed_hex = "00" * 32
        raw = {
            "features": {"ohttp": True, "real_attestation": True},
            "relay_urls": ["https://relay.example.com"],
            "gateway_url": "http://gateway.local/",
            "router_url": "http://router.local/",
            "ohttp_seeds": [
                {
                    "key_id": "01",
                    "seed_hex": seed_hex,
                    "active_from": "2026-01-30T00:00:00Z",
                    "active_until": "2026-02-06T00:00:00Z",
                }
            ],
            "attestation": {"policy_id": "policy-1"},
        }

        parsed = cfg.parse_config(raw)
        payload = cfg.build_api_payload(parsed)

        bundle_bytes = base64.b64decode(payload["ohttp_key_configs_bundle"])
        bundle = json.loads(bundle_bytes)
        self.assertEqual(bundle["format"], cfg.BUNDLE_FORMAT)
        self.assertEqual(len(bundle["keys"]), 1)

        expected_public_key = base64.b64encode(
            cfg.derive_public_key_bytes(seed_hex, "01")
        ).decode("ascii")
        self.assertEqual(bundle["keys"][0]["public_key_b64"], expected_public_key)

        rotation = payload["ohttp_key_rotation_periods"]
        self.assertEqual(rotation[0]["key_id"], "01")

    def test_missing_ohttp_fields(self) -> None:
        raw = {"features": {"ohttp": True, "real_attestation": False}}
        with self.assertRaises(cfg.ConfigError):
            cfg.parse_config(raw)

    def test_disable_ohttp(self) -> None:
        raw = {"features": {"ohttp": False, "real_attestation": False}}
        parsed = cfg.parse_config(raw)
        payload = cfg.build_api_payload(parsed)
        self.assertEqual(payload["relay_urls"], [])
        self.assertEqual(payload["ohttp_key_configs_bundle"], "")


if __name__ == "__main__":
    unittest.main()
