#!/usr/bin/env python3
"""Generate a deterministic SPDX 2.3 SBOM for the Oriel source tree."""

from __future__ import annotations

import hashlib
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
OUTPUT = ROOT / "artifacts" / "HermesCapture.spdx.json"
EXCLUDED_PARTS = {
    ".git",
    ".build",
    ".derivedData",
    ".package-cache",
    "DerivedData",
    "xcuserdata",
    "artifacts",
}
EXCLUDED_NAMES = {".DS_Store"}
RELAY_REQUIREMENTS = {
    "cryptography": ">=42,<47",
    "websockets": ">=14,<16",
}
DEPENDENCY_PACKAGES = [
    {
        "SPDXID": "SPDXRef-Package-PythonRuntime",
        "name": "python-container-runtime",
        "versionInfo": "3.12-slim",
        "downloadLocation": "https://hub.docker.com/_/python",
        "filesAnalyzed": False,
        "licenseConcluded": "NOASSERTION",
        "licenseDeclared": "NOASSERTION",
        "copyrightText": "NOASSERTION",
        "primaryPackagePurpose": "CONTAINER",
        "summary": (
            "Declared relay container base. Pin by digest and generate an image-level "
            "SBOM before deployment."
        ),
        "externalRefs": [
            {
                "referenceCategory": "PACKAGE-MANAGER",
                "referenceType": "purl",
                "referenceLocator": "pkg:docker/python@3.12-slim",
            }
        ],
    },
    {
        "SPDXID": "SPDXRef-Package-Cryptography",
        "name": "cryptography",
        "versionInfo": RELAY_REQUIREMENTS["cryptography"],
        "downloadLocation": "https://pypi.org/project/cryptography/",
        "filesAnalyzed": False,
        "licenseConcluded": "NOASSERTION",
        "licenseDeclared": "Apache-2.0 OR BSD-3-Clause",
        "copyrightText": "NOASSERTION",
        "primaryPackagePurpose": "LIBRARY",
        "summary": "Direct Python runtime dependency declared by relay/requirements.txt.",
        "externalRefs": [
            {
                "referenceCategory": "PACKAGE-MANAGER",
                "referenceType": "purl",
                "referenceLocator": "pkg:pypi/cryptography",
            }
        ],
    },
    {
        "SPDXID": "SPDXRef-Package-Websockets",
        "name": "websockets",
        "versionInfo": RELAY_REQUIREMENTS["websockets"],
        "downloadLocation": "https://pypi.org/project/websockets/",
        "filesAnalyzed": False,
        "licenseConcluded": "NOASSERTION",
        "licenseDeclared": "BSD-3-Clause",
        "copyrightText": "NOASSERTION",
        "primaryPackagePurpose": "LIBRARY",
        "summary": "Direct Python runtime dependency declared by relay/requirements.txt.",
        "externalRefs": [
            {
                "referenceCategory": "PACKAGE-MANAGER",
                "referenceType": "purl",
                "referenceLocator": "pkg:pypi/websockets",
            }
        ],
    },
]


def included_files() -> list[Path]:
    files: list[Path] = []
    for path in ROOT.rglob("*"):
        if (
            not path.is_file()
            or path.name in EXCLUDED_NAMES
            or path.suffix == ".pyc"
            or any(part in EXCLUDED_PARTS for part in path.parts)
        ):
            continue
        files.append(path)
    return sorted(files, key=lambda path: path.relative_to(ROOT).as_posix())


def digest(path: Path, algorithm: str) -> str:
    hasher = hashlib.new(algorithm)
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            hasher.update(chunk)
    return hasher.hexdigest()


def validate_relay_requirements() -> None:
    requirements_path = ROOT / "relay" / "requirements.txt"
    declared: dict[str, str] = {}
    for raw_line in requirements_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if ">=" not in line:
            raise SystemExit(f"unsupported relay requirement syntax: {line}")
        name, constraint = line.split(">=", 1)
        declared[name] = f">={constraint}"
    if declared != RELAY_REQUIREMENTS:
        raise SystemExit(
            "relay dependency metadata is stale: "
            f"expected {RELAY_REQUIREMENTS!r}, found {declared!r}"
        )


def main() -> None:
    validate_relay_requirements()
    files = included_files()
    file_entries = []
    verification_hashes: list[str] = []
    relationships = []

    for index, path in enumerate(files, start=1):
        relative = path.relative_to(ROOT).as_posix()
        spdx_id = f"SPDXRef-File-{index}"
        sha1 = digest(path, "sha1")
        sha256 = digest(path, "sha256")
        verification_hashes.append(sha1)
        file_entries.append(
            {
                "SPDXID": spdx_id,
                "fileName": f"./{relative}",
                "checksums": [
                    {"algorithm": "SHA1", "checksumValue": sha1},
                    {"algorithm": "SHA256", "checksumValue": sha256},
                ],
                "licenseConcluded": "NOASSERTION",
                "copyrightText": "NOASSERTION",
            }
        )
        relationships.append(
            {
                "spdxElementId": "SPDXRef-Package-HermesCapture",
                "relationshipType": "CONTAINS",
                "relatedSpdxElement": spdx_id,
            }
        )

    verification_code = hashlib.sha1("".join(sorted(verification_hashes)).encode()).hexdigest()
    namespace_material = "\n".join(
        f'{entry["fileName"]}:{entry["checksums"][1]["checksumValue"]}'
        for entry in file_entries
    )
    namespace_seed = hashlib.sha256(namespace_material.encode()).hexdigest()[:24]
    dependency_relationships = [
        {
            "spdxElementId": "SPDXRef-Package-HermesCapture",
            "relationshipType": "DEPENDS_ON",
            "relatedSpdxElement": "SPDXRef-Package-PythonRuntime",
            "comment": "Runtime dependency of the optional relay service.",
        },
        {
            "spdxElementId": "SPDXRef-Package-HermesCapture",
            "relationshipType": "DEPENDS_ON",
            "relatedSpdxElement": "SPDXRef-Package-Cryptography",
            "comment": "Direct relay dependency from relay/requirements.txt.",
        },
        {
            "spdxElementId": "SPDXRef-Package-HermesCapture",
            "relationshipType": "DEPENDS_ON",
            "relatedSpdxElement": "SPDXRef-Package-Websockets",
            "comment": "Direct relay dependency from relay/requirements.txt.",
        },
    ]
    document = {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": "Oriel-1.0-source",
        "documentNamespace": f"https://67enterprise.com/spdx/oriel/1.0/{namespace_seed}",
        "creationInfo": {
            "created": "2026-07-13T00:00:00Z",
            "creators": ["Tool: Oriel-SBOM-Generator/1.1"],
        },
        "documentDescribes": ["SPDXRef-Package-HermesCapture"],
        "packages": [
            {
                "SPDXID": "SPDXRef-Package-HermesCapture",
                "name": "Oriel",
                "versionInfo": "1.0",
                "downloadLocation": "NOASSERTION",
                "filesAnalyzed": True,
                "packageVerificationCode": {
                    "packageVerificationCodeValue": verification_code
                },
                "licenseConcluded": "LicenseRef-Proprietary",
                "licenseDeclared": "LicenseRef-Proprietary",
                "copyrightText": "Copyright 2026 67 Enterprise",
                "externalRefs": [],
            }
        ]
        + DEPENDENCY_PACKAGES,
        "files": file_entries,
        "relationships": relationships + dependency_relationships,
        "hasExtractedLicensingInfos": [
            {
                "licenseId": "LicenseRef-Proprietary",
                "extractedText": "Proprietary. See LICENSE.",
                "name": "HermesCapture Proprietary License",
            }
        ],
    }

    OUTPUT.parent.mkdir(parents=True, exist_ok=True)
    OUTPUT.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")
    print(f"wrote {OUTPUT} with {len(files)} files and {len(document['packages'])} packages")


if __name__ == "__main__":
    main()
