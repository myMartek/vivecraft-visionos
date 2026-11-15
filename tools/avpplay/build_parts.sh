#!/bin/bash
# build_parts.sh — unattended build of the game parts of Minecraft: Java Edition 26.3 + Vivecraft for Apple Vision Pro.
#
# Turns a clean checkout of this repository into one zip that holds what BUILDING.md sections 1-7 produce, device
# slices only, without the host app:
#
#   Payload/KleptonVivecraft.app/Frameworks/<18 game dylibs>      visionOS arm64, unsigned
#   Payload/KleptonVivecraft.app/klepton-payload/{launch.txt,baked.cp,payload-version,tree,root/...}
#                                                                 visionos/bundle_payload.sh + stage_native.sh
#   Payload/KleptonVivecraft.app/Licenses/...                     visionos/copy_licenses.sh
#
# Usage (no arguments, no questions, no sudo, no Homebrew):
#   AVPPLAY_WORK=<folder> AVPPLAY_OUT=<zip> tools/avpplay/build_parts.sh
#   AVPPLAY_WORK=<folder> tools/avpplay/build_parts.sh --check
#
#   AVPPLAY_WORK  absolute folder without blanks. Every download and all build state go there (about 8 GB) and stay
#                 for the next run. The checkout is only read: the project's scripts write beside themselves, so the
#                 work folder holds a working copy of the tree (AVPPLAY_WORK/tree) and the build runs in that copy.
#   AVPPLAY_OUT   absolute path of the zip to write.
#
# Output on stdout: "STAGE <i>/<n> <name>" when a stage begins ("... (already done)" when its result is there and
# passes its check), log lines in between (also in AVPPLAY_WORK/logs/), and as the LAST line on success
#   PARTS <absolute path of the zip> <sha256>
# with exit status 0. On a failure the last two lines are
#   FAILED <i>/<n> <name>: <one sentence>
#   LOG <path of the log>
# and the exit status is not 0 (143 after SIGTERM). A SIGTERM, to this process or to its process group, stops
# everything the build started, the running game included; the next run continues at the interrupted stage.
#
# Two more kinds of lines are for a progress display (BUILDING.md, "Progress lines"); a reader that does not know
# them can skip them, the lines above stay as they are:
#   PLAN <stage>:<seconds>[:<flags>] ...   once, before the first STAGE line: every stage in order, how long it took
#                                          on the reference Mac in the state this work folder is in, flag d when its
#                                          result is there and it will be skipped, n when it is mostly a download
#   PROGRESS <done> <total> <unit>[ <w>,...]  within a stage, at most about once a second: files, bytes, libraries,
#                                          parts (with the reference seconds of each part) or seconds (a timed wait)
#
# --check tests the prerequisites only and prints one line per problem (exit 1), or nothing (exit 0).
#
# Two stages run the real game on this Mac for about three minutes in all (BUILDING.md section 6: the world the bake
# loads, then the Knot bake). It needs a logged-in desktop, because the game draws into a real window, but nobody has
# to see it: the window is invisible, the game shows no Dock icon and leaves keyboard and mouse pointer alone. Sound is
# off, the microphone is not opened, and both runs end by themselves.
#
# Optional environment: AVPPLAY_NI_HEAP (native-image heap, e.g. 11g), AVPPLAY_NI_THREADS, AVPPLAY_BUILD_JOBS (compiler
# jobs of the native helpers), AVPPLAY_STALL_MIN (minutes without output or download progress before a stage counts as hung),
# VIVECRAFT_BUILD_SHOW_WINDOWS=1 (the two runs open ordinary Minecraft windows that come to the front, as a game
# started by hand does; for looking at what the game does. Not an AVPPLAY_ name, so AVP Play hands it through).

# zsh/sh-safe entry: everything below is bash.
if [ -z "${BASH_VERSION:-}" ]; then exec /bin/bash "$0" "$@"; fi

SELF_DIR="$(cd "$(dirname "$0")" && pwd -P)" || exit 2
SELF="$SELF_DIR/$(basename "$0")"

# A build must not depend on what the calling shell or app exports (JAVA_HOME, CFLAGS, a Homebrew PATH, git or Python
# settings). Start again with an empty environment and a short list of variables.
if [ "${AVPPLAY_ENV:-}" != clean ]; then
  keep=(AVPPLAY_ENV=clean "HOME=${HOME:-}" "USER=${USER:-$(/usr/bin/id -un)}" "LOGNAME=${LOGNAME:-$(/usr/bin/id -un)}"
        PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C LANG=C)
  for v in AVPPLAY_WORK AVPPLAY_OUT AVPPLAY_NI_HEAP AVPPLAY_NI_THREADS AVPPLAY_BUILD_JOBS AVPPLAY_STALL_MIN \
           AVPPLAY_DEV_STAMP VIVECRAFT_BUILD_SHOW_WINDOWS DEVELOPER_DIR http_proxy https_proxy all_proxy no_proxy \
           HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY; do
    eval "isset=\${$v+x}"
    if [ -n "$isset" ]; then eval "keep+=(\"$v=\${$v}\")"; fi
  done
  # The same goes for signals. A program that ignores SIGTERM (or blocks it) hands that on to everything it starts,
  # and a shell cannot take back a signal that was ignored when it started: `kill` then ends nothing this script
  # starts, and a stage waits for ever on a helper it thought it had stopped (seen with the world stage, run from a
  # job that had SIGTERM ignored). So the clean start also puts every signal back to its default.
  exec /usr/bin/env -i "${keep[@]}" /usr/bin/python3 -I -c '
import os, signal, sys
for n in range(1, signal.NSIG):
    if n in (signal.SIGKILL, signal.SIGSTOP):
        continue
    try:
        signal.signal(n, signal.SIG_DFL)
    except (OSError, ValueError, RuntimeError):
        pass
signal.pthread_sigmask(signal.SIG_SETMASK, [])
os.execv("/bin/bash", ["/bin/bash"] + sys.argv[1:])
' "$SELF" "$@"
fi

set -u
set -o pipefail
umask 022
trap '' PIPE

# ---------------------------------------------------------------------------------------------------------------
# Pins. Everything this script downloads itself, with the hash it must have. Official release archives only.
# The project's own scripts carry the pins of what they fetch (BUILDING.md, UPSTREAM.md); the Maven jars they
# fetch without a hash are checked against pins/lwjgl-3.4.3-maven.sha256.
#
#   what      version    bytes      sha256                                                            url
PINS='
cmake     4.3.3      87452640   5221a13450c7a0219a2a0d1b6c9085eb06489721fafd8488ccebc1584175d2fb  https://github.com/Kitware/CMake/releases/download/v4.3.3/cmake-4.3.3-macos-universal.tar.gz
ninja     1.13.2     314051     c99048673aa765960a99cf10c6ddb9f1fad506099ff0a0e137ad8960a88f321b  https://github.com/ninja-build/ninja/releases/download/v1.13.2/ninja-mac.zip
graalvm   25.0.4+7.1 353673229  0b79e23c133facbad2f7aa55a3b76d17bd59d2fa15e2735bb63391ace223fd13  https://download.oracle.com/graalvm/25/archive/graalvm-jdk-25.0.4_macos-aarch64_bin.tar.gz
'
# Oracle GraalVM is under the GraalVM Free Terms and Conditions (https://www.oracle.com/downloads/licenses/graal-free-license.html).
# The URL is Oracle's archive address of the file BUILDING.md section 1 names (same bytes as ".../25/latest/..." on
# 2026-11-15); "latest" moves with the next update and would then fail the hash.
pin() { printf '%s\n' "$PINS" | /usr/bin/awk -v n="$1" -v f="$2" '$1==n{print $f}'; }   # pin <what> <column 2..5>

# Pins of BUILDING.md that the project's scripts do not check themselves (sections 3 and 5).
VIVECRAFT_URL=https://github.com/Vivecraft/VivecraftMod
VIVECRAFT_BASE=15a9011fd5eb7816d44e168256814fc4b5c24c04
VIVECRAFT_TREE=9f23d5f57f45c63278987abaef03a921d5f21b65        # after patches 0000-0007
VIVECRAFT_JAR=vivecraft-26.3-1.3.18-fabric.jar
VIVECRAFT_JAR_SHA=5c2df5a85e9d76e768203dd4d38e247fd0c052330ad62e7985ef8bcdd197f913
VIVECRAFT_JAR_BYTES=19770429
LTW_URL=https://github.com/PojavLauncherTeam/ltw
LTW_COMMIT=7703f1c29a1fd7f151484c38fb7563bb79ca8ccb
SVC_PINS='opus4j=362db14553d39c4dc080e4edd50630b17dbf9682 rnnoise4j=5f2097d504fc67f31d0d8900e9df0a5bdf4ec9ae speex4j=9428cb14b8ec373fcd36f5b5792899611042ece9 lame4j=b09599989878cbc7349075eca0b3aa4f105e5957'

MCV=26.3
# The classpath scripts take the mod jars in the shell's glob order, and that order depends on the locale: release
# 1.0.3 was made in a UTF-8 locale (bbrb.jar after BadOptimizations.jar), the C locale puts bbrb.jar last. The
# classpath is built in this locale and then compared with the release's (pins/baked-26.3.cp).
CP_LOCALE=en_US.UTF-8
STAGES="tree tools graalvm headers vivecraft minecraft openal lwjgl klsdl ltw voicechat shims classpath world bake launcher image relink payload zip"
NSTAGES=20
LAST_NETWORK_STAGE=11          # voicechat: the last stage that downloads
# Hosts the build downloads from (--check and the first stage that needs the network test them).
HOSTS="github.com codeload.github.com raw.githubusercontent.com download.oracle.com repo1.maven.org
repo.maven.apache.org chromium.googlesource.com piston-meta.mojang.com piston-data.mojang.com libraries.minecraft.net
resources.download.minecraft.net meta.fabricmc.net maven.fabricmc.net cdn.modrinth.com services.gradle.org"

HELPER="$SELF_DIR/parts_helper.py"
py() { /usr/bin/python3 -I -B "$HELPER" "$@"; }
SRC="$(cd "$SELF_DIR/../.." && pwd -P)"

# ---------------------------------------------------------------------------------------------------------------
# Prerequisites
MEM_BYTES=$(/usr/sbin/sysctl -n hw.memsize 2>/dev/null || echo 0)
MEM_GB=$(( (MEM_BYTES + 536870912) / 1073741824 ))

work_problem() {   # prints a sentence when AVPPLAY_WORK is unusable
  local w="${AVPPLAY_WORK:-}"
  if [ -z "$w" ]; then echo "AVPPLAY_WORK is not set."; return; fi
  case "$w" in /*) ;; *) echo "AVPPLAY_WORK is not an absolute path: $w"; return ;; esac
  case "$w" in *[[:space:]]*) echo "AVPPLAY_WORK contains a blank; the project's build scripts cannot work in such a folder: $w"; return ;; esac
  case "$w/" in "$SRC"/*) echo "AVPPLAY_WORK is inside the checkout; it must be a folder of its own: $w"; return ;; esac
  case "$SRC/" in "$w"/*) echo "The checkout is inside AVPPLAY_WORK; the work folder must be a folder of its own: $w"; return ;; esac
}

free_gb() {   # free space of the volume that holds (or will hold) the work folder
  local d="${AVPPLAY_WORK:-/}"
  while [ ! -d "$d" ] && [ "$d" != / ]; do d="$(dirname "$d")"; done
  /bin/df -k "$d" 2>/dev/null | /usr/bin/awk 'NR==2{printf "%d", $4/1048576}'
}

need_gb() {   # what the rest of the build still needs
  local s="${AVPPLAY_WORK:-/nonexistent}/state/done"
  if [ -f "$s/relink" ]; then echo 3; elif [ -f "$s/voicechat" ]; then echo 6; else echo 12; fi
}

prereq_problems() {   # prereq_problems <net: 0|1> -> one line per problem on stdout; returns 0 when there is none
  local net=$1 n=0 p
  if [ "$(/usr/bin/uname -m)" != arm64 ] || [ "$(/usr/sbin/sysctl -n sysctl.proc_translated 2>/dev/null || echo 0)" = 1 ]; then
    echo "This Mac does not have Apple silicon (or the build was started under Rosetta); the build needs an Apple silicon Mac."; n=$((n+1))
  fi
  if [ "$MEM_GB" -lt 16 ]; then
    echo "This Mac has $MEM_GB GB of memory; the build needs at least 16 GB."; n=$((n+1))
  fi
  p="$(work_problem)"
  if [ -n "$p" ]; then echo "$p"; n=$((n+1))
  else
    local free need; free=$(free_gb); need=$(need_gb)
    if [ "${free:-0}" -lt "$need" ]; then
      echo "Only ${free:-0} GB are free on the volume of AVPPLAY_WORK; the build needs about $need GB."; n=$((n+1))
    fi
  fi
  local dev; dev="$(/usr/bin/xcode-select -p 2>/dev/null || true)"
  if [ -z "$dev" ] || [ ! -d "$dev" ]; then
    echo "Xcode is not installed or not selected (xcode-select -p names no folder)."; n=$((n+1))
  elif ! /usr/bin/xcodebuild -version >/dev/null 2>&1; then
    echo "The selected developer folder is not a full Xcode ($dev); select Xcode with xcode-select or DEVELOPER_DIR."; n=$((n+1))
  elif ! /usr/bin/xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
    echo "Xcode has not finished its first start (licence or components); open Xcode once."; n=$((n+1))
  elif ! /usr/bin/xcrun --sdk xros --show-sdk-path >/dev/null 2>&1; then
    echo "The selected Xcode has no visionOS SDK; install the visionOS platform in Xcode (Settings, Components)."; n=$((n+1))
  elif ! /usr/bin/xcrun --sdk xros --find clang >/dev/null 2>&1; then
    echo "The selected Xcode has no compiler for the visionOS SDK."; n=$((n+1))
  fi
  if ! /usr/bin/python3 -I -c 'import zipfile, hashlib, json' >/dev/null 2>&1; then
    echo "/usr/bin/python3 does not run (it comes with Xcode's command line tools)."; n=$((n+1))
  fi
  if ! /usr/bin/git --version >/dev/null 2>&1; then
    echo "/usr/bin/git does not run (it comes with Xcode's command line tools)."; n=$((n+1))
  fi
  if [ "$net" = 1 ]; then
    local d h; d="$(/usr/bin/mktemp -d /tmp/avpplay-net.XXXXXX)"
    for h in $HOSTS; do
      ( /usr/bin/curl -sS -o /dev/null -I --connect-timeout 20 -m 40 "https://$h/" >/dev/null 2>&1 || echo "$h" > "$d/$h" ) &
    done
    wait
    for h in $HOSTS; do   # a second, unhurried try before a host counts as unreachable (a busy line is not a dead one)
      [ -f "$d/$h" ] || continue
      if ! /usr/bin/curl -sS -o /dev/null -I --connect-timeout 30 -m 60 "https://$h/" >/dev/null 2>&1; then
        echo "The download host $h cannot be reached."; n=$((n+1))
      fi
    done
    /bin/rm -rf "$d"
  fi
  [ "$n" = 0 ]
}

case "${1:-}" in
  --check) if prereq_problems 1; then exit 0; else exit 1; fi ;;
  "") ;;
  *) echo "usage: AVPPLAY_WORK=<folder> AVPPLAY_OUT=<zip> $0 [--check]" >&2; exit 2 ;;
esac

# ---------------------------------------------------------------------------------------------------------------
# Run state
P="$(work_problem)"
if [ -n "$P" ]; then echo "FAILED 0/$NSTAGES setup: $P"; echo "LOG -"; exit 2; fi
OUT="${AVPPLAY_OUT:-}"
case "$OUT" in /*) ;; *) echo "FAILED 0/$NSTAGES setup: AVPPLAY_OUT is not set or not an absolute path."; echo "LOG -"; exit 2 ;; esac
WORK="${AVPPLAY_WORK%/}"
/bin/mkdir -p "$WORK/state/done" "$WORK/logs" "$WORK/dl" "$WORK/tools" "$WORK/bin" "$WORK/agents" || {
  echo "FAILED 0/$NSTAGES setup: the work folder $WORK cannot be created."; echo "LOG -"; exit 2; }
WORK="$(cd "$WORK" && pwd -P)"
STATE="$WORK/state"
TREE="$WORK/tree"
NI="$TREE/work/native-image"
I="$NI/inst-$MCV"
T8="$NI/out/t8-$MCV"
GRAAL="$WORK/graalvm/graalvm-jdk-$(pin graalvm 2)/Contents/Home"
PARTS="$WORK/parts"
APP="$PARTS/Payload/KleptonVivecraft.app"
LOG="$WORK/logs/build-$(/bin/date +%Y%m%d-%H%M%S)-$$.log"
HB="$STATE/heartbeat"
FIFO="$STATE/pipe"
: > "$LOG"

say() {   # a line of this script's own: stdout and the log
  printf '%s\n' "$*" 2>/dev/null || true
  printf '%s %s\n' "$(/bin/date +%H:%M:%S)" "$*" >> "$LOG"
}

CUR_I=0; CUR_NAME=setup; LP_PID=""; ST_PID=""
T_NAMES=(); T_SECS=(); T_STAT=()

finish_fail() {   # finish_fail <exit status> <sentence>
  local rc=$1; shift
  /bin/rm -rf "$STATE/lock" "$FIFO"
  say "FAILED $CUR_I/$NSTAGES $CUR_NAME: $*"
  say "LOG $LOG"
  exit "$rc"
}

# One build per work folder.
if ! /bin/mkdir "$STATE/lock" 2>/dev/null; then
  OTHER="$(/bin/cat "$STATE/lock/pid" 2>/dev/null || true)"
  if [ -n "$OTHER" ] && /bin/kill -0 "$OTHER" 2>/dev/null \
     && /bin/ps -o command= -p "$OTHER" 2>/dev/null | /usr/bin/grep -q build_parts; then
    say "FAILED 0/$NSTAGES setup: another build is running in this work folder (process $OTHER)."
    say "LOG $LOG"
    exit 3
  fi
  /bin/rm -rf "$STATE/lock"; /bin/mkdir "$STATE/lock"
fi
echo $$ > "$STATE/lock/pid"

# ---------------------------------------------------------------------------------------------------------------
# Environment of every stage
/bin/rm -rf "$WORK/tmp"; /bin/mkdir -p "$WORK/tmp"
CMAKE_BIN="$WORK/tools/cmake-$(pin cmake 2)/CMake.app/Contents/bin"
NINJA_BIN="$WORK/tools/ninja-$(pin ninja 2)"
export PATH="$WORK/bin:$CMAKE_BIN:$NINJA_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
export TMPDIR="$WORK/tmp/"
export MCV
export G="$GRAAL" JAVA_HOME="$GRAAL"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0 GIT_CEILING_DIRECTORIES="$WORK"
export GIT_AUTHOR_NAME="avpplay build" GIT_AUTHOR_EMAIL="build@localhost"
export GIT_COMMITTER_NAME="avpplay build" GIT_COMMITTER_EMAIL="build@localhost"
export COPYFILE_DISABLE=1
export KL_MSA_SECRETS=/nonexistent      # stage_native.sh must never look for a Microsoft token on this Mac
# `python3` of the project's scripts is the system one, whatever else is installed.
printf '#!/bin/sh\nexec /usr/bin/python3 "$@"\n' > "$WORK/bin/python3"; /bin/chmod 755 "$WORK/bin/python3"

if [ -n "${AVPPLAY_BUILD_JOBS:-}" ]; then JOBS=$AVPPLAY_BUILD_JOBS
elif [ "$MEM_GB" -lt 24 ]; then JOBS=2
else JOBS=4; fi
export JOBS
# native-image: 11g and one worker built the 26.3 image on a 16 GB Mac (14 m 49 s, 5.8 GB peak resident). More
# memory gets a larger heap, up to the 28g BUILDING.md used on 36 GB; only the 16 GB point is measured here.
NI_HEAP_G=$(( MEM_GB * 7 / 10 ))
[ "$NI_HEAP_G" -gt 28 ] && NI_HEAP_G=28
[ "$NI_HEAP_G" -lt 11 ] && NI_HEAP_G=11
NI_HEAP="${AVPPLAY_NI_HEAP:-${NI_HEAP_G}g}"
if [ -n "${AVPPLAY_NI_THREADS:-}" ]; then NI_THREADS=$AVPPLAY_NI_THREADS
elif [ "$MEM_GB" -lt 24 ]; then NI_THREADS=1
elif [ "$MEM_GB" -lt 32 ]; then NI_THREADS=2
else NI_THREADS=""; fi

MYPGID="$(/bin/ps -o pgid= -p $$ | /usr/bin/tr -d ' ')"
LEADER=0; [ "$MYPGID" = "$$" ] && LEADER=1

# ---------------------------------------------------------------------------------------------------------------
# Processes
descendants() {   # descendants <pid>... -> every process below them
  /bin/ps -axo pid=,ppid= | /usr/bin/awk -v roots="$*" '
    BEGIN { n = split(roots, r, " "); for (i = 1; i <= n; i++) want[r[i]] = 1 }
    { pp[$1] = $2 }
    END { do { more = 0; for (p in pp) if (!(p in want) && (pp[p] in want)) { want[p] = 1; out[p] = 1; more = 1 } } while (more)
          for (p in out) print p }'
}

started() {   # everything this build started and that still runs (not this shell, not the log writer)
  # Children and grandchildren, plus processes of this process group that lost their parent (launchd adopted
  # them): all of those when this script leads the group, otherwise the ones whose command line names the work
  # folder. A neighbour in a shell pipeline (same group, other parent) is not touched.
  local roots
  roots="$(/bin/ps -axo pid=,ppid=,pgid=,command= | /usr/bin/awk -v g="$MYPGID" -v w="$WORK/" -v lead="$LEADER" -v me="$$" '
    { pid = $1; pp = $2; pg = $3; if (pid == me || pg != g) next
      if (pp == 1 && (lead == 1 || index($0, w) > 0)) print pid }')"
  { printf '%s\n' $roots; descendants $$ $roots; } | /usr/bin/sort -u | while read -r p; do
    [ -n "$p" ] && [ "$p" != "$$" ] && [ "$p" != "${LP_PID:-x}" ] && echo "$p"
  done
}

stop_started() {   # SIGTERM to everything started, SIGKILL to what is left after ten seconds
  local pids p left n=0
  pids="$(started)"
  [ -n "$pids" ] || return 0
  for p in $pids; do /bin/kill -TERM "$p" 2>/dev/null; done
  while [ $n -lt 20 ]; do
    left=""
    for p in $pids; do /bin/kill -0 "$p" 2>/dev/null && left="$left $p"; done
    [ -z "$left" ] && return 0
    /bin/sleep 0.5; n=$((n+1))
  done
  for p in $left; do /bin/kill -KILL "$p" 2>/dev/null; done
  pids="$(started)"
  for p in $pids; do /bin/kill -KILL "$p" 2>/dev/null; done
  return 0
}

stop_logpipe() {
  local n=0
  [ -n "$LP_PID" ] || return 0
  while /bin/kill -0 "$LP_PID" 2>/dev/null && [ $n -lt 20 ]; do /bin/sleep 0.1; n=$((n+1)); done
  /bin/kill -TERM "$LP_PID" 2>/dev/null
  wait "$LP_PID" 2>/dev/null
  LP_PID=""
}

on_signal() {
  trap '' TERM INT HUP
  say "!! SIG$1 received: stopping everything this build started"
  stop_started
  stop_logpipe
  case $1 in TERM) finish_fail 143 "stopped by SIGTERM; the next run continues at this stage." ;;
             INT)  finish_fail 130 "stopped by SIGINT; the next run continues at this stage." ;;
             *)    finish_fail 129 "stopped by SIGHUP; the next run continues at this stage." ;; esac
}
trap 'on_signal TERM' TERM
trap 'on_signal INT' INT
trap 'on_signal HUP' HUP

# ---------------------------------------------------------------------------------------------------------------
# Helpers used inside stages (a stage runs in a subshell with `set -e`, its output goes to the log and stdout)
fail() {   # the one sentence the caller is told
  printf '%s\n' "$*" > "$STATE/why"
  echo "!! $*"
  exit 1
}

retry() {   # retry <attempts> <what, for the message> <command...>
  local max=$1 what=$2 n=1; shift 2
  while :; do
    if "$@"; then return 0; fi
    if [ $n -ge $max ]; then echo "!! $what failed $n times"; return 1; fi
    echo "!! $what failed (attempt $n of $max); trying again in $((n * 10)) s"
    /bin/sleep $((n * 10)); n=$((n+1))
  done
}

fetch_pinned() {   # fetch_pinned <url> <file> <sha256> [<bytes>] -- resumed download, six attempts, hash checked
  local url=$1 file=$2 sha=$3 bytes=${4:-} n=1 whole=0
  if py verify "$file" "$sha" $bytes; then echo "have $(basename "$file") (sha256 ok)"; return 0; fi
  /bin/mkdir -p "$(dirname "$file")"; /bin/rm -f "$file"
  while :; do
    if [ -f "$file.part" ]; then   # what an earlier attempt or an interrupted run left
      if py verify "$file.part" "$sha" $bytes; then
        /bin/mv -f "$file.part" "$file"; echo "sha256 ok: $(basename "$file")"; return 0
      fi
      if [ $whole = 1 ] || { [ -n "$bytes" ] && [ "$(/usr/bin/stat -f %z "$file.part")" -ge "$bytes" ]; }; then
        echo "!! $(basename "$file"): the downloaded file does not have the pinned sha256 $sha"
        /bin/rm -f "$file.part"
      fi
    fi
    if [ $n -gt 6 ]; then printf '%s\n' "$url could not be downloaded with the pinned hash after 6 attempts." > "$STATE/why"; return 1; fi
    if [ $n -gt 1 ]; then
      echo "!! download failed (attempt $((n - 1)) of 6); trying again in $(((n - 1) * 10)) s"; /bin/sleep $(((n - 1) * 10))
    fi
    echo "downloading $url"
    whole=0
    if /usr/bin/curl -fL --connect-timeout 30 --speed-limit 500 --speed-time 180 -C - -o "$file.part" "$url"; then whole=1; fi
    n=$((n+1))
  done
}

clone_at() {   # clone_at <dir> <url> <commit> -- shallow fetch of exactly that commit
  local dir=$1 url=$2 commit=$3
  if [ -d "$dir/.git" ] && [ "$(/usr/bin/git -C "$dir" rev-parse -q --verify HEAD 2>/dev/null)" = "$commit" ]; then return 0; fi
  /bin/rm -rf "$dir"; /bin/mkdir -p "$dir"
  /usr/bin/git -C "$dir" init -q
  /usr/bin/git -C "$dir" fetch --progress --depth 1 "$url" "$commit" || return 1
  /usr/bin/git -C "$dir" -c advice.detachedHead=false checkout -q FETCH_HEAD || return 1
  [ "$(/usr/bin/git -C "$dir" rev-parse HEAD)" = "$commit" ]
}

drop_broken_clones() {   # a clone that an interrupted fetch left without a commit would stop the project's scripts
  local d
  for d in "$@"; do
    [ -e "$d" ] || continue
    if [ ! -d "$d/.git" ] || ! /usr/bin/git -C "$d" rev-parse -q --verify HEAD >/dev/null 2>&1; then
      echo "removing the incomplete clone $d"; /bin/rm -rf "$d"
    fi
  done
}

platform_of() { /usr/bin/xcrun vtool -show-build "$1" 2>/dev/null | /usr/bin/awk '/platform/{print $2; exit}'; }

# ---------------------------------------------------------------------------------------------------------------
# Stages. stage_<name> does the work; check_<name> says whether its result is there (quick, no side effects).

stage_tree() {
  /bin/mkdir -p "$TREE"
  py sync "$SRC" "$TREE" "$STATE/manifest.new.json" "$STATE/manifest.json"
  /bin/cp "$STATE/manifest.new.json" "$STATE/manifest.json"
  # GraalVM is kept outside the working copy; the project's scripts look for it at this path.
  /bin/mkdir -p "$NI"
  if [ -e "$NI/graalvm" ] && [ ! -L "$NI/graalvm" ]; then /bin/rm -rf "$NI/graalvm"; fi
  /bin/ln -sfn "$WORK/graalvm" "$NI/graalvm"
}
check_tree() { [ -f "$TREE/BUILDING.md" ] && [ -f "$TREE/visionos/bundle_payload.sh" ] && [ -L "$NI/graalvm" ]; }

stage_tools() {
  local v d
  v=$(pin cmake 2); d="$WORK/tools/cmake-$v"
  fetch_pinned "$(pin cmake 5)" "$WORK/dl/cmake-$v-macos-universal.tar.gz" "$(pin cmake 4)" "$(pin cmake 3)" || exit 1
  /bin/rm -rf "$d" "$d.tmp"; /bin/mkdir -p "$d.tmp"
  /usr/bin/tar -xzf "$WORK/dl/cmake-$v-macos-universal.tar.gz" -C "$d.tmp" --strip-components 1
  /usr/bin/xattr -dr com.apple.quarantine "$d.tmp" 2>/dev/null || true
  /bin/mv "$d.tmp" "$d"
  v=$(pin ninja 2); d="$WORK/tools/ninja-$v"
  fetch_pinned "$(pin ninja 5)" "$WORK/dl/ninja-$v-mac.zip" "$(pin ninja 4)" "$(pin ninja 3)" || exit 1
  /bin/rm -rf "$d" "$d.tmp"; /bin/mkdir -p "$d.tmp"
  /usr/bin/unzip -q "$WORK/dl/ninja-$v-mac.zip" -d "$d.tmp"
  /usr/bin/xattr -dr com.apple.quarantine "$d.tmp" 2>/dev/null || true
  /bin/chmod 755 "$d.tmp/ninja"
  /bin/mv "$d.tmp" "$d"
  "$CMAKE_BIN/cmake" --version | /usr/bin/head -1
  echo "ninja $("$NINJA_BIN/ninja" --version)"
  [ "$("$CMAKE_BIN/cmake" --version | /usr/bin/awk 'NR==1{print $3}')" = "$(pin cmake 2)" ] || fail "the unpacked cmake does not report version $(pin cmake 2)."
  [ "$("$NINJA_BIN/ninja" --version)" = "$(pin ninja 2)" ] || fail "the unpacked ninja does not report version $(pin ninja 2)."
}
check_tools() { [ -x "$CMAKE_BIN/cmake" ] && [ -x "$NINJA_BIN/ninja" ]; }

stage_graalvm() {
  local v tgz; v=$(pin graalvm 2); tgz="$WORK/dl/graalvm-jdk-$v-macos-aarch64.tar.gz"
  echo "Oracle GraalVM JDK $v: its use is under the GraalVM Free Terms and Conditions,"
  echo "  https://www.oracle.com/downloads/licenses/graal-free-license.html"
  fetch_pinned "$(pin graalvm 5)" "$tgz" "$(pin graalvm 4)" "$(pin graalvm 3)" || exit 1
  /bin/rm -rf "$WORK/graalvm" "$WORK/graalvm.tmp"; /bin/mkdir -p "$WORK/graalvm.tmp"
  /usr/bin/tar -xzf "$tgz" -C "$WORK/graalvm.tmp"
  /usr/bin/xattr -dr com.apple.quarantine "$WORK/graalvm.tmp" 2>/dev/null || true
  [ -d "$WORK/graalvm.tmp/graalvm-jdk-$v" ] || fail "the GraalVM archive does not hold graalvm-jdk-$v."
  /bin/mv "$WORK/graalvm.tmp" "$WORK/graalvm"
  /usr/bin/grep -E '^(JAVA_VERSION|JAVA_RUNTIME_VERSION|GRAALVM_VERSION)=' "$GRAAL/release"
  /usr/bin/grep -q '^JAVA_VERSION="25.0.4"' "$GRAAL/release" || fail "the unpacked GraalVM is not JDK 25.0.4."
  "$GRAAL/bin/native-image" --version | /usr/bin/head -1
}
check_graalvm() { [ -x "$GRAAL/bin/java" ] && [ -x "$GRAAL/bin/native-image" ] && /usr/bin/grep -q '^JAVA_VERSION="25.0.4"' "$GRAAL/release"; }

stage_headers() {   # BUILDING.md section 2
  cd "$TREE"
  retry 3 "fetching the ANGLE and Vulkan headers" python3 -I work/natives/scripts/fetch-graphics-headers.py \
    || fail "the ANGLE and Vulkan headers could not be fetched from chromium.googlesource.com."
}
check_headers() { [ -f "$TREE/vendor/include/EGL/egl.h" ] && [ -f "$TREE/vendor/third_party/vulkan-headers/src/include/vulkan/vulkan.h" ]; }

stage_vivecraft() {   # BUILDING.md section 3
  local V="$TREE/work/vivecraft-openxr-26.3" M
  M="$V/VivecraftMod"
  cd "$V"
  if [ ! -d "$M/.git" ] || [ "$(/usr/bin/git -C "$M" rev-parse -q --verify 'HEAD^{tree}' 2>/dev/null)" != "$VIVECRAFT_TREE" ]; then
    # The guide clones the whole repository; the one base commit is enough for `git am` and the build.
    /bin/rm -rf "$M"
    retry 3 "fetching VivecraftMod $VIVECRAFT_BASE" clone_at "$M" "$VIVECRAFT_URL" "$VIVECRAFT_BASE" \
      || fail "the Vivecraft sources could not be fetched from github.com."
    /usr/bin/git -C "$M" checkout -q -B kl-mobile-26.3 "$VIVECRAFT_BASE"
    /usr/bin/git -C "$M" -c commit.gpgsign=false -c core.autocrlf=false am "$V/patches/"*.patch
    local t; t="$(/usr/bin/git -C "$M" rev-parse 'HEAD^{tree}')"
    [ "$t" = "$VIVECRAFT_TREE" ] || fail "the patched Vivecraft tree is $t, not the pinned $VIVECRAFT_TREE."
    echo "patched tree $t (as pinned)"
  fi
  printf 'project.build.excludeForge=true\nproject.build.excludeNeoforge=true\n' > "$M/local.properties"
  export GRADLE_USER_HOME="$V/gradle-home"
  cd "$M"
  /bin/rm -rf build/libs build/canonical
  retry 3 "the Vivecraft Gradle build" ./gradlew --no-daemon --console=plain :fabric:build -x test \
    -Pfabric_api_version=0.165.2+26.3 || fail "the Vivecraft Gradle build failed."
  /bin/mkdir -p build/canonical
  python3 -I ../../vivecraft-openxr-26.2/canonicalize-vivecraft-jar.py \
    "build/libs/$VIVECRAFT_JAR" "build/canonical/$VIVECRAFT_JAR"
  py verify "build/canonical/$VIVECRAFT_JAR" "$VIVECRAFT_JAR_SHA" "$VIVECRAFT_JAR_BYTES" \
    || fail "the Vivecraft jar is $(py sha256 "build/canonical/$VIVECRAFT_JAR"), not the pinned $VIVECRAFT_JAR_SHA."
  echo "Vivecraft jar sha256 $VIVECRAFT_JAR_SHA (as pinned)"
  python3 -I ../check-touch-map.py "build/canonical/$VIVECRAFT_JAR" "$JAVA_HOME/bin/javap" > "$WORK/tmp/touch-map.txt" \
    || { /bin/cat "$WORK/tmp/touch-map.txt"; fail "the static check of the Vivecraft jar (check-touch-map.py) failed."; }
  /usr/bin/grep -E '^\[(touch-map|direct-post|no-seated)\]' "$WORK/tmp/touch-map.txt"
  /usr/bin/grep -q '^\[touch-map\] OK' "$WORK/tmp/touch-map.txt" && /usr/bin/grep -q '^\[direct-post\] OK' "$WORK/tmp/touch-map.txt" \
    && /usr/bin/grep -q '^\[no-seated\] OK' "$WORK/tmp/touch-map.txt" \
    || fail "the static check of the Vivecraft jar did not print its three OK lines."
}
check_vivecraft() { [ -f "$TREE/work/vivecraft-openxr-26.3/VivecraftMod/build/canonical/$VIVECRAFT_JAR" ]; }

stage_minecraft() {   # BUILDING.md section 4
  cd "$NI"
  /bin/rm -rf "$I/files/mods"
  retry 3 "fetching Minecraft $MCV, its libraries, assets and the mods" python3 -I scripts/m3a/fetch-inst.py "$MCV" \
    || fail "the Minecraft client, libraries, assets or mods could not be fetched completely."
  py verify "$I/files/mods/Vivecraft.jar" "$VIVECRAFT_JAR_SHA" || fail "fetch-inst.py did not install the Vivecraft jar."
  [ -f "$I/assets/indexes/$(/bin/cat "$I/asset-index-id.txt").json" ] || fail "the asset index is missing after fetch-inst.py."
}
check_minecraft() { [ -f "$I/files/versions/$MCV/client.jar" ] && [ -f "$I/files/mods/Vivecraft.jar" ] && [ -d "$I/assets/objects" ]; }

stage_openal() {   # BUILDING.md section 5, device slice only
  cd "$TREE"
  local s=work/natives/scripts/build-openal.sh url sha
  url="$(/usr/bin/sed -n 's/^URL=//p' $s | /usr/bin/head -1)"; sha="$(/usr/bin/sed -n 's/^SHA=//p' $s | /usr/bin/head -1)"
  if [ -n "$url" ] && [ ${#sha} = 64 ]; then
    fetch_pinned "$url" work/natives/downloads/openal/openal-soft-1.25.2.tar.gz "$sha" || exit 1
  fi
  /bin/rm -rf work/natives/openal/xros
  $s xros
}
check_openal() { [ -f "$TREE/work/natives/openal/xros/libopenal.dylib" ]; }

maven_pins_ok() {   # every pinned LWJGL jar present with its hash; a wrong file is removed so the next fetch replaces it
  local dir=$1 ok=0 sha name
  while read -r sha name; do
    [ -n "$name" ] || continue
    if ! py verify "$dir/$name" "$sha"; then
      [ -e "$dir/$name" ] && echo "!! $name does not have its pinned sha256; removed"
      /bin/rm -f "$dir/$name"; ok=1
    fi
  done < "$SELF_DIR/pins/lwjgl-3.4.3-maven.sha256"
  return $ok
}

shaderc_sources() { /bin/ls -d work/natives/downloads/shaderc-* work/natives/downloads/shaderc-*/third_party/glslang \
  work/natives/downloads/shaderc-*/third_party/spirv-tools work/natives/downloads/shaderc-*/third_party/spirv-headers \
  work/natives/downloads/SPIRV-Cross-* 2>/dev/null; }

stage_lwjgl() {   # BUILDING.md section 5: LWJGL 3.4.3, FreeType, shaderc, SPIRV-Cross (host libraries + device slice)
  cd "$TREE"
  . work/natives/scripts/lwjgl-ver.sh
  fetch_pinned "https://github.com/freetype/freetype/archive/refs/tags/$FT_TAG.tar.gz" \
    "work/natives/downloads/freetype-$FT_TAG.tar.gz" "$FT_SHA256" || exit 1
  fetch_pinned "https://github.com/libffi/libffi/releases/download/v$FFI_VER/libffi-$FFI_VER.tar.gz" \
    "work/native-image/dl/libffi/libffi-$FFI_VER.tar.gz" "$FFI_SHA256" || exit 1
  local n=1
  while :; do
    drop_broken_clones "$LWJGL_SRC"
    if work/natives/scripts/fetch-lwjgl341.sh && maven_pins_ok "$LWJGL_MV"; then break; fi
    maven_pins_ok "$LWJGL_MV" || true
    [ $n -lt 4 ] || fail "the LWJGL 3.4.3 sources or Maven jars could not be fetched completely after 4 attempts."
    echo "!! fetching LWJGL failed (attempt $n of 4); trying again in $((n * 10)) s"; /bin/sleep $((n * 10)); n=$((n+1))
  done
  echo "LWJGL $LWJGL_VER at $(/usr/bin/git -C "$LWJGL_SRC" rev-parse HEAD); $(/usr/bin/grep -c . "$SELF_DIR/pins/lwjgl-3.4.3-maven.sha256") Maven jars match their pinned sha256"
  # macosx: build-t4.sh asks for READY-macosx, and the stock macOS dylibs are what the Knot bake runs on
  work/native-image/scripts/t2/build-lwjgl341-natives.sh
  work/natives/scripts/build-shaderc-spvc.sh macosx
  work/native-image/scripts/t2/build-lwjgl341-natives.sh xros
  n=1
  while :; do
    drop_broken_clones $(shaderc_sources)
    if work/natives/scripts/build-shaderc-spvc.sh xros; then break; fi
    # all five checkouts complete and it still failed: a build error, not the network
    if [ "$(shaderc_sources | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = 5 ] && [ -z "$(drop_broken_clones $(shaderc_sources))" ]; then
      fail "building shaderc and SPIRV-Cross for visionOS failed."
    fi
    [ $n -lt 4 ] || fail "the shaderc and SPIRV-Cross sources could not be fetched after 4 attempts."
    echo "!! fetching the shaderc sources failed (attempt $n of 4); trying again in $((n * 10)) s"; /bin/sleep $((n * 10)); n=$((n+1))
  done
}
check_lwjgl() {
  local o="$TREE/work/natives/build/lwjgl-3.4.3"
  [ -f "$o/BUILT-lwjgl-macosx" ] && [ -f "$o/BUILT-lwjgl-xros" ] && [ -f "$o/xros/liblwjgl.dylib" ] \
    && [ -f "$o/xros/libfreetype.dylib" ] && [ -f "$o/xros/libshaderc.dylib" ] && [ -f "$o/xros/libspirv-cross.dylib" ]
}

stage_klsdl() {   # BUILDING.md section 5: klglfw (build-t4.sh checks its READY files) and klsdl
  cd "$TREE"
  work/native-image/scripts/t2/build-klglfw341.sh macosx xros
  work/native-image/scripts/t2/build-klsdl.sh xros
}
check_klsdl() {
  local o="$TREE/work/natives/build/lwjgl-3.4.3"
  [ -f "$o/READY-macosx" ] && [ -f "$o/READY-xros" ] && [ -f "$o/klsdl/lwjgl-sdl-klsdl-3.4.3.jar" ] && [ -f "$o/xros/libklsdl.dylib" ]
}

stage_ltw() {   # BUILDING.md section 5
  cd "$TREE"
  /bin/mkdir -p work/src
  retry 3 "fetching ltw $LTW_COMMIT" clone_at work/src/PojavLauncherTeam_ltw "$LTW_URL" "$LTW_COMMIT" \
    || fail "the ltw sources could not be fetched from github.com."
  /bin/rm -rf work/natives/ltw/build/xros
  /usr/bin/make -j"$JOBS" -C work/natives/ltw SDK=xros ANGLE_INC="$TREE/vendor/include"
}
check_ltw() { [ -f "$TREE/work/natives/ltw/build/xros/libltw.dylib" ]; }

stage_voicechat() {   # BUILDING.md section 5: Simple Voice Chat codecs
  cd "$TREE"
  local pair r want have
  /bin/rm -rf work/natives/svc/xros
  drop_broken_clones work/natives/downloads/svc/opus4j work/natives/downloads/svc/rnnoise4j \
    work/natives/downloads/svc/speex4j work/natives/downloads/svc/lame4j
  retry 3 "fetching and building the Simple Voice Chat codecs" work/natives/scripts/build-svc.sh xros \
    || fail "the Simple Voice Chat codecs could not be fetched or built."
  for pair in $SVC_PINS; do
    r=${pair%%=*}; want=${pair#*=}; have="$(/usr/bin/git -C "work/natives/downloads/svc/$r" rev-parse HEAD)"
    [ "$have" = "$want" ] || fail "$r is at $have, not the pinned $want."
  done
  echo "opus4j, rnnoise4j, speex4j, lame4j at their pinned commits"
}
check_voicechat() {
  local d="$TREE/work/natives/svc/xros"
  [ -f "$d/libopus4j.dylib" ] && [ -f "$d/librnnoise4j.dylib" ] && [ -f "$d/libspeex4j.dylib" ] && [ -f "$d/liblame4j.dylib" ]
}

stage_shims() {   # BUILDING.md section 5: OpenXR loader shims, klegl
  cd "$TREE"
  work/natives/scripts/build-openxr-shim.sh      # builds both slices in a second; only xros is used
  /bin/mkdir -p work/native-image/lwjgl-fork-t4/natives
  work/native-image/scripts/t8b/build-natives.sh xros
}
check_shims() {
  [ -f "$TREE/work/natives/openxr-shim/xros/libopenxr_loader.dylib" ] && [ -f "$TREE/work/natives/openxr-shim/xros/libvloader.dylib" ] \
    && [ -f "$NI/out/t8b/xros/libklegl.dylib" ]
}

mac_run_settings() {   # what the two runs on this Mac start with
  # Mod configs: the committed defaults, so the mixins the bake applies are the ones the shipped configs ask for.
  # options.txt: sound off, no pause when the window is not in front, nothing that waits for a click.
  local F="$I/fgamedir" s
  /bin/rm -rf "$F/config"; /bin/cp -R "$SELF_DIR/defaults/fgamedir/config" "$F/config"
  s="$F/config/voicechat/voicechat-client.properties"
  # run_local_server=false: no voice chat in the singleplayer world, so Simple Voice Chat never opens the
  # microphone (macOS would ask for permission); macos_check_microphone_permission=false: no permission query.
  /usr/bin/sed -e 's/^run_local_server=.*/run_local_server=false/' \
               -e 's/^macos_check_microphone_permission=.*/macos_check_microphone_permission=false/' "$s" > "$s.tmp"
  /usr/bin/grep -q '^run_local_server=false' "$s.tmp" && /usr/bin/grep -q '^macos_check_microphone_permission=false' "$s.tmp" \
    || fail "the voice chat defaults have no run_local_server / macos_check_microphone_permission line."
  /bin/mv "$s.tmp" "$s"
  # version: the options version Minecraft 26.3 writes, so no data fixer rewrites these lines.
  printf '%s\n' 'version:5023' 'soundCategory_master:0.0' 'pauseOnLostFocus:false' 'onboardAccessibility:false' \
    'narrator:0' 'tutorialStep:none' 'fullscreen:false' > "$F/options.txt"
}

stage_classpath() {   # BUILDING.md section 6: classpaths and the two agents
  cd "$NI"
  /bin/rm -rf "$I/vanilla" "$I/fabric" "$I/fgamedir" "$I/gamedir" "$I/bake" "$I/baked" "$I/klsdl" "$I/klglfw" \
    "$I/jarfix" "$I/out" "$I/mac-run-settings" "$I"/*.cp bakeagent baked
  LC_ALL=$CP_LOCALE scripts/mkcp.sh
  LC_ALL=$CP_LOCALE scripts/mkcp-fabric.sh
  local BA="$WORK/tmp/bakeagent-classes"
  /bin/rm -rf "$BA"; /bin/mkdir -p "$BA" bakeagent
  "$G/bin/javac" -cp "$(/bin/cat "$I/fabric.cp")" -d "$BA" scripts/bake-src/BakeAgent.java
  "$G/bin/jar" cfm bakeagent/bakeagent.jar scripts/bake-src/MANIFEST.MF -C "$BA" .
  # The world agent is compiled without the game and kept outside the instance: never in mods/, on no classpath.
  local MW="$WORK/tmp/mkworld-classes"
  /bin/rm -rf "$MW" "$WORK/agents/mkworld-agent.jar"; /bin/mkdir -p "$MW"
  "$G/bin/javac" -d "$MW" "$SELF_DIR/mkworld/MkWorldAgent.java"
  "$G/bin/jar" cfm "$WORK/agents/mkworld-agent.jar" "$SELF_DIR/mkworld/MANIFEST.MF" -C "$MW" .
  # The window helper of the two runs (tools/avpplay/quietwindow, see run_game). The build does not depend on it:
  # without it the two windows are small, never take the keyboard and show no Dock icon, but they can be seen, and
  # the game puts the mouse pointer into the middle of its window once when the player enters the world.
  /bin/rm -f "$QUIET_LIB"
  if /usr/bin/xcrun --sdk macosx clang -arch arm64 -fobjc-arc -O1 -dynamiclib -framework AppKit \
       -o "$QUIET_LIB" "$SELF_DIR/quietwindow/quiet_window.m" \
     && "$G/bin/java" -agentpath:"$QUIET_LIB" -version >/dev/null 2>&1; then
    echo "window helper built: the two Minecraft windows will be invisible"
  else
    /bin/rm -f "$QUIET_LIB"
    echo "!! note: the window helper could not be built or loaded; the two Minecraft windows will be small and will not take the keyboard"
  fi
  mac_run_settings
  echo "$(/usr/bin/tr ':' '\n' < "$I/fabric.cp" | /usr/bin/wc -l | /usr/bin/tr -d ' ') classpath entries, $(/bin/ls "$I/fgamedir/mods" | /usr/bin/wc -l | /usr/bin/tr -d ' ') mods"
}
check_classpath() { [ -f "$I/fabric.cp" ] && [ -f "$NI/bakeagent/bakeagent.jar" ] && [ -f "$WORK/agents/mkworld-agent.jar" ] && [ -d "$I/fgamedir/mods" ]; }

QUIET_W=320; QUIET_H=240      # the window of the two runs (points), unless VIVECRAFT_BUILD_SHOW_WINDOWS=1
QUIET_LIB="$WORK/agents/libquietwindow.dylib"

window_note() {   # what the user will see of the run that starts now
  if [ "${VIVECRAFT_BUILD_SHOW_WINDOWS:-0}" = 1 ]; then echo "A Minecraft window opens for about $1 (sound off)."
  elif [ -f "$QUIET_LIB" ]; then echo "Minecraft runs for about $1 (sound off). Its window is invisible: nothing opens on the screen."
  else echo "Minecraft runs for about $1 (sound off) in a small window that does not take the keyboard."; fi
}

# A run of the game does not get past its loading screen while the screen of this Mac is locked (seen 2026-11-15:
# the world run of a job stayed on the loading overlay for its full five minutes, the screen locked, no error). So
# a run does not start then, and a run that fails says so when the screen is locked.
screen_locked() { /usr/sbin/ioreg -n Root -d1 2>/dev/null | /usr/bin/grep -q '"IOConsoleLocked" = Yes'; }
LOCKED_HINT="the screen of this Mac is locked, and Minecraft does not get past its loading screen then; unlock the Mac and resume the build"

# run_game <tag> <kill timer s> <stop: summary|agent> <runfabric.sh arguments...>
# Starts Minecraft on this Mac (scripts/runfabric.sh: Knot, stock SDL3 window) and ends it: "agent" waits for the
# world agent to stop the game, "summary" stops it once the bake summary is written. Sets GAME_LOG, GAME_JOIN_S.
run_game() {
  local tag=$1 timer=$2 stop=$3; shift 3
  GAME_LOG="$WORK/logs/game-$tag.log"; GAME_JOIN_S=""
  : > "$GAME_LOG"
  local t0 sh tl kids="" java n why="" quiet=() helper=()
  if screen_locked; then fail "$LOCKED_HINT."; fi
  # The window keeps out of the way of whoever works at this Mac (VIVECRAFT_BUILD_SHOW_WINDOWS=1 shows it as an
  # ordinary window instead).
  # 1. SDL 3, the window library of Minecraft 26.3, reads these from the environment: the game does not become a
  #    foreground app (no Dock icon, no menu bar, nothing is taken from the app in front), and its window is put on
  #    screen without being made the key window. The window is small.
  # 2. The window helper, when stage "classpath" could build it, makes that window invisible (fully transparent, no
  #    shadow, clicks pass through) and tells the game that its window is not the one in front, so that the game
  #    does not put the mouse pointer into it. It is a native library with no Java in it (-agentpath).
  # None of this is game code: the classpath, the mods and the Java agents are the same as with the window shown.
  # Compared on 2026-11-15, same world, window shown against window invisible: the bake wrote the same 19,314 class
  # names, the same failure list and the same prune counts; where bytes differed (715 classes) it was the Mixin
  # session id of the run and, in two classes, the counter Mixin appends to merged member names, as between any two
  # bakes.
  if [ "${VIVECRAFT_BUILD_SHOW_WINDOWS:-0}" != 1 ]; then
    quiet=(SDL_MAC_BACKGROUND_APP=1 SDL_WINDOW_ACTIVATE_WHEN_SHOWN=0 SDL_WINDOW_ACTIVATE_WHEN_RAISED=0)
    GAMEARGS="${GAMEARGS:+$GAMEARGS }--width $QUIET_W --height $QUIET_H"
    if [ -f "$QUIET_LIB" ]; then helper=(-agentpath:"$QUIET_LIB"); fi
  fi
  t0=$(/bin/date +%s)
  ( cd "$NI" && exec /usr/bin/env ${quiet[@]+"${quiet[@]}"} /bin/bash scripts/runfabric.sh "$timer" "$@" \
      ${helper[@]+"${helper[@]}"} -Djava.io.tmpdir="$WORK/tmp" -Djna.tmpdir="$WORK/tmp" ) > "$GAME_LOG" 2>&1 < /dev/null &
  sh=$!
  /usr/bin/tail -n +1 -f "$GAME_LOG" &
  tl=$!
  while /bin/kill -0 "$sh" 2>/dev/null; do
    /bin/sleep 1
    n="$(descendants "$sh")"; [ -n "$n" ] && kids="$n"
    if [ -z "$GAME_JOIN_S" ] && /usr/bin/grep -q 'joined the game' "$GAME_LOG"; then GAME_JOIN_S=$(( $(/bin/date +%s) - t0 )); fi
    if /usr/bin/grep -q '\[MKWORLD\] FAILED' "$GAME_LOG"; then why="the world agent reported a failure"; break; fi
    if [ "$stop" = summary ] && [ -f "$I/bake/summary.txt" ]; then /bin/sleep 3; break; fi
    if [ $(( $(/bin/date +%s) - t0 )) -gt $((timer + 30)) ]; then why="the game did not end within $timer s"; break; fi
  done
  if /bin/kill -0 "$sh" 2>/dev/null; then
    # end the game the way BUILDING.md does after the summary: SIGTERM to the JVM
    for java in $kids; do
      if /bin/ps -o command= -p "$java" 2>/dev/null | /usr/bin/grep -q '/bin/java '; then /bin/kill -TERM "$java" 2>/dev/null; fi
    done
    n=0; while /bin/kill -0 "$sh" 2>/dev/null && [ $n -lt 40 ]; do /bin/sleep 0.5; n=$((n+1)); done
  fi
  # runfabric.sh leaves its kill timer (a subshell in `sleep`) behind; it must not outlive the run
  for java in $kids; do /bin/kill -TERM "$java" 2>/dev/null || true; done
  /bin/sleep 1
  for java in $kids; do /bin/kill -KILL "$java" 2>/dev/null || true; done
  wait "$sh" 2>/dev/null || true
  /bin/sleep 1; /bin/kill "$tl" 2>/dev/null || true; /bin/sleep 0.2; /bin/kill -KILL "$tl" 2>/dev/null || true
  wait "$tl" 2>/dev/null || true
  if /usr/bin/grep -q 'MicrophoneThread' "$GAME_LOG"; then echo "!! note: Simple Voice Chat started its microphone thread in this run"; fi
  if [ -n "$why" ] && screen_locked; then fail "$why (game log: $GAME_LOG); $LOCKED_HINT."; fi
  [ -z "$why" ] || fail "$why (game log: $GAME_LOG)."
}

stage_world() {   # BUILDING.md section 6: the world the bake loads, made without clicks
  /bin/rm -rf "$I/fgamedir/saves/world"; /bin/mkdir -p "$I/fgamedir/saves"
  mac_run_settings
  window_note "a minute"
  export GAMEARGS=""
  run_game world 900 agent -javaagent:"$WORK/agents/mkworld-agent.jar=30" -Dvivecraft.openxr.mobile=true
  /usr/bin/grep -q '\[MKWORLD\] DONE' "$GAME_LOG" \
    || fail "the world-creation run ended early: $(/usr/bin/grep -o '\[MKWORLD\].*' "$GAME_LOG" | /usr/bin/tail -1 | /usr/bin/cut -c1-160) (game log: $GAME_LOG)."
  [ -f "$I/fgamedir/saves/world/level.dat" ] || fail "the world-creation run left no saves/world/level.dat."
  # what the game said about itself while the player was in the world (MkWorldAgent's "rendering" lines)
  echo "the game drew $(/usr/bin/sed -n 's/.*\[MKWORLD\] rendering: \([0-9]*\) fps.*/\1/p' "$GAME_LOG" | /usr/bin/sort -n | /usr/bin/sed -n '1p;$p' | /usr/bin/tr '\n' ' ')frames a second (lowest and highest of $(/usr/bin/grep -c '\[MKWORLD\] rendering:' "$GAME_LOG") readings)"
  if [ "${VIVECRAFT_BUILD_SHOW_WINDOWS:-0}" != 1 ] && /usr/bin/grep -q '\[MKWORLD\] rendering:.*mouse grabbed=true' "$GAME_LOG"; then
    echo "!! note: the game held the mouse during this run although its window was meant to stay out of the way"
  fi
  echo "world created: saves/world ($(/usr/bin/du -sh "$I/fgamedir/saves/world" | /usr/bin/cut -f1))"
}
check_world() { [ -f "$I/fgamedir/saves/world/level.dat" ]; }

stage_bake() {   # BUILDING.md section 6: the Knot bake, its check, the prune
  cd "$NI"
  local at ok=0 s
  for at in 120 300; do
    /bin/rm -rf "$I/bake"
    mac_run_settings
    window_note "$((at / 60 + 1)) minutes"; echo "The full pass starts $at s after the JVM."
    export GAMEARGS="--quickPlaySingleplayer world"
    run_game bake $((at + 480)) summary \
      -javaagent:"$NI/bakeagent/bakeagent.jar=$I/bake" -Dbake.fullAt=$at -Dvivecraft.openxr.mobile=true
    [ -f "$I/bake/summary.txt" ] || fail "the bake run ended without writing its summary (game log: $GAME_LOG)."
    # the world must be loaded when the full pass starts (BUILDING.md: "raise it on a slow Mac")
    if [ -n "$GAME_JOIN_S" ] && [ "$GAME_JOIN_S" -le $((at - 20)) ]; then ok=1; echo "the player was in the world $GAME_JOIN_S s after the start, the full pass began at $at s"; break; fi
    echo "!! the world was not loaded in time (player in the world after ${GAME_JOIN_S:-no} s, full pass at $at s)"
  done
  [ $ok = 1 ] || fail "the world had not loaded when the bake pass started, even with a 300 s delay."
  s="$(/bin/cat "$I/bake/summary.txt")"; echo "$s"
  case "$s" in *" null=0 "*) ;; *) fail "the bake summary does not say null=0: $s" ;; esac
  case "$s" in *"other-loader-classes=0") ;; *) fail "the bake found classes defined by other class loaders: $s" ;; esac
  py bake-compare "$I/bake/fullpass-failures.txt" "$SELF_DIR/bake-failures-$MCV.txt" \
    || fail "the bake's list of failed classes differs from the expected list for Minecraft $MCV (tools/avpplay/bake-failures-$MCV.txt); the names are in the log."
  # what this Mac's JVM wrote into the game dir, for the record (the payload gets the committed defaults)
  /bin/rm -rf "$I/mac-run-settings"; /bin/mkdir -p "$I/mac-run-settings"
  /bin/cp -R "$I/fgamedir/config" "$I/fgamedir/options.txt" "$I/mac-run-settings/"
  python3 -I scripts/prune_overlay.py "$I/bake/classes" "$I"/vanilla/lib/*.jar "$I"/fabric/lib/*.jar | /usr/bin/tee "$WORK/tmp/prune.txt"
  local c gone=""
  for c in org/lwjgl/VersionImpl org/lwjgl/system/CheckIntrinsics org/lwjgl/system/StackWalkUtil \
           org/lwjgl/system/Pointer 'org/lwjgl/system/Pointer$Default'; do
    if [ -f "$I/bake/classes/$c.class" ]; then /bin/rm -f "$I/bake/classes/$c.class"; gone="$gone $c"; fi
  done
  echo "LWJGL multi-release classes removed from the overlay:${gone:- none}"
  { /bin/cat "$WORK/tmp/prune.txt"; echo "removed by build_parts.sh:${gone:- none}"; } > "$I/bake/PRUNE-NOTE.txt"
  echo "overlay: $(/usr/bin/find "$I/bake/classes" -type f | /usr/bin/wc -l | /usr/bin/tr -d ' ') classes"
}
check_bake() { [ -f "$I/bake/summary.txt" ] && [ -f "$I/bake/PRUNE-NOTE.txt" ] && [ -d "$I/bake/classes/net" ]; }

stage_launcher() {   # BUILDING.md section 6: baked classpath, launcher, t4, the two gates before the image
  cd "$NI"
  LC_ALL=$CP_LOCALE scripts/mkcp-baked.sh
  LC_ALL=$CP_LOCALE scripts/m3a/build-launcher.sh
  python3 -I scripts/m3a/pin-gl-options.py "$I/fgamedir/options.txt"
  /bin/bash scripts/t4/build-t4.sh
  # The classpath the image is built from and the payload names, entry by entry and in order, must be release
  # 1.0.3's (same pinned mods, same libraries). The two class folders are jars in the payload (bundle_payload.sh).
  /usr/bin/tr ':' '\n' < "$I/t4.cp" | /usr/bin/sed -n "s#^$NI/##p" \
    | /usr/bin/sed -e 's#^\(inst-[0-9.]*/baked/t4\)$#\1.jar#' -e 's#^\(inst-[0-9.]*/baked/launcher\)$#\1.jar#' > "$WORK/tmp/baked.cp"
  if ! /usr/bin/diff "$SELF_DIR/pins/baked-$MCV.cp" "$WORK/tmp/baked.cp"; then
    fail "the classpath differs from release 1.0.3's (tools/avpplay/pins/baked-$MCV.cp); the lines are in the log."
  fi
  echo "classpath: $(/usr/bin/grep -c . "$WORK/tmp/baked.cp") entries, the same and in the same order as release 1.0.3's baked.cp"
  if /usr/bin/grep -l -i mkworld "$I"/*.cp >/dev/null 2>&1; then fail "the world agent is on a classpath."; fi
  if [ -n "$(/usr/bin/find "$I/bake/classes" "$I/fgamedir/mods" -iname '*mkworld*' | /usr/bin/head -1)" ]; then fail "the world agent is in the bake overlay or in mods/."; fi
  # The committed reflection list must be the one this classpath generates (BUILDING.md: "commit the new JSON with
  # the image that used it"); a difference means the classpath is not the one the configs were made for.
  local rc="inst-$MCV/config/t23-extra/reflect-config.json"
  RESCAN=1 python3 -I scripts/t8/gen-reflect-extra.py
  if ! /usr/bin/cmp -s "$NI/$rc" "$SRC/work/native-image/$rc"; then
    /bin/cp "$NI/$rc" "$WORK/tmp/reflect-config.generated.json"; /bin/cp "$SRC/work/native-image/$rc" "$NI/$rc"
    fail "the reflection list generated from this classpath differs from the committed one (generated copy: $WORK/tmp/reflect-config.generated.json)."
  fi
  echo "reflect-config.json generated from this classpath is byte-identical to the committed file"
  python3 -I scripts/m3a/check-subst.py "$I/out/cpindex.json" > "$WORK/tmp/check-subst.txt" || true
  /usr/bin/tail -3 "$WORK/tmp/check-subst.txt"
  [ "$(/usr/bin/tail -1 "$WORK/tmp/check-subst.txt")" = "0 problem(s)" ] || fail "check-subst.py reports substitution targets that do not resolve."
}
check_launcher() { [ -f "$I/t4.cp" ] && [ -f "$I/t4-ni.cp" ] && [ -d "$I/baked/t4" ] && [ -d "$I/baked/launcher" ]; }

stage_image() {   # BUILDING.md section 7: native-image
  cd "$NI"
  /bin/rm -rf "$T8" "$STATE/image-peak-rss" "$STATE/image-real"; /bin/mkdir -p logs
  echo "native-image: heap $NI_HEAP, workers ${NI_THREADS:-default}, on $MEM_GB GB of memory"
  echo "memory before: swap $(/usr/sbin/sysctl -n vm.swapusage 2>/dev/null); $(/usr/bin/memory_pressure 2>/dev/null | /usr/bin/tail -1)"
  echo "other heavy jobs right now: $(/usr/bin/pgrep -fl 'xcodebuild|swift-frontend|native-image' 2>/dev/null | /usr/bin/cut -c1-80 | /usr/bin/tr '\n' ';' || true)"
  NATIVE_IMAGE_HEAP="$NI_HEAP" NATIVE_IMAGE_THREADS="$NI_THREADS" \
    CPFILE="$I/t4-ni.cp" CONFIG_DIRS="$I/config/t23-trim,$I/config/t23-extra" \
    T8OUT="$T8" LOGTAG=avpplay scripts/t8/build-shared.sh || fail "native-image failed (heap $NI_HEAP, workers ${NI_THREADS:-default})."
  /usr/bin/awk '/maximum resident set size/{print $1}' logs/t8-build-avpplay.txt | /usr/bin/tail -1 > "$STATE/image-peak-rss"
  /usr/bin/awk '$2=="real"{print $1}' logs/t8-build-avpplay.txt | /usr/bin/tail -1 > "$STATE/image-real"
  echo "native-image: $(/bin/cat "$STATE/image-real") s, peak resident memory $(/usr/bin/awk '{printf "%.2f GB", $1/1e9}' "$STATE/image-peak-rss")"
  echo "memory after: swap $(/usr/sbin/sysctl -n vm.swapusage 2>/dev/null)"
}
check_image() { [ -f "$T8/ni/libminecraft.dylib" ] && /bin/ls "$T8"/tmp/SVM-*/libminecraft.o >/dev/null 2>&1; }

stage_relink() {   # BUILDING.md section 7: the device dylib
  cd "$NI"
  /bin/rm -rf "$T8/xros"
  T8OUT="$T8" scripts/t8/relink-xros.sh xros
  local v="$T8/xros/verify.txt"
  /usr/bin/grep -q 'platform VISIONOS$' "$v" || fail "the relinked libminecraft.dylib is not a visionOS device library."
  /usr/bin/grep -q '^non-system imports: none' "$v" || fail "the relinked libminecraft.dylib imports a non-system library."
  if /usr/bin/grep -q 'MISSING' "$v"; then fail "the relinked libminecraft.dylib lacks an entry point (see verify.txt in the log)."; fi
}
check_relink() { [ -f "$T8/xros/libminecraft.dylib" ] && [ -f "$T8/xros/verify.txt" ]; }

stage_payload() {   # the parts as the release app carries them (BUILDING.md section 8 without the host app)
  local env_app libs n f id
  /bin/rm -rf "$PARTS"; /bin/mkdir -p "$APP/Frameworks"
  # Settings: the committed defaults instead of what the two runs on this Mac wrote, then AVP Play's overrides.
  py defaults "$I/fgamedir" "$SELF_DIR/defaults/fgamedir" "$SELF_DIR/defaults/options-overrides.txt"
  cd "$TREE/visionos"
  env_app="env KL_BUNDLE_PAYLOAD=1 KLEPTON_TARGET=vivecraft PROJECT_DIR=$TREE/visionos TARGET_BUILD_DIR=$PARTS/Payload UNLOCALIZED_RESOURCES_FOLDER_PATH=KleptonVivecraft.app"
  /bin/rm -rf build/native-stage
  if ! $env_app ./bundle_payload.sh; then
    /bin/cat build/bundle-payload-stage.log 2>/dev/null || true
    fail "visionos/bundle_payload.sh failed (its personal-data and install checks are in the log)."
  fi
  /bin/cat build/bundle-payload-stage.log
  $env_app ./copy_licenses.sh
  # The 18 libraries, device slice, through the project's own list (targets.py) and copy rules (mknative.sh).
  XROS_PLATFORMS=xros KLEPTON_TARGET=vivecraft ./mknative.sh
  eval "$(KLEPTON_TARGET=vivecraft python3 targets.py vivecraft | /usr/bin/grep '^KLT_LIBS=')"
  n=0
  for f in $KLT_LIBS; do
    /bin/cp "build/native/vivecraft/xros/$f.dylib" "$APP/Frameworks/$f.dylib"; n=$((n+1))
  done
  [ "$n" = 18 ] && [ "$(/bin/ls "$APP/Frameworks" | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = 18 ] \
    || fail "the target lists $n libraries, not the 18 the release carries."
  # run.sh's last step before packaging: the home prefix inside Mach-O copies (a no-op unless it is 13 bytes long)
  python3 scrub_paths.py "$APP"
  for f in "$APP"/Frameworks/*.dylib; do
    id="$(/usr/bin/otool -D "$f" | /usr/bin/tail -1)"
    [ "$(/usr/bin/lipo -archs "$f")" = arm64 ] || fail "$(basename "$f") is not an arm64-only library."
    [ "$(platform_of "$f")" = VISIONOS ] || fail "$(basename "$f") is not built for visionOS devices."
    [ "$id" = "@rpath/$(basename "$f")" ] || fail "$(basename "$f") has the install name $id."
    # the parts are unsigned (the app that embeds them signs); a linker-made ad-hoc signature would go here
    if /usr/bin/otool -l "$f" | /usr/bin/grep -q LC_CODE_SIGNATURE; then /usr/bin/codesign --remove-signature "$f"; fi
    /bin/chmod 755 "$f"
  done
  for f in launch.txt baked.cp payload-version tree; do
    [ -s "$APP/klepton-payload/$f" ] || fail "the payload has no $f."
  done
  [ -d "$APP/klepton-payload/root/inst-$MCV/fgamedir/config" ] && [ -f "$APP/Licenses/NOTICES.txt" ] || fail "the payload is incomplete."
  /usr/bin/grep -q '^renderDistance:5$' "$APP/klepton-payload/root/inst-$MCV/fgamedir/options.txt" || fail "the payload's options.txt does not carry the overrides."
  py scan "$APP" "$HOME/" "$WORK/" || fail "a payload or licence file names a path of this Mac (list in the log)."
  echo "parts: 18 libraries, payload $(/bin/cat "$APP/klepton-payload/payload-version" | /usr/bin/cut -c1-12), $(/usr/bin/du -sh "$APP" | /usr/bin/cut -f1)"
}
check_payload() {
  [ -s "$APP/klepton-payload/payload-version" ] && [ -f "$APP/Licenses/NOTICES.txt" ] \
    && [ "$(/bin/ls "$APP/Frameworks" 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')" = 18 ]
}

stage_zip() {
  /bin/mkdir -p "$(dirname "$OUT")" || fail "the folder of AVPPLAY_OUT cannot be created."
  /bin/rm -f "$STATE/parts.txt"
  local r; r="$(py zip "$PARTS" "$OUT")" || fail "the zip could not be written to $OUT."
  set -- $r
  printf '%s %s\n' "$1" "$OUT" > "$STATE/parts.txt"
  echo "zip: $2 bytes, $3 entries, sha256 $1"
}
check_zip() {
  [ -f "$OUT" ] && [ -f "$STATE/parts.txt" ] || return 1
  local sha rest; read -r sha rest < "$STATE/parts.txt"
  [ "$rest" = "$OUT" ] && py verify "$OUT" "$sha"
}

# ---------------------------------------------------------------------------------------------------------------
# Stage bookkeeping
# A stage is done when its marker carries the stamp of its inputs and its check passes. Stamps (parts_helper.py):
# the tools and GraalVM depend on the pin table; payload and zip on the whole checkout minus documentation; every
# other stage on the checkout minus documentation, the option defaults and the licence folder. So a new commit that
# only changes options or licences repeats the last two stages, any other change rebuilds from the headers on
# (downloads are kept and checked, not fetched again).
read -r STAMP_ALL STAMP_BUILD STAMP_PAYLOAD <<EOF
$(py manifest "$SRC" "$STATE/manifest.new.json" 2>>"$LOG")
EOF
[ -n "${STAMP_PAYLOAD:-}" ] || finish_fail 2 "the checkout $SRC could not be read."
if [ -n "${AVPPLAY_DEV_STAMP:-}" ]; then STAMP_BUILD="dev-$AVPPLAY_DEV_STAMP"; STAMP_PAYLOAD="dev-$AVPPLAY_DEV_STAMP"; fi   # development only
STAMP_PINS="$(printf '%s' "$PINS" | /usr/bin/shasum -a 256 | /usr/bin/cut -c1-24)"

stamp_for() {
  case $1 in
    tree) echo "$STAMP_ALL" ;;
    tools|graalvm) echo "pins-$STAMP_PINS" ;;
    payload) echo "$STAMP_PAYLOAD" ;;
    zip) echo "$STAMP_PAYLOAD $OUT" ;;
    *) echo "$STAMP_BUILD" ;;
  esac
}
stage_done() {
  local m="$STATE/done/$1"
  [ -f "$m" ] && [ "$(/bin/cat "$m")" = "$(stamp_for "$1")" ] && ( "check_$1" ) >/dev/null 2>&1
}
mark_done() { printf '%s\n' "$(stamp_for "$1")" > "$STATE/done/$1.tmp" && /bin/mv -f "$STATE/done/$1.tmp" "$STATE/done/$1"; }
stall_limit() {
  if [ -n "${AVPPLAY_STALL_MIN:-}" ]; then echo $((AVPPLAY_STALL_MIN * 60)); return; fi
  case $1 in image) echo 2700 ;; *) echo 1200 ;; esac
}
# Some of the project's scripts download without a word (git clone -q, curl -s). On a slow line that silence can
# last longer than the limit, so growth of the folders a stage downloads into counts as a sign of life too.
progress_dirs() {
  case $1 in
    headers|openal|lwjgl|ltw) echo "$TREE/work/natives/downloads $TREE/work/native-image/dl $TREE/work/src" ;;
    voicechat) echo "$TREE/work/natives/downloads/svc $TREE/work/natives/build" ;;
    vivecraft) echo "$TREE/work/vivecraft-openxr-26.3" ;;
    minecraft) echo "$I/files $I/assets" ;;
  esac
}
progress_size() {   # progress_size <dir>... -> kilobytes in all of them
  [ $# -gt 0 ] || { echo 0; return; }
  /usr/bin/du -sk "$@" 2>/dev/null | /usr/bin/awk '{s += $1} END {print s + 0}'
}

# ---------------------------------------------------------------------------------------------------------------
# Reference durations, for the PLAN line: how many seconds each stage took on the reference Mac (Mac mini M4,
# 10 cores, 16 GB, macOS 27.2, Xcode 27.1), medians of the full runs of 2026-11-15: the proof run from an empty work
# folder, the verification run of bc355cd, and three AVP Play jobs (one from an empty folder, two that rebuilt with
# the downloads kept). A stage that downloads what it builds from is much shorter once that is in the work folder;
# both values are measured unless a comment says otherwise. AVP Play scales them by how fast this Mac turns out to
# be; they are no limits.
ref_of() {   # ref_of <stage> -> <seconds>, or <seconds>:n for a stage whose time is mostly the internet line's
  local n
  case $1 in
    tree) echo 2 ;;
    tools) if [ -f "$WORK/dl/cmake-$(pin cmake 2)-macos-universal.tar.gz" ] && [ -f "$WORK/dl/ninja-$(pin ninja 2)-mac.zip" ]
           then echo 3; else echo 14:n; fi ;;                      # 16, 12 s downloaded; 3 s unpacked only
    graalvm) if [ -f "$WORK/dl/graalvm-jdk-$(pin graalvm 2)-macos-aarch64.tar.gz" ]; then echo 3; else echo 35:n; fi ;;
    headers) echo 2 ;;
    vivecraft)   # 165, 289, 507 s from an empty Gradle home (Gradle and Fabric Loom download Minecraft's sources)
      if [ ! -d "$TREE/work/vivecraft-openxr-26.3/gradle-home/wrapper/dists" ]; then echo 290:n
      elif [ "$(/usr/bin/git -C "$TREE/work/vivecraft-openxr-26.3/VivecraftMod" rev-parse -q --verify 'HEAD^{tree}' 2>/dev/null)" = "$VIVECRAFT_TREE" ]
      then echo 8                                                   # 7, 9, 7 s: Gradle finds everything up to date
      else echo 30; fi ;;   # not measured: a cached Loom set-up plus the three compile tasks of the runs above (12-19 s)
    minecraft)   # 183, 882 s with nothing there; 8, 9, 9 s with every file there (only checked)
      n=$(/usr/bin/find "$I/assets/objects" -type f 2>/dev/null | /usr/bin/wc -l | /usr/bin/tr -d ' ')
      [ "${n:-0}" -gt 5149 ] && n=5149
      if [ -f "$I/files/versions/$MCV/client.jar" ] && [ "${n:-0}" = 5149 ]; then echo 9
      else echo "$(( 9 + 411 * (5149 - ${n:-0}) / 5149 )):n"; fi ;;
    openal) echo 58 ;;
    lwjgl) if lwjgl_cold; then echo 263; else echo 158; fi ;;     # 263 s with the sources downloaded (one run)
    klsdl) echo 12 ;;
    ltw) echo 28 ;;
    voicechat) if [ -d "$TREE/work/natives/downloads/svc/opus4j/.git" ]; then echo 37; else echo 83; fi ;;   # 83: one run
    shims) echo 2 ;;
    classpath) echo 3 ;;
    world) echo 62 ;;
    bake) echo 141 ;;
    launcher) echo 17 ;;
    image) echo 975 ;;          # 824, 925, 1024, 1416 s (the last one while the Mac was busy with other work)
    relink) echo 6 ;;
    payload) echo 31 ;;
    zip) echo 8 ;;
    *) echo 60 ;;
  esac
}
lwjgl_cold() { ! /bin/ls "$TREE"/work/natives/downloads/freetype-*.tar.gz >/dev/null 2>&1; }

plan_line() {   # the PLAN line: every stage with its reference seconds; d = will be skipped, n = see ref_of
  local i=0 s r f runs=0 line=PLAN
  for s in $STAGES; do
    i=$((i+1)); r="$(ref_of "$s")"; f=""
    # the same rule as run_stage: a stage after the third that has to run makes every later one run too
    if [ $runs = 0 ] && stage_done "$s"; then f=d
    elif [ "$i" -gt 3 ]; then runs=1; fi
    case $r in *:n) r=${r%:n}; f="${f}n" ;; esac
    line="$line $s:$r${f:+:$f}"
  done
  say "$line"
}

progress_args() {   # what the log pipe needs to count a stage's progress (parts_helper.py, class Progress)
  case $1 in
    tools) echo "files=$WORK/dl/cmake-$(pin cmake 2)-macos-universal.tar.gz:$(pin cmake 3),$WORK/dl/ninja-$(pin ninja 2)-mac.zip:$(pin ninja 3)" ;;
    graalvm) echo "files=$WORK/dl/graalvm-jdk-$(pin graalvm 2)-macos-aarch64.tar.gz:$(pin graalvm 3)" ;;
    lwjgl) if lwjgl_cold; then echo cold=1; fi ;;
  esac
}

PREFLIGHT=0
preflight() {   # before the first stage that has work to do
  [ $PREFLIGHT = 0 ] || return 0
  PREFLIGHT=1
  local net=0 out
  [ "$1" -le $LAST_NETWORK_STAGE ] && net=1
  if ! out="$(prereq_problems $net)"; then
    printf '%s\n' "$out" | while IFS= read -r l; do say "!! $l"; done
    finish_fail 1 "$(printf '%s\n' "$out" | /usr/bin/head -1)"
  fi
}

run_stage() {
  local i=$1 name=$2 t0 rc limit age stalled=0 why later j ticks=0 size=0 now_size dirs
  CUR_I=$i; CUR_NAME=$name
  if stage_done "$name"; then
    say "STAGE $i/$NSTAGES $name (already done)"
    T_NAMES+=("$name"); T_SECS+=(0); T_STAT+=("already done")
    return 0
  fi
  preflight "$i"
  say "STAGE $i/$NSTAGES $name"
  /bin/rm -f "$STATE/done/$name" "$STATE/why"
  if [ "$i" -gt 3 ]; then   # a stage that runs again makes every later result stale
    j=0; for later in $STAGES; do j=$((j+1)); [ $j -gt "$i" ] && /bin/rm -f "$STATE/done/$later"; done
  fi
  t0=$(/bin/date +%s)
  /usr/bin/touch "$HB"
  /bin/rm -f "$FIFO"; /usr/bin/mkfifo "$FIFO"
  /usr/bin/python3 -I -B "$HELPER" logpipe "$LOG" "$HB" "$name" $(progress_args "$name") < "$FIFO" &
  LP_PID=$!
  ( trap - TERM INT HUP; set -e; "stage_$name" ) > "$FIFO" 2>&1 < /dev/null &
  ST_PID=$!
  limit=$(stall_limit "$name"); dirs="$(progress_dirs "$name")"
  while /bin/kill -0 "$ST_PID" 2>/dev/null; do
    /bin/sleep 1 &
    wait $! 2>/dev/null
    ticks=$((ticks+1))
    if [ -n "$dirs" ] && [ $((ticks % 30)) = 0 ]; then
      now_size=$(progress_size $dirs)
      if [ "$now_size" != "$size" ]; then size=$now_size; /usr/bin/touch "$HB"; fi
    fi
    age=$(( $(/bin/date +%s) - $(/usr/bin/stat -f %m "$HB" 2>/dev/null || echo 0) ))
    if [ "$age" -ge "$limit" ]; then stalled=1; break; fi
  done
  if [ $stalled = 1 ]; then stop_started; fi
  wait "$ST_PID" 2>/dev/null; rc=$?
  ST_PID=""
  stop_logpipe
  stop_started          # nothing a stage started may outlive it
  /bin/rm -f "$FIFO"
  T_NAMES+=("$name"); T_SECS+=($(( $(/bin/date +%s) - t0 )))
  if [ $stalled = 1 ]; then
    T_STAT+=("hung"); finish_fail 1 "no output and no download progress for $((limit / 60)) min, so the stage was stopped as hung."
  fi
  if [ $rc != 0 ]; then
    T_STAT+=("failed")
    why="$(/bin/cat "$STATE/why" 2>/dev/null || true)"
    if [ -z "$why" ] && [ $rc -gt 128 ]; then why="the stage was ended by signal $((rc - 128)) from outside; the next run continues at this stage."; fi
    [ -n "$why" ] || why="a command of this stage failed (exit status $rc); the last log lines say which."
    finish_fail 1 "$why"
  fi
  if ! ( "check_$name" ) >/dev/null 2>&1; then
    T_STAT+=("failed"); finish_fail 1 "the stage ended without an error, but its result is not there."
  fi
  mark_done "$name"
  T_STAT+=("done")
  say "  $name: $(( $(/bin/date +%s) - t0 )) s"
}

# ---------------------------------------------------------------------------------------------------------------
say "build_parts.sh: Minecraft $MCV + Vivecraft parts for Apple Vision Pro"
say "checkout $SRC (stamp $STAMP_ALL), work folder $WORK, log $LOG"
say "$MEM_GB GB memory, $(/usr/sbin/sysctl -n hw.ncpu) cores, $(/usr/bin/sw_vers -productVersion 2>/dev/null | /usr/bin/tr -d '\n') / $(/usr/bin/xcodebuild -version 2>/dev/null | /usr/bin/tr '\n' ' ')"
plan_line
T_START=$(/bin/date +%s)
n=0
for s in $STAGES; do n=$((n+1)); run_stage $n "$s"; done

CUR_I=$NSTAGES; CUR_NAME=zip
read -r SHA REST < "$STATE/parts.txt" || finish_fail 1 "the zip's hash was not recorded."
say "stage times of this run:"
k=0
while [ $k -lt ${#T_NAMES[@]} ]; do
  say "$(printf '  %-10s %5s s  %s' "${T_NAMES[$k]}" "${T_SECS[$k]}" "${T_STAT[$k]}")"
  k=$((k+1))
done
if [ -s "$STATE/image-peak-rss" ]; then
  say "native-image (when it was built): $(/bin/cat "$STATE/image-real" 2>/dev/null) s, peak resident memory $(/usr/bin/awk '{printf "%.2f GB", $1/1e9}' "$STATE/image-peak-rss")"
fi
say "total $(( $(/bin/date +%s) - T_START )) s"
/bin/rm -rf "$STATE/lock"
say "PARTS $OUT $SHA"
exit 0
