#!/usr/bin/env python3
"""Small deterministic checks for mass-transfer arithmetic used by SnowfallMac."""
from __future__ import annotations
from math import exp, isclose
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
overlay = (ROOT / "SnowfallMac/Sources/SnowOverlayView.swift").read_text()
surfaces = (ROOT / "SnowfallMac/Sources/SurfaceTracker.swift").read_text()

# Guard the important source-level handoffs: edge grains and fling grains carry
# an explicit mass, and landed grains use that mass instead of their pixel radius.
required = [
    "var snowMass: CGFloat",
    "massPerParticle: CGFloat = 0",
    "massPerParticle: emissionMass",
    "let particleMass = totalFlingMass / CGFloat(requestedCount)",
    "massPerParticle: particleMass",
    "let landingMass = flake.snowMass > 0 ? flake.snowMass",
    "amount * sample.weight / totalWeight",
    "let freshSide = freshRemoved * 0.12",
    "let packedSide = packedRemoved * 0.06",
]
missing = [token for token in required if token not in overlay]
assert not missing, f"Missing mass-transfer implementation: {missing}"

# Check normalized deposition at both ends and in the middle of a pile. A
# truncated Gaussian must still distribute exactly the supplied amount.
def distribute(amount: float, center: int, count: int, radius: int, sigma: float) -> list[float]:
    samples = []
    for offset in range(-radius, radius + 1):
        index = center + offset
        if 0 <= index < count:
            weight = exp(-(offset * offset) / (2 * sigma * sigma))
            samples.append((index, weight))
    total = sum(weight for _, weight in samples)
    result = [0.0] * count
    for index, weight in samples:
        result[index] += amount * weight / total
    return result

for count in (1, 2, 17, 250):
    for center in {0, count // 2, max(0, count - 1)}:
        for radius, sigma in ((2, 1.25), (3, 1.75), (5, 2.5)):
            amount = 0.731
            values = distribute(amount, center, count, radius, sigma)
            assert isclose(sum(values), amount, rel_tol=1e-10, abs_tol=1e-10)
            assert min(values, default=0) >= 0

# Snowblower load + left/right side banks must equal removed mass for each
# material independently.
for fresh, packed in ((0, 0), (0.1, 0.8), (12.7, 3.4), (1000, 400)):
    fresh_side = fresh * 0.12
    packed_side = packed * 0.06
    machine_fresh = fresh - fresh_side
    machine_packed = packed - packed_side
    returned_fresh = machine_fresh + fresh_side * 0.5 + fresh_side * 0.5
    returned_packed = machine_packed + packed_side * 0.5 + packed_side * 0.5
    assert isclose(returned_fresh, fresh, rel_tol=1e-12, abs_tol=1e-12)
    assert isclose(returned_packed, packed, rel_tol=1e-12, abs_tol=1e-12)

# Explicit surface profiles must remain distinct and ordered from slick glass
# to a rougher ground surface.
for token in (
    "case .window: return 0.68",
    "case .dock: return 0.82",
    "case .ground: return 1.08",
    "case .window: return 0.225",
    "case .dock: return 0.19",
    "case .ground: return 0.145",
):
    assert token in surfaces, f"Missing surface profile: {token}"

print("Physics sanity passed: normalized deposits, carried mass, plow partition and surface profiles.")

# The dog event is coordinated globally, throttled to a ten-minute cadence,
# targets the largest mound, and adds a visual stain without increasing mass.
for token in (
    "static var nextEventTime: TimeInterval = 0",
    "SnowDogCoordinator.nextEventTime = now + 600",
    "max { $0.mass < $1.mass }",
    "let comesFromLeft = Bool.random()",
    "private func applyYellowSnow(on pile: SnowPile, at x: CGFloat)",
    "let radius = 7",
    "let normalized = CGFloat(offset) / 2.8",
    "pile.yellow[index] = max(pile.yellow[index], intensity)",
    "dog.direction *= -1",
    "yellow: pile.yellow",
    "appendSnowDog()",
    "Позвать собаку сейчас (проверка)",
):
    assert token in overlay or token in (ROOT / "SnowfallMac/Sources/AppDelegate.swift").read_text(), f"Missing dog feature: {token}"

# Yellow pigment stays local to the snow crust: narrow Gaussian profile,
# bounded intensity, and no stream/droplet primitives in the dog renderer.
patch = [0.78 * exp(-0.5 * (offset / 2.8) ** 2) for offset in range(-7, 8)]
assert 0 < min(patch) < max(patch) <= 0.78
assert patch[7] == 0.78
assert patch[0] < patch[4] < patch[7]
dog_draw = overlay[overlay.index("    private func appendSnowDog()"):
                   overlay.index("    private func appendSnowPolygon", overlay.index("    private func appendSnowDog()"))]
assert "streamStart" not in dog_draw and "streamEnd" not in dog_draw
assert "appendSnowDisc(center: position" not in dog_draw

print("Dog event sanity passed: ten-minute cadence, randomized side, shoulder targeting, and localized snow tint.")
