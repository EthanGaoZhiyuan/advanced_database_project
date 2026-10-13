"""Read the supplied fictional dataset. Expected results are used only by step 07."""
import hashlib
import json

from boa_etl.config import DATA_DIR, ENTITIES, SOURCES

PROFILE_FIELDS = ("full_name", "email", "phone", "date_of_birth", "street_address", "state", "postcode", "country")


def read_jsonl(path):
    return [json.loads(line) for line in path.read_text().splitlines() if line.strip()]


def sha256(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_manifest():
    manifest = json.loads((DATA_DIR / "manifest.json").read_text())
    required = {(source, entity) for source in SOURCES for entity in ENTITIES} | {("REGISTRY", "crosswalk")}
    entries = manifest["files"]
    if len(entries) != len(required) or {(f["source_system"], f["entity_name"]) for f in entries} != required:
        raise ValueError("Dataset must contain the 12 source tables and the verified identity crosswalk.")
    for entry in entries:
        path = (DATA_DIR / entry["path"]).resolve()
        if not path.is_relative_to(DATA_DIR.resolve()) or not path.is_file():
            raise ValueError(f"Invalid dataset path: {entry['path']}")
        if sha256(path) != entry["sha256"]:
            raise ValueError(f"Sample file changed: {entry['path']}")
    return manifest

