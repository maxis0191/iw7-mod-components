"""Deterministic measurements on in-game frames, so agents look at pixels only
when the question is really visual.

Two instruments, both offline and read-only (they never touch a game, a
server or a lease):

frames    Per-frame metrics (luma, contrast, black/clipped fractions, pixel
          hash, perceptual hash) and an evidence-validity verdict for a
          capture sequence: black or uniform frames, and consecutive captures
          that are pixel-identical (frozen camera, intro screen, capture taken
          before the client advanced). Run it before any vision review: a
          sequence that fails it cannot answer a visual question.
diff      Test-versus-control measurement inside an optional region: changed
          pixel fraction, mean difference, change bounding box and the colour
          of the change. "Does the converted effect draw where the stock one
          does" becomes a number instead of an opinion.

Deliberately absent: a pixel detector of placeholder, void or untextured
regions. Calibrated on 2564 Station Zero frame quadrants against the vision
reviewers' localised findings it ranked them with AUC 0.70 at best (bright
flat regions were anti-correlated, AUC 0.35-0.43): too weak to direct a
reviewer. Geometry and material defects belong to source-level lint; look and
mood belong to vision review. See docs/FRAME-EVIDENCE.md.

Inputs for `frames`: PNG/BMP/JPG files, directories of them, a witness
`result.local.json` (schema iw7.bo3wpn-visual/1, frames grouped by scenario),
or a vision `index.json` (entries with `name` and `full`).

Requires Pillow and numpy. Output is JSON (schema iw7.frame-evidence/1).
"""
import argparse
import hashlib
import json
import os
import sys

import numpy as np
from PIL import Image

SCHEMA = 'iw7.frame-evidence/1'
IMAGE_EXT = ('.png', '.bmp', '.jpg', '.jpeg', '.tga')

# Thresholds, in 0..1 luma or colour units. Chosen on retained IW7 captures and
# kept explicit so a result can be reproduced and argued with.
BLACK_LUMA = 0.03          # a pixel this dark carries no visual information
CLIP_LUMA = 0.98           # a pixel this bright is clipped
BLACK_FRAME_FRACTION = 0.95
UNIFORM_STD = 0.01         # whole-frame luma deviation of a blank frame
IDENTICAL_MAX = 2 / 255    # capture/encoder noise allowed between "identical" frames
CHANGE_THRESHOLD = 12 / 255
STATIC_FRACTION = 0.001    # below this changed fraction two captures show the same picture


def load_rgb(path):
    with Image.open(path) as im:
        return np.asarray(im.convert('RGB'), dtype=np.float32) / 255.0


def luma(rgb):
    return rgb[..., 0] * 0.2126 + rgb[..., 1] * 0.7152 + rgb[..., 2] * 0.0722


def pixel_sha256(rgb):
    return hashlib.sha256(np.round(rgb * 255).astype(np.uint8).tobytes()).hexdigest()


def dhash64(y):
    """64-bit difference hash of a luma image (9x8 box downscale)."""
    h, w = y.shape
    rows = np.linspace(0, h, 9, dtype=int)
    cols = np.linspace(0, w, 10, dtype=int)
    small = np.array([[y[rows[r]:rows[r + 1], cols[c]:cols[c + 1]].mean() for c in range(9)] for r in range(8)])
    bits = (small[:, 1:] > small[:, :-1]).flatten()
    return '%016x' % int(''.join('1' if b else '0' for b in bits), 2)


def frame_metrics(rgb):
    y = luma(rgb)
    mx = rgb.max(axis=2)
    mn = rgb.min(axis=2)
    sat = np.where(mx > 0, (mx - mn) / np.maximum(mx, 1e-6), 0)
    m = {
        'width': int(rgb.shape[1]), 'height': int(rgb.shape[0]),
        'mean_luma': round(float(y.mean()), 4), 'std_luma': round(float(y.std()), 4),
        'p01_luma': round(float(np.percentile(y, 1)), 4), 'p99_luma': round(float(np.percentile(y, 99)), 4),
        'black_fraction': round(float((y < BLACK_LUMA).mean()), 4),
        'clipped_fraction': round(float((y > CLIP_LUMA).mean()), 4),
        'mean_saturation': round(float(sat.mean()), 4),
        'pixel_sha256': pixel_sha256(rgb), 'dhash': dhash64(y),
    }
    flags = []
    if m['black_fraction'] >= BLACK_FRAME_FRACTION:
        flags.append('BLACK')
    elif m['std_luma'] < UNIFORM_STD:
        flags.append('UNIFORM')
    if m['clipped_fraction'] >= 0.5:
        flags.append('CLIPPED')
    m['flags'] = flags
    return m


def _roi_slice(roi, shape):
    if roi is None:
        return slice(0, shape[0]), slice(0, shape[1])
    x, y, w, h = roi
    if w <= 0 or h <= 0 or x < 0 or y < 0 or x + w > shape[1] or y + h > shape[0]:
        raise ValueError('Region outside the frame: %r for %dx%d' % (roi, shape[1], shape[0]))
    return slice(y, y + h), slice(x, x + w)


def compare(a, b, roi=None, threshold=CHANGE_THRESHOLD):
    """Measure how b differs from a (b = test, a = control or earlier capture)."""
    if a.shape != b.shape:
        raise ValueError('Frame sizes differ: %s vs %s' % (a.shape[:2], b.shape[:2]))
    ys, xs = _roi_slice(roi, a.shape)
    da, db = a[ys, xs], b[ys, xs]
    diff = np.abs(db - da).max(axis=2)
    changed = diff > threshold
    out = {
        'region': list(roi) if roi else None,
        'max_difference': round(float(diff.max()), 4),
        'mean_difference': round(float(diff.mean()), 4),
        'changed_fraction': round(float(changed.mean()), 5),
        'identical': bool(diff.max() <= IDENTICAL_MAX),
        'mean_luma_delta': round(float(luma(db).mean() - luma(da).mean()), 4),
    }
    out['static'] = out['identical'] or out['changed_fraction'] < STATIC_FRACTION
    if changed.any():
        rr, cc = np.nonzero(changed)
        x0 = (roi[0] if roi else 0)
        y0 = (roi[1] if roi else 0)
        out['change_bbox'] = [int(cc.min()) + x0, int(rr.min()) + y0, int(cc.max() - cc.min() + 1), int(rr.max() - rr.min() + 1)]
        out['changed_mean_rgb_control'] = [round(float(v), 3) for v in da[changed].mean(axis=0)]
        out['changed_mean_rgb_test'] = [round(float(v), 3) for v in db[changed].mean(axis=0)]
    else:
        out['change_bbox'] = None
    return out, changed


# --- inputs ----------------------------------------------------------------

def collect(inputs):
    """Return [(sequence, name, path)] in capture order."""
    items = []
    for inp in inputs:
        if os.path.isdir(inp):
            names = sorted(f for f in os.listdir(inp) if f.lower().endswith(IMAGE_EXT))
            items += [(os.path.basename(os.path.normpath(inp)), os.path.splitext(f)[0], os.path.join(inp, f)) for f in names]
        elif inp.lower().endswith('.json'):
            with open(inp, encoding='utf-8-sig') as fh:
                doc = json.load(fh)
            if isinstance(doc, dict) and 'Frames' in doc:
                for f in doc.get('Frames') or []:
                    items.append((f.get('Scenario') or 'frames', f.get('Step') or os.path.basename(f['Path']), f['Path']))
            elif isinstance(doc, list) and doc and 'full' in doc[0]:
                for f in doc:
                    items.append((f.get('zone') or 'frames', f['name'], f['full']))
            else:
                raise ValueError('Unrecognised JSON input: ' + inp)
        elif inp.lower().endswith(IMAGE_EXT):
            items.append(('frames', os.path.splitext(os.path.basename(inp))[0], inp))
        else:
            raise ValueError('Not a frame, directory or known JSON: ' + inp)
    return items


def analyse(inputs):
    items = collect(inputs)
    frames = []
    previous = {}
    for seq, name, path in items:
        row = {'sequence': seq, 'name': name, 'path': path}
        if not os.path.exists(path):
            row['flags'] = ['MISSING']
            frames.append(row)
            continue
        rgb = load_rgb(path)
        row.update(frame_metrics(rgb))
        prev = previous.get(seq)
        if prev is not None and prev[1].shape == rgb.shape:
            cmp, _ = compare(prev[1], rgb)
            row['vs_previous'] = {'name': prev[0], 'identical': cmp['identical'], 'static': cmp['static'],
                                  'changed_fraction': cmp['changed_fraction'], 'change_bbox': cmp['change_bbox']}
            if cmp['identical']:
                row['flags'].append('IDENTICAL_TO_PREVIOUS')
            elif cmp['static']:
                row['flags'].append('STATIC_SINCE_PREVIOUS')
        previous[seq] = (name, rgb)
        frames.append(row)
    # Sequence-level verdict: can these frames answer a visual question at all?
    sequences = {}
    for row in frames:
        s = sequences.setdefault(row['sequence'], {'frames': 0, 'unusable': [], 'identical_pairs': 0, 'static_pairs': 0, 'changes': []})
        s['frames'] += 1
        if 'vs_previous' in row:
            s['changes'].append(row['vs_previous']['changed_fraction'])
        if set(row['flags']) & {'MISSING', 'BLACK', 'UNIFORM'}:
            s['unusable'].append(row['name'])
        if 'IDENTICAL_TO_PREVIOUS' in row['flags']:
            s['identical_pairs'] += 1
        if 'STATIC_SINCE_PREVIOUS' in row['flags']:
            s['static_pairs'] += 1
    for s in sequences.values():
        pairs = s['frames'] - 1
        reasons = []
        if s['unusable']:
            reasons.append('%d unusable frame(s)' % len(s['unusable']))
        if pairs > 0 and s['identical_pairs'] + s['static_pairs'] == pairs:
            reasons.append('every capture shows the same picture as the previous one')
        s['verdict'] = 'SUSPECT' if reasons else 'USABLE'
        s['reasons'] = reasons
        # Activity between consecutive captures: whether anything moved or drew.
        changes = s.pop('changes')
        s['max_change'] = max(changes) if changes else None
        s['mean_change'] = round(sum(changes) / len(changes), 5) if changes else None
    by_hash = {}
    for row in frames:
        if 'pixel_sha256' in row:
            by_hash.setdefault(row['pixel_sha256'], []).append(row['name'])
    duplicates = [names for names in by_hash.values() if len(names) > 1]
    return {'schema': SCHEMA, 'frames': frames, 'sequences': sequences, 'duplicate_groups': duplicates,
            'summary': {'frames': len(frames), 'suspect_sequences': sum(1 for s in sequences.values() if s['verdict'] != 'USABLE'),
                        'flagged_frames': sum(1 for f in frames if f['flags'])}}


def parse_roi(text):
    if not text:
        return None
    parts = [int(v) for v in text.split(',')]
    if len(parts) != 4:
        raise argparse.ArgumentTypeError('ROI is x,y,w,h')
    return tuple(parts)


def write_mask(changed, roi, shape, path):
    full = np.zeros(shape[:2], dtype=np.uint8)
    ys, xs = _roi_slice(roi, shape)
    full[ys, xs] = np.where(changed, 255, 0)
    Image.fromarray(full).save(path)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split('\n\n')[0])
    sub = ap.add_subparsers(dest='cmd', required=True)
    f = sub.add_parser('frames', help='metrics and evidence validity for captures')
    f.add_argument('inputs', nargs='+')
    f.add_argument('--json', help='write the full report here')
    d = sub.add_parser('diff', help='test frame versus control frame')
    d.add_argument('control')
    d.add_argument('test')
    d.add_argument('--roi', type=parse_roi, help='x,y,w,h in full-frame pixels')
    d.add_argument('--threshold', type=float, default=CHANGE_THRESHOLD * 255, help='per-channel change threshold, 0..255')
    d.add_argument('--mask', help='write the changed-pixel mask (PNG)')
    args = ap.parse_args(argv)
    try:
        if args.cmd == 'frames':
            report = analyse(args.inputs)
            if args.json:
                with open(args.json, 'w', encoding='utf-8') as fh:
                    json.dump(report, fh, indent=1)
            for name, s in report['sequences'].items():
                print('%-28s %-8s frames=%d identical=%d static=%d max_change=%s %s' % (
                    name, s['verdict'], s['frames'], s['identical_pairs'], s['static_pairs'], s['max_change'], '; '.join(s['reasons'])))
            print(json.dumps(report['summary']))
            return 1 if report['summary']['suspect_sequences'] else 0
        if args.cmd == 'diff':
            a, b = load_rgb(args.control), load_rgb(args.test)
            out, changed = compare(a, b, args.roi, args.threshold / 255)
            out['schema'] = SCHEMA
            if args.mask:
                write_mask(changed, args.roi, a.shape, args.mask)
            print(json.dumps(out, indent=1))
            return 0
    except (OSError, ValueError) as error:
        print('error: %s' % error, file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
