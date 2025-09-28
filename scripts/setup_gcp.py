#!/usr/bin/env python3
"""Simple GCP bootstrap helper for oak-disperser.

Creates (or reuses) a GCP project, links billing, enables the required Google
Cloud services, provisions the Pub/Sub topic and CI service account, and
(optionally) uploads GitHub Actions secrets using the gh CLI.
"""
from __future__ import annotations

import argparse
import json
import os
import pathlib
import re
import shlex
import subprocess
import sys
import textwrap\nimport time
from typing import List, Optional

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_REGION = "us-central1"
DEFAULT_TOPIC = "action-dispersal"
DEFAULT_SA_ID = "oak-disperser-ci"
DEFAULT_SA_NAME = "Oak Disperser CI"

GCLOUD = os.environ.get("GCLOUD_BIN", "gcloud")
GH = os.environ.get("GH_BIN", "gh")
RUN_GH_SCRIPT = REPO_ROOT / "scripts" / "run-gh.ps1"


def run(cmd: List[str], *, capture: bool = False, check: bool = True) -> subprocess.CompletedProcess:
    """Run a subprocess command."""
    kwargs = {"text": True}
    if capture:
        kwargs["stdout"] = subprocess.PIPE
        kwargs["stderr"] = subprocess.PIPE
    print(f"--> {' '.join(shlex.quote(part) for part in cmd)}")
    result = subprocess.run(cmd, **kwargs)
    if check and result.returncode != 0:
        raise RuntimeError(result.stderr.strip() if capture else f"Command failed: {' '.join(cmd)}")
    return result


def repo_base_name() -> str:
    """Derive a sensible base name from the git repository or folder."""
    try:
        result = run(["git", "rev-parse", "--show-toplevel"], capture=True, check=True)
        return pathlib.Path(result.stdout.strip()).name
    except Exception:
        return REPO_ROOT.name


def sanitize_base(value: str) -> str:
    cleaned = re.sub(r"[^a-z0-9-]+", "-", value.lower()).strip("-")
    cleaned = re.sub(r"-+", "-", cleaned)
    return cleaned or "oak-disperser"


def generate_project_id(base_name: str) -> str:
    sanitized = sanitize_base(base_name)
    if len(sanitized) < 6:
        sanitized = (sanitized + "oak")[:10]
    if not sanitized.endswith("-oak-disperser"):
        sanitized = f"{sanitized}-oak-disperser"
    project_id = sanitized[:30]
    suffix = 1
    while project_exists(project_id):
        candidate = f"{sanitized[:30-len(str(suffix))-1]}-{suffix}"
        project_id = candidate
        suffix += 1
    return project_id


def project_exists(project_id: str) -> bool:
    result = subprocess.run([GCLOUD, "projects", "describe", project_id, "--format=value(projectId)", "--quiet"],
                            stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
    return result.returncode == 0


def select_billing_account(force_id: Optional[str]) -> Optional[str]:
    if force_id:
        return force_id

    print("Retrieving billing accounts…")
    try:
        result = run([GCLOUD, "billing", "accounts", "list", "--format=json", "--quiet"], capture=True)
        accounts = json.loads(result.stdout)
    except Exception as exc:
        print(f"Warning: unable to list billing accounts ({exc}).")
        return None

    if not accounts:
        print("Warning: no billing accounts available.")
        return None

    def account_id(entry: dict) -> Optional[str]:
        if entry.get("accountId"):
            return entry["accountId"]
        if entry.get("name"):
            return entry["name"].split("/")[-1]
        return None

    open_accounts = [acc for acc in accounts if acc.get("open")]
    if not open_accounts:
        open_accounts = accounts

    if len(open_accounts) == 1:
        acc = open_accounts[0]
        acc_id = account_id(acc)
        if acc_id:
            print(f"Using billing account {acc.get('displayName')} ({acc_id})")
            return acc_id
        return None

    print("Select a billing account:")
    for idx, acc in enumerate(open_accounts, start=1):
        acc_id = account_id(acc)
        print(f"[{idx}] {acc.get('displayName')} ({acc_id})")

    while True:
        choice = input("Enter a number or press Enter to skip: ").strip()
        if not choice:
            print("Skipping billing linkage.")
            return None
        if choice.isdigit():
            index = int(choice) - 1
            if 0 <= index < len(open_accounts):
                return account_id(open_accounts[index])
        print("Invalid selection; please try again.")


def link_billing(project_id: str, billing_id: str) -> None:
    if not billing_id:
        return
    run([GCLOUD, "beta", "billing", "projects", "link", project_id, "--billing-account", billing_id, "--quiet"])


def create_project(project_id: str, display_name: str) -> None:
    run([GCLOUD, "projects", "create", project_id, "--name", display_name, "--quiet"])
    # allow propagation
    time.sleep(5)


def enable_services(project_id: str, services: List[str]) -> None:
    for service in services:
        run([GCLOUD, "services", "enable", service, "--project", project_id, "--quiet"])


def ensure_topic(project_id: str, topic: str) -> None:
    exists = subprocess.run([GCLOUD, "pubsub", "topics", "describe", topic, "--project", project_id,
                              "--format=value(name)", "--quiet"],
                             stdout=subprocess.DEVNULL,
                             stderr=subprocess.DEVNULL)
    if exists.returncode == 0:
        return
    run([GCLOUD, "pubsub", "topics", "create", topic, "--project", project_id, "--quiet"])


def ensure_service_account(project_id: str, account_id: str, display_name: str) -> str:
    email = f"{account_id}@{project_id}.iam.gserviceaccount.com"
    exists = subprocess.run([GCLOUD, "iam", "service-accounts", "describe", email, "--project", project_id,
                              "--quiet"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if exists.returncode != 0:
        run([GCLOUD, "iam", "service-accounts", "create", account_id,
             "--display-name", display_name, "--project", project_id, "--quiet"])
    return email


def grant_service_account_roles(project_id: str, email: str) -> None:
    roles = [
        "roles/cloudfunctions.developer",
        "roles/iam.serviceAccountUser",
        "roles/pubsub.admin",
        "roles/secretmanager.secretAccessor",
    ]
    for role in roles:
        run([GCLOUD, "projects", "add-iam-policy-binding", project_id,
             "--member", f"serviceAccount:{email}", "--role", role, "--quiet"])


def create_service_account_key(email: str, project_id: str, output_path: pathlib.Path) -> pathlib.Path:
    if output_path.exists():
        raise RuntimeError(f"Refusing to overwrite existing key: {output_path}")
    run([GCLOUD, "iam", "service-accounts", "keys", "create", str(output_path),
         "--iam-account", email, "--project", project_id, "--quiet"])
    return output_path


def configure_github_secrets(project_id: str, region: str, topic: str, key_path: Optional[pathlib.Path]) -> None:
    if not RUN_GH_SCRIPT.exists():
        raise RuntimeError("scripts/run-gh.ps1 is required to set secrets via gh")
    secrets = {
        "GCP_PROJECT": project_id,
        "GCP_REGION": region,
        "PUBSUB_TOPIC": topic,
    }
    if key_path:
        secrets["GCP_SA_KEY"] = key_path.read_text()
    optional = {
        "INGEST_API_KEY": input("Optional INGEST_API_KEY (leave blank to skip): "),
        "ALLOWED_AUDIENCE": input("Optional ALLOWED_AUDIENCE (leave blank to skip): "),
        "ALLOWED_ISSUERS": input("Optional ALLOWED_ISSUERS (comma separated, leave blank to skip): "),
    }

    for name, value in secrets.items():
        run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(RUN_GH_SCRIPT),
             "secret", "set", name, "--body", value])

    for name, value in optional.items():
        if value.strip():
            run(["powershell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", str(RUN_GH_SCRIPT),
                 "secret", "set", name, "--body", value.strip()])


def format_display_name(project_id: str) -> str:
    safe = re.sub(r"[^a-zA-Z0-9 -]", " ", project_id).strip()
    safe = re.sub(r"\s+", " ", safe)
    label = f"Oak Disperser - {safe}" if safe else "Oak Disperser"
    return label[:30]


def parse_args(argv: List[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Bootstrap GCP resources for oak-disperser", formatter_class=argparse.ArgumentDefaultsHelpFormatter)
    parser.add_argument("--project-id")
    parser.add_argument("--base-name")
    parser.add_argument("--region", default=DEFAULT_REGION)
    parser.add_argument("--topic", default=DEFAULT_TOPIC)
    parser.add_argument("--service-account-id", default=DEFAULT_SA_ID)
    parser.add_argument("--service-account-name", default=DEFAULT_SA_NAME)
    parser.add_argument("--billing-account")
    parser.add_argument("--key-output", type=pathlib.Path)
    parser.add_argument("--configure-github", action="store_true")
    parser.add_argument("--dry-run", action="store_true")
    return parser.parse_args(argv)


def main(argv: List[str]) -> int:
    args = parse_args(argv)

    base_name = args.base_name or sanitize_base(repo_base_name())
    if not args.project_id:
        project_id = generate_project_id(base_name)
    else:
        project_id = args.project_id
        if not project_exists(project_id):
            create_project(project_id, format_display_name(project_id))
    print(f"Project ID: {project_id}")

    billing_id = select_billing_account(args.billing_account)
    if billing_id:
        link_billing(project_id, billing_id)

    if not project_exists(project_id):
        create_project(project_id, format_display_name(base_name))

    services = [
        "cloudfunctions.googleapis.com",
        "pubsub.googleapis.com",
        "secretmanager.googleapis.com",
    ]
    enable_services(project_id, services)

    ensure_topic(project_id, args.topic)
    sa_email = ensure_service_account(project_id, args.service_account_id, args.service_account_name)
    grant_service_account_roles(project_id, sa_email)

    key_path = None
    if not args.dry_run:
        key_path = args.key_output or REPO_ROOT / "gcp-service-account-key.json"
        key_path = key_path.resolve()
        key_path.parent.mkdir(parents=True, exist_ok=True)
        key_path = create_service_account_key(sa_email, project_id, key_path)
        print(f"Service account key written to {key_path}")

    if args.configure_github:
        configure_github_secrets(project_id, args.region, args.topic, key_path)

    print("GCP bootstrap complete.")
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv[1:]))
    except KeyboardInterrupt:
        print("Aborted by user.")
        sys.exit(1)
    except Exception as exc:
        print(f"Error: {exc}", file=sys.stderr)
        sys.exit(1)
