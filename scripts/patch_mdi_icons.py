#!/usr/bin/env python3
"""Patch material_design_icons_flutter to avoid extending final IconData.

The package declares `class _MdiIconData extends IconData` and stores values
in a const map. IconData is final in recent Flutter versions, so this script
removes the class and inlines each entry as a const IconData instance:

    'abTesting': const _MdiIconData(0xf01c9),
becomes
    'abTesting': IconData(0xf01c9, fontFamily: 'Material Design Icons',
                          fontPackage: 'material_design_icons_flutter'),

Inside the const map literal the const keyword is inferred, so all entries
stay constant and release-build icon tree-shaking keeps working. The script
is idempotent and also upgrades files patched by an older version of this
script (which used a non-const factory function and broke tree-shaking).
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

ICON_DATA = (
    "IconData(\\1, fontFamily: 'Material Design Icons', "
    "fontPackage: 'material_design_icons_flutter')"
)


def main() -> int:
    if not os.path.exists(ICON_MAP):
        print(f'Not found: {ICON_MAP}', file=sys.stderr)
        return 0

    text = open(ICON_MAP, encoding='utf-8').read()
    if '_MdiIconData' not in text:
        print('material_design_icons_flutter already patched.')
        return 0

    # Remove the original class declaration.
    text = re.sub(
        r'class _MdiIconData extends IconData \{\s*const _MdiIconData\(int codePoint\)\s*:\s*super\(\s*codePoint,\s*fontFamily: \'Material Design Icons\',\s*fontPackage: \'material_design_icons_flutter\',\s*\);\s*\}\n?',
        '',
        text,
        flags=re.DOTALL,
    )

    # Remove the factory function inserted by older versions of this patch.
    text = re.sub(
        r"IconData _MdiIconData\(int codePoint\) => IconData\(\s*codePoint,\s*fontFamily: 'Material Design Icons',\s*fontPackage: 'material_design_icons_flutter',\s*\);\n?",
        '',
        text,
    )

    # Inline const IconData instances in place of constructor/function calls.
    text = re.sub(r'(?:const )?_MdiIconData\((0x[0-9a-fA-F]+)\)', ICON_DATA, text)

    # Older patches made the map non-const; restore const so entries are
    # constant instances and tree-shaking works.
    text = text.replace(
        'final iconMap = <String, IconData>',
        'const iconMap = <String, IconData>',
        1,
    )

    open(ICON_MAP, 'w', encoding='utf-8').write(text)
    print('Patched material_design_icons_flutter icon_map.dart')
    return 0


if __name__ == '__main__':
    raise SystemExit(main())
