#!/usr/bin/env python3
"""
Generate Godot GDScript from FFT effect trajectory analysis.

Takes the output from regress_trajectories.py and generates a complete
GDScript file that recreates the animation.

Usage:
    python3 generate_godot.py analysis.json [-o effect.gd]
"""

import json
import argparse
import sys
from pathlib import Path
from datetime import datetime


TEMPLATE = '''extends Node2D
## Auto-generated FFT Effect Animation
## Effect: {effect_name} (E{effect_id:03d})
## Generated: {timestamp}

# Animation state
var frame: int = 0
const TOTAL_FRAMES: int = {total_frames}
var playing: bool = true

# Scale and offset for screen positioning
var scale_factor: float = 2.0
var offset: Vector2 = Vector2(100, 100)

{vertex_declarations}

func _ready() -> void:
	print("Effect animation ready: {effect_name}")


func _process(delta: float) -> void:
	if playing:
		frame += 1
		if frame >= TOTAL_FRAMES:
			frame = 0

	# Update vertex positions
	_update_vertices()
	queue_redraw()


func _update_vertices() -> void:
{update_code}


func _draw() -> void:
{draw_code}


func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_SPACE:
				playing = not playing
			KEY_R:
				frame = 0
			KEY_EQUAL, KEY_KP_ADD:
				scale_factor = min(10.0, scale_factor + 0.5)
			KEY_MINUS, KEY_KP_SUBTRACT:
				scale_factor = max(0.5, scale_factor - 0.5)
'''


def sanitize_uv_name(uv_key: str) -> str:
    """Convert UV key to valid GDScript variable name."""
    return "uv_" + uv_key.replace('(', '').replace(')', '').replace(',', '_').replace('-', 'n')


def generate_formula(analysis: dict, var_prefix: str) -> tuple:
    """Generate GDScript formula for a coordinate.

    Returns (declaration, update_line) tuple.
    """
    atype = analysis.get('type', 'unknown')

    if atype == 'constant':
        val = int(analysis.get('value', 0))
        return (f"var {var_prefix}: float = {val}.0", None)

    elif atype == 'linear':
        start = analysis.get('start', 0)
        rate = analysis.get('rate', 0)
        return (
            f"var {var_prefix}: float = 0.0",
            f"\t{var_prefix} = {start:.1f} + float(frame) * {rate:.6f}"
        )

    elif atype == 'sinusoid':
        amp = analysis.get('amplitude', 0)
        freq = analysis.get('frequency', 0)
        phase = analysis.get('phase', 0)
        offset = analysis.get('offset', 0)
        angular_freq = freq * 2 * 3.14159
        return (
            f"var {var_prefix}: float = 0.0",
            f"\t{var_prefix} = {amp:.1f} * sin(float(frame) * {angular_freq:.6f} + {phase:.2f}) + {offset:.1f}"
        )

    else:
        return (f"var {var_prefix}: float = 0.0  # Unknown pattern", None)


def generate_vertex_code(uv_key: str, analysis: dict) -> tuple:
    """Generate code for one vertex.

    Returns (declarations, updates, draw_commands) tuple.
    """
    name = sanitize_uv_name(uv_key)
    declarations = []
    updates = []

    for coord in ['x', 'y']:
        if coord in analysis and isinstance(analysis[coord], dict):
            var_name = f"{name}_{coord}"
            decl, update = generate_formula(analysis[coord], var_name)
            declarations.append(decl)
            if update:
                updates.append(update)

    # Color handling
    for coord in ['r', 'g', 'b']:
        if coord in analysis and isinstance(analysis[coord], dict):
            var_name = f"{name}_{coord}"
            decl, update = generate_formula(analysis[coord], var_name)
            declarations.append(decl)
            if update:
                updates.append(update)

    # Draw command
    has_x = 'x' in analysis and isinstance(analysis['x'], dict)
    has_y = 'y' in analysis and isinstance(analysis['y'], dict)
    has_r = 'r' in analysis and isinstance(analysis['r'], dict)

    draw_cmd = None
    if has_x and has_y:
        color = "Color.WHITE"
        if has_r:
            color = f"Color({name}_r / 255.0, {name}_g / 255.0, {name}_b / 255.0)"
        draw_cmd = f"\tdraw_circle(Vector2({name}_x, {name}_y) * scale_factor + offset, 3, {color})"

    return (declarations, updates, draw_cmd)


def main():
    parser = argparse.ArgumentParser(
        description='Generate Godot animation code from trajectory analysis'
    )
    parser.add_argument('analysis_file', help='JSON analysis file from regress_trajectories.py')
    parser.add_argument('-o', '--output', default='effect_animation.gd',
                       help='Output GDScript file')
    parser.add_argument('--max-vertices', type=int, default=100,
                       help='Maximum vertices to include (default: 100)')
    parser.add_argument('--motion-only', action='store_true',
                       help='Only include vertices with motion')
    args = parser.parse_args()

    # Load analysis
    try:
        with open(args.analysis_file, 'r') as f:
            data = json.load(f)
    except Exception as e:
        print(f"Error loading analysis: {e}")
        sys.exit(1)

    effect_name = data.get('effect_name', 'Unknown')
    effect_id = data.get('effect_id', 0)
    trajectories = data.get('trajectories', {})

    print(f"Generating code for: {effect_name} (E{effect_id:03d})")
    print(f"Trajectories: {len(trajectories)}")

    # Collect code parts
    all_declarations = []
    all_updates = []
    all_draws = []

    # Sort trajectories by point count (most points first = most important)
    sorted_keys = sorted(
        trajectories.keys(),
        key=lambda k: trajectories[k].get('point_count', 0),
        reverse=True
    )

    vertex_count = 0
    for uv_key in sorted_keys:
        analysis = trajectories[uv_key]

        # Skip if motion-only and no motion
        if args.motion_only:
            has_motion = False
            for coord in ['x', 'y']:
                if coord in analysis and isinstance(analysis[coord], dict):
                    if analysis[coord].get('type') in ['linear', 'sinusoid']:
                        has_motion = True
            if not has_motion:
                continue

        # Generate code
        decls, updates, draw = generate_vertex_code(uv_key, analysis)

        all_declarations.extend(decls)
        all_updates.extend(updates)
        if draw:
            all_draws.append(draw)

        vertex_count += 1
        if vertex_count >= args.max_vertices:
            print(f"Limiting to {args.max_vertices} vertices")
            break

    print(f"Generated code for {vertex_count} vertices")

    # Determine total frames from analysis
    total_frames = 120  # Default
    for analysis in trajectories.values():
        frame_range = analysis.get('frame_range', [])
        if len(frame_range) >= 2:
            total_frames = max(total_frames, frame_range[1] + 1)

    # Build final code
    decl_text = '\n'.join(all_declarations) if all_declarations else "# No vertex declarations"
    update_text = '\n'.join(all_updates) if all_updates else "\tpass  # No updates"
    draw_text = '\n'.join(all_draws) if all_draws else "\tpass  # No draws"

    code = TEMPLATE.format(
        effect_name=effect_name,
        effect_id=effect_id or 0,
        timestamp=datetime.now().strftime('%Y-%m-%d %H:%M'),
        total_frames=total_frames,
        vertex_declarations=decl_text,
        update_code=update_text,
        draw_code=draw_text
    )

    # Write output
    output_path = Path(args.output)
    with open(output_path, 'w') as f:
        f.write(code)

    print(f"\nGenerated: {output_path}")
    print(f"  Declarations: {len(all_declarations)}")
    print(f"  Updates: {len(all_updates)}")
    print(f"  Draw commands: {len(all_draws)}")


if __name__ == '__main__':
    main()
