#!/usr/bin/env python3
"""Patch material_design_icons_flutter to avoid extending final IconData.

The package declares `class _MdiIconData extends IconData` and stores values
in a const map. IconData is final in recent Flutter versions, so this script
replaces the class with a function and makes the map non-const.
"""

import os
import re
import sys

PUB_CACHE = os.environ.get('PUB_CACHE', os.path.expanduser('~/.pub-cache'))
PACKAGE_DIR = os.path.join(
    PUB_CACHE,
    'hosted',
    'pub.dev',
    'material_design_icons_flutter-7.0.7296',
)
ICON_MAP = os.path.join(PACKAGE_DIR, 'lib', 'icon_map.dart')


def main() -> int:
    if not os.path.exists(ICON_MAP):
        print(f'Not found: {ICON_MAP}', file=sys.stderr)
        return 0

    text = open(ICON_MAP, encoding='utf-8').read()
    if 'final iconMap = <String, IconData>' in text:
        print('material_design_icons_flutter already patched.')
        return 0

    # Make the map non-const so entries can be function calls.
    text = text.replace(
        'const iconMap = <String, IconData>',
        'final iconMap = <String, IconData>',
        1,
    )

    # Replace const constructor calls with function calls in the map.
    text = re.sub(r'const _MdiIconData\((0x[0-9a-fA-F]+)\)', r'_MdiIconData(\1)', text)

    # Replace the class with a top-level function.
    text = re.sub(
        r'class _MdiIconData extends IconData \{\s*const _MdiIconData\(int codePoint\)\s*:\s*super\(\s*codePoint,\s*fontFamily: \'Material Design Icons\',\s*fontPackage: \'material_design_icons_flutter\',\s*\);\s*\}',
        "IconData _MdiIconData(int codePoint) => IconData(\n  codePoint,\n  fontFamily: 'Material Design Icons',\n  fontPackage: 'material_design_icons_flutter',\n);",
        text,
        flags=re.DOTALL,
    )

    open(ICON_MAP, 'w', encoding='utf-8').write(text)
    print('Patched material_design_icons_flutter icon_map.dart')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
