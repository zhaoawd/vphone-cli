"""Unit tests for scripts/f3_stats.py.

The tests are offline: no VM, no socket, no file I/O. Every case that depends on
pseudo-random draws uses a fixed seed, so the assertions are deterministic.
"""

from pathlib import Path
import random
import statistics
import sys
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))

import f3_stats  # noqa: E402


class QuantileTests(unittest.TestCase):
    def test_interpolates_between_neighbours(self):
        # x = [1, 2, 3, 4], idx = 0.25 * 3 = 0.75 -> 1 + 0.75 * (2 - 1) = 1.75
        self.assertAlmostEqual(f3_stats.quantile([1, 2, 3, 4], 0.25), 1.75)
        # idx = 0.9 * 3 = 2.7 -> 3 + 0.7 * (4 - 3) = 3.7
        self.assertAlmostEqual(f3_stats.quantile([1, 2, 3, 4], 0.9), 3.7)

    def test_exact_order_statistic(self):
        # x = [10, 20, 30], idx = 0.5 * 2 = 1.0 -> the middle point, no interpolation
        self.assertAlmostEqual(f3_stats.quantile([30, 10, 20], 0.5), 20.0)

    def test_bounds(self):
        values = [5, 1, 9, 3]
        self.assertAlmostEqual(f3_stats.quantile(values, 0.0), 1.0)
        self.assertAlmostEqual(f3_stats.quantile(values, 1.0), 9.0)

    def test_single_element_sample(self):
        for probability in (0.0, 0.37, 0.99, 1.0):
            self.assertAlmostEqual(f3_stats.quantile([4.25], probability), 4.25)

    def test_p99_of_zero_to_ninetynine(self):
        # x = [0..99], idx = 0.99 * 99 = 98.01 -> 98 + 0.01 * (99 - 98) = 98.01
        self.assertAlmostEqual(f3_stats.quantile(list(range(100)), 0.99), 98.01)

    def test_unsorted_input_is_not_mutated(self):
        values = [3.0, 1.0, 2.0]
        f3_stats.quantile(values, 0.5)
        self.assertEqual(values, [3.0, 1.0, 2.0])

    def test_quantiles_matches_quantile(self):
        values = [7, 2, 9, 4, 1, 6]
        probabilities = (0.0, 0.5, 0.9, 0.99, 1.0)
        result = f3_stats.quantiles(values, probabilities)
        self.assertEqual(set(result), set(probabilities))
        for probability in probabilities:
            self.assertAlmostEqual(result[probability], f3_stats.quantile(values, probability))

    def test_quantiles_accepts_duplicate_probabilities(self):
        result = f3_stats.quantiles([1, 2, 3], [0.5, 0.5])
        self.assertEqual(result, {0.5: 2.0})


class BootstrapTests(unittest.TestCase):
    def setUp(self):
        rng = random.Random(1234)
        self.sample = [rng.gauss(10.0, 2.0) for _ in range(200)]

    def test_same_seed_is_reproducible(self):
        first = f3_stats.bootstrap_ci(self.sample, statistics.fmean, seed=17, resamples=200)
        second = f3_stats.bootstrap_ci(self.sample, statistics.fmean, seed=17, resamples=200)
        self.assertEqual(first, second)

    def test_different_seed_changes_the_interval(self):
        first = f3_stats.bootstrap_ci(self.sample, statistics.fmean, seed=17, resamples=200)
        other = f3_stats.bootstrap_ci(self.sample, statistics.fmean, seed=18, resamples=200)
        self.assertNotEqual(first, other)

    def test_interval_is_ordered_and_brackets_the_estimate(self):
        low, high = f3_stats.bootstrap_ci(self.sample, statistics.fmean, seed=3, resamples=400)
        self.assertLess(low, high)
        self.assertLess(low, statistics.fmean(self.sample))
        self.assertGreater(high, statistics.fmean(self.sample))

    def test_constant_sample_gives_a_degenerate_interval(self):
        low, high = f3_stats.bootstrap_ci([5.0] * 30, statistics.fmean, seed=1, resamples=50)
        self.assertAlmostEqual(low, 5.0)
        self.assertAlmostEqual(high, 5.0)

    def test_confidence_widens_the_interval(self):
        narrow = f3_stats.bootstrap_ci(self.sample, statistics.fmean, seed=9,
                                       resamples=400, confidence=0.50)
        wide = f3_stats.bootstrap_ci(self.sample, statistics.fmean, seed=9,
                                     resamples=400, confidence=0.99)
        self.assertLess(wide[0], narrow[0])
        self.assertGreater(wide[1], narrow[1])


class LatencySummaryTests(unittest.TestCase):
    @staticmethod
    def make_sample(count):
        rng = random.Random(99)
        return [rng.uniform(1.0, 5.0) for _ in range(count)]

    def test_p99_suppressed_below_one_hundred_samples(self):
        summary = f3_stats.latency_summary(self.make_sample(99), seed=5, resamples=50)
        self.assertEqual(summary["count"], 99)
        self.assertTrue(summary["p99_suppressed"])
        self.assertIsNone(summary["p99"])
        self.assertIsNone(summary["p99_ci"])
        self.assertIsNotNone(summary["p50_ci"])

    def test_p99_reported_at_one_hundred_samples(self):
        sample = self.make_sample(100)
        summary = f3_stats.latency_summary(sample, seed=5, resamples=50)
        self.assertEqual(summary["count"], 100)
        self.assertFalse(summary["p99_suppressed"])
        self.assertAlmostEqual(summary["p99"], f3_stats.quantile(sample, 0.99))
        self.assertEqual(len(summary["p99_ci"]), 2)
        self.assertLessEqual(summary["p99_ci"][0], summary["p99_ci"][1])

    def test_keys_and_basic_statistics(self):
        sample = [1.0, 2.0, 3.0, 4.0]
        summary = f3_stats.latency_summary(sample, seed=2, resamples=20)
        self.assertEqual(set(summary), {"count", "min", "max", "mean", "p50", "p90", "p99",
                                        "p50_ci", "p99_ci", "p99_suppressed"})
        self.assertEqual(summary["count"], 4)
        self.assertAlmostEqual(summary["min"], 1.0)
        self.assertAlmostEqual(summary["max"], 4.0)
        self.assertAlmostEqual(summary["mean"], 2.5)
        self.assertAlmostEqual(summary["p50"], 2.5)
        self.assertAlmostEqual(summary["p90"], 3.7)

    def test_same_seed_is_reproducible(self):
        sample = self.make_sample(120)
        first = f3_stats.latency_summary(sample, seed=42, resamples=50)
        second = f3_stats.latency_summary(sample, seed=42, resamples=50)
        self.assertEqual(first, second)


class TheilSenTests(unittest.TestCase):
    def test_recovers_a_known_slope(self):
        times = [float(index) for index in range(40)]
        values = [3.0 + 2.5 * time_point for time_point in times]
        self.assertAlmostEqual(f3_stats.theil_sen(times, values), 2.5)

    def test_tolerates_outliers(self):
        times = [float(index) for index in range(40)]
        values = [3.0 + 2.5 * time_point for time_point in times]
        for index in (7, 19, 31):
            values[index] += 500.0
        self.assertAlmostEqual(f3_stats.theil_sen(times, values), 2.5, places=6)

    def test_constant_series_has_zero_slope(self):
        times = [float(index) * 5.0 for index in range(20)]
        self.assertAlmostEqual(f3_stats.theil_sen(times, [7.0] * 20), 0.0)

    def test_negative_slope(self):
        times = [0.0, 10.0, 20.0, 30.0]
        values = [100.0, 90.0, 80.0, 70.0]
        self.assertAlmostEqual(f3_stats.theil_sen(times, values), -1.0)

    def test_duplicate_times_are_skipped(self):
        # The pair (0, 0) carries no slope; the remaining pairs all give 1.0.
        times = [0.0, 0.0, 1.0, 2.0]
        values = [0.0, 5.0, 1.0, 2.0]
        self.assertAlmostEqual(f3_stats.theil_sen(times, values), 1.0)

    def test_sampled_path_is_reproducible_and_accurate(self):
        count = f3_stats.THEIL_SEN_EXACT_MAX_POINTS + 50
        times = [float(index) for index in range(count)]
        values = [1.0 + 0.75 * time_point for time_point in times]
        first = f3_stats.theil_sen(times, values)
        self.assertAlmostEqual(first, 0.75)
        self.assertEqual(first, f3_stats.theil_sen(times, values))

    def test_all_times_equal_raises(self):
        with self.assertRaises(ValueError):
            f3_stats.theil_sen([2.0, 2.0, 2.0], [1.0, 2.0, 3.0])


class MovingBlockBootstrapTests(unittest.TestCase):
    BLOCK_SPAN = 300.0

    @staticmethod
    def times(count, step=30.0):
        return [index * step for index in range(count)]

    def test_rising_series_has_a_positive_lower_bound(self):
        rng = random.Random(20260918)
        times = self.times(60)
        values = [0.5 * index + rng.gauss(0.0, 0.5) for index in range(60)]
        result = f3_stats.moving_block_bootstrap_slope_ci(
            times, values, block_span=self.BLOCK_SPAN, seed=7, resamples=200)
        self.assertIsNone(result["reason"])
        self.assertGreater(result["ci"][0], 0.0)
        self.assertLess(result["ci"][0], result["ci"][1])
        # The true slope is 0.5 per step of 30 time units.
        self.assertLessEqual(result["ci"][0], 0.5 / 30.0)
        self.assertGreaterEqual(result["ci"][1], 0.5 / 30.0)

    def test_trendless_noise_interval_contains_zero(self):
        rng = random.Random(4242)
        times = self.times(60)
        values = [rng.gauss(0.0, 1.0) for _ in range(60)]
        result = f3_stats.moving_block_bootstrap_slope_ci(
            times, values, block_span=self.BLOCK_SPAN, seed=7, resamples=200)
        self.assertIsNone(result["reason"])
        self.assertLessEqual(result["ci"][0], 0.0)
        self.assertGreaterEqual(result["ci"][1], 0.0)

    def test_autocorrelated_noise_interval_contains_zero(self):
        rng = random.Random(777)
        times = self.times(60)
        values = []
        state = 0.0
        for _ in range(60):
            state = 0.8 * state + rng.gauss(0.0, 1.0)
            values.append(state)
        result = f3_stats.moving_block_bootstrap_slope_ci(
            times, values, block_span=self.BLOCK_SPAN, seed=11, resamples=200)
        self.assertIsNone(result["reason"])
        self.assertLessEqual(result["ci"][0], 0.0)
        self.assertGreaterEqual(result["ci"][1], 0.0)

    def test_same_seed_is_reproducible(self):
        times = self.times(60)
        values = [float(index % 7) for index in range(60)]
        first = f3_stats.moving_block_bootstrap_slope_ci(
            times, values, block_span=self.BLOCK_SPAN, seed=3, resamples=100)
        second = f3_stats.moving_block_bootstrap_slope_ci(
            times, values, block_span=self.BLOCK_SPAN, seed=3, resamples=100)
        self.assertEqual(first, second)

    def test_short_series_returns_a_reason(self):
        result = f3_stats.moving_block_bootstrap_slope_ci(
            [0.0, 100.0, 200.0], [1.0, 2.0, 3.0],
            block_span=self.BLOCK_SPAN, seed=1, resamples=10)
        self.assertIsNone(result["ci"])
        self.assertEqual(result["block_count"], 0)
        self.assertIn("fewer than two blocks", result["reason"])

    def test_result_keys_are_fixed(self):
        result = f3_stats.moving_block_bootstrap_slope_ci(
            self.times(60), [float(index) for index in range(60)],
            block_span=self.BLOCK_SPAN, seed=1, resamples=20)
        self.assertEqual(set(result), {"ci", "reason", "block_count"})

    def test_unsorted_input_is_accepted(self):
        times = self.times(60)
        values = [0.5 * index for index in range(60)]
        pairs = list(zip(times, values))
        shuffler = random.Random(5)
        shuffler.shuffle(pairs)
        shuffled = f3_stats.moving_block_bootstrap_slope_ci(
            [pair[0] for pair in pairs], [pair[1] for pair in pairs],
            block_span=self.BLOCK_SPAN, seed=2, resamples=50)
        ordered = f3_stats.moving_block_bootstrap_slope_ci(
            times, values, block_span=self.BLOCK_SPAN, seed=2, resamples=50)
        self.assertEqual(shuffled, ordered)


class GrowthVerdictTests(unittest.TestCase):
    def test_confirmed_two_runs_same_sign(self):
        runs = [{"slope": 1.2, "ci_low": 0.4, "ci_high": 2.0},
                {"slope": 0.9, "ci_low": 0.1, "ci_high": 1.7}]
        self.assertEqual(f3_stats.growth_verdict(runs), "confirmed")

    def test_candidate_single_run_satisfies(self):
        runs = [{"slope": 1.2, "ci_low": 0.4, "ci_high": 2.0},
                {"slope": 0.9, "ci_low": -0.1, "ci_high": 1.7}]
        self.assertEqual(f3_stats.growth_verdict(runs), "candidate")

    def test_candidate_when_only_one_interval_is_available(self):
        runs = [{"slope": 1.2, "ci_low": 0.4, "ci_high": 2.0},
                {"slope": 0.9, "ci_low": None, "ci_high": None}]
        self.assertEqual(f3_stats.growth_verdict(runs), "candidate")

    def test_not_detected_when_no_lower_bound_is_positive(self):
        runs = [{"slope": 1.2, "ci_low": -0.4, "ci_high": 2.0},
                {"slope": -0.9, "ci_low": -1.5, "ci_high": 0.2}]
        self.assertEqual(f3_stats.growth_verdict(runs), "not_detected")

    def test_not_detected_when_all_intervals_are_missing(self):
        runs = [{"slope": 1.2, "ci_low": None, "ci_high": None},
                {"slope": 3.4, "ci_low": None, "ci_high": None}]
        self.assertEqual(f3_stats.growth_verdict(runs), "not_detected")

    def test_not_detected_for_no_runs(self):
        self.assertEqual(f3_stats.growth_verdict([]), "not_detected")

    def test_zero_lower_bound_does_not_satisfy(self):
        runs = [{"slope": 1.0, "ci_low": 0.0, "ci_high": 2.0},
                {"slope": 1.1, "ci_low": 0.0, "ci_high": 2.2}]
        self.assertEqual(f3_stats.growth_verdict(runs), "not_detected")

    def test_mixed_sign_slopes_stay_candidate(self):
        runs = [{"slope": 1.2, "ci_low": 0.4, "ci_high": 2.0},
                {"slope": -0.9, "ci_low": 0.1, "ci_high": 1.7}]
        self.assertEqual(f3_stats.growth_verdict(runs), "candidate")

    def test_three_satisfying_runs_confirm(self):
        runs = [{"slope": 1.2, "ci_low": 0.4, "ci_high": 2.0},
                {"slope": 0.9, "ci_low": 0.1, "ci_high": 1.7},
                {"slope": 0.2, "ci_low": None, "ci_high": None}]
        self.assertEqual(f3_stats.growth_verdict(runs), "confirmed")


class ValidationTests(unittest.TestCase):
    def test_quantile_rejects_empty_sample(self):
        with self.assertRaises(ValueError):
            f3_stats.quantile([], 0.5)

    def test_quantile_rejects_probability_out_of_range(self):
        for probability in (-0.01, 1.5):
            with self.assertRaises(ValueError):
                f3_stats.quantile([1, 2, 3], probability)

    def test_quantile_rejects_non_numeric_values(self):
        with self.assertRaises(ValueError):
            f3_stats.quantile([1, "2", 3], 0.5)
        with self.assertRaises(ValueError):
            f3_stats.quantile([1, None, 3], 0.5)
        with self.assertRaises(ValueError):
            f3_stats.quantile([1, float("nan")], 0.5)

    def test_quantile_rejects_string_sample(self):
        with self.assertRaises(ValueError):
            f3_stats.quantile("123", 0.5)

    def test_quantile_rejects_non_numeric_probability(self):
        with self.assertRaises(ValueError):
            f3_stats.quantile([1, 2, 3], "0.5")

    def test_quantiles_rejects_bad_probability(self):
        with self.assertRaises(ValueError):
            f3_stats.quantiles([1, 2, 3], [0.5, 2.0])

    def test_bootstrap_rejects_bad_arguments(self):
        with self.assertRaises(ValueError):
            f3_stats.bootstrap_ci([], statistics.fmean, seed=1)
        with self.assertRaises(ValueError):
            f3_stats.bootstrap_ci([1, 2, 3], "not callable", seed=1)
        with self.assertRaises(ValueError):
            f3_stats.bootstrap_ci([1, 2, 3], statistics.fmean, seed=1, resamples=0)
        with self.assertRaises(ValueError):
            f3_stats.bootstrap_ci([1, 2, 3], statistics.fmean, seed=1, confidence=1.0)
        with self.assertRaises(ValueError):
            f3_stats.bootstrap_ci([1, 2, 3], statistics.fmean, seed=1, confidence=0.0)

    def test_latency_summary_rejects_empty_sample(self):
        with self.assertRaises(ValueError):
            f3_stats.latency_summary([], seed=1, resamples=10)

    def test_theil_sen_rejects_length_mismatch(self):
        with self.assertRaises(ValueError):
            f3_stats.theil_sen([0.0, 1.0, 2.0], [1.0, 2.0])

    def test_theil_sen_rejects_empty_series(self):
        with self.assertRaises(ValueError):
            f3_stats.theil_sen([], [])

    def test_theil_sen_rejects_non_numeric(self):
        with self.assertRaises(ValueError):
            f3_stats.theil_sen([0.0, 1.0], [1.0, "2"])

    def test_moving_block_rejects_bad_block_span(self):
        times = [index * 30.0 for index in range(60)]
        values = [float(index) for index in range(60)]
        for block_span in (0.0, -300.0):
            with self.assertRaises(ValueError):
                f3_stats.moving_block_bootstrap_slope_ci(
                    times, values, block_span=block_span, seed=1, resamples=10)

    def test_moving_block_rejects_length_mismatch(self):
        with self.assertRaises(ValueError):
            f3_stats.moving_block_bootstrap_slope_ci(
                [0.0, 30.0, 60.0], [1.0, 2.0], block_span=300.0, seed=1, resamples=10)

    def test_growth_verdict_rejects_bad_runs(self):
        with self.assertRaises(ValueError):
            f3_stats.growth_verdict([{"ci_low": 0.1}])
        with self.assertRaises(ValueError):
            f3_stats.growth_verdict([{"slope": "1.0", "ci_low": 0.1}])
        with self.assertRaises(ValueError):
            f3_stats.growth_verdict([{"slope": 1.0, "ci_low": "0.1"}])
        with self.assertRaises(ValueError):
            f3_stats.growth_verdict([[0.1, 0.2]])


if __name__ == "__main__":
    unittest.main()
