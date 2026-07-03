import os
import unittest

from token_dashboard.pricing import load_pricing, cost_for, format_for_user

PRICING = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "pricing.json"))


class CostTests(unittest.TestCase):
    def setUp(self):
        self.p = load_pricing(PRICING)

    def _u(self, **kw):
        base = {
            "input_tokens": 0, "output_tokens": 0, "cache_read_tokens": 0,
            "cache_create_5m_tokens": 0, "cache_create_1h_tokens": 0,
        }
        base.update(kw)
        return base

    def test_known_opus_input_cost(self):
        c = cost_for("claude-opus-4-7", self._u(input_tokens=1_000_000), self.p)
        self.assertAlmostEqual(c["usd"], 15.00, places=4)
        self.assertFalse(c["estimated"])

    def test_known_sonnet_output_cost(self):
        c = cost_for("claude-sonnet-4-6", self._u(output_tokens=1_000_000), self.p)
        self.assertAlmostEqual(c["usd"], 15.00, places=4)

    def test_unknown_opus_falls_back(self):
        c = cost_for("claude-opus-9-9-experimental", self._u(input_tokens=1_000_000), self.p)
        self.assertAlmostEqual(c["usd"], 15.00, places=4)
        self.assertTrue(c["estimated"])

    def test_unknown_unparseable_returns_none(self):
        c = cost_for("custom-local-model", self._u(input_tokens=9999), self.p)
        self.assertIsNone(c["usd"])

    def test_known_fable_costs(self):
        c = cost_for("claude-fable-5", self._u(input_tokens=1_000_000, output_tokens=1_000_000), self.p)
        self.assertAlmostEqual(c["usd"], 60.00, places=4)  # $10 in + $50 out
        self.assertFalse(c["estimated"])

    def test_fable_billing_flag_present(self):
        self.assertEqual(self.p["models"]["claude-fable-5"].get("billing"), "usage_credits")

    def test_unknown_fable_falls_back_to_fable_tier(self):
        c = cost_for("claude-fable-5-20260601", self._u(input_tokens=1_000_000), self.p)
        self.assertAlmostEqual(c["usd"], 10.00, places=4)
        self.assertTrue(c["estimated"])

    def test_known_sonnet_5_intro_pricing(self):
        # Intro pricing $2/$10 through 2026-08-31 (see pricing.json notes)
        c = cost_for("claude-sonnet-5", self._u(input_tokens=1_000_000, output_tokens=1_000_000), self.p)
        self.assertAlmostEqual(c["usd"], 12.00, places=4)
        self.assertFalse(c["estimated"])

    def test_known_opus_4_8_cost(self):
        c = cost_for("claude-opus-4-8", self._u(input_tokens=1_000_000, output_tokens=1_000_000), self.p)
        self.assertAlmostEqual(c["usd"], 30.00, places=4)  # $5 in + $25 out
        self.assertFalse(c["estimated"])

    def test_cache_read_cheaper_than_input(self):
        c_in = cost_for("claude-opus-4-7", self._u(input_tokens=1_000_000), self.p)
        c_cr = cost_for("claude-opus-4-7", self._u(cache_read_tokens=1_000_000), self.p)
        self.assertLess(c_cr["usd"], c_in["usd"])


class PlanFormatTests(unittest.TestCase):
    def setUp(self):
        self.p = load_pricing(PRICING)

    def test_api_plan_returns_raw(self):
        out = format_for_user(12.34, "api", self.p)
        self.assertEqual(out["display_usd"], 12.34)
        self.assertIsNone(out["subscription_usd"])

    def test_pro_plan_returns_subscription_subtitle(self):
        out = format_for_user(12.34, "pro", self.p)
        self.assertEqual(out["subscription_usd"], 20)
        self.assertIn("Pro", out["subtitle"])


if __name__ == "__main__":
    unittest.main()
