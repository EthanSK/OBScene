#!/usr/bin/env python3
"""update-appcast.py — maintain OBScene's Sparkle appcast.xml.

Appends (or replaces) a single `<item>` for the given release in
`site/appcast.xml`. The file is Pages-served at
https://ethansk.github.io/OBScene/appcast.xml — that's the URL in
`SUFeedURL` in `OBScene/Info.plist`.

Inputs come via env vars (and a couple of positional args) so the release
workflow can call it without fiddling with quoting:

    VERSION            — full semver, e.g. 1.6.0                   (required)
    DISPLAY_VERSION    — two-part display, e.g. 1.6                (required)
    BUILD_NUMBER       — CFBundleVersion integer, e.g. 10600       (required)
    RELEASE_TAG        — GitHub tag name, e.g. v1.6                (required)
    ZIP_FILENAME       — e.g. OBScene-1.6.0-mac-universal.zip      (required)
    ZIP_SIZE           — file size in bytes                        (required)
    ED_SIGNATURE       — Sparkle EdDSA signature for ZIP           (required)
    RELEASE_NOTES_URL  — HTML release notes URL                    (required)
    MIN_MACOS          — minimum system version, e.g. 13.0         (defaults to 13.0)
    REPO               — GitHub owner/repo                         (defaults to EthanSK/OBScene)
    PUB_DATE           — RFC 2822 date string                      (defaults to now UTC)

The appcast file is created from scratch if it doesn't exist yet.

Sparkle's appcast spec: https://sparkle-project.org/documentation/publishing/
"""

from __future__ import annotations

import os
import sys
from datetime import datetime, timezone
from pathlib import Path
import xml.etree.ElementTree as ET

# --- Namespaces Sparkle's appcast uses -------------------------------------
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ATOM_NS = "http://www.w3.org/2005/Atom"
ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("atom", ATOM_NS)

SPARKLE = f"{{{SPARKLE_NS}}}"


def require_env(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        print(f"::error::update-appcast: missing required env var {name}", file=sys.stderr)
        sys.exit(1)
    return value


def build_item(
    *,
    version: str,
    display_version: str,
    build_number: str,
    release_tag: str,
    zip_filename: str,
    zip_size: str,
    ed_signature: str,
    release_notes_url: str,
    min_macos: str,
    repo: str,
    pub_date: str,
) -> ET.Element:
    """Build a single Sparkle <item> element for this release."""
    item = ET.Element("item")

    title = ET.SubElement(item, "title")
    title.text = f"OBScene v{display_version}"

    pub = ET.SubElement(item, "pubDate")
    pub.text = pub_date

    # Sparkle uses sparkle:version (build number) and
    # sparkle:shortVersionString (user-facing version). They mirror
    # CFBundleVersion + CFBundleShortVersionString respectively.
    sparkle_version = ET.SubElement(item, f"{SPARKLE}version")
    sparkle_version.text = build_number

    sparkle_short = ET.SubElement(item, f"{SPARKLE}shortVersionString")
    sparkle_short.text = version

    # Minimum system version. Matches LSMinimumSystemVersion in Info.plist.
    min_sys = ET.SubElement(item, f"{SPARKLE}minimumSystemVersion")
    min_sys.text = min_macos

    # Release notes live on the GitHub Release page. Sparkle fetches the
    # URL and renders it in-dialog (HTML). GitHub's release HTML is
    # reasonable for this — headline, changelog, download links.
    notes = ET.SubElement(item, f"{SPARKLE}releaseNotesLink")
    notes.text = release_notes_url

    # Enclosure points at the ZIP download. Sparkle requires length and
    # type attributes. `sparkle:edSignature` is the EdDSA signature of the
    # zip, computed by `sign_update` against the SPARKLE_ED_PRIVATE_KEY.
    download_url = (
        f"https://github.com/{repo}/releases/download/{release_tag}/{zip_filename}"
    )
    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", download_url)
    enclosure.set("length", zip_size)
    enclosure.set("type", "application/octet-stream")
    enclosure.set(f"{SPARKLE}version", build_number)
    enclosure.set(f"{SPARKLE}shortVersionString", version)
    enclosure.set(f"{SPARKLE}edSignature", ed_signature)

    return item


def load_or_create_channel(appcast_path: Path) -> tuple[ET.ElementTree, ET.Element]:
    if appcast_path.exists():
        tree = ET.parse(appcast_path)
        root = tree.getroot()
        channel = root.find("channel")
        if channel is None:
            print(f"::error::{appcast_path} is missing <channel>", file=sys.stderr)
            sys.exit(1)
        return tree, channel

    # Create a fresh appcast scaffold. Sparkle requires an RSS 2.0 document
    # with the sparkle: namespace declared on the root. `register_namespace`
    # above already causes ElementTree to emit the xmlns:sparkle and
    # xmlns:atom declarations on the root automatically — we only need to
    # set the RSS version attribute.
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "OBScene Updates"
    ET.SubElement(channel, "link").text = "https://ethansk.github.io/OBScene/"
    ET.SubElement(channel, "description").text = (
        "Automatic update feed for OBScene — the menu-bar companion that "
        "flips OBS into your streaming scene when external displays connect."
    )
    ET.SubElement(channel, "language").text = "en"
    # Atom self-link (harmless, some feed readers complain without it).
    atom_link = ET.SubElement(channel, f"{{{ATOM_NS}}}link")
    atom_link.set("href", "https://ethansk.github.io/OBScene/appcast.xml")
    atom_link.set("rel", "self")
    atom_link.set("type", "application/rss+xml")

    return ET.ElementTree(rss), channel


def upsert_item(channel: ET.Element, new_item: ET.Element, version: str) -> None:
    """Replace any existing item for this semver, else prepend the new one."""
    # Find existing item by matching sparkle:shortVersionString.
    existing = None
    for existing_candidate in channel.findall("item"):
        short = existing_candidate.find(f"{SPARKLE}shortVersionString")
        if short is not None and (short.text or "").strip() == version:
            existing = existing_candidate
            break

    if existing is not None:
        # Replace in place so ordering is preserved.
        idx = list(channel).index(existing)
        channel.remove(existing)
        channel.insert(idx, new_item)
        return

    # Prepend so the newest release appears first. Insert after the static
    # channel metadata elements — find the index of the first existing item,
    # or append if none yet.
    first_item_index = None
    for i, child in enumerate(list(channel)):
        if child.tag == "item":
            first_item_index = i
            break
    if first_item_index is None:
        channel.append(new_item)
    else:
        channel.insert(first_item_index, new_item)


def main() -> int:
    repo_root = Path(__file__).resolve().parent.parent
    appcast_path = repo_root / "site" / "appcast.xml"
    appcast_path.parent.mkdir(parents=True, exist_ok=True)

    version = require_env("VERSION")
    display_version = require_env("DISPLAY_VERSION")
    build_number = require_env("BUILD_NUMBER")
    release_tag = require_env("RELEASE_TAG")
    zip_filename = require_env("ZIP_FILENAME")
    zip_size = require_env("ZIP_SIZE")
    ed_signature = require_env("ED_SIGNATURE")
    release_notes_url = require_env("RELEASE_NOTES_URL")
    min_macos = os.environ.get("MIN_MACOS", "13.0")
    repo = os.environ.get("REPO", "EthanSK/OBScene")
    pub_date = os.environ.get("PUB_DATE") or datetime.now(timezone.utc).strftime(
        "%a, %d %b %Y %H:%M:%S +0000"
    )

    tree, channel = load_or_create_channel(appcast_path)

    new_item = build_item(
        version=version,
        display_version=display_version,
        build_number=build_number,
        release_tag=release_tag,
        zip_filename=zip_filename,
        zip_size=zip_size,
        ed_signature=ed_signature,
        release_notes_url=release_notes_url,
        min_macos=min_macos,
        repo=repo,
        pub_date=pub_date,
    )

    upsert_item(channel, new_item, version)

    # Pretty print. xml.etree.ElementTree.indent exists on Python 3.9+.
    ET.indent(tree, space="  ")
    tree.write(appcast_path, xml_declaration=True, encoding="utf-8")

    print(f"[update-appcast] wrote {appcast_path} ({version} / {release_tag})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
