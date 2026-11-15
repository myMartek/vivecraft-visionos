#!/usr/bin/python3
"""Helper for tools/avpplay/build_parts.sh. Run as: /usr/bin/python3 -I -B parts_helper.py <command> ...

Only the Python that macOS and Xcode bring (3.9), standard library only.

  manifest <checkout> <out.json>            hash every file of the checkout; print "<all> <build> <payload>" stamps
  sync <checkout> <tree> <new.json> <old.json>
                                            make <tree> hold the checkout's files (changed ones copied, vanished
                                            ones removed); build products in <tree> are left alone
  logpipe <logfile> <heartbeat>             stdin -> stdout and, time-stamped, -> logfile; touches heartbeat
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


def cmd_logpipe(logfile, heartbeat):
    """Copy stdin to stdout and to the log. A line that looks like one of the protocol lines the caller prints
    itself (STAGE, PARTS, FAILED, LOG) gets a leading blank so a reader of stdout cannot mistake it."""
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

    def emit(raw):
        if b"\r" in raw:
            raw = raw.rstrip(b"\r").split(b"\r")[-1]
        text = raw.decode("utf-8", "replace")
        if text.startswith(("STAGE ", "PARTS ", "FAILED ", "LOG ")):
            text = " " + text
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

    while True:
        if stop["at"] is not None and time.time() >= stop["at"]:
            break
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
    with zipfile.ZipFile(tmp, "w", allowZip64=True) as z:
        for name, path in entries:
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
