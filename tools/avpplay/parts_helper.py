#!/usr/bin/python3
"""Helper for tools/avpplay/build_parts.sh. Run as: /usr/bin/python3 -I -B parts_helper.py <command> ...

Only the Python that macOS and Xcode bring (3.9), standard library only.

  manifest <checkout> <out.json>            hash every file of the checkout; print "<all> <build> <payload>" stamps
  sync <checkout> <tree> <new.json> <old.json>
                                            make <tree> hold the checkout's files (changed ones copied, vanished
                                            ones removed); build products in <tree> are left alone
  logpipe <logfile> <heartbeat> [<stage> [files=<path>:<bytes>,...] [cold=1]]
                                            stdin -> stdout and, time-stamped, -> logfile; touches heartbeat; with a
                                            stage name it adds that stage's PROGRESS lines (BUILDING.md)
  sha256 <file>                             print the file's sha256
  verify <file> <sha256> [<bytes>]          exit 0 when the file has that hash (and size)
  bake-compare <failures.txt> <expected.txt>
                                            compare a Knot bake's fullpass-failures.txt with the expected names
  defaults <fgamedir> <defaults-fgamedir> <overrides.txt>
                                            replace config/ and options.txt of a game dir with the committed defaults
  scan <app-dir> <needle>...                fail when a file outside Frameworks/ contains one of the strings
  zip <dir> <out.zip>                       write <dir> (its Payload/ folder) as a reproducible zip; print its sha256
"""
import hashlib
import json
import os
import select
import shutil
import signal
import stat
import subprocess
import sys
import time
import zipfile

# Files that only matter to the last two stages (payload, zip). Everything else that is not documentation is a
# build input: a change there rebuilds from the headers stage on.
PAYLOAD_ONLY = (
    "tools/avpplay/defaults/fgamedir/options.txt",
    "tools/avpplay/defaults/options-overrides.txt",
    "visionos/Licenses/",
)
DOCS = ("docs/", ".github/", "LICENSES/", "LICENSE", ".gitignore")
SKIP_NAMES = {".DS_Store", "__pycache__", ".git"}


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def checkout_files(root):
    """Relative paths of the checkout's files. With git metadata: tracked plus untracked-but-not-ignored files, so a
    checkout that was also used for a manual build does not drag its build products along. Without (an exported
    tree): every file."""
    if os.path.exists(os.path.join(root, ".git")):
        env = dict(os.environ, GIT_OPTIONAL_LOCKS="0")
        try:
            out = subprocess.run(
                ["/usr/bin/git", "-C", root, "ls-files", "-z", "--cached", "--others", "--exclude-standard"],
                check=True, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=env).stdout
            names = [n for n in out.decode("utf-8", "surrogateescape").split("\0") if n]
            return sorted(n for n in set(names)
                          if os.path.lexists(os.path.join(root, n)) and os.path.basename(n) not in SKIP_NAMES)
        except (OSError, subprocess.CalledProcessError):
            pass
    names = []
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_NAMES)
        for f in filenames:
            if f in SKIP_NAMES or f.endswith(".pyc"):
                continue
            names.append(os.path.relpath(os.path.join(dirpath, f), root))
    return sorted(names)


def kind_of(rel):
    if any(rel == p or (p.endswith("/") and rel.startswith(p)) for p in PAYLOAD_ONLY):
        return "payload"
    if any(rel == p or (p.endswith("/") and rel.startswith(p)) for p in DOCS):
        return "docs"
    if "/" not in rel and rel.endswith(".md"):
        return "docs"
    return "build"


def cmd_manifest(root, out):
    files = {}
    for rel in checkout_files(root):
        p = os.path.join(root, rel)
        st = os.lstat(p)
        if stat.S_ISLNK(st.st_mode):
            files[rel] = {"link": os.readlink(p)}
        elif stat.S_ISREG(st.st_mode):
            files[rel] = {"sha": sha256_file(p), "x": bool(st.st_mode & 0o111)}
    def stamp(kinds):
        h = hashlib.sha256()
        for rel in sorted(files):
            if kind_of(rel) in kinds:
                e = files[rel]
                h.update(("%s %s %s\n" % (e.get("sha") or "link:" + e["link"], int(e.get("x", False)), rel))
                         .encode("utf-8", "surrogateescape"))
        return h.hexdigest()[:24]
    stamps = {"all": stamp(("build", "payload", "docs")), "build": stamp(("build",)),
              "payload": stamp(("build", "payload"))}
    tmp = out + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump({"files": files, "stamps": stamps}, f)
    os.replace(tmp, out)
    print(stamps["all"], stamps["build"], stamps["payload"])


def cmd_sync(root, tree, new_json, old_json):
    new = json.load(open(new_json, encoding="utf-8"))["files"]
    old = {}
    if os.path.isfile(old_json):
        try:
            old = json.load(open(old_json, encoding="utf-8"))["files"]
        except (ValueError, KeyError):
            old = {}
    copied = removed = 0
    for rel, e in new.items():
        src = os.path.join(root, rel)
        dst = os.path.join(tree, rel)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if "link" in e:
            if os.path.islink(dst) and os.readlink(dst) == e["link"]:
                continue
            if os.path.lexists(dst):
                os.remove(dst)
            os.symlink(e["link"], dst)
            copied += 1
            continue
        same = os.path.isfile(dst) and not os.path.islink(dst) and sha256_file(dst) == e["sha"]
        if not same:
            if os.path.lexists(dst):
                if os.path.isdir(dst) and not os.path.islink(dst):
                    shutil.rmtree(dst)
                else:
                    os.remove(dst)
            shutil.copyfile(src, dst)
            copied += 1
        mode = 0o755 if e.get("x") else 0o644
        if stat.S_IMODE(os.stat(dst).st_mode) != mode:
            os.chmod(dst, mode)
    for rel in old:
        if rel not in new:
            dst = os.path.join(tree, rel)
            if os.path.lexists(dst) and not os.path.isdir(dst):
                os.remove(dst)
                removed += 1
    print("working copy: %d files, %d copied, %d removed -> %s" % (len(new), copied, removed, tree))


PROTOCOL = ("STAGE ", "PARTS ", "FAILED ", "LOG ", "PLAN ", "PROGRESS ")

# How far a stage is, for "PROGRESS <done> <total> <unit>[ <w1>,<w2>,...]" (BUILDING.md, "Progress lines").
#
# Parts: a stage whose tools print a line when one of its parts ENDS. The weights are the reference seconds of the
# parts, medians of the full runs on the reference Mac (Mac mini M4, 16 GB, 2026-11-15: the proof run, the
# verification run of bc355cd and the AVP Play jobs that built from an empty or a kept work folder):
#   vivecraft  3 runs from an empty Gradle home; parts end at "Welcome to Gradle", "> Configure project :common",
#              "> Configure project :fabric", the first "> Task ", "BUILD SUCCESSFUL" and the pinned-jar check.
#   lwjgl      5 runs; parts end at the LWJGL checkout ("LWJGL 3.4.3 at"), the macOS libraries ("== macosx: stock"),
#              the visionOS LWJGL libraries ("BUILT-lwjgl-xros") and shaderc/SPIRV-Cross ("== xros: shaderc").
#              The first part is 76 s when the sources and jars are downloaded, 3 s when they are there.
#   image      4 runs; native-image prints "[k/8] <phase>" when phase k ends.
PARTS = {
    "vivecraft": ([r"^Welcome to Gradle", r"^> Configure project :common", r"^> Configure project :fabric",
                   r"^> Task ", r"^BUILD SUCCESSFUL", r"^Vivecraft jar sha256 .*\(as pinned\)"],
                  [18, 32, 79, 74, 12, 3]),
    "lwjgl": ([r"^LWJGL 3\.4\.3 at ", r"^== macosx: stock", r"^BUILT-lwjgl-xros", r"^== xros: shaderc"],
              [3, 15, 19, 120]),
    "image": ([r"^\[1/8\] ", r"^\[2/8\] ", r"^\[3/8\] ", r"^\[4/8\] ", r"^\[5/8\] ", r"^\[6/8\] ", r"^\[7/8\] ",
               r"^\[8/8\] "],
              [11, 568, 50, 28, 38, 170, 40, 70]),
}
# Minecraft: fetch-inst.py prints "<group> <done>/<total>" every 25 files and one "mod ..." line per mod. The totals
# here are only the start (26.3: 51 + 7 + 22 libraries, 5,149 asset objects in index 34, 13 pinned mods); each
# group's own line replaces them.
MINECRAFT_GROUPS = (("vanilla", 51), ("fabric", 7), ("lwjgl", 22), ("assets", 5149), ("mods", 13))
# The bake: the full pass starts a fixed time after the JVM, and the summary is there about 22 s later (4 runs:
# 140-155 s for a 120 s delay).
BAKE_AFTER_PASS = 22


class Progress:
    """Watches one stage's lines (and, for downloads, the size of the files being written) and prints PROGRESS
    lines: at most one a second, the last state always."""

    def __init__(self, stage, args, write, clock=time.time):
        import re
        self.re = re
        self.stage = stage
        self.write = write
        self.clock = clock
        self.start = clock()
        self.files = []          # (path, bytes) of downloads whose size is the progress
        self.cold = False
        for a in args:
            if a.startswith("files="):
                for item in a[6:].split(","):
                    path, _, size = item.rpartition(":")
                    if path and size.isdigit():
                        self.files.append((path, int(size)))
            elif a == "cold=1":
                self.cold = True
        self.parts = None
        if stage in PARTS:
            marks, weights = PARTS[stage]
            weights = list(weights)
            if stage == "lwjgl" and self.cold:
                weights[0] = 76
            self.parts = ([re.compile(m) for m in marks], weights)
        self.groups = dict((g, [0, n]) for g, n in MINECRAFT_GROUPS) if stage == "minecraft" else None
        self.state = None        # (done, total, unit, extra)
        self.sent = None
        self.sent_at = 0.0
        self.polled_at = 0.0
        self.parts_done = 0
        self.libs = 0
        # A stage that will be counted says so as it begins, so that its bar is there from the start.
        if self.parts is not None:
            self.set(0, len(self.parts[1]), "parts", ",".join(str(w) for w in self.parts[1]), now=True)
        elif self.groups is not None:
            self.set(0, sum(g[1] for g in self.groups.values()), "files", now=True)
        elif stage == "voicechat":
            self.set(0, 4, "libraries", now=True)

    def set(self, done, total, unit, extra="", now=False):
        done = max(0, min(int(done), int(total)))
        self.state = (done, int(total), unit, extra)
        self.flush(force=now or done == total)

    def flush(self, force=False):
        if self.state is None or self.state == self.sent:
            return
        t = self.clock()
        if not force and t - self.sent_at < 1.0:
            return
        done, total, unit, extra = self.state
        self.write("PROGRESS %d %d %s%s" % (done, total, unit, (" " + extra) if extra else ""))
        self.sent, self.sent_at = self.state, t

    def line(self, text):
        s = text.strip()
        if self.parts is not None:
            marks, weights = self.parts
            for k in range(len(marks) - 1, self.parts_done - 1, -1):
                if marks[k].search(s):
                    self.parts_done = k + 1
                    self.set(k + 1, len(weights), "parts", ",".join(str(w) for w in weights), now=True)
                    break
        elif self.groups is not None:
            m = self.re.match(r"^(vanilla|fabric|lwjgl|assets) (\d+)/(\d+)$", s)
            if m:
                self.groups[m.group(1)] = [int(m.group(2)), int(m.group(3))]
            elif s.startswith("mod ") and ".jar " in s:
                g = self.groups["mods"]
                g[0] += 1
                g[1] = max(g[1], g[0])
            elif s.startswith("DONE "):
                for g in self.groups.values():
                    g[0] = g[1]
            else:
                return
            done = sum(g[0] for g in self.groups.values())
            total = sum(g[1] for g in self.groups.values())
            self.set(done, total, "files")
        elif self.stage == "voicechat":
            if self.re.match(r"^OK xros \w+ -> ", s):
                self.libs += 1
                self.set(self.libs, max(4, self.libs), "libraries", now=True)
        elif self.stage == "bake":
            m = self.re.match(r"^The full pass starts (\d+) s after the JVM", s)
            if m:
                behind = self.clock() - self.start
                self.set(behind, behind + int(m.group(1)) + BAKE_AFTER_PASS, "seconds", now=True)
        elif self.stage == "zip":
            m = self.re.match(r"^zip (\d+)/(\d+) bytes$", s)
            if m:
                self.set(int(m.group(1)), int(m.group(2)), "bytes")

    def tick(self):
        if self.files:
            t = self.clock()
            if t - self.polled_at >= 1.0:
                self.polled_at = t
                have = 0
                for path, size in self.files:
                    n = 0
                    for p in (path, path + ".part"):
                        try:
                            n = max(n, os.path.getsize(p))
                        except OSError:
                            pass
                    have += min(n, size)
                total = sum(size for _, size in self.files)
                if have > 0 or self.state is None:
                    self.set(have, total, "bytes")
        self.flush()


def cmd_logpipe(logfile, heartbeat, stage=None, *args):
    """Copy stdin to stdout and to the log. A line that looks like one of the protocol lines the caller prints
    itself (STAGE, PARTS, FAILED, LOG, PLAN, PROGRESS) gets a leading blank so a reader of stdout cannot mistake it.
    With a stage name, the stage's PROGRESS lines are added (class Progress)."""
    stop = {"at": None}
    def on_term(signum, frame):
        if stop["at"] is None:
            stop["at"] = time.time() + 1.0
    signal.signal(signal.SIGTERM, on_term)
    signal.signal(signal.SIGINT, on_term)
    signal.signal(signal.SIGHUP, on_term)
    signal.signal(signal.SIGPIPE, signal.SIG_IGN)
    log = open(logfile, "ab", buffering=0)
    out_ok = [True]
    last_beat = [0.0]
    buf = b""

    def beat():
        now = time.time()
        if now - last_beat[0] >= 1.0:
            last_beat[0] = now
            try:
                os.utime(heartbeat, None)
            except OSError:
                pass

    def put(text):
        line = text.encode("utf-8", "replace") + b"\n"
        try:
            log.write(time.strftime("%H:%M:%S ").encode() + line)
        except OSError:
            pass
        if out_ok[0]:
            try:
                sys.stdout.buffer.write(line)
                sys.stdout.buffer.flush()
            except (OSError, ValueError):
                out_ok[0] = False

    progress = Progress(stage, args, put) if stage else None

    def emit(raw):
        if b"\r" in raw:
            raw = raw.rstrip(b"\r").split(b"\r")[-1]
        text = raw.decode("utf-8", "replace")
        if text.startswith(PROTOCOL):
            text = " " + text
        put(text)
        if progress is not None:
            progress.line(text)

    while True:
        if stop["at"] is not None and time.time() >= stop["at"]:
            break
        if progress is not None:
            progress.tick()
        try:
            ready, _, _ = select.select([0], [], [], 0.25)
        except (InterruptedError, OSError):
            continue
        if not ready:
            continue
        try:
            chunk = os.read(0, 65536)
        except InterruptedError:
            continue
        except OSError:
            break
        if not chunk:
            break
        beat()
        buf += chunk
        while True:
            i = buf.find(b"\n")
            if i < 0:
                break
            emit(buf[:i])
            buf = buf[i + 1:]
        if len(buf) > 65536:
            emit(buf)
            buf = b""
    if buf:
        emit(buf)
    if progress is not None:
        progress.flush(force=True)


def cmd_verify(path, want, size=None):
    if not os.path.isfile(path):
        sys.exit(1)
    if size is not None and os.path.getsize(path) != int(size):
        sys.exit(1)
    sys.exit(0 if sha256_file(path) == want.lower() else 1)


def cmd_bake_compare(failures, expected):
    want = [l.strip() for l in open(expected, encoding="utf-8") if l.strip() and not l.startswith("#")]
    got, gen = [], []
    for line in open(failures, encoding="utf-8", errors="replace"):
        line = line.strip()
        if not line:
            continue
        if line.startswith("GEN-"):
            gen.append(line)
        else:
            got.append(line.split(" :: ", 1)[0].strip())
    only_got = sorted(set(got) - set(want))
    only_want = sorted(set(want) - set(got))
    dup = len(got) - len(set(got))
    listing = "\n".join(sorted(set(got))) + "\n"
    print("bake failure list: %d lines, %d distinct names, %d generated-class lines; expected %d names; "
          "sha256 of the sorted names %s"
          % (len(got), len(set(got)), len(gen), len(want), hashlib.sha256(listing.encode()).hexdigest()))
    if not only_got and not only_want and not gen and not dup:
        print("bake failure list: identical to the expected list")
        return
    for name in only_got[:30]:
        print("  only in this bake: " + name)
    for name in only_want[:30]:
        print("  only in the expected list: " + name)
    for line in gen[:30]:
        print("  generated class not recovered: " + line[:200])
    print("bake failure list DIFFERS: %d unexpected, %d missing, %d generated-class lines, %d duplicates"
          % (len(only_got), len(only_want), len(gen), dup))
    sys.exit(3)


def cmd_defaults(fgamedir, defaults, overrides):
    cfg_src = os.path.join(defaults, "config")
    opt_src = os.path.join(defaults, "options.txt")
    if not os.path.isdir(cfg_src) or not os.path.isfile(opt_src):
        sys.exit("defaults: %s has no config/ or options.txt" % defaults)
    cfg_dst = os.path.join(fgamedir, "config")
    if os.path.lexists(cfg_dst):
        shutil.rmtree(cfg_dst)
    shutil.copytree(cfg_src, cfg_dst)
    lines = open(opt_src, encoding="utf-8").read().splitlines()
    changed = []
    for raw in open(overrides, encoding="utf-8").read().splitlines():
        raw = raw.strip()
        if not raw or raw.startswith("#"):
            continue
        if ":" not in raw:
            sys.exit("defaults: bad override line %r" % raw)
        key = raw.split(":", 1)[0]
        hit = [i for i, l in enumerate(lines) if l.split(":", 1)[0] == key]
        if hit:
            if lines[hit[0]] != raw:
                changed.append("%s -> %s" % (lines[hit[0]], raw))
            lines[hit[0]] = raw
        else:
            lines.append(raw)
            changed.append("+ " + raw)
    tmp = os.path.join(fgamedir, "options.txt.tmp")
    with open(tmp, "w", encoding="utf-8") as f:
        f.write("\n".join(lines) + "\n")
    os.replace(tmp, os.path.join(fgamedir, "options.txt"))
    n = sum(len(fs) for _, _, fs in os.walk(cfg_dst))
    print("defaults: config/ (%d files) and options.txt installed; overrides: %s" % (n, "; ".join(changed) or "none"))


def cmd_scan(app, needles):
    needles = [n.encode() for n in needles if n]
    bad, fw = [], 0
    for dirpath, dirnames, filenames in os.walk(app):
        for f in filenames:
            p = os.path.join(dirpath, f)
            rel = os.path.relpath(p, app)
            if os.path.islink(p):
                bad.append(rel + " (symbolic link)")
                continue
            data = open(p, "rb").read()
            if any(n in data for n in needles):
                if rel.startswith("Frameworks" + os.sep):
                    fw += 1
                else:
                    bad.append(rel)
    print("scan: %d libraries in Frameworks/ still name a path of this Mac (compiler paths)" % fw)
    if bad:
        for b in bad[:40]:
            print("  names a path of this Mac: " + b)
        sys.exit(4)
    print("scan: no file outside Frameworks/ names a path of this Mac")


STORED_SUFFIXES = (".jar", ".zip", ".png", ".ogg", ".jpg", ".jpeg", ".gz")


def cmd_zip(src, out):
    """Sorted entries, fixed dates, directory entries kept (an empty resourcepacks/ must survive), no symlinks."""
    top = os.path.join(src, "Payload")
    if not os.path.isdir(top):
        sys.exit("zip: %s has no Payload/" % src)
    entries = []
    for dirpath, dirnames, filenames in os.walk(top):
        dirnames.sort()
        rel = os.path.relpath(dirpath, src)
        entries.append((rel + "/", None))
        for f in sorted(filenames):
            if f == ".DS_Store":
                continue
            p = os.path.join(dirpath, f)
            if os.path.islink(p) or not os.path.isfile(p):
                sys.exit("zip: not a regular file: " + p)
            entries.append((os.path.join(rel, f), p))
    entries.sort(key=lambda e: e[0])
    tmp = out + ".partial"
    if os.path.lexists(tmp):
        os.remove(tmp)
    date = (1980, 1, 1, 0, 0, 0)
    # How far it is, in bytes of the files written, about once a second (on stderr: stdout is the result line).
    total = sum(os.path.getsize(p) for _, p in entries if p is not None)
    told, written = 0.0, 0
    with zipfile.ZipFile(tmp, "w", allowZip64=True) as z:
        for name, path in entries:
            if time.time() - told >= 1.0:
                told = time.time()
                sys.stderr.write("zip %d/%d bytes\n" % (written, total))
                sys.stderr.flush()
            info = zipfile.ZipInfo(name, date_time=date)
            info.create_system = 3
            if path is None:
                info.external_attr = (0o40755 << 16) | 0x10
                info.compress_type = zipfile.ZIP_STORED
                z.writestr(info, b"")
                continue
            mode = 0o755 if os.stat(path).st_mode & 0o111 else 0o644
            info.external_attr = (0o100000 | mode) << 16
            stored = name.lower().endswith(STORED_SUFFIXES) or "/assets/objects/" in name
            info.compress_type = zipfile.ZIP_STORED if stored else zipfile.ZIP_DEFLATED
            with open(path, "rb") as f, z.open(info, "w", force_zip64=False) as dst:
                shutil.copyfileobj(f, dst, 1 << 20)
            written += os.path.getsize(path)
    sys.stderr.write("zip %d/%d bytes\n" % (total, total))
    with zipfile.ZipFile(tmp) as z:
        n = len(z.infolist())
    os.replace(tmp, out)
    print("%s %d %d" % (sha256_file(out), os.path.getsize(out), n))


def main(argv):
    if len(argv) < 2:
        sys.exit(__doc__)
    cmd, args = argv[1], argv[2:]
    if cmd == "manifest":
        cmd_manifest(*args)
    elif cmd == "sync":
        cmd_sync(*args)
    elif cmd == "logpipe":
        cmd_logpipe(*args)
    elif cmd == "sha256":
        print(sha256_file(args[0]))
    elif cmd == "verify":
        cmd_verify(*args)
    elif cmd == "bake-compare":
        cmd_bake_compare(*args)
    elif cmd == "defaults":
        cmd_defaults(*args)
    elif cmd == "scan":
        cmd_scan(args[0], args[1:])
    elif cmd == "zip":
        cmd_zip(*args)
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main(sys.argv)
