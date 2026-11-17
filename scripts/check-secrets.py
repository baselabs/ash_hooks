#!/usr/bin/env python3
"""Scan CI event ranges with the repository rules and the installed gitleaks."""

import argparse
import json
import os
from pathlib import Path
import re
import secrets
import subprocess
import tempfile


def git(repo, *args):
    return subprocess.check_output(
        ["git", "-c", "core.hooksPath=/dev/null", "-c", "commit.gpgSign=false",
         "-c", "user.name=Secret scan proof", "-c", "user.email=scan@example.invalid",
         "-C", str(repo), *args], text=True
    ).strip()


def commit(repo, message):
    git(repo, "add", "--all")
    git(repo, "commit", "--quiet", "-m", message)
    return git(repo, "rev-parse", "HEAD")


def object_id(value):
    if not isinstance(value, str) or not re.fullmatch(r"(?:[0-9a-f]{40}|[0-9a-f]{64})", value):
        raise ValueError("event must supply a full commit object ID")
    return value


def event_range(repo, event_name, event):
    if event_name == "pull_request":
        pr = event["pull_request"]
        base = object_id(pr["base"]["sha"])
        head = object_id(pr["head"]["sha"])
        git(repo, "rev-parse", "--verify", base + "^{commit}")
        git(repo, "rev-parse", "--verify", head + "^{commit}")
        return base + ".." + head
    if event_name == "push":
        head = object_id(event["after"])
        if set(head) == {"0"}:
            return None  # A deleted ref introduces no commits.
        git(repo, "rev-parse", "--verify", head + "^{commit}")
        before = object_id(event["before"])
        if set(before) != {"0"}:
            ancestor = subprocess.run(
                ["git", "-C", str(repo), "merge-base", "--is-ancestor", before, head],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
            if ancestor.returncode == 0:
                return before + ".." + head
        # New branches, first pushes or unavailable/non-ancestor old tips:
        # scan all reachable commits, never guess HEAD^ or omit older additions.
        return head
    return git(repo, "rev-parse", "HEAD")


def validate_ignores(ignore):
    for number, line in enumerate(ignore.read_text().splitlines(), 1):
        entry = line.strip()
        if not entry or entry.startswith("#"):
            continue
        if not re.fullmatch(r"(?:[0-9a-f]{40,64}:)?[^:]+:[a-z0-9-]+:[1-9][0-9]*", entry):
            raise ValueError(f"invalid gitleaks fingerprint at {ignore}:{number}")


def scan(repo, revision, rules):
    validate_ignores(rules / ".gitleaksignore")
    env = dict(os.environ)
    env.pop("GITLEAKS_CONFIG", None)
    env.pop("GITLEAKS_CONFIG_TOML", None)
    with tempfile.TemporaryDirectory(prefix="gitleaks-report-") as work:
        report = Path(work) / "findings.json"
        # -m includes each merge's diff against its parents. --root includes
        # the initial commit; an explicit revision avoids scanning other refs.
        log_opts = "--full-history --root -m --no-ext-diff --no-textconv " + revision + " --"
        result = subprocess.run(
            ["gitleaks", "git", "--no-banner", "--redact", "--exit-code=1",
             "--config", str(rules / ".gitleaks.toml"),
             "--gitleaks-ignore-path", str(rules / ".gitleaksignore"),
             "--report-format=json", "--report-path", str(report),
             "--log-opts=" + log_opts, str(repo)], env=env
        )
        findings = json.loads(report.read_text()) if report.exists() else []
        return result.returncode, findings


def self_test(rules):
    with tempfile.TemporaryDirectory(prefix="gitleaks-proof-") as work:
        repo = Path(work)
        git(repo, "init", "--quiet", "--initial-branch=main")
        (repo / "README").write_text("A clean repository.\n")
        base = commit(repo, "clean root")
        status, findings = scan(repo, base, rules)
        assert status == 0 and not findings, "clean repository must pass"
        print("W26 GREEN: the production invocation accepts a clean repository", flush=True)

        # Assemble a deliberately synthetic matching token only at runtime.
        # It is committed only inside this disposable repository, never here.
        token = "gh" + "p_" + secrets.token_hex(18)
        (repo / "token.txt").write_text(token + "\n")
        introduced = commit(repo, "runtime synthetic scanner probe")
        (repo / "token.txt").unlink()
        head = commit(repo, "remove runtime probe")

        events = {
            "push range": ("push", {"before": base, "after": head}),
            "first push or new branch": ("push", {"before": "0" * 40, "after": head}),
            "PR range": ("pull_request", {"pull_request": {
                "base": {"sha": base}, "head": {"sha": head}}}),
        }
        for label, (event_name, event) in events.items():
            revision = event_range(repo, event_name, event)
            status, findings = scan(repo, revision, rules)
            assert status == 1 and any(
                f["RuleID"] == "github-pat" and f["File"] == "token.txt"
                and f["Commit"] == introduced for f in findings
            ), f"{label} must detect the removed runtime token in the introducing commit"
            print(f"W26 RED: {label} detects a runtime token absent from the final tree", flush=True)

        # A later clean push must exclude the already-scanned history.
        (repo / "README").write_text("Another clean change.\n")
        clean = commit(repo, "clean incremental push")
        revision = event_range(repo, "push", {"before": head, "after": clean})
        assert revision == head + ".." + clean
        status, findings = scan(repo, revision, rules)
        assert status == 0 and not findings, "a clean incremental range must pass"
        assert event_range(repo, "push", {"before": clean, "after": "0" * 40}) is None
        print("W26 GREEN: clean incremental push passes; deleted refs introduce no commits", flush=True)

        # Prove merge-only additions are scanned even when neither parent
        # contains the token. No rewrite or force push is involved.
        git(repo, "checkout", "--quiet", "-b", "side", base)
        (repo / "side.txt").write_text("A clean side branch.\n")
        side = commit(repo, "clean side branch")
        git(repo, "checkout", "--quiet", "main")
        git(repo, "merge", "--quiet", "--no-ff", "--no-commit", "side")
        (repo / "merge-token.txt").write_text(token + "\n")
        merged = commit(repo, "runtime merge-only probe")
        revision = event_range(repo, "push", {"before": clean, "after": merged})
        status, findings = scan(repo, revision, rules)
        assert status == 1 and any(
            f["RuleID"] == "github-pat" and f["File"] == "merge-token.txt"
            and f["Commit"] == merged for f in findings
        ), "merge-only additions must be scanned"
        assert event_range(repo, "push", {"before": side, "after": clean}) == clean
        assert event_range(repo, "push", {"before": "f" * 40, "after": clean}) == clean
        print("W26 RED: merge-only token detected; unavailable or divergent bases scan full history", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("--full-history", action="store_true")
    args = parser.parse_args()
    repo = Path(git(Path.cwd(), "rev-parse", "--show-toplevel"))
    if args.self_test:
        self_test(repo)
        return 0
    if args.full_history:
        if git(repo, "rev-parse", "--is-shallow-repository") != "false":
            raise ValueError("full-history scanning requires fetch-depth: 0")
        revision = "--all"
    else:
        event_path = os.environ.get("GITHUB_EVENT_PATH")
        event = json.loads(Path(event_path).read_text()) if event_path else {}
        revision = event_range(repo, os.environ.get("GITHUB_EVENT_NAME", ""), event)
    if revision is None:
        print("Deleted ref: no introduced commits to scan")
        return 0
    print("Secret scan revision: " + revision, flush=True)
    status, _ = scan(repo, revision, repo)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
