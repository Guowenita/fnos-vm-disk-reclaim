#!/usr/bin/env bash
# ============================================================================
# diagnose.sh - fnOS / KVM virtual-machine disk bloat: read-only diagnosis
#
# Usage:
#   sudo bash diagnose.sh              # scan all /vol* pools
#   sudo bash diagnose.sh /vol3        # focus on one pool
#
# READ-ONLY GUARANTEE: this script runs queries only (df / btrfs usage /
# subvolume list / lsof +L1 / find / qemu-img info --force-share /
# virsh dumpxml). It never deletes, rebalances, defines or shuts down
# anything.
#
# Exit codes: 0 = ran fine (see verdict), 1 = usage error, 2 = not root.
# ============================================================================
set -u

RED='\033[0;31m'; GREEN='\033[0;32m'; YEL='\033[0;33m'; CYA='\033[0;36m'; NC='\033[0m'
hr() { printf '%s\n' "------------------------------------------------------------------"; }
title() { printf "\n${CYA}== %s${NC}\n" "$1"; }
bad() { printf "  ${RED}[BAD]${NC} %s\n" "$1"; }
ok()  { printf "  ${GREEN}[OK ]${NC} %s\n" "$1"; }
warn(){ printf "  ${YEL}[!! ]${NC} %s\n" "$1"; }
info(){ printf "  [-- ] %s\n" "$1"; }

[ "$(id -u)" -eq 0 ] || { echo "Run as root (sudo bash diagnose.sh)"; exit 2; }

# ---------------------------------------------------------------- 1. pools
if [ $# -ge 1 ]; then
    POOLS="$1"
else
    POOLS=$(ls -d /vol* 2>/dev/null | tr '\n' ' ')
fi
[ -n "$POOLS" ] || { echo "No /vol* pools found"; exit 1; }

title "Storage pools"
for v in $POOLS; do
    df -h "$v" 2>/dev/null | tail -n +2 | sed 's/^/  /'
done

# ------------------------------------------------- 2. qcow2 inventory
title "Virtual disk inventory (qcow2)"
QCOWS=""
for v in $POOLS; do
    QCOWS="$QCOWS$(find "$v" -xdev -type f -name '*.qcow2' 2>/dev/null)"
done
QCOWS=$(echo "$QCOWS" | grep -v '^$' | sort -u)
if [ -z "$QCOWS" ]; then
    info "no qcow2 found under given pool(s)"
else
    for q in $QCOWS; do
        echo "  $q"
        qemu-img info --force-share "$q" 2>/dev/null | \
            grep -E "virtual size|disk size" | sed 's/^/    /'
    done
fi

# ------------------------------------------------- 3. per-VM XML verdicts
title "libvirt XML verdict (per running/defined VM)"
have_virsh=0
command -v virsh >/dev/null 2>&1 && have_virsh=1
if [ "$have_virsh" -eq 0 ]; then
    warn "virsh not found - skipping VM XML checks (non-libvirt host?)"
else
    while IFS= read -r vm; do
        [ -n "$vm" ] || continue
        echo "  VM: $vm"
        xml=$(virsh dumpxml "$vm" 2>/dev/null)
        [ -n "$xml" ] || { warn "  cannot dump XML"; continue; }

        # controllers that are virtio-scsi
        VSCSI=$(echo "$xml" | grep -c "controller type='scsi'[^>]*model='virtio-scsi'")

        # extract each <disk device='disk'> block (RS split, no fragile ranges)
        tmpx=$(mktemp)
        printf '%s\n' "$xml" > "$tmpx"
        awk 'BEGIN{RS="</disk>"} /device=.disk./ && /type=.file./' "$tmpx" | \
        while IFS= read -r blk; do
            src=$(printf '%s' "$blk" | grep -o "source file='[^']*'" | head -n1 | cut -d"'" -f2)
            dev=$(printf '%s' "$blk" | grep -o "target dev='[^']*'" | head -n1 | cut -d"'" -f2)
            bus=$(printf '%s' "$blk" | grep -o "target dev='[^']*' bus='[^']*'" | grep -o "bus='[^']*'" | head -n1 | cut -d"'" -f2)
            drv=$(printf '%s' "$blk" | grep -o "<driver [^>]*>" | head -n1)
            has_discard=$(printf '%s' "$drv" | grep -c "discard='unmap'")
            echo "    disk $dev  bus=$bus  src=$src"
            case "$bus" in
                scsi) if [ "$VSCSI" -ge 1 ]; then
                          ok "bus=virtio-scsi (controller present)"
                      else
                          warn "bus=scsi but no virtio-scsi controller model - verify"
                      fi ;;
                virtio) ok "bus=virtio-blk" ;;
                sata|ide|usb)
                      bad "bus=$bus - QEMU ide/sata emulation does NOT pass TRIM; switch to VirtIO SCSI" ;;
                *)     warn "bus=$bus unrecognized" ;;
            esac
            if [ "$has_discard" -ge 1 ]; then
                ok "driver discard='unmap' (guest TRIM accepted)"
            else
                bad "driver lacks discard='unmap' - format layer defaults to ignore; every guest TRIM is silently dropped"
            fi
        done
    done < <(virsh list --all --name 2>/dev/null)
fi

# ------------------------------------------------- 4. btrfs health per pool
title "btrfs health (per pool)"
for v in $POOLS; do
    fs=$(df -T "$v" 2>/dev/null | tail -n1 | awk '{print $2}')
    [ "$fs" = "btrfs" ] || { info "$v: not btrfs ($fs), skip"; continue; }
    echo "  $v:"
    unalloc=$(btrfs filesystem usage "$v" 2>/dev/null | grep -o 'Device unallocated:\s*[0-9.]*[KMG]i*' | grep -o '[0-9.]*[KMG]i*')
    echo "    Device unallocated: $unalloc"
    case "$unalloc" in
        0*|1.00MiB|1MiB|[0-9]*KiB)
            warn "unallocated nearly exhausted - even with free df space btrfs can hit metadata ENOSPC (read-only FS). Consider: btrfs balance start -dusage=0 -musage=0 $v" ;;
        *) ok "unallocated headroom present" ;;
    esac
    snaps=$(btrfs subvolume list "$v" 2>/dev/null | grep -c "snapshot")
    [ "$snaps" -gt 0 ] && warn "$snaps snapshot subvolume(s) may pin deleted extents" \
                        || info "no snapshot subvolumes"
done

# ------------------------------------------------- 5. deleted-but-open files
title "Deleted-but-still-open files (space held by processes)"
OPEN_DELETED=$(lsof +L1 2>/dev/null | awk 'NR>1 && $7 > 1048576 {printf "  %.1f GiB  %s (pid %s)\n", $7/1073741824, $1, $2}')
if [ -n "$OPEN_DELETED" ]; then
    printf '%s\n' "$OPEN_DELETED" | head -n 10
else
    ok "no large deleted-open files"
fi

# ------------------------------------------------- 6. verdict
title "VERDICT"
cat <<'EOF'
  Fix checklist (ALL five, in order):
   1. disk bus: SATA/IDE  ->  VirtIO SCSI        (XML: bus='scsi' + virtio-scsi controller)
   2. driver:    <driver name='qemu' type='qcow2' discard='unmap'/>
   3. cold boot: full shutdown THEN start        (virsh reboot is NOT enough)
   4. guest:     defrag /L C:   (interactive admin window; Windows built-in
                 ScheduledDefrag runs 'defrag -c -h -o -' WITHOUT /L - it never TRIMs)
   5. weekly:    schtasks ... defrag /L C: /RU SYSTEM   (see scripts/retrim-admin.bat)
  Then re-run this script: bus=OK + discard=OK + shrinking disk size = fixed.
EOF
hr
printf "Read-only run complete. Nothing was modified.\n"
rm -f "$tmpx" 2>/dev/null
exit 0
