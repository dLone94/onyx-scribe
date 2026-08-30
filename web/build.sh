#!/usr/bin/env bash
# Regenerate web/index.html by inlining the Fraunces face + Onyx Cat icon
# (self-contained, deployable, no external requests). Run from repo root.
set -euo pipefail
cd "$(dirname "$0")/.."
sips -Z 160 FlowClone/Support/AppIcon-1024.png --out web/.icon160.png >/dev/null
python3 - <<'PY'
import base64
font = base64.b64encode(open("FlowClone/Sources/FlowClone/Resources/Fonts/Fraunces-VF.ttf","rb").read()).decode()
icon = base64.b64encode(open("web/.icon160.png","rb").read()).decode()
html = open("web/index.template.html").read().replace("__FRAUNCES_B64__", font).replace("__ICON_B64__", icon)
open("web/index.html","w").write(html)
print("web/index.html regenerated")
PY
rm -f web/.icon160.png
