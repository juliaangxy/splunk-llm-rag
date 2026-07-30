#!/usr/bin/env python3
"""Parse a DSDL mltk-container images.conf (normally the app's default/images.conf) into
the dsdl-default-images.json manifest shape used by seed-default-dsdl-images.sh and
generate_default_images_conf.py.

This lets the upgrade flow discover the image set/versions an upgraded DSDL app expects
straight from the app, instead of a hard-coded list.

Each stanza in default/images.conf looks like:
  [golden-cpu]
  title = Golden Image CPU (5.2.5)
  image = mltk-container-golden-cpu:5.2.5
  repo  = splunk/
  runtime = none

Emits {"version": <derived>, "images": [{stanza, source, ecr_tag, title, runtime}, ...]}
where source = repo + image (Docker Hub ref) and ecr_tag = <image-name>-<tag>.

Usage: dsdl_images_conf_to_manifest.py <path-to-images.conf>   (writes JSON to stdout)
"""

import configparser
import json
import sys


def derive_ecr_tag(image_field):
    # image_field e.g. "mltk-container-golden-cpu:5.2.5" or ".../name:tag"
    name_and_tag = image_field.rsplit("/", 1)[-1]
    if ":" in name_and_tag:
        name, tag = name_and_tag.rsplit(":", 1)
    else:
        name, tag = name_and_tag, "latest"
    return f"{name}-{tag}", tag


def main():
    if len(sys.argv) != 2:
        print("usage: dsdl_images_conf_to_manifest.py <images.conf>", file=sys.stderr)
        sys.exit(2)

    cp = configparser.ConfigParser(strict=False)
    # Preserve key case (Splunk .conf keys are lowercase anyway).
    cp.optionxform = str
    with open(sys.argv[1], "r", encoding="utf-8") as fh:
        cp.read_file(fh)

    images = []
    version = ""
    for stanza in cp.sections():
        if stanza == "default":
            continue
        image = cp.get(stanza, "image", fallback="").strip()
        if not image:
            continue
        repo = cp.get(stanza, "repo", fallback="").strip()
        runtime = cp.get(stanza, "runtime", fallback="none").strip()
        title = cp.get(stanza, "title", fallback=stanza).strip()
        source = f"{repo}{image}" if repo else image
        ecr_tag, tag = derive_ecr_tag(image)
        # Use the first plain numeric-looking tag as the manifest version hint.
        if not version and tag and tag[0].isdigit():
            version = tag
        images.append({
            "stanza": stanza,
            "source": source,
            "ecr_tag": ecr_tag,
            "title": title,
            "runtime": runtime,
        })

    if not images:
        print("ERROR: no image stanzas found", file=sys.stderr)
        sys.exit(1)

    print(json.dumps({"version": version, "images": images}, indent=2))


if __name__ == "__main__":
    main()
