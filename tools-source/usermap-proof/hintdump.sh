#!/bin/bash
# usage: hintdump.sh <cell> <out>
C=$1
P=$(python -B /c/forge/forge.py peek 0x146b22ab8 --type ptr --cell $C | python -c "import json,sys;print(int(json.load(sys.stdin)['value'],16)+0x4018)")
A=$(python -B /c/forge/forge.py peek $(printf '0x%X' $P) --type ptr --cell $C | python -c "import json,sys;print(json.load(sys.stdin)['value'])")
python -B /c/studio-data/r1/peek_hints2.py $C $A $2 | head -1
