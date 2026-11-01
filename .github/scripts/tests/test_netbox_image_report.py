"""The report script's fail sides, on stub reports (platform issue 250).

python3 -I -m unittest discover -s .github/scripts/tests
"""

import contextlib
import importlib.util
import io
import json
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "netbox-image-report.py"
spec = importlib.util.spec_from_file_location("netbox_image_report", SCRIPT)
report_script = importlib.util.module_from_spec(spec)
spec.loader.exec_module(report_script)

PIN = "sha256:" + "a" * 64
OTHER = "sha256:" + "b" * 64
NETBOX = [{"Name": "Django"}, {"Name": "djangorestframework"}, {"Name": "pillow"}]


def vulnerability(severity, fixed=""):
    return {
        "VulnerabilityID": "CVE-2026-0001",
        "PkgName": "django",
        "InstalledVersion": "5.2.1",
        "FixedVersion": fixed,
        "Severity": severity,
    }


def report(image=PIN, packages=NETBOX, vulnerabilities=None):
    python = {"Target": "Python", "Packages": packages}
    if vulnerabilities is not None:
        python["Vulnerabilities"] = vulnerabilities
    node = {"Target": "Node.js", "Packages": [{"Name": "npm"}]}
    return {"Metadata": {"ImageID": image}, "Results": [python, node]}


def sbom(image=PIN, names=("django", "djangorestframework", "pillow"), fmt="CycloneDX"):
    return {
        "bomFormat": fmt,
        "metadata": {
            "component": {
                "properties": [{"name": "aquasecurity:trivy:ImageID", "value": image}]
            }
        },
        "components": [{"name": name} for name in names],
    }


class Problems(unittest.TestCase):
    def problems(self, found):
        return report_script.problems_and_rows(found, PIN)[0]

    def test_a_clean_report_with_unfixed_findings_passes(self):
        found = report(vulnerabilities=[vulnerability("HIGH"), vulnerability("LOW")])
        self.assertEqual(self.problems(found), [])

    def test_another_image_fails(self):
        found = report(image=OTHER, vulnerabilities=[vulnerability("LOW")])
        self.assertIn(
            f"the scanned image is {OTHER}, the pin {PIN}", self.problems(found)
        )

    def test_an_empty_report_fails(self):
        problems = self.problems({})
        self.assertIn("the scanned image is None, the pin " + PIN, problems)
        self.assertIn("no result carries vulnerability data", problems)

    def test_no_netbox_packages_fails(self):
        found = report(
            packages=[{"Name": "npm"}], vulnerabilities=[vulnerability("LOW")]
        )
        self.assertIn(
            "the scan lists none of django, djangorestframework, pillow",
            self.problems(found),
        )

    def test_a_fixed_high_fails(self):
        found = report(vulnerabilities=[vulnerability("HIGH", "5.2.2")])
        self.assertEqual(
            self.problems(found), ["1 critical or high with a fixed version"]
        )

    def test_a_fixed_critical_fails(self):
        found = report(vulnerabilities=[vulnerability("CRITICAL", "5.2.2")])
        self.assertEqual(
            self.problems(found), ["1 critical or high with a fixed version"]
        )

    def test_a_fixed_medium_passes(self):
        found = report(vulnerabilities=[vulnerability("MEDIUM", "5.2.2")])
        self.assertEqual(self.problems(found), [])

    def test_packages_without_vulnerability_data_fail(self):
        self.assertEqual(
            self.problems(report()), ["no result carries vulnerability data"]
        )


class Sbom(unittest.TestCase):
    def test_the_pinned_image_with_netbox_packages_passes(self):
        self.assertEqual(report_script.sbom_problems(sbom(), PIN), [])

    def test_another_format_fails(self):
        self.assertEqual(
            report_script.sbom_problems(sbom(fmt="SPDX"), PIN),
            ["the SBOM is not CycloneDX"],
        )

    def test_another_image_fails(self):
        self.assertEqual(
            report_script.sbom_problems(sbom(image=OTHER), PIN),
            [f"the SBOM names the image ['{OTHER}'], the pin {PIN}"],
        )

    def test_no_image_fails(self):
        found = sbom()
        found["metadata"] = {}
        self.assertEqual(
            report_script.sbom_problems(found, PIN),
            [f"the SBOM names the image [], the pin {PIN}"],
        )

    def test_missing_netbox_packages_fail(self):
        self.assertEqual(
            report_script.sbom_problems(sbom(names=("django",)), PIN),
            ["the SBOM lists none of djangorestframework, pillow"],
        )


class Main(unittest.TestCase):
    def run_main(self, *documents):
        with tempfile.TemporaryDirectory() as tmp:
            paths = []
            for i, document in enumerate(documents):
                path = Path(tmp) / f"{i}.json"
                path.write_text(json.dumps(document))
                paths.append(str(path))
            argv = ["netbox-image-report.py", paths[0], PIN, *paths[1:]]
            out = io.StringIO()
            old = sys.argv
            sys.argv = argv
            try:
                with contextlib.redirect_stdout(out):
                    code = report_script.main()
            finally:
                sys.argv = old
        return code, out.getvalue()

    def test_a_good_report_and_sbom_exit_0(self):
        code, out = self.run_main(
            report(vulnerabilities=[vulnerability("LOW")]), sbom()
        )
        self.assertEqual(code, 0)
        self.assertNotIn("::error::", out)

    def test_a_bad_sbom_exits_1(self):
        code, out = self.run_main(
            report(vulnerabilities=[vulnerability("LOW")]), sbom(image=OTHER)
        )
        self.assertEqual(code, 1)
        self.assertIn("::error::the SBOM names the image", out)

    def test_no_vulnerability_data_exits_1(self):
        code, out = self.run_main(report())
        self.assertEqual(code, 1)
        self.assertIn("::error::no result carries vulnerability data", out)

    def test_a_call_without_both_files_exits_2(self):
        old = sys.argv
        sys.argv = ["netbox-image-report.py", "report.json"]
        try:
            with contextlib.redirect_stderr(io.StringIO()):
                self.assertEqual(report_script.main(), 2)
        finally:
            sys.argv = old


if __name__ == "__main__":
    unittest.main()
