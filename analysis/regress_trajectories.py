#!/usr/bin/env python3
"""
Analyze vertex trajectories from FFT effect capture to find animation formulas.

This script performs regression analysis on captured UV trajectories to detect:
- Constant values (static)
- Linear motion (velocity)
- Sinusoidal motion (oscillation)
- Polynomial curves

Usage:
    python3 regress_trajectories.py capture.json [-o analysis.json]
"""

import json
import argparse
import sys
from pathlib import Path

# Try to import numpy/scipy, but provide fallbacks
try:
    import numpy as np
    from scipy.optimize import curve_fit
    from scipy.fft import fft
    HAS_SCIPY = True
except ImportError:
    HAS_SCIPY = False
    print("Warning: numpy/scipy not available. Using basic analysis only.")
    print("Install with: pip install numpy scipy")


def load_capture(path: str) -> dict:
    """Load JSON capture file."""
    with open(path, 'r') as f:
        return json.load(f)


def analyze_trajectory_basic(points: list, coord: str) -> dict:
    """Basic analysis without numpy (fallback)."""
    values = [p.get(coord, 0) for p in points]
    frames = [p.get('frame', i) for i, p in enumerate(points)]

    if len(values) < 2:
        return {'type': 'constant', 'value': values[0] if values else 0}

    # Check if constant
    min_val = min(values)
    max_val = max(values)
    if max_val - min_val < 2:
        return {'type': 'constant', 'value': sum(values) / len(values)}

    # Simple linear regression
    n = len(values)
    sum_x = sum(frames)
    sum_y = sum(values)
    sum_xy = sum(f * v for f, v in zip(frames, values))
    sum_x2 = sum(f * f for f in frames)

    denom = n * sum_x2 - sum_x * sum_x
    if abs(denom) < 0.001:
        return {'type': 'constant', 'value': sum_y / n}

    slope = (n * sum_xy - sum_x * sum_y) / denom
    intercept = (sum_y - slope * sum_x) / n

    # Calculate error
    predictions = [slope * f + intercept for f in frames]
    errors = [(v - p) ** 2 for v, p in zip(values, predictions)]
    mse = sum(errors) / len(errors)

    if abs(slope) < 0.1:
        return {'type': 'constant', 'value': sum_y / n}

    return {
        'type': 'linear',
        'start': intercept,
        'rate': slope,
        'error': mse
    }


def analyze_trajectory_scipy(points: list, coord: str) -> dict:
    """Analyze trajectory with numpy/scipy for better pattern detection."""
    values = np.array([p.get(coord, 0) for p in points])
    frames = np.array([p.get('frame', i) for i, p in enumerate(points)])

    if len(frames) < 4:
        return {'type': 'constant', 'value': float(np.mean(values))}

    # Check if constant
    if np.std(values) < 1.0:
        return {'type': 'constant', 'value': float(np.mean(values))}

    # Linear fit
    slope, intercept = np.polyfit(frames, values, 1)
    linear_pred = slope * frames + intercept
    linear_error = float(np.mean((values - linear_pred) ** 2))

    # Try sinusoidal fit
    sin_result = None
    try:
        # Use FFT to find dominant frequency
        centered = values - np.mean(values)
        if len(centered) > 2:
            fft_result = fft(centered)
            freqs = np.fft.fftfreq(len(values))
            # Find peak (skip DC component)
            magnitudes = np.abs(fft_result[1:len(fft_result)//2])
            if len(magnitudes) > 0:
                dominant_idx = np.argmax(magnitudes) + 1
                dominant_freq = abs(freqs[dominant_idx])

                # Define sinusoid function
                def sinusoid(f, amp, freq, phase, offset):
                    return amp * np.sin(2 * np.pi * freq * f + phase) + offset

                # Initial guess
                amp_guess = float((np.max(values) - np.min(values)) / 2)
                offset_guess = float(np.mean(values))
                freq_guess = dominant_freq if dominant_freq > 0 else 0.01

                try:
                    popt, _ = curve_fit(
                        sinusoid, frames, values,
                        p0=[amp_guess, freq_guess, 0, offset_guess],
                        maxfev=5000
                    )
                    sin_pred = sinusoid(frames, *popt)
                    sin_error = float(np.mean((values - sin_pred) ** 2))

                    # Only use sinusoid if it fits significantly better
                    if sin_error < linear_error * 0.5 and abs(popt[0]) > 1:
                        sin_result = {
                            'type': 'sinusoid',
                            'amplitude': float(popt[0]),
                            'frequency': float(popt[1]),
                            'phase': float(popt[2]),
                            'offset': float(popt[3]),
                            'error': sin_error
                        }
                except:
                    pass
    except:
        pass

    if sin_result:
        return sin_result

    # Check if linear is good enough
    if abs(slope) > 0.1:
        return {
            'type': 'linear',
            'start': float(intercept),
            'rate': float(slope),
            'error': linear_error
        }

    # Otherwise constant
    return {'type': 'constant', 'value': float(np.mean(values))}


def analyze_trajectory(points: list, coord: str) -> dict:
    """Analyze a trajectory for a single coordinate."""
    if HAS_SCIPY:
        return analyze_trajectory_scipy(points, coord)
    else:
        return analyze_trajectory_basic(points, coord)


def analyze_uv_group(uv_key: str, points: list) -> dict:
    """Analyze all coordinates for a UV group."""
    if not points:
        return {'uv': uv_key, 'point_count': 0}

    result = {
        'uv': uv_key,
        'point_count': len(points),
        'frame_range': [
            points[0].get('frame', 0),
            points[-1].get('frame', len(points) - 1)
        ],
    }

    # Analyze each coordinate
    for coord in ['x', 'y', 'r', 'g', 'b']:
        if coord in points[0]:
            result[coord] = analyze_trajectory(points, coord)

    return result


def generate_godot_formula(analysis: dict) -> str:
    """Generate GDScript formula for an analyzed trajectory."""
    atype = analysis.get('type', 'unknown')

    if atype == 'constant':
        val = analysis.get('value', 0)
        return f"{int(val)}"

    elif atype == 'linear':
        start = analysis.get('start', 0)
        rate = analysis.get('rate', 0)
        return f"{start:.1f} + frame * {rate:.4f}"

    elif atype == 'sinusoid':
        amp = analysis.get('amplitude', 0)
        freq = analysis.get('frequency', 0)
        phase = analysis.get('phase', 0)
        offset = analysis.get('offset', 0)
        angular_freq = freq * 2 * 3.14159
        return f"{amp:.1f} * sin(frame * {angular_freq:.4f} + {phase:.2f}) + {offset:.1f}"

    else:
        return "0  # Unknown pattern"


def main():
    parser = argparse.ArgumentParser(
        description='Analyze FFT effect capture trajectories'
    )
    parser.add_argument('capture_file', help='JSON capture file')
    parser.add_argument('-o', '--output', help='Output file for analysis JSON')
    parser.add_argument('-v', '--verbose', action='store_true',
                       help='Print detailed analysis')
    args = parser.parse_args()

    # Load capture
    try:
        data = load_capture(args.capture_file)
    except Exception as e:
        print(f"Error loading capture: {e}")
        sys.exit(1)

    print(f"Effect: {data.get('effect_name', 'unknown')}")
    print(f"Effect ID: {data.get('effect_id', 'unknown')}")
    print(f"Frames: {len(data.get('frames', []))}")
    print()

    trajectories = data.get('uv_trajectories', {})
    print(f"UV groups to analyze: {len(trajectories)}")
    print()

    # Analyze each trajectory
    results = {}
    summary = {
        'constant': 0,
        'linear': 0,
        'sinusoid': 0,
        'unknown': 0
    }

    for uv_key, points in trajectories.items():
        analysis = analyze_uv_group(uv_key, points)
        results[uv_key] = analysis

        # Count pattern types
        for coord in ['x', 'y', 'r', 'g', 'b']:
            if coord in analysis and isinstance(analysis[coord], dict):
                ptype = analysis[coord].get('type', 'unknown')
                summary[ptype] = summary.get(ptype, 0) + 1

        if args.verbose:
            print(f"\n=== UV {uv_key} ({len(points)} points) ===")
            for coord in ['x', 'y', 'r', 'g', 'b']:
                if coord in analysis and isinstance(analysis[coord], dict):
                    formula = generate_godot_formula(analysis[coord])
                    ptype = analysis[coord].get('type', 'unknown')
                    print(f"  {coord}: {ptype} -> {formula}")

    # Print summary
    print("\n=== Pattern Summary ===")
    for ptype, count in summary.items():
        if count > 0:
            print(f"  {ptype}: {count}")

    # Generate formulas for interesting trajectories
    print("\n=== Generated Formulas ===")
    formula_count = 0
    for uv_key, analysis in results.items():
        has_motion = False
        for coord in ['x', 'y']:
            if coord in analysis and isinstance(analysis[coord], dict):
                if analysis[coord].get('type') in ['linear', 'sinusoid']:
                    has_motion = True

        if has_motion:
            formula_count += 1
            if formula_count <= 10:  # Limit output
                print(f"\n# UV {uv_key}")
                for coord in ['x', 'y']:
                    if coord in analysis and isinstance(analysis[coord], dict):
                        formula = generate_godot_formula(analysis[coord])
                        print(f"var {uv_key.replace('(','').replace(')','').replace(',','_')}_{coord} := {formula}")

    if formula_count > 10:
        print(f"\n... and {formula_count - 10} more motion trajectories")

    # Save results
    if args.output:
        output_data = {
            'effect_id': data.get('effect_id'),
            'effect_name': data.get('effect_name'),
            'summary': summary,
            'trajectories': results
        }
        with open(args.output, 'w') as f:
            json.dump(output_data, f, indent=2)
        print(f"\nSaved analysis to {args.output}")


if __name__ == '__main__':
    main()
