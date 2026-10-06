#!/usr/bin/env python3
"""Fail-closed validation for the resolved Oriel relay image SPDX SBOM."""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from typing import Any
from urllib.parse import unquote


_SHA256 = re.compile(r"^[0-9a-f]{64}$")
_UNRESOLVED_VERSIONS = {"", "NOASSERTION", "NONE", "UNKNOWN"}
APPROVED_PYTHON_312_SLIM_DIGEST = (
    "423ed6ab25b1921a477529254bfeeabf5855151dc2c3141699a1bfc852199fbf"
)


def uses_approved_python_base(dockerfile: str) -> bool:
    """Require the single reviewed immutable Python base, not any digest-shaped value."""
    from_lines = [
        line.strip()
        for line in dockerfile.splitlines()
        if line.strip().upper().startswith("FROM ")
    ]
    expected = f"FROM python:3.12-slim@sha256:{APPROVED_PYTHON_312_SLIM_DIGEST}"
    return from_lines == [expected]


@dataclass(frozen=True)
class ImageSbomValidation:
    valid: bool
    errors: tuple[str, ...]
    image_digest: str | None = None
    package_count: int = 0
    os_package_count: int = 0
    resolved_packages: dict[str, str] = field(default_factory=dict)


def _purls(package: dict[str, Any]) -> list[str]:
    refs = package.get("externalRefs")
    if not isinstance(refs, list):
        return []
    return [
        ref.get("referenceLocator", "")
        for ref in refs
        if isinstance(ref, dict)
        and ref.get("referenceCategory") == "PACKAGE-MANAGER"
        and ref.get("referenceType") == "purl"
        and isinstance(ref.get("referenceLocator"), str)
    ]


def _resolved_version(package: dict[str, Any]) -> str | None:
    version = package.get("versionInfo")
    if not isinstance(version, str) or version.strip().upper() in _UNRESOLVED_VERSIONS:
        return None
    return version.strip()


def _purl_records_version(purl: str, prefix: str, version: str) -> bool:
    decoded = unquote(purl)
    expected = f"{prefix}{version}"
    return decoded == expected or decoded.startswith(f"{expected}?") or decoded.startswith(f"{expected}#")


def _purl_has_resolved_version(
    purl: str,
    package_type: str,
    package_name: str,
    version: str,
) -> bool:
    decoded = unquote(purl)
    package, separator, remainder = decoded.partition("@")
    recorded_version = re.split(r"[?#]", remainder, maxsplit=1)[0]
    package_path = package.removeprefix(f"pkg:{package_type}/")
    recorded_name = package_path.rsplit("/", maxsplit=1)[-1]
    return (
        package.startswith(f"pkg:{package_type}/")
        and recorded_name == package_name
        and bool(separator)
        and recorded_version == version
    )


def validate_image_sbom(document: object) -> ImageSbomValidation:
    """Validate Syft SPDX structure, image identity, and resolved runtime inventory."""
    errors: list[str] = []
    if not isinstance(document, dict):
        return ImageSbomValidation(False, ("image SBOM root must be an object",))

    if document.get("spdxVersion") != "SPDX-2.3":
        errors.append("image SBOM must use SPDX-2.3")
    if document.get("dataLicense") != "CC0-1.0" or document.get("SPDXID") != "SPDXRef-DOCUMENT":
        errors.append("image SBOM has invalid SPDX document identity")
    if document.get("name") != "oriel-relay":
        errors.append("image SBOM must describe oriel-relay")

    creation_info = document.get("creationInfo")
    creators = creation_info.get("creators", []) if isinstance(creation_info, dict) else []
    if not isinstance(creators, list) or not any(
        isinstance(creator, str) and creator.lower().startswith("tool: syft-")
        for creator in creators
    ):
        errors.append("image SBOM must identify the Syft generator version")

    raw_packages = document.get("packages")
    if not isinstance(raw_packages, list) or not raw_packages:
        errors.append("image SBOM packages must be a non-empty list")
        packages: list[dict[str, Any]] = []
    else:
        packages = [package for package in raw_packages if isinstance(package, dict)]
        if len(packages) != len(raw_packages):
            errors.append("every image SBOM package must be an object")

    raw_relationships = document.get("relationships")
    if not isinstance(raw_relationships, list):
        errors.append("image SBOM relationships must be a list")
        relationships: list[dict[str, Any]] = []
    else:
        relationships = [item for item in raw_relationships if isinstance(item, dict)]
        if len(relationships) != len(raw_relationships):
            errors.append("every image SBOM relationship must be an object")

    roots = [
        package
        for package in packages
        if package.get("name") == "oriel-relay"
        and package.get("primaryPackagePurpose") == "CONTAINER"
    ]
    root = roots[0] if len(roots) == 1 else None
    if root is None:
        errors.append("image SBOM must contain exactly one oriel-relay container package")

    image_digest: str | None = None
    contained_ids: set[str] = set()
    if root is not None:
        root_id = root.get("SPDXID")
        if not isinstance(root_id, str) or not root_id.startswith("SPDXRef-"):
            errors.append("image container package must have an SPDXID")
        else:
            if not any(
                relationship.get("spdxElementId") == "SPDXRef-DOCUMENT"
                and relationship.get("relationshipType") == "DESCRIBES"
                and relationship.get("relatedSpdxElement") == root_id
                for relationship in relationships
            ):
                errors.append("SPDX document must DESCRIBE the image container package")
            contained_ids = {
                relationship.get("relatedSpdxElement")
                for relationship in relationships
                if relationship.get("spdxElementId") == root_id
                and relationship.get("relationshipType") == "CONTAINS"
                and isinstance(relationship.get("relatedSpdxElement"), str)
            }

        checksums = root.get("checksums")
        digest_values = [
            checksum.get("checksumValue", "")
            for checksum in checksums
            if isinstance(checksum, dict) and checksum.get("algorithm") == "SHA256"
        ] if isinstance(checksums, list) else []
        digest = digest_values[0] if len(digest_values) == 1 else ""
        if not isinstance(digest, str) or not _SHA256.fullmatch(digest):
            errors.append("image container package must have one lowercase SHA256 image digest")
        else:
            image_digest = f"sha256:{digest}"
            decoded_purls = [unquote(purl) for purl in _purls(root)]
            expected_image_purl = f"pkg:oci/oriel-relay@sha256:{digest}"
            valid_image_purls = {
                expected_image_purl,
                f"{expected_image_purl}?arch=amd64&tag=verified",
                f"{expected_image_purl}?arch=arm64&tag=verified",
            }
            if not any(purl in valid_image_purls for purl in decoded_purls):
                errors.append("image purl must record the same exact image digest as its checksum")

    packages_by_id = {
        package.get("SPDXID"): package
        for package in packages
        if isinstance(package.get("SPDXID"), str)
    }
    contained_packages = [
        packages_by_id[spdx_id]
        for spdx_id in contained_ids
        if spdx_id in packages_by_id
    ]
    resolved_packages: dict[str, str] = {}

    def require_package(name: str, purl_prefix: str, label: str) -> None:
        candidates = [
            package
            for package in contained_packages
            if package.get("name") == name
            and (version := _resolved_version(package))
            and any(
                _purl_records_version(purl, purl_prefix, version)
                for purl in _purls(package)
            )
        ]
        versions = [version for package in candidates if (version := _resolved_version(package))]
        if len(versions) != 1:
            errors.append(f"image SBOM must contain one resolved {label}")
        else:
            resolved_packages[name] = versions[0]

    require_package("python", "pkg:generic/python@", "Python runtime")
    require_package("cryptography", "pkg:pypi/cryptography@", "PyPI package cryptography")
    require_package("websockets", "pkg:pypi/websockets@", "PyPI package websockets")

    os_packages = [
        package
        for package in contained_packages
        if (version := _resolved_version(package))
        and any(
            _purl_has_resolved_version(purl, "deb", str(package.get("name", "")), version)
            for purl in _purls(package)
        )
    ]
    if not os_packages:
        errors.append("image SBOM must contain at least one resolved OS package")

    return ImageSbomValidation(
        valid=not errors,
        errors=tuple(errors),
        image_digest=image_digest,
        package_count=len(packages),
        os_package_count=len(os_packages),
        resolved_packages=resolved_packages,
    )
