#!/usr/bin/env python3
"""Offline statistics for the F3 performance baseline.

The module implements the estimators required by
research/f3_performance_baseline_plan_2026-09-18.md §3.1 and §3.6 using the
standard library only (§9 decision 9: no NumPy). Every function is pure: no
file I/O, no printing, no argument parsing, no network or VM access. Other
scripts import this module.

Contents:
  quantile / quantiles                    linear-interpolation quantiles
  bootstrap_ci                            ordinary bootstrap percentile interval
  latency_summary                         §3.1 latency report for one command class
  theil_sen                               Theil-Sen slope
  moving_block_bootstrap_slope_ci         §3.6 moving-block bootstrap slope interval
  step_summary                            §3.6 discrete-step detection (see 10.11)
  growth_verdict                          §3.6 growth decision over independent runs

Time unit: the caller chooses the unit of `times`; F3 passes seconds, so a
slope is reported in `value unit / second` and `block_span` is in seconds.
"""

import bisect
import math
import random
import statistics

# Theil-Sen pair budget. At most THEIL_SEN_EXACT_MAX_POINTS samples are handled
# by enumerating all pairs. Above that the estimator draws
# THEIL_SEN_SAMPLED_PAIRS random index pairs with the fixed seed
# THEIL_SEN_SAMPLE_SEED, so repeated calls on the same input return the same
# slope. A moving-block bootstrap therefore costs about
# `resamples * THEIL_SEN_SAMPLED_PAIRS` slope evaluations on long series.
THEIL_SEN_EXACT_MAX_POINTS = 200
THEIL_SEN_SAMPLED_PAIRS = 20000
THEIL_SEN_SAMPLE_SEED = 20260918

# §3.1: p99 is not reported below this sample count.
MIN_SAMPLES_FOR_P99 = 100

# The interquartile range of a standard normal sample, used to express an IQR in
# the same unit as a median absolute deviation.
GAUSSIAN_IQR_IN_SIGMA = 1.349

# Step detection (§3.6, evidence 10.11). A point-to-point difference counts as a
# discrete step when it lies more than STEP_MAD_MULTIPLIER robust scale units
# away from the median difference. The scale comes from `_spread_scale`, or from
# `_sparse_move_scale` when the differences have no measurable spread, so the
# criterion carries no absolute size constant and works on MiB, KiB and CPU
# cores alike.
#
# Multiplier 8: the scale equals sigma for Gaussian differences, so the
# threshold is about 8 sigma and a 60-to-1000 point series produces no false
# step. The events 10.11 has to catch sit far above that: the ~76 MiB Disk.img
# allocation appears in a series whose other point-to-point changes are a few
# MiB, tens of scale units away. A smaller multiplier (3-5, the usual outlier
# convention) would also catch them but would start flagging ordinary sampling
# jitter in the near-flat series, which must keep their existing verdicts.
STEP_MAD_MULTIPLIER = 8.0

# Quantization evidence (see `_quantum`). A series counts as quantised at `q`
# only when its smallest value is at least this many quanta above zero. Without
# it the test is vacuous: a flat series holding one jump has values 0 and 1
# jumps' worth, which are trivially "multiples of the jump" and say nothing
# about the measurement resolution.
STEP_QUANTIZATION_LEVELS = 8

# A series is called step dominated when the detected steps account for more
# than this share of its net change.
#
# Share 0.5: above it the discrete component exceeds everything else in the
# window, so the Theil-Sen slope cannot be read as a rate. The observed values
# separate widely around it - 10.11 reports 0.83 (headless run: +75.5 of
# +91.1 MiB), 0.92 (E5a rerun: +103 of +112.3 MiB) and ~0.99 (E5a: +286 of
# +287.6 MiB), against 0 for the step-free windows E5b and E4 - so the exact
# cut inside that gap does not change any recorded verdict. The share counts
# only the steps aligned with the net change (see `step_summary`).
STEP_DOMINANCE_SHARE = 0.5

# Attempts per drawn pair when sampling pairs with distinct times.
_PAIR_DRAW_ATTEMPTS = 8


# MARK: - input validation


def _as_float(value, label):
    """Return `value` as a finite float or raise ValueError."""
    if isinstance(value, bool) or not isinstance(value, (int, float)):
        raise ValueError(f"{label} must be a real number, got {type(value).__name__}")
    number = float(value)
    if not math.isfinite(number):
        raise ValueError(f"{label} must be finite, got {value!r}")
    return number


def _as_float_list(values, label):
    """Return `values` as a list of finite floats or raise ValueError."""
    if isinstance(values, (str, bytes, bytearray)):
        raise ValueError(f"{label} must be a sequence of numbers, not {type(values).__name__}")
    try:
        items = list(values)
    except TypeError as error:
        raise ValueError(f"{label} must be an iterable of numbers: {error}") from error
    return [_as_float(item, f"{label}[{index}]") for index, item in enumerate(items)]


def _check_probability(probability, label="probability"):
    """Return `probability` as a float in [0, 1] or raise ValueError."""
    number = _as_float(probability, label)
    if not 0.0 <= number <= 1.0:
        raise ValueError(f"{label} must lie in [0, 1], got {number!r}")
    return number


def _check_confidence(confidence):
    """Return `confidence` as a float in (0, 1) or raise ValueError."""
    number = _as_float(confidence, "confidence")
    if not 0.0 < number < 1.0:
        raise ValueError(f"confidence must lie in (0, 1), got {number!r}")
    return number


def _check_resamples(resamples):
    """Return `resamples` as a positive int or raise ValueError."""
    if isinstance(resamples, bool) or not isinstance(resamples, int):
        raise ValueError(f"resamples must be an int, got {type(resamples).__name__}")
    if resamples < 1:
        raise ValueError(f"resamples must be >= 1, got {resamples}")
    return resamples


# MARK: - quantiles


def _quantile_sorted(ordered, probability):
    """Linear-interpolation quantile of an already ascending list."""
    count = len(ordered)
    if count == 1:
        return ordered[0]
    position = probability * (count - 1)
    lower = math.floor(position)
    upper = math.ceil(position)
    if lower == upper:
        return ordered[int(position)]
    fraction = position - lower
    return ordered[lower] + (ordered[upper] - ordered[lower]) * fraction


def quantile(values, probability):
    """Return the linear-interpolation quantile of `values` at `probability`.

    Equivalent to NumPy `method="linear"`: for the ascending sample `x`,
    `idx = probability * (len(x) - 1)` and the result interpolates linearly
    between the two neighbouring order statistics.

    Raises ValueError for an empty sample, a non-numeric element, or a
    probability outside [0, 1].
    """
    probability = _check_probability(probability)
    ordered = sorted(_as_float_list(values, "values"))
    if not ordered:
        raise ValueError("values must contain at least one sample")
    return _quantile_sorted(ordered, probability)


def quantiles(values, probabilities):
    """Return `{probability: quantile}` for every entry of `probabilities`.

    The sample is sorted once. Duplicate probabilities collapse into one key.
    Raises ValueError under the same conditions as `quantile`.
    """
    wanted = [_check_probability(item, f"probabilities[{index}]")
              for index, item in enumerate(_iterable(probabilities, "probabilities"))]
    ordered = sorted(_as_float_list(values, "values"))
    if not ordered:
        raise ValueError("values must contain at least one sample")
    return {probability: _quantile_sorted(ordered, probability) for probability in wanted}


def _iterable(values, label):
    """Return `values` as a list, rejecting strings and non-iterables."""
    if isinstance(values, (str, bytes, bytearray)):
        raise ValueError(f"{label} must be a sequence, not {type(values).__name__}")
    try:
        return list(values)
    except TypeError as error:
        raise ValueError(f"{label} must be an iterable: {error}") from error


# MARK: - bootstrap


def bootstrap_ci(values, statistic, *, seed, resamples=2000, confidence=0.95):
    """Return the ordinary bootstrap percentile interval `[low, high]`.

    `statistic` is called with one resampled list and returns a scalar. The
    resamples are drawn with replacement from `values` by `random.Random(seed)`,
    so the same seed and inputs give the same interval. The interval bounds are
    the `(1 - confidence) / 2` and `1 - (1 - confidence) / 2` quantiles of the
    resampled statistics, computed with `quantile`.

    Raises ValueError for an empty sample, a non-callable statistic,
    `resamples < 1`, or a confidence outside (0, 1).
    """
    sample = _as_float_list(values, "values")
    if not sample:
        raise ValueError("values must contain at least one sample")
    if not callable(statistic):
        raise ValueError("statistic must be callable")
    resamples = _check_resamples(resamples)
    confidence = _check_confidence(confidence)

    rng = random.Random(seed)
    count = len(sample)
    estimates = []
    for _ in range(resamples):
        draw = [sample[rng.randrange(count)] for _ in range(count)]
        estimates.append(_as_float(statistic(draw), "statistic result"))
    estimates.sort()
    tail = (1.0 - confidence) / 2.0
    return [_quantile_sorted(estimates, tail), _quantile_sorted(estimates, 1.0 - tail)]


def _quantile_statistic(probability):
    """Return a callable computing the given quantile of a sample."""
    def compute(sample):
        return quantile(sample, probability)
    return compute


def latency_summary(values, *, seed, resamples=2000, confidence=0.95):
    """Return the §3.1 latency report for one command class.

    Keys: `count`, `min`, `max`, `mean`, `p50`, `p90`, `p99`, `p50_ci`,
    `p99_ci`, `p99_suppressed`. Each CI is `[low, high]` from `bootstrap_ci`
    with the same seed, so both intervals use the same resampled datasets.

    Below MIN_SAMPLES_FOR_P99 samples, `p99` and `p99_ci` are None and
    `p99_suppressed` is True; otherwise `p99_suppressed` is False.

    Raises ValueError for an empty sample or invalid bootstrap arguments.
    """
    sample = _as_float_list(values, "values")
    if not sample:
        raise ValueError("values must contain at least one sample")
    resamples = _check_resamples(resamples)
    confidence = _check_confidence(confidence)

    ordered = sorted(sample)
    suppress_p99 = len(ordered) < MIN_SAMPLES_FOR_P99
    summary = {
        "count": len(ordered),
        "min": ordered[0],
        "max": ordered[-1],
        "mean": statistics.fmean(ordered),
        "p50": _quantile_sorted(ordered, 0.50),
        "p90": _quantile_sorted(ordered, 0.90),
        "p99": None if suppress_p99 else _quantile_sorted(ordered, 0.99),
        "p50_ci": bootstrap_ci(ordered, _quantile_statistic(0.50), seed=seed,
                               resamples=resamples, confidence=confidence),
        "p99_ci": None,
        "p99_suppressed": suppress_p99,
    }
    if not suppress_p99:
        summary["p99_ci"] = bootstrap_ci(ordered, _quantile_statistic(0.99), seed=seed,
                                         resamples=resamples, confidence=confidence)
    return summary


# MARK: - Theil-Sen slope


def _check_series(times, values):
    """Return `(times, values)` as float lists of equal, non-zero length."""
    time_points = _as_float_list(times, "times")
    measurements = _as_float_list(values, "values")
    if len(time_points) != len(measurements):
        raise ValueError(
            f"times and values must have the same length, got {len(time_points)} and {len(measurements)}")
    if not time_points:
        raise ValueError("times and values must contain at least one point")
    return time_points, measurements


def _pair_slopes(time_points, measurements):
    """Yield pairwise slopes, skipping pairs whose times are equal."""
    count = len(time_points)
    if count <= THEIL_SEN_EXACT_MAX_POINTS:
        for i in range(count - 1):
            t_i = time_points[i]
            v_i = measurements[i]
            for j in range(i + 1, count):
                delta_t = time_points[j] - t_i
                if delta_t != 0.0:
                    yield (measurements[j] - v_i) / delta_t
        return
    rng = random.Random(THEIL_SEN_SAMPLE_SEED)
    for _ in range(THEIL_SEN_SAMPLED_PAIRS):
        for _attempt in range(_PAIR_DRAW_ATTEMPTS):
            i = rng.randrange(count)
            j = rng.randrange(count)
            delta_t = time_points[j] - time_points[i]
            if delta_t != 0.0:
                yield (measurements[j] - measurements[i]) / delta_t
                break


def theil_sen(times, values):
    """Return the Theil-Sen slope: the median of the pairwise slopes.

    `times` and `values` must have equal length and hold finite numbers. Pairs
    with identical times are skipped. Up to THEIL_SEN_EXACT_MAX_POINTS points
    all pairs are enumerated; above that THEIL_SEN_SAMPLED_PAIRS index pairs are
    drawn with the fixed seed THEIL_SEN_SAMPLE_SEED, so the result stays
    reproducible.

    The unit of `times` is the caller's choice (F3 passes seconds); the return
    value is in `value unit / time unit`.

    Raises ValueError for mismatched lengths, non-numeric input, or when no pair
    has distinct times.
    """
    time_points, measurements = _check_series(times, values)
    slopes = list(_pair_slopes(time_points, measurements))
    if not slopes:
        raise ValueError("no point pair with distinct times; the slope is undefined")
    return statistics.median(slopes)


# MARK: - moving-block bootstrap


def _build_blocks(time_points, series, block_span):
    """Return blocks `[(relative_times, series_slice), ...]` of span `block_span`.

    One block starts at every index whose block fits inside the observed time
    range. Blocks overlap, as in the moving-block bootstrap. Times inside a
    block are stored relative to the block start.
    """
    last_time = time_points[-1]
    blocks = []
    for start in range(len(time_points)):
        start_time = time_points[start]
        if start_time + block_span > last_time:
            break
        end = bisect.bisect_left(time_points, start_time + block_span, start)
        block_times = [time_points[index] - start_time for index in range(start, end)]
        if block_times:
            blocks.append((block_times, series[start:end]))
    return blocks


def moving_block_bootstrap_slope_ci(times, values, *, block_span, seed,
                                    resamples=2000, confidence=0.95):
    """Return the moving-block bootstrap interval for the Theil-Sen slope.

    Return shape, always these three keys:
        {"ci": [low, high] or None, "reason": str or None, "block_count": int}
    `ci` is None when the series cannot be resampled; `reason` then states why
    and `block_count` is the number of blocks per resample that was attempted
    (0 when no block could be formed). When `ci` is present, `reason` is None.

    `block_span` uses the same unit as `times` (F3 passes 300 seconds).

    Method: fit the Theil-Sen line on the observed series and take the
    residuals. Form overlapping residual blocks of span `block_span`. Each
    resample concatenates `block_count` blocks drawn with replacement and
    rebuilds the time axis by placing block j at offset `j * block_span` while
    keeping the within-block spacing; the fitted line is evaluated on the
    rebuilt axis and the resampled residuals are added back. The Theil-Sen
    slope of that series is one bootstrap estimate. The interval bounds are the
    `(1 - confidence) / 2` and `1 - (1 - confidence) / 2` quantiles of those
    estimates. `random.Random(seed)` makes the result reproducible.

    Resampling the residuals rather than the raw values keeps the trend in each
    bootstrap series; concatenating raw blocks would discard it, because pairs
    spanning two blocks carry no trend information and dominate the pair
    median.

    Raises ValueError for mismatched lengths, non-numeric input,
    `block_span <= 0`, `resamples < 1`, or a confidence outside (0, 1).
    """
    time_points, measurements = _check_series(times, values)
    block_span = _as_float(block_span, "block_span")
    if block_span <= 0.0:
        raise ValueError(f"block_span must be > 0, got {block_span!r}")
    resamples = _check_resamples(resamples)
    confidence = _check_confidence(confidence)

    order = sorted(range(len(time_points)), key=lambda index: time_points[index])
    time_points = [time_points[index] for index in order]
    measurements = [measurements[index] for index in order]

    total_span = time_points[-1] - time_points[0]
    if total_span < 2.0 * block_span:
        return {"ci": None, "block_count": 0,
                "reason": (f"time span {total_span:g} covers fewer than two blocks "
                           f"of {block_span:g}")}

    observed_slope = theil_sen(time_points, measurements)
    intercept = statistics.median(
        measurement - observed_slope * time_point
        for time_point, measurement in zip(time_points, measurements))
    residuals = [measurement - (observed_slope * time_point + intercept)
                 for time_point, measurement in zip(time_points, measurements)]

    blocks = _build_blocks(time_points, residuals, block_span)
    if len(blocks) < 2:
        return {"ci": None, "block_count": len(blocks),
                "reason": f"only {len(blocks)} block start position(s) available, need 2"}

    block_count = int(total_span // block_span)
    rng = random.Random(seed)
    slopes = []
    for _ in range(resamples):
        draw_times = []
        draw_values = []
        for position in range(block_count):
            block_times, block_residuals = blocks[rng.randrange(len(blocks))]
            offset = position * block_span
            for relative, residual in zip(block_times, block_residuals):
                time_point = offset + relative
                draw_times.append(time_point)
                draw_values.append(observed_slope * time_point + intercept + residual)
        try:
            slopes.append(theil_sen(draw_times, draw_values))
        except ValueError:
            continue
    if len(slopes) < 2:
        return {"ci": None, "block_count": block_count,
                "reason": "fewer than two resamples produced a defined slope"}

    slopes.sort()
    tail = (1.0 - confidence) / 2.0
    return {"ci": [_quantile_sorted(slopes, tail), _quantile_sorted(slopes, 1.0 - tail)],
            "block_count": block_count, "reason": None}


# MARK: - step detection


def _spread_scale(differences, median_difference):
    """Return the robust spread of the differences, or 0.0 when it is unmeasurable.

    Two estimators, larger first, both in the unit of the differences:

    1. The median absolute deviation of the differences from their median.
    2. Their interquartile range divided by GAUSSIAN_IQR_IN_SIGMA, which puts it
       in the same unit as the MAD (both equal sigma for Gaussian differences).

    The MAD alone is not enough: a quantised ramp drives it to 0 or to a
    rounding remainder, and a threshold built on that flags ordinary jitter as
    steps. The interquartile range keeps a usable spread in those series while
    staying robust. A 0 here means more than three quarters of the differences
    are the same value, so no "n sigma" scale exists and the caller falls back
    to `_sparse_move_scale`.
    """
    deviations = [abs(difference - median_difference) for difference in differences]
    ordered = sorted(differences)
    iqr = _quantile_sorted(ordered, 0.75) - _quantile_sorted(ordered, 0.25)
    return max(statistics.median(deviations), iqr / GAUSSIAN_IQR_IN_SIGMA)


def _quantum(values, candidate):
    """Return `candidate` when the series is quantised at it, else 0.0.

    The series is quantised at `candidate` when every value is an integer
    multiple of it and the smallest value is at least STEP_QUANTIZATION_LEVELS
    quanta above zero. The second condition is what makes the test evidence
    rather than arithmetic: a flat series holding a single jump trivially passes
    the first one, because its two values are 0 and 1 jumps above the origin.
    A `footprint` series reported in whole MiB sits at 73 and 74 quanta and
    passes both, so its 1 MiB movements are resolution, not events.
    """
    if candidate <= 0.0:
        return 0.0
    smallest = min(abs(value) for value in values)
    if smallest < STEP_QUANTIZATION_LEVELS * candidate:
        return 0.0
    for value in values:
        multiple = value / candidate
        if abs(multiple - round(multiple)) > 1e-6 * max(1.0, abs(multiple)):
            return 0.0
    return candidate


def _sparse_move_scale(values, moves):
    """Return the scale for a series whose differences have no measurable spread.

    `moves` are the non-zero deviations from the median difference: the whole
    movement of such a series. The staircase problem lives here. A series
    sampled in whole MiB rises one quantum at a time, so a slow trend arrives as
    a handful of identical 1 MiB differences; calling each of them a discrete
    event is wrong. One large jump in an otherwise constant series has exactly
    the same shape - differences that are mostly zero - so the two cannot be
    separated by counting or by the size of the smallest move.

    What separates them is whether the moves look like the measurement
    resolution and whether they look like each other:

    - `_quantum` asks the values, not the moves, whether the series lives on a
      lattice whose pitch is the smallest move. A movement of a few quanta on
      such a lattice is resolution.
    - The median move covers a staircase of several similar jumps: a genuine
      event stands out from the other moves, a stair does not. It is only
      meaningful with at least two moves, so a lone move is measured against the
      lattice alone, and a lone move on a series with no lattice evidence is an
      event whatever its size.

    Both are expressed in the unit of the differences, so the caller applies the
    same multiplier as in the ordinary case. A scale of 0 means every move is an
    event.
    """
    if not moves:
        return 0.0
    quantum = _quantum(values, min(moves))
    if len(moves) == 1:
        return quantum
    return max(quantum, statistics.median(moves))


def step_summary(times, values, *, mad_multiplier=STEP_MAD_MULTIPLIER,
                 dominance_share=STEP_DOMINANCE_SHARE):
    """Return the §3.6 discrete-step report for one series.

    A step is a point-to-point difference whose deviation from the median
    difference exceeds `mad_multiplier` robust scale units (see
    STEP_MAD_MULTIPLIER). The criterion is scale free: it holds no absolute
    size constant and so applies to MiB, KiB and CPU core series alike.

    The scale comes from the spread of the differences when that spread is
    measurable, and from the movement itself when it is not (`_spread_scale`,
    `_sparse_move_scale`); `scale_source` records which was used.

    Return shape, always these keys:
        {"steps": [{"index": int, "time": float, "delta": float}, ...],
         "step_count": int, "step_delta_sum": float, "aligned_delta_sum": float,
         "net_change": float,
         "dominated_share": float or None, "step_dominated": bool,
         "scale": float, "scale_source": str, "median_difference": float,
         "threshold": float, "mad_multiplier": float, "dominance_share": float}

    `time` is the time of the later point of the pair, in the caller's unit.
    `dominated_share` is `|aligned_delta_sum| / |net_change|`, where
    `aligned_delta_sum` adds only the steps that move the series in the
    direction of its net change: those are the ones that could account for it.
    The share is None when the net change is 0, and `step_dominated` is then
    True whenever a step was found, because all of the movement inside the
    window is discrete.

    Raises ValueError for mismatched lengths, non-numeric input, a
    non-positive multiplier, or a dominance share outside (0, 1].
    """
    time_points, measurements = _check_series(times, values)
    mad_multiplier = _as_float(mad_multiplier, "mad_multiplier")
    if mad_multiplier <= 0.0:
        raise ValueError(f"mad_multiplier must be > 0, got {mad_multiplier!r}")
    dominance_share = _as_float(dominance_share, "dominance_share")
    if not 0.0 < dominance_share <= 1.0:
        raise ValueError(f"dominance_share must lie in (0, 1], got {dominance_share!r}")

    order = sorted(range(len(time_points)), key=lambda index: time_points[index])
    time_points = [time_points[index] for index in order]
    measurements = [measurements[index] for index in order]

    empty = {"steps": [], "step_count": 0, "step_delta_sum": 0.0,
             "aligned_delta_sum": 0.0,
             "net_change": measurements[-1] - measurements[0],
             "dominated_share": None, "step_dominated": False,
             "scale": 0.0, "scale_source": "no difference", "median_difference": 0.0,
             "threshold": 0.0,
             "mad_multiplier": mad_multiplier, "dominance_share": dominance_share}
    if len(measurements) < 2:
        return empty

    differences = [measurements[index] - measurements[index - 1]
                   for index in range(1, len(measurements))]
    median_difference = statistics.median(differences)
    moves = [abs(difference - median_difference) for difference in differences
             if difference != median_difference]
    scale = _spread_scale(differences, median_difference)
    scale_source = "difference spread"
    if scale <= 0.0:
        # More than three quarters of the differences are identical: a constant
        # series, a perfect ramp, or a quantised series that moves one step at a
        # time. The spread carries no information, so the scale comes from the
        # movement itself.
        scale = _sparse_move_scale(measurements, moves)
        scale_source = "sparse moves"
    if not moves:
        return dict(empty, median_difference=median_difference,
                    scale_source="no movement")

    threshold = mad_multiplier * scale
    steps = [{"index": index + 1, "time": time_points[index + 1], "delta": difference}
             for index, difference in enumerate(differences)
             if abs(difference - median_difference) > threshold]
    delta_sum = math.fsum(step["delta"] for step in steps)
    net_change = measurements[-1] - measurements[0]
    # Dominance asks whether the net change of the window is a discrete event
    # rather than a rate, so only the steps that move the series the way it
    # actually went can account for it. Steps against the net change cancel part
    # of it instead of explaining it; counting them gives shares above 1 on quiet
    # series, where a few small drops against a small net rise would otherwise be
    # read as "the growth is a step".
    aligned_sum = math.fsum(step["delta"] for step in steps
                            if (step["delta"] > 0.0) == (net_change > 0.0))
    if net_change == 0.0:
        share = None
        dominated = bool(steps)
    else:
        share = abs(aligned_sum) / abs(net_change)
        dominated = share > dominance_share
    return {"steps": steps, "step_count": len(steps), "step_delta_sum": delta_sum,
            "aligned_delta_sum": aligned_sum,
            "net_change": net_change, "dominated_share": share,
            "step_dominated": dominated, "scale": scale, "scale_source": scale_source,
            "median_difference": median_difference, "threshold": threshold,
            "mad_multiplier": mad_multiplier, "dominance_share": dominance_share}


# MARK: - growth decision


def growth_verdict(runs):
    """Return the §3.6 growth decision over independent runs of one setup.

    Each run is a mapping `{"slope": float, "ci_low": float or None,
    "ci_high": float or None}`; None bounds mean the interval is unavailable.
    A run satisfies the growth condition when `ci_low` is present and > 0.
    An optional `"step_dominated": True` marks a run whose net change is
    dominated by discrete steps (see `step_summary`); a run without that key is
    treated as not dominated, so callers that predate step detection keep their
    results unchanged.

    Returns:
        "confirmed"      at least two satisfying, not step dominated runs whose
                         slopes share one sign
        "candidate"      at least one satisfying, not step dominated run,
                         condition for "confirmed" not met (this includes two or
                         more such runs with slopes of different signs)
        "step_dominated" no satisfying run survives the step filter, but at
                         least one satisfying run was step dominated: the
                         interval excludes zero because of one or more discrete
                         jumps inside the window, not because of a rate
        "not_detected"   no satisfying run, including an empty input

    Raises ValueError when a run is not a mapping, lacks `slope`, or holds a
    non-numeric field.
    """
    satisfying_slopes = []
    dominated_count = 0
    for index, run in enumerate(_iterable(runs, "runs")):
        label = f"runs[{index}]"
        try:
            slope = run["slope"]
            ci_low = run.get("ci_low")
            dominated = run.get("step_dominated")
        except (TypeError, AttributeError) as error:
            raise ValueError(f"{label} must be a mapping with a 'slope' key: {error}") from error
        except KeyError as error:
            raise ValueError(f"{label} is missing the 'slope' key") from error
        slope = _as_float(slope, f"{label}['slope']")
        if ci_low is None:
            continue
        if _as_float(ci_low, f"{label}['ci_low']") <= 0.0:
            continue
        if dominated is True:
            dominated_count += 1
            continue
        satisfying_slopes.append(slope)

    if not satisfying_slopes:
        return "step_dominated" if dominated_count else "not_detected"
    if len(satisfying_slopes) >= 2:
        positive = all(slope > 0.0 for slope in satisfying_slopes)
        negative = all(slope < 0.0 for slope in satisfying_slopes)
        if positive or negative:
            return "confirmed"
    return "candidate"
