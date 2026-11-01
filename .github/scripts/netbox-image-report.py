"""Judge Trivy's JSON report on the pinned NetBox image (platform issue 247).

Usage: netbox-image-report.py REPORT IMAGE_ID [SBOM]

Fails when the scanned image is not the pinned one, when the scan saw none of
NetBox's own Python packages, or when a critical or high vulnerability has a
fixed version, since moving the pin avoids it. Unfixed ones are listed and do
not fail the job: no pin move avoids them, and each needs its own reading.

Trivy leaves out a result's Vulnerabilities when it found none, so a report
with no vulnerability data at all reads like a clean image. Every NetBox pin
scanned so far had findings, so such a report fails too (platform issue 250).
A clean image would fail the same way, and gets a reading before the check
is changed for it.

With SBOM, the CycloneDX file of a scan of the same digest has to name the
pinned image and list NetBox's own packages, as the report does.
"""

import json
import os
import sys

FAILING = ("CRITICAL", "HIGH")
# NetBox's own pins. A scan that lists none of them did not read the image's
# Python packages, and an empty list must not pass as a clean image.
NETBOX_PACKAGES = {"django", "djangorestframework", "pillow"}


def problems_and_rows(report, image_id):
    problems = []
    scanned = (report.get("Metadata") or {}).get("ImageID")
    if scanned != image_id:
        problems.append(f"the scanned image is {scanned}, the pin {image_id}")
    names = set()
    counts = {}
    rows = []
    for result in report.get("Results") or []:
        for package in result.get("Packages") or []:
            names.add(str(package.get("Name", "")).lower())
        for vulnerability in result.get("Vulnerabilities") or []:
            severity = vulnerability.get("Severity", "UNKNOWN")
            fixed = vulnerability.get("FixedVersion") or ""
            key = (severity, "fixed" if fixed else "unfixed")
            counts[key] = counts.get(key, 0) + 1
            if severity in FAILING:
                rows.append(
                    (
                        severity,
                        vulnerability.get("VulnerabilityID", "?"),
                        vulnerability.get("PkgName", "?"),
                        vulnerability.get("InstalledVersion", "?"),
                        fixed or "none",
                        result.get("Target", "?"),
                    )
                )
    missing = sorted(NETBOX_PACKAGES - names)
    if missing:
        problems.append("the scan lists none of " + ", ".join(missing))
    if not any(result.get("Vulnerabilities") for result in report.get("Results") or []):
        problems.append("no result carries vulnerability data")
    failing = [row for row in rows if row[4] != "none"]
    if failing:
        problems.append(f"{len(failing)} critical or high with a fixed version")
    return problems, counts, sorted(rows), len(names)


def sbom_problems(sbom, image_id):
    if sbom.get("bomFormat") != "CycloneDX":
        return ["the SBOM is not CycloneDX"]
    problems = []
    component = (sbom.get("metadata") or {}).get("component") or {}
    ids = [
        p.get("value")
        for p in component.get("properties") or []
        if p.get("name") == "aquasecurity:trivy:ImageID"
    ]
    if ids != [image_id]:
        problems.append(f"the SBOM names the image {ids}, the pin {image_id}")
    names = {str(c.get("name", "")).lower() for c in sbom.get("components") or []}
    missing = sorted(NETBOX_PACKAGES - names)
    if missing:
        problems.append("the SBOM lists none of " + ", ".join(missing))
    return problems


def main():
    if len(sys.argv) not in (3, 4):
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    with open(sys.argv[1], encoding="utf-8") as handle:
        report = json.load(handle)
    problems, counts, rows, packages = problems_and_rows(report, sys.argv[2])
    if len(sys.argv) == 4:
        with open(sys.argv[3], encoding="utf-8") as handle:
            problems += sbom_problems(json.load(handle), sys.argv[2])
    scanned = (report.get("Metadata") or {}).get("ImageID")
    lines = [
        f"Image {scanned}, {packages} packages",
        "",
        "| Severity | Fixed | Unfixed |",
        "| --- | --- | --- |",
    ]
    for severity in ("CRITICAL", "HIGH", "MEDIUM", "LOW", "UNKNOWN"):
        fixed = counts.get((severity, "fixed"), 0)
        unfixed = counts.get((severity, "unfixed"), 0)
        lines.append(f"| {severity} | {fixed} | {unfixed} |")
    lines += ["", "| Severity | ID | Package | Installed | Fixed in | Target |"]
    lines.append("| --- | --- | --- | --- | --- | --- |")
    lines += ["| " + " | ".join(row) + " |" for row in rows]
    text = "\n".join(lines) + "\n"
    print(text)
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as handle:
            handle.write("## NetBox image scan\n\n" + text)
    for problem in problems:
        print(f"::error::{problem}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
