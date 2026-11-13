#!/usr/bin/python3 -I
"""Card S2's live check: does anything personal survive in Velum's redacted diagnostics report?

It reads the strings to look for from this Mac's live configuration, at run time:
- OneDrive's settings (its folders, site and library titles, the SharePoint tenant);
- the live folders in ~/Library/CloudStorage (organizations, Google addresses);
- Velum's own saved state (account names, pending and recent file names, Google sign-in addresses);
- OneDrive's activity list, Google Drive's numeric account IDs, iCloud's storage figure;
- the names in Velum's debug log;
- the home folder, the user's names and the Mac's name.
Then it runs `Velum --dump --redact` (or reads an exported report) and looks for each string, plus shapes no
report should hold (addresses, byte figures, storage percentages, long IDs, web addresses, tokens, home paths).

It never writes anything and never prints the strings: only how many of each kind it looked for, and for a hit,
its kind, its line number and the line with every known string masked.

    Scripts/check-redaction.py                      # runs build/Velum.app's Velum --dump --redact
    Scripts/check-redaction.py --app /path/to/Velum # another build
    Scripts/check-redaction.py --file report.txt    # an exported report (••• → Export Diagnostics…)

Exit status: 0 nothing found, 1 something found, 2 the report couldn't be made or read.
"""
import glob
import json
import os
import plistlib
import pwd
import re
import sqlite3
import subprocess
import sys
import unicodedata
from urllib.parse import unquote, urlparse

HOME = os.path.expanduser("~")
CLOUD = os.path.join(HOME, "Library/CloudStorage")
ONEDRIVE_SETTINGS = os.path.join(HOME, "Library/Application Support/OneDrive/settings")
DRIVEFS = os.path.join(HOME, "Library/Application Support/Google/DriveFS")
LOGS = os.path.join(HOME, "Library/Logs/Velum")
REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
with open(os.path.join(REPO, "Resources/Info.plist"), "rb") as info:
    DOMAIN = plistlib.load(info)["CFBundleIdentifier"]  # Velum's defaults domain
# The same rules as the redactor (Sources/Velum/Diagnostics.swift): Velum's and the services' own words, and
# names under three characters, aren't treated as personal.
OWN_WORDS = {"personal", "business", "onedrive", "icloud", "icloud drive", "google drive", "my drive", "desktop",
             "documents", "sharedlibraries", "shared libraries", "shared drives", "other computers",
             "mobile documents", "library", "cloudstorage"}
SHORTEST = 3
# Kinds compared in any case; the rest (names of things) as written, so a folder called "Notes" doesn't match
# the report's own "notes:" label.
ANY_CASE = {"email", "home folder", "Google account ID", "storage figure", "user name", "organization"}

SHAPES = {
    "an email address": r"[\w.%+\-]+@[\w\-]+(?:\.[\w\-]+)*\.[^\W\d_]{2,}",
    "a byte figure": r"(?<![\w.,])\d+(?:[.,]\d+)?[\s  ]?(?:bytes?|[KMGTP]B|kB)\b",
    "a storage percentage": r"\d+(?:[.,]\d+)?[\s ]?%[\s ]+(?:full|used)",
    "a long number (an ID)": r"(?<!\w)\d{15,}(?!\w)",
    "a web address": r"https?://",
    "a home path": r"/Users/(?!<user>)",
    "a sign-in token": r"\bya29\.|\b1//[\w\-]{10,}|\beyJ[\w\-]+\.[\w\-]+\.",
}


def nfc(s):
    return unicodedata.normalize("NFC", s)


class Strings:
    def __init__(self):
        self.kinds = {}

    def add(self, kind, value):
        s = nfc(str(value or "")).strip()
        if len(s) < SHORTEST or s.lower() in OWN_WORDS:
            return
        self.kinds.setdefault(kind, set()).add(s)

    def all(self):
        return [(kind, s) for kind, values in self.kinds.items() for s in values]


def run(args, timeout=60):
    try:
        return subprocess.run(args, capture_output=True, timeout=timeout).stdout.decode("utf-8", "replace")
    except (OSError, subprocess.TimeoutExpired):
        return ""


def read_text(path):
    try:
        raw = open(path, "rb").read()
    except OSError:
        return ""
    if raw[:2] in (b"\xff\xfe", b"\xfe\xff"):
        return raw.decode("utf-16", "replace")
    return raw.decode("utf-8", "replace")


def camel_split(name):
    out, previous = "", ""
    for ch in name:
        if previous and ch.isupper() and previous.islower():
            out += " "
        out += ch
        previous = ch
    return out


def add_cloud_folder(found, folder):
    if folder.startswith("OneDrive-"):
        rest = folder[len("OneDrive-"):]
        if rest.startswith("SharedLibraries-"):
            rest = rest[len("SharedLibraries-"):]
        found.add("organization", rest)
        found.add("organization", camel_split(rest))
    elif folder.startswith("GoogleDrive-"):
        found.add("email", folder[len("GoogleDrive-"):])


def synced_roots():
    roots = [os.path.join(HOME, "Library/Mobile Documents/com~apple~CloudDocs"), os.path.join(HOME, "Desktop"),
             os.path.join(HOME, "Documents"), os.path.join(HOME, "OneDrive")]
    if os.path.isdir(CLOUD):
        roots += [os.path.join(CLOUD, name) for name in os.listdir(CLOUD)]
    return sorted(roots, key=len, reverse=True)


def add_path(found, path, roots):
    """A file's name, and the folders between its synced folder and it (the report drops both)."""
    path = nfc(path)
    found.add("file name", os.path.basename(path))
    for root in roots:
        if path.startswith(nfc(root) + "/"):
            for part in path[len(root) + 1:].split("/")[:-1]:
                found.add("folder name", part)
            return


def gather():
    found = Strings()
    roots = synced_roots()

    # The home folder, the user's names, the Mac's name.
    found.add("home folder", HOME)
    user = pwd.getpwuid(os.getuid())
    found.add("user name", user.pw_name)
    full = user.pw_gecos.split(",")[0]
    found.add("user name", full)
    for part in full.split():
        found.add("user name", part)
    found.add("computer name", run(["/usr/sbin/scutil", "--get", "ComputerName"]))

    # OneDrive's settings: each account's folder, its SharePoint tenant and personal site, site and library titles.
    for ini in glob.glob(os.path.join(ONEDRIVE_SETTINGS, "*", "*.ini")):
        for line in read_text(ini).splitlines():
            key, _, value = line.partition("=")
            key = key.strip()
            if key == "libraryScope":
                for quoted in re.findall(r'"([^"]*)"', value):
                    if quoted.startswith(("/", "~/")):
                        add_cloud_folder(found, os.path.basename(quoted.rstrip("/")))
                    elif quoted.startswith("https://"):
                        url = urlparse(quoted)
                        tenant = (url.hostname or "").split(".")[0]
                        found.add("organization", tenant[:-3] if tenant.endswith("-my") else tenant)
                        for segment in unquote(url.path).split("/"):
                            if "_" in segment:
                                found.add("account name", segment)
            elif key in ("SiteTitle", "LibraryTitle"):
                found.add("organization", value.strip().strip('"'))
    if os.path.isdir(CLOUD):
        for name in os.listdir(CLOUD):
            add_cloud_folder(found, name)

    # Velum's saved state: OneDrive's account names, files pending or recently uploaded, Google sign-in addresses.
    try:
        saved = plistlib.loads(subprocess.run(["defaults", "export", DOMAIN, "-"], capture_output=True).stdout)
    except Exception:
        saved = {}
    for key, value in saved.items():
        if key.startswith("name."):
            found.add("account name", value)
    for address in saved.get("googleSignInAccounts", []) or []:
        found.add("email", address)
    # Every value under every key, whatever the key (pendingUploads, recentUploads, A5's sleepGuardWatch, keys not
    # written yet): anything shaped like a path counts, and so does a "name" beside one.
    def walk(value):
        if isinstance(value, (bytes, bytearray)):
            for decode in (lambda b: json.loads(b), lambda b: plistlib.loads(b)):
                try:
                    walk(decode(bytes(value)))
                    return
                except Exception:
                    pass
        elif isinstance(value, dict):
            for key, inner in value.items():
                walk(key)
                walk(inner)
            if isinstance(value.get("path"), str) and isinstance(value.get("name"), str):
                found.add("file name", value["name"])
        elif isinstance(value, (list, tuple)):
            for inner in value:
                walk(inner)
        elif isinstance(value, str) and (value.startswith(HOME + "/") or value.startswith("/Volumes/")):
            add_path(found, value, roots)
    for key, value in saved.items():
        walk(value)

    # OneDrive's activity list, as Velum's Recent reads it.
    for db in glob.glob(os.path.join(ONEDRIVE_SETTINGS, "*", "UXDatabase.db")):
        try:
            con = sqlite3.connect("file:%s?mode=ro" % db, uri=True, timeout=1)
            for path, name in con.execute("SELECT FilePath, FileName FROM history_list ORDER BY LastUpdatedTimeUTC DESC LIMIT 30"):
                found.add("file name", name)
                if path:
                    add_path(found, path, roots)
            con.close()
        except sqlite3.Error:
            pass

    # Google Drive's numeric account IDs.
    if os.path.isdir(DRIVEFS):
        for name in os.listdir(DRIVEFS):
            if name.isdigit():
                found.add("Google account ID", name)

    # Names in Velum's debug log: accounts it has seen, files that failed.
    for log in glob.glob(os.path.join(LOGS, "Velum*.log")):
        for line in read_text(log).splitlines():
            line = nfc(line)
            for pattern in (r"\[status\] (.+?) \[(?:OneDrive|iCloud|Google Drive)\]: (?:appeared|gone)",
                            r"\[status\] (.+?): (?:ok|unknown|syncing|offline|paused|warning|notRunning|error) → "):
                for name in re.findall(pattern, line):
                    found.add("account name", name)
            for pattern in (r"\[status\] .+?: \d+ failing · first: (.+?): ", r"\[alert\] .+?: \d+ files? can’t upload · (.+?): ",
                            r"“([^”\n]+\.[^\W\d_][^\W_]{0,7})”"):
                for name in re.findall(pattern, line):
                    found.add("file name", name)

    # iCloud's storage figure, as brctl gives it.
    quota = re.search(r"-?\d+(?= bytes of quota remaining)", run(["/usr/bin/brctl", "quota"], timeout=20))
    if quota:
        found.add("storage figure", quota.group(0))
    return found


def pattern_for(s, kind):
    edge = r"[^\W_]"
    left = r"(?<!%s)" % edge if re.match(edge, s[0]) else ""
    right = r"(?!%s)" % edge if re.match(edge, s[-1]) else ""
    flags = re.IGNORECASE if kind in ANY_CASE else 0
    return re.compile(left + re.escape(s) + right, flags)


def main(argv):
    if "--file" in argv:
        source = argv[argv.index("--file") + 1]
        try:
            report = open(source, encoding="utf-8").read()
        except OSError as error:
            print("Can’t read the report: %s" % error.strerror)
            return 2
        where = "an exported report"
    else:
        app = argv[argv.index("--app") + 1] if "--app" in argv else os.path.join(REPO, "build/Velum.app/Contents/MacOS/Velum")
        try:
            done = subprocess.run([app, "--dump", "--redact"], capture_output=True, timeout=180)
        except (OSError, subprocess.TimeoutExpired) as error:
            print("Couldn’t run Velum --dump --redact: %s" % error)
            return 2
        report = done.stdout.decode("utf-8", "replace")
        where = "Velum --dump --redact (exit %d)" % done.returncode
        if done.returncode != 0 or not report.startswith("Velum diagnostics (redacted)"):
            print("Velum --dump --redact didn’t give a report (exit %d)." % done.returncode)
            return 2

    found = gather()
    strings = found.all()
    lines = nfc(report).splitlines()
    print("Velum diagnostics: live redaction check")
    print("Report: %d lines, from %s" % (len(lines), where))
    print("Looked for %d strings from this Mac’s live configuration: %s" % (
        len(strings), ", ".join("%s %d" % (kind, len(values)) for kind, values in sorted(found.kinds.items()))))

    compiled = [(kind, pattern_for(s, kind)) for kind, s in sorted(strings, key=lambda ks: -len(ks[1]))]

    def masked(line):
        for _, pattern in compiled:
            line = pattern.sub("▮▮▮", line)
        return line

    hits = []
    for number, line in enumerate(lines, 1):
        for kind, pattern in compiled:
            if pattern.search(line):
                hits.append((number, kind, line))
        for kind, shape in SHAPES.items():
            if re.search(shape, line):
                hits.append((number, kind, line))
    shown = set()
    for number, kind, line in hits:
        if (number, kind) in shown:
            continue
        shown.add((number, kind))
        print("FOUND %s on line %d: %s" % (kind, number, masked(line)))
    print("Result: %s" % ("nothing personal found" if not hits else "%d finding(s)" % len(shown)))
    return 1 if hits else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
