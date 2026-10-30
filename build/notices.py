# SPDX-License-Identifier: AGPL-3.0-or-later
# Copyright (C) 2026 Philoneous
"""Lizenzhinweise des App-Pakets: jede mitgelieferte Komponente mit Version, Lizenz, Herkunft und Lizenztexten.

Schreibt nach <Licenses>:
  THIRD-PARTY-NOTICES.txt  Übersicht, vorgeschriebene Namensnennungen, Bezugsquelle des Quellcodes
  PDF-MRC-LICENSE.txt      Lizenz der App (AGPL-3.0-or-later)
  homebrew/<Paket>/…       Lizenzdateien der Homebrew-Pakete (Tesseract, OpenJPEG, jbig2enc, Bibliotheken)
  python-runtime/…         Lizenzen von CPython und den darin eingebauten Bibliotheken (python-build-standalone)
  python-packages/<Paket>/ Lizenzdateien der Python-Pakete (dazu fehlende Hinweise zu eingebauten Bibliotheken)
  mupdf/…                  Lizenzen von MuPDF und seinen eingebauten Bibliotheken (Teil von PyMuPDF)
  sparkle/, tessdata/      Sparkle (Updates), Tesseract-Sprachdaten
  sources.json             Quellarchive aller Komponenten mit Copyleft-Lizenz (für build/release.sh)

Bricht ab (Exit 1), wenn für eine Komponente kein Lizenztext gefunden wird, eine eingebaute Bibliothek keinem
Lizenzhinweis zugeordnet werden kann oder für Copyleft-Code kein Quellarchiv feststeht.

    python3 build/notices.py --app <PDF MRC.app> --kegs <kegs.json> --sparkle <Sparkle-Ordner> \
        --license <LICENSE> --version <Version>
"""

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from pathlib import Path

# Copyleft-Lizenzen (Kürzel und ausgeschriebene Namen aus Klassifikatoren, z. B. „GNU Affero General Public License v3“)
COPYLEFT = re.compile(r"\b(A?GPL|LGPL|MPL|EPL|CDDL|EUPL|OSL|Sleepycat)\b|General Public License|Mozilla Public|"
                      r"Eclipse Public|Common Development and Distribution|European Union Public|Open Software License",
                      re.I)
LICENSE_FILE = re.compile(r"(?i)^(licen[cs]e|copying|notice|copyright)")
SPDX_TEXTS = "https://raw.githubusercontent.com/spdx/license-list-data/v3.27.0/text/{}.txt"
PBS = "https://github.com/astral-sh/python-build-standalone/releases/download/{tag}/"
PBS_ARCHIVE = "cpython-{version}+{tag}-aarch64-apple-darwin-pgo+lto-full.tar.zst"
MUPDF = "https://mupdf.com/downloads/archive/mupdf-{}-source.tar.gz"
# python-build-standalone: Lizenzen der in libpython eingebauten Bibliotheken (Tcl/Tk entfernt die App)
PBS_SKIP = {"LICENSE.tcl.txt", "LICENSE.tix.txt", "LICENSE.bdb.txt", "LICENSE.openssl-1.1.txt"}
# Bibliotheken in PIL/.dylibs, die Pillows eigene Lizenzdatei nicht nennt → Text aus python-build-standalone
# (dieselben Projekte) bzw. von zlib-ng
PILLOW_EXTRA = {
    "libxcb": ("python-runtime", "LICENSE.libxcb.txt"),
    "libXau": ("python-runtime", "LICENSE.libXau.txt"),
    "zlib-ng": ("url", "https://raw.githubusercontent.com/zlib-ng/zlib-ng/2.2.4/LICENSE.md"),
}
# Suchwort je eingebauter Bibliothek → muss in der Lizenzdatei des Python-Pakets (oder PILLOW_EXTRA) vorkommen
BUNDLED_TOKENS = [
    (r"libxcb", "libxcb"), (r"libXau", "libXau"), (r"libz\..*zlib-ng", "zlib-ng"), (r"libz\b", "zlib"),
    (r"libavif", "avif"), (r"libbrotli", "brotli"), (r"libfreetype", "freetype"), (r"libharfbuzz", "harfbuzz"),
    (r"libjpeg", "jpeg"), (r"liblcms2", "lcms"), (r"liblzma", "lzma"), (r"libopenjp2", "openjpeg"),
    (r"libpng", "png"), (r"libsharpyuv", "webp"), (r"libtiff", "tiff"), (r"libwebp", "webp"), (r"libqpdf", "qpdf"),
]


def fail(message: str) -> None:
    print(f"[FEHLER] {message}", file=sys.stderr)
    sys.exit(1)


def run(*cmd: str) -> str:
    return subprocess.run(cmd, check=True, capture_output=True, text=True).stdout


def fetch(url: str, target: Path) -> Path:
    subprocess.run(["curl", "-fsSL", "--retry", "3", "-o", str(target), url], check=True)
    return target


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


class Notices:
    def __init__(self, out: Path):
        self.out = out
        self.components = []  # dict: name, version, license, part, homepage, files
        self.sources = []     # dict: name, version, license, url, sha256, filename
        self.spdx_cache = {}

    def add(self, name, version, license, part, homepage, files):
        if not files:
            fail(f"Kein Lizenztext für {name} {version} ({license})")
        self.components.append(dict(name=name, version=version, license=license or "?", part=part,
                                    homepage=homepage or "", files=sorted(str(f.relative_to(self.out)) for f in files)))

    def spdx_text(self, ident: str, folder: Path) -> Path:
        """Vollständiger Lizenztext aus der SPDX-Liste (für Pakete ohne eigene Lizenzdatei)."""
        folder.mkdir(parents=True, exist_ok=True)
        return fetch(SPDX_TEXTS.format(ident), folder / f"{ident}.txt")

    def copy(self, files, folder: Path):
        folder.mkdir(parents=True, exist_ok=True)
        result = []
        for f in files:
            target = folder / f.name
            n = 2
            while target.exists():  # gleiche Namen aus Unterordnern
                target = folder / f"{f.stem}-{n}{f.suffix}"
                n += 1
            shutil.copy2(f, target)
            result.append(target)
        return result

    def need_source(self, name, version, license, url, digest=None, filename=None, download=None):
        if download is not None:
            digest = sha256(download)
        if not url or not digest:
            fail(f"Kein Quellarchiv für {name} {version} ({license})")
        self.sources.append(dict(name=name, version=version, license=license, url=url, sha256=digest,
                                 filename=filename or url.rsplit("/", 1)[-1]))


# ------------------------------------------------------------------------------------------- Homebrew


def spdx_ids(license) -> list[str]:
    """SPDX-Kennungen aus der Homebrew-Lizenzangabe (Text oder z. B. {"any_of": ["MIT", {"all_of": …}]})."""
    if isinstance(license, str):
        words = re.findall(r"[A-Za-z0-9][A-Za-z0-9_.+-]*", re.sub(r"\b(AND|OR|WITH)\b", " ", license))
        return [w for w in words if w not in ("public_domain", "cannot_represent")]
    if isinstance(license, list):
        return [i for item in license for i in spdx_ids(item)]
    if isinstance(license, dict):
        return [i for key, value in license.items() for i in (spdx_ids(value) if key in ("any_of", "all_of", "with")
                                                               else spdx_ids(key) + spdx_ids(value))]
    return []


def homebrew(n: Notices, kegs: dict):
    if not kegs:
        return
    info = {f["name"]: f for f in json.loads(run("brew", "info", "--json=v2", *kegs))["formulae"]}
    for name, keg in kegs.items():
        meta = info[name]
        keg = Path(keg)
        version = keg.name
        raw = meta.get("license")
        ids = spdx_ids(raw)
        license = raw if isinstance(raw, str) or raw is None else " / ".join(ids)
        files = [f for f in keg.iterdir() if f.is_file() and (LICENSE_FILE.match(f.name) or "LICENSE" in f.name.upper())]
        if (keg / "LICENSES").is_dir():
            files += [f for f in (keg / "LICENSES").iterdir() if f.is_file()]
        folder = n.out / "homebrew" / name
        copied = n.copy(files, folder)
        if not copied:  # kein Lizenztext im Paket: Volltext(e) aus der SPDX-Liste
            copied = [n.spdx_text(i, folder) for i in ids]
        n.add(name, version, license, "Contents/Helpers, Contents/Frameworks", meta.get("homepage"), copied)
        if COPYLEFT.search(license or ""):
            stable = meta.get("urls", {}).get("stable", {})
            n.need_source(name, version, license, stable.get("url"), stable.get("checksum"))


# ------------------------------------------------------------------------------------------- Python

DIST_SCRIPT = r"""
import importlib.metadata as m, json, sys
out = []
for d in m.distributions(path=[sys.argv[1]]):  # nur die Pakete der App
    md = d.metadata
    files = [str(d.locate_file(f)) for f in (d.files or [])]
    out.append(dict(name=md["Name"], version=md["Version"], license=md.get("License-Expression") or "",
                    license_text=(md.get("License") or "")[:200],
                    classifiers=[c for c in (md.get_all("Classifier") or []) if c.startswith("License ::")],
                    homepage=md.get("Home-page") or next((u.split(",", 1)[1].strip() for u in
                             (md.get_all("Project-URL") or []) if u.lower().startswith(("homepage", "source",
                             "repository"))), ""),
                    files=files))
json.dump(out, sys.stdout)
"""


def python_license(dist: dict) -> str:
    if dist["license"]:
        return dist["license"]
    classifiers = [c.split("::")[-1].strip() for c in dist["classifiers"]]
    return " / ".join(classifiers) or dist["license_text"].split("\n")[0]


def pypi_sdist(name: str, version: str):
    meta = json.loads(run("curl", "-fsSL", "--retry", "3", f"https://pypi.org/pypi/{name}/{version}/json"))
    for u in meta["urls"]:
        if u["packagetype"] == "sdist":
            return u["url"], u["digests"]["sha256"], u["filename"]
    return None, None, None


def python_packages(n: Notices, python: Path, site: Path, work: Path):
    dists = json.loads(run(str(python), "-I", "-c", DIST_SCRIPT, str(site)))
    for dist in sorted(dists, key=lambda d: d["name"].lower()):
        name, version = dist["name"], dist["version"]
        license = python_license(dist)
        files = [Path(f) for f in dist["files"] if ".dist-info/" in f and Path(f).is_file()
                 and (LICENSE_FILE.match(Path(f).name) or "/licenses/" in f) and not f.endswith(".json")]
        folder = n.out / "python-packages" / name
        copied = n.copy(files, folder)
        if name.lower() == "pymupdf":
            copied += pymupdf(n, python, work, folder)  # vollständiger AGPL-Text (COPYING von PyMuPDF: eine Zeile)
        if name.lower() == "pillow":
            copied += bundled_libs(n, site / "PIL" / ".dylibs", copied, folder)
        elif name.lower() == "pikepdf":
            bundled_libs(n, site / "pikepdf" / ".dylibs", copied, folder)
        elif name.lower() == "scipy":
            bundled_libs(n, site / "scipy" / ".dylibs", copied, folder)
        homepage = dist["homepage"] or ("https://github.com/Philoneous/paperless-mrc" if name == "paperless-mrc" else "")
        n.add(name, version, license, "Contents/Resources/python (Python package)", homepage, copied)
        if name.lower() == "paperless-mrc":  # Quelle: eigenes Repository, Commit aus direct_url.json
            direct = next((Path(f) for f in dist["files"] if f.endswith("direct_url.json")), None)
            vcs = json.loads(direct.read_text()).get("vcs_info", {}) if direct and direct.exists() else {}
            commit = vcs.get("commit_id")
            if not commit:
                fail("paperless-mrc: Commit unbekannt (direct_url.json)")
            url = f"https://github.com/Philoneous/paperless-mrc/archive/{commit}.tar.gz"
            archive = fetch(url, work / f"paperless-mrc-{commit[:7]}.tar.gz")
            n.need_source(name, version, license, url, filename=archive.name, download=archive)
        elif COPYLEFT.search(license):
            url, digest, filename = pypi_sdist(name, version)
            n.need_source(name, version, license, url, digest, filename)


def bundled_libs(n: Notices, dylibs: Path, license_files, folder: Path):
    """Jede in einem Python-Paket eingebaute Bibliothek muss in dessen Lizenzhinweisen vorkommen."""
    if not dylibs.is_dir():
        return []
    text = "\n".join(Path(n.out / f).read_text(errors="replace") if not Path(f).is_absolute() else
                     Path(f).read_text(errors="replace") for f in license_files)
    extra = []
    for lib in sorted(p.name for p in dylibs.iterdir()):
        token = next((t for pattern, t in BUNDLED_TOKENS if re.match(pattern, lib)), None)
        if token is None:
            fail(f"Unbekannte eingebaute Bibliothek {dylibs.parent.name}/.dylibs/{lib} – Lizenz zuordnen")
        if re.search(re.escape(token), text, re.I):
            continue
        if token not in PILLOW_EXTRA:
            fail(f"{dylibs.parent.name}/.dylibs/{lib}: kein Lizenzhinweis zu „{token}“")
        kind, ref = PILLOW_EXTRA[token]
        target = folder / f"{token}-LICENSE.txt"
        if kind == "url":
            fetch(ref, target)
        else:
            shutil.copy2(n.out / kind / ref, target)
        extra.append(target)
        text += target.read_text(errors="replace")
    return extra


def pymupdf(n: Notices, python: Path, work: Path, folder: Path):
    """PyMuPDF enthält MuPDF (und dessen eingebaute Bibliotheken); Quellcode: MuPDF-Archiv von Artifex."""
    version = run(str(python), "-I", "-c",
                  "import pymupdf; print(getattr(pymupdf, 'mupdf_version', None) or pymupdf.VersionFitz)").strip()
    archive = fetch(MUPDF.format(version), work / f"mupdf-{version}-source.tar.gz")
    target = n.out / "mupdf"
    files = []
    # MuPDF selbst (COPYING) und jede eingebaute Bibliothek in thirdparty/<lib>/ (auch docs/FTL.TXT von FreeType;
    # die Bedingungen der IJG stehen in der README von libjpeg)
    pattern = re.compile(r"^[^/]+/(?:thirdparty/([^/]+)/(?:docs/)?)?([^/]+)$")
    wanted = re.compile(r"(?i)(copying|licen[cs]e|notice|copyright|^ftl\.txt$)")
    with tarfile.open(archive) as tf:
        for member in tf:
            m = pattern.match(member.name)
            if not (m and member.isfile()):
                continue
            lib, filename = m.group(1), m.group(2)
            if not (wanted.search(filename) or (lib == "libjpeg" and filename == "README")):
                continue
            sub = target / (lib or "mupdf")
            sub.mkdir(parents=True, exist_ok=True)
            with tf.extractfile(member) as src, open(sub / filename, "wb") as dst:
                shutil.copyfileobj(src, dst)
            files.append(sub / filename)
    if not (target / "mupdf" / "COPYING").exists():
        fail("MuPDF-Archiv ohne COPYING")
    n.add("MuPDF", version, "AGPL-3.0-or-later", "Contents/Resources/python (part of PyMuPDF)",
          "https://mupdf.com", files)
    n.need_source("MuPDF", version, "AGPL-3.0-or-later", MUPDF.format(version), filename=archive.name,
                  download=archive)
    folder.mkdir(parents=True, exist_ok=True)
    shutil.copy2(target / "mupdf" / "COPYING", folder / "AGPL-3.0.txt")
    return [folder / "AGPL-3.0.txt"]


# ------------------------------------------------------------------------------------------- Python-Laufzeit


def python_runtime(n: Notices, python_dir: Path, work: Path):
    tag = (python_dir / "BUILD").read_text().strip()
    version = run(str(python_dir / "bin" / "python3"), "-I", "-c",
                  "import platform; print(platform.python_version())").strip()
    name = PBS_ARCHIVE.format(version=version, tag=tag)
    sums = run("curl", "-fsSL", "--retry", "3", PBS.format(tag=tag) + "SHA256SUMS")
    expected = next((line.split()[0] for line in sums.splitlines() if line.endswith(name)), None)
    if expected is None:
        fail(f"{name} nicht im Release {tag} von python-build-standalone")
    archive = fetch(PBS.format(tag=tag) + name, work / name)
    if sha256(archive) != expected:
        fail(f"Prüfsumme von {name} falsch")
    folder = n.out / "python-runtime"
    folder.mkdir(parents=True, exist_ok=True)
    tar = subprocess.Popen(["zstd", "-dc", str(archive)], stdout=subprocess.PIPE)
    files = []
    with tarfile.open(fileobj=tar.stdout, mode="r|") as tf:
        for member in tf:
            m = re.match(r"^python/licenses/(LICENSE[^/]*\.txt)$", member.name)
            if m and member.isfile() and m.group(1) not in PBS_SKIP:
                with tf.extractfile(member) as src, open(folder / m.group(1), "wb") as dst:
                    shutil.copyfileobj(src, dst)
                files.append(folder / m.group(1))
    tar.wait()
    if not any(f.name in ("LICENSE.txt", "LICENSE.cpython.txt") for f in files):
        fail("python-build-standalone: Lizenzen nicht gefunden")
    n.add("Python (CPython, python-build-standalone)", f"{version}+{tag}",
          "PSF-2.0; built-in: OpenSSL (Apache-2.0), bzip2, expat, libffi, liblzma, mpdecimal, ncurses, SQLite, "
          "libuuid, zlib", "Contents/Resources/python", "https://github.com/astral-sh/python-build-standalone", files)


# ------------------------------------------------------------------------------------------- Ausgabe


ACKNOWLEDGEMENTS = """\
Required acknowledgements
-------------------------
Portions of this software are copyright (c) The FreeType Project (www.freetype.org). All rights reserved.
This software is based in part on the work of the Independent JPEG Group.
"""


def write(n: Notices, version: str):
    lines = [
        f"PDF MRC {version} – third-party notices",
        "=" * 60,
        "",
        "PDF MRC: Copyright (C) 2026 Philoneous. Licensed under the GNU Affero General Public License, version 3",
        "or later (AGPL-3.0-or-later), see PDF-MRC-LICENSE.txt. Source code: https://github.com/Philoneous/mac-pdf-mrc",
        "(the release tag of this version). PDF MRC is an independent project and is not affiliated with or endorsed",
        "by Paperless-ngx, the Internet Archive, Artifex or any other project named below.",
        "",
        "PDF MRC bundles the following components. Each is distributed under its own license; the full license",
        "texts are in the files listed for it (paths relative to this folder).",
        "",
        ACKNOWLEDGEMENTS,
        "Source code of components under copyleft licenses",
        "-------------------------------------------------",
        "The exact source archives are available next to the app downloads, in the GitHub release",
        "“third-party-sources”: https://github.com/Philoneous/mac-pdf-mrc/releases/tag/third-party-sources",
        "(listed with SHA-256 checksums in sources.json). You may also request them by opening an issue at",
        "https://github.com/Philoneous/mac-pdf-mrc/issues – for at least three years after the last release.",
        "",
    ]
    for s in n.sources:
        lines.append(f"  {s['name']} {s['version']} ({s['license']}): {s['filename']}  sha256 {s['sha256']}")
    lines += ["", "Components", "----------", ""]
    for c in sorted(n.components, key=lambda c: c["name"].lower()):
        lines.append(f"{c['name']} {c['version']}")
        lines.append(f"  License: {c['license']}")
        lines.append(f"  Part of the app: {c['part']}")
        if c["homepage"]:
            lines.append(f"  Project: {c['homepage']}")
        lines.append(f"  License texts: {', '.join(c['files'])}")
        lines.append("")
    (n.out / "THIRD-PARTY-NOTICES.txt").write_text("\n".join(lines), encoding="utf-8")
    (n.out / "sources.json").write_text(json.dumps(n.sources, indent=2))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--app", type=Path, required=True)
    ap.add_argument("--kegs", type=Path, required=True)
    ap.add_argument("--sparkle", type=Path, required=True)
    ap.add_argument("--license", type=Path, required=True)
    ap.add_argument("--version", required=True)
    args = ap.parse_args()

    resources = args.app / "Contents" / "Resources"
    out = resources / "Licenses"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    n = Notices(out)
    shutil.copy2(args.license, out / "PDF-MRC-LICENSE.txt")
    python_dir = resources / "python"
    site = next((python_dir / "lib").glob("python3.*/site-packages"))
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        python_runtime(n, python_dir, work)  # zuerst: liefert auch Texte für Pillow (libxcb, libXau)
        python_packages(n, python_dir / "bin" / "python3", site, work)
        homebrew(n, json.loads(args.kegs.read_text()))
    sparkle = n.copy(sorted(args.sparkle.glob("LICENSE*")), out / "sparkle")
    if not sparkle:
        fail("Sparkle: Lizenztext fehlt")
    sparkle_version = re.search(r"(\d+(?:\.\d+)+)", args.sparkle.name)
    n.add("Sparkle", sparkle_version.group(1) if sparkle_version else "2",
          "MIT (with bundled bsdiff/bspatch: BSD-2-Clause, ed25519: Zlib)", "Contents/Frameworks",
          "https://sparkle-project.org", sparkle)
    langs = sorted(f.name.split(".")[0] for f in (args.app / "Contents" / "Resources" / "tessdata").glob("*.traineddata"))
    tessdata = out / "tessdata"
    tessdata.mkdir()
    fetch("https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/main/LICENSE", tessdata / "LICENSE")
    n.add(f"tessdata_fast ({', '.join(langs) or 'eng, osd'})", "main", "Apache-2.0", "Contents/Resources/tessdata",
          "https://github.com/tesseract-ocr/tessdata_fast", [tessdata / "LICENSE"])
    write(n, args.version)
    print(f"[OK] Lizenzhinweise: {len(n.components)} Komponenten, {len(n.sources)} Quellarchive (Copyleft)")
    for s in n.sources:
        print(f"     Quelle: {s['name']} {s['version']} ({s['license']})")


if __name__ == "__main__":
    main()
