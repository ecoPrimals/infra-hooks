#!/bin/bash
# northgate-pull.sh — pull from outside (GitHub) into Forgejo
#
# Three-body inbound path:
#   northgate (outside) → GitHub → this script → Forgejo → post-receive hook → golgi
#
# Runs as cron every 5 minutes. Checks all repos with 'github' remotes.
# If GitHub has new commits on main, fast-forwards and pushes to origin (Forgejo).
# The Forgejo post-receive hook then fires the osmotic publish cycle.
#
# RPM as pressure gauge:
#   Reads bloom.signal from golgi for current requests-per-minute.
#   Reads anderson-profile for entity classification (human/agent/bot/ghost).
#   Braids traffic pressure into the publish cycle.
#
# Feels: humans, agents, bots — all of it.

set -euo pipefail

LOG="/var/log/forgejo/northgate-pull.log"
BRAID_API="https://neutron.primals.eco/api/discuss"
REPOS_ROOT="/home/eastgate/Development/ecoPrimals"

mkdir -p "$(dirname "$LOG")"

TS=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# ═══ RPM — requests per minute as osmotic pressure ═══
read_rpm() {
    # Read bloom.signal from golgi via SSH
    local bloom
    bloom=$(ssh -o ConnectTimeout=3 golgi 'cat /run/membrane/bloom.signal 2>/dev/null' 2>/dev/null) || {
        echo "0|0|0"
        return
    }
    local total=$(echo "$bloom" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('total_requests',0))" 2>/dev/null || echo 0)
    local ips=$(echo "$bloom" | python3 -c "import sys,json; d=json.load(sys.stdin); print(d.get('unique_ips',0))" 2>/dev/null || echo 0)
    # bloom window is 30s, so RPM ≈ total * 2
    local rpm=$(( total * 2 ))
    echo "${rpm}|${ips}|${total}"
}

# ═══ ENTITY CLASSIFICATION — who's pushing against the membrane ═══
read_entities() {
    ssh -o ConnectTimeout=3 golgi 'cat /run/membrane/anderson-profile.json 2>/dev/null' 2>/dev/null | \
    python3 -c "
import sys,json
try:
    d=json.load(sys.stdin)
    modes = {m['class']: m['count'] for m in d.get('modes',[])}
    h = modes.get('human',0)
    s = modes.get('sovereign',0)
    g = modes.get('ghost',0)
    c = modes.get('chorus',0)
    st = modes.get('stealth',0)
    sp = modes.get('spectrum',0)
    sel = d.get('selectivity_observed',0)
    print(f'{h}|{s}|{g}|{c}|{st}|{sp}|{sel}')
except:
    print('0|0|0|0|0|0|0')
" 2>/dev/null || echo "0|0|0|0|0|0|0"
}

# ═══ POST TO BRAID — record the pull event ═══
post_pull_to_braid() {
    local repo="$1"
    local rev="$2"
    local rpm_data="$3"
    local entity_data="$4"
    local result="$5"

    IFS='|' read -r rpm ips total <<< "$rpm_data"
    IFS='|' read -r humans sovereign ghosts chorus stealth spectrum selectivity <<< "$entity_data"

    local body="NORTHGATE PULL | $TS | outside→inside | $repo $rev | $result | RPM:${rpm} IPs:${ips} | feels: human=${humans} sovereign=${sovereign} ghost=${ghosts} chorus=${chorus} stealth=${stealth} spectrum=${spectrum} | selectivity:${selectivity}"

    curl -s --max-time 5 -X POST "$BRAID_API" \
        -d "{\"page\": \"vcs-membrane\", \"author\": \"northgate\", \"body\": $(echo "$body" | python3 -c 'import sys,json; print(json.dumps(sys.stdin.read().strip()))' 2>/dev/null || echo "\"$body\"")}" \
        >/dev/null 2>&1 || true
}

# ═══ MAIN — scan repos for GitHub changes ═══

echo "" >> "$LOG"
echo "$TS northgate-pull: scanning GitHub remotes" >> "$LOG"

# Read RPM and entity data once per run (shared pressure for all repos)
RPM_DATA=$(read_rpm)
ENTITY_DATA=$(read_entities)

IFS='|' read -r RPM_VAL _ _ <<< "$RPM_DATA"
IFS='|' read -r E_HUMAN E_SOV E_GHOST E_CHORUS _ _ E_SEL <<< "$ENTITY_DATA"
echo "  RPM: $RPM_VAL | human=$E_HUMAN sovereign=$E_SOV ghost=$E_GHOST chorus=$E_CHORUS selectivity=$E_SEL" >> "$LOG"

PULLED=0
CHECKED=0

# Find all repos with github remotes
find "$REPOS_ROOT" -maxdepth 3 -name ".git" -type d 2>/dev/null | while read gitdir; do
    repo_dir=$(dirname "$gitdir")
    repo_name=$(basename "$repo_dir")

    # Skip if no github remote
    cd "$repo_dir"
    git remote get-url github >/dev/null 2>&1 || continue

    CHECKED=$((CHECKED + 1))

    # Fetch from GitHub (read-only, no auth needed for public repos)
    if ! git fetch github main --quiet 2>/dev/null; then
        continue
    fi

    # Check if GitHub has new commits
    LOCAL=$(git rev-parse main 2>/dev/null || echo "none")
    REMOTE=$(git rev-parse github/main 2>/dev/null || echo "none")

    if [ "$LOCAL" = "$REMOTE" ] || [ "$REMOTE" = "none" ]; then
        continue
    fi

    # Count new commits from GitHub
    NEW_COMMITS=$(git rev-list main..github/main --count 2>/dev/null || echo 0)
    if [ "$NEW_COMMITS" = "0" ]; then
        continue
    fi

    SHORT_REV=$(echo "$REMOTE" | cut -c1-7)
    LAST_MSG=$(git log -1 --format="%s" github/main 2>/dev/null || echo "?")
    LAST_AUTHOR=$(git log -1 --format="%an" github/main 2>/dev/null || echo "?")

    echo "  ← $repo_name: $NEW_COMMITS new commits from GitHub ($SHORT_REV by $LAST_AUTHOR)" >> "$LOG"
    echo "    msg: $LAST_MSG" >> "$LOG"

    # Fast-forward merge
    if git merge github/main --ff-only --quiet 2>/dev/null; then
        echo "    merged: ff-only OK" >> "$LOG"

        # Push to Forgejo — this triggers the post-receive hook!
        if git push origin main --quiet 2>/dev/null; then
            echo "    pushed: → Forgejo → sporeGate hook fires" >> "$LOG"
            PULLED=$((PULLED + 1))

            # Post to braid
            post_pull_to_braid "$repo_name" "$SHORT_REV" "$RPM_DATA" "$ENTITY_DATA" "OK"
        else
            echo "    ✗ push to Forgejo failed" >> "$LOG"
            post_pull_to_braid "$repo_name" "$SHORT_REV" "$RPM_DATA" "$ENTITY_DATA" "PUSH_FAIL"
        fi
    else
        echo "    ✗ ff-only merge failed (diverged? needs manual resolve)" >> "$LOG"
        post_pull_to_braid "$repo_name" "$SHORT_REV" "$RPM_DATA" "$ENTITY_DATA" "DIVERGED"
    fi
done

echo "  scanned, pulled $PULLED new" >> "$LOG"
