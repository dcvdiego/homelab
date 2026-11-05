# Bedroom sleep mode: lift the guard at 09:30 instead of at sunrise (sun elevation > 4°).
# In November that is ~07:35, while the room is still dark and someone is asleep, so the first
# presence flicker turned the lights on (2026-11-05 08:31). Manual on (button/app) still disarms.
# On docker-prod (CT 101): back up /docker/ha/automations.yaml, swap the sunrise trigger of
# automation 1790104193270 for a 09:30 time trigger, check the YAML still parses in the HA container.
# Idempotent: an already-changed file is left alone.
# Takes effect after Developer Tools -> YAML -> Reload automations (the runner has no HA token).
# Undo: pct exec 101 -- cp /docker/ha/automations.yaml.bak-20261105 /docker/ha/automations.yaml, then reload.
ssh -F "$OPS_SSH_CONFIG" pve 'pct exec 101 -- python3 -' <<'PY'
import shutil, subprocess, sys

f = "/docker/ha/automations.yaml"
bak = f + ".bak-20261105"
edits = [
    ("  alias: Bedroom sleep mode - disarm on manual on or sunrise\n",
     "  alias: Bedroom sleep mode - disarm on manual on or 09:30\n"),
    ("  description: Someone wants a light again (button/app/Alexa), or morning - lift the guard\n",
     "  description: Someone wants a light again (button/app/Alexa), or 09:30 - lift the guard\n"),
    ("  - trigger: numeric_state\n"
     "    entity_id: sun.sun\n"
     "    attribute: elevation\n"
     "    above: 4\n"
     "    id: sunrise\n",
     "  - trigger: time\n"
     "    at: '09:30:00'\n"
     "    id: morning\n"),
    ("    - condition: trigger\n"
     "      id: sunrise\n",
     "    - condition: trigger\n"
     "      id: morning\n"),
]

text = open(f).read()
if all(new in text and old not in text for old, new in edits):
    print("kept: already disarms at 09:30")
    sys.exit(0)
for old, new in edits:
    if text.count(old) != 1:
        print(f"error: expected exactly one match, found {text.count(old)}:\n{old}")
        sys.exit(1)
    text = text.replace(old, new)

shutil.copy2(f, bak)
print(f"backup: {bak}")
tmp = f + ".new"
open(tmp, "w").write(text)
check = subprocess.run(
    ["docker", "exec", "homeassistant", "python3", "-c",
     "import yaml,sys; a=[x for x in yaml.safe_load(open('/config/automations.yaml.new')) if x['id']=='1790104193270'][0]; print(a['triggers'][-1]); print(a['conditions'][0]['conditions'][-1])"],
    capture_output=True, text=True)
if check.returncode != 0:
    print("error: new file does not parse, left unchanged\n" + check.stderr)
    subprocess.run(["rm", "-f", tmp])
    sys.exit(1)
print("parsed:\n" + check.stdout.strip())
shutil.copymode(f, tmp)
subprocess.run(["mv", tmp, f], check=True)
print(f"wrote: {f}")
print("next: Developer Tools -> YAML -> Reload automations")
PY
