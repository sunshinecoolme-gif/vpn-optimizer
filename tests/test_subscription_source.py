#!/usr/bin/env python3
import importlib.util
import base64
import pathlib
import tempfile
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("source_builder", ROOT / "scripts/build-subscription-source.py")
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader
SPEC.loader.exec_module(MODULE)


class SubscriptionSourceTests(unittest.TestCase):
    def test_parse_percent_encoded_link(self):
        values = MODULE.parse_link(
            "hysteria2://p%40ss%3Aword@example.com:8443?sni=edge.example&insecure=1#My%20VPS"
        )
        self.assertEqual(values, ("example.com", 8443, "p@ss:word", "edge.example", True, "My VPS"))

    def test_parse_generated_server_config_with_quote(self):
        with tempfile.NamedTemporaryFile("w", encoding="utf-8") as config:
            config.write("listen: :443\nauth:\n  type: password\n  password: 'it''s-secret'\n")
            config.flush()
            values = MODULE.parse_config(config.name, "192.0.2.1")
        self.assertEqual(values[1:3], (443, "it's-secret"))

    def test_build_link_escapes_credentials_and_name(self):
        result = MODULE.build_link("192.0.2.1", 443, "a@b/c", "www.bing.com", True, "VPS CN")
        self.assertIn("a%40b%2Fc@192.0.2.1:443", result)
        self.assertTrue(result.endswith("#VPS%20CN"))

    def test_subscription_content_is_base64_encoded(self):
        link = "hysteria2://secret@example.com:443#Test"
        content = MODULE.build_subscription_content(link)
        self.assertEqual(base64.b64decode(content).decode("utf-8"), link + "\n")


if __name__ == "__main__":
    unittest.main()
