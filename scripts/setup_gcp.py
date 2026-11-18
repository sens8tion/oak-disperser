#!/usr/bin/env python3
"""GCP bootstrap helper for oak-disperser using Terraform-managed resources.

Creates (or reuses) a GCP project, links billing, enables the required Google
Cloud services, provisions the Pub/Sub topic and CI service account through
Terraform, and (optionally) uploads GitHub Actions secrets using the gh CLI.
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
import time
from typing import List, Optional, Sequence, Set

REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_REGION = "us-central1"
DEFAULT_TOPIC = "action-dispersal"
DEFAULT_SA_ID = "oak-disperser-ci"
DEFAULT_SA_NAME = "Oak Disperser CI"

GCLOUD = os.environ.get("GCLOUD_BIN", "gcloud")
TERRAFORM = os.environ.get("TERRAFORM_BIN", "terraform")
RUN_GH_SCRIPT = REPO_ROOT / "scripts" / "run-gh.ps1"
TERRAFORM_DIR = REPO_ROOT / "infra" / "gcp"


def run(cmd: Sequence[str], *, capture: bool = False, check: bool = True) -> subprocess.CompletedProcess:
    """Run a subprocess command, logging the invocation."""
    kwargs: dict[str, object] = {"text": True}
    if capture:
        kwargs["stdout"] = subprocess.PIPE
        kwargs["stderr"] = subprocess.PIPE
    printable = " ".join(shlex.quote(str(part)) for part in cmd)
    print(f"--> {printable}")
    try:
        result = subprocess.run(list(cmd), **kwargs)
    except FileNotFoundError as exc:
        raise RuntimeError(f"Command not found: {cmd[0]}") from exc
    if check and result.returncode != 0:
        message = result.stderr.strip() if capture and result.stderr else f"Command failed: {printable}"
        raise RuntimeError(message)
    return result


def terraform(cmd: Sequence[str], *, capture: bool = False, check: bool = True) -> subprocess.CompletedProcess:
    """Invoke Terraform inside the repository configuration directory."""
    if not TERRAFORM_DIR.exists():
        raise RuntimeError(f"Terraform configuration not found at {TERRAFORM_DIR}")
    tf_cmd = [TERRAFORM, f"-chdir={os.fspath(TERRAFORM_DIR)}", *cmd]
    return run(tf_cmd, capture=capture, check=check)


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
        sanitized = (sanitized + "oakdsp")[:6]
    sanitized = sanitized[:30].rstrip('-') or sanitized[:30]
    project_id = sanitized
    suffix = 1
    while project_exists(project_id):
        suffix_str = str(suffix)
        prefix = sanitized[: max(1, 30 - len(suffix_str) - 1)].rstrip('-')
        if not prefix:
            prefix = sanitized[: max(1, 30 - len(suffix_str) - 1)]
        project_id = f"{prefix}-{suffix}"
        suffix += 1
    return project_id


def project_exists(project_id: str) -> bool:
    result = subprocess.run(
        [
            GCLOUD,
            "projects",
            "describe",
            project_id,
            "--format=value(projectId)",
            "--quiet",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0


def select_billing_account(force_id: Optional[str]) -> Optional[str]:
    if force_id:
        return force_id

    print("Retrieving billing accounts.")
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
    run(
        [
            GCLOUD,
            "beta",
            "billing",
            "projects",
            "link",
            project_id,
            "--billing-account",
            billing_id,
            "--quiet",
        ]
    )


def create_project(project_id: str, display_name: str) -> None:
    if project_exists(project_id):
        print(f"Project {project_id} already exists; reusing.")
        return
    result = run([GCLOUD, "projects", "create", project_id, "--name", display_name, "--quiet"], capture=True, check=False)
    if result.returncode != 0:
        raw_output = (result.stderr or result.stdout or "").strip()
        output = raw_output.lower()
        if "already in use" in output or "already exists" in output:
            if project_exists(project_id):
                print(f"Project {project_id} already exists; reusing.")
                return
            raise RuntimeError(
                f"Project ID {project_id} already exists but is not accessible. Use --recreate-project if you own it or choose a different ID."
            )
        raise RuntimeError(raw_output or f"Failed to create project {project_id}.")
    # allow propagation
    time.sleep(5)


def delete_project(project_id: str) -> None:
    print(f"Deleting existing project {project_id}.")
    result = run([GCLOUD, "projects", "delete", project_id, "--quiet"], capture=True, check=False)
    if result.returncode != 0:
        raw_output = (result.stderr or result.stdout or "").strip()
        output = raw_output.lower()
        benign = any(token in output for token in ("not found", "does not exist"))
        if benign:
            print(f"Project {project_id} not found; nothing to delete.")
            return
        raise RuntimeError(raw_output or f"Failed to delete project {project_id}.")
    for attempt in range(12):
        time.sleep(5)
        if not project_exists(project_id):
            print(f"Project {project_id} deletion confirmed.")
            return
        print(f"Waiting for project {project_id} to be fully deleted...")
    raise RuntimeError(f"Project {project_id} still exists after deletion attempt; retry later.")


def topic_exists(project_id: str, topic: str) -> bool:
    result = subprocess.run(
        [
            GCLOUD,
            "pubsub",
            "topics",
            "describe",
            topic,
            "--project",
            project_id,
            "--format=value(name)",
            "--quiet",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0


def service_account_email(project_id: str, account_id: str) -> str:
    return f"{account_id}@{project_id}.iam.gserviceaccount.com"


def service_account_exists(project_id: str, email: str) -> bool:
    result = subprocess.run(
        [
            GCLOUD,
            "iam",
            "service-accounts",
            "describe",
            email,
            "--project",
            project_id,
            "--quiet",
        ],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    return result.returncode == 0


def terraform_state_list() -> Set[str]:
    result = terraform(["state", "list"], capture=True, check=False)
    if result.returncode != 0 or not result.stdout:
        return set()
    return {line.strip() for line in result.stdout.splitlines() if line.strip()}


def terraform_var_flags(vars_map: dict[str, str]) -> List[str]:
    flags: List[str] = []
    for key, value in vars_map.items():
        flags.extend(["-var", f"{key}={value}"])
    return flags


def terraform_provision(
    project_id: str,
    region: str,
    topic: str,
    account_id: str,
    display_name: str,
    *,
    dry_run: bool,
) -> None:
    terraform(["init", "-upgrade"])
    state_entries = terraform_state_list()

    topic_address = "google_pubsub_topic.topic"
    topic_identifier = f"projects/{project_id}/topics/{topic}"
    if topic_exists(project_id, topic) and topic_address not in state_entries:
        terraform(["import", topic_address, topic_identifier])
        state_entries.add(topic_address)

    sa_address = "google_service_account.ci"
    sa_email_addr = service_account_email(project_id, account_id)
    sa_identifier = f"projects/{project_id}/serviceAccounts/{sa_email_addr}"
    if service_account_exists(project_id, sa_email_addr) and sa_address not in state_entries:
        terraform(["import", sa_address, sa_identifier])
        state_entries.add(sa_address)

    vars_flags = terraform_var_flags(
        {
            "project_id": project_id,
            "region": region,
            "topic_name": topic,
            "service_account_id": account_id,
            "service_account_display_name": display_name,
        }
    )

    if dry_run:
        terraform(["plan", "-input=false", *vars_flags])
    else:
        terraform(["apply", "-input=false", "-auto-approve", *vars_flags])


def terraform_destroy(
    project_id: str,
    region: str,
    topic: str,
    account_id: str,
    display_name: str,
    *,
    dry_run: bool,
) -> None:
    terraform(["init", "-upgrade"])
    vars_flags = terraform_var_flags(
        {
            "project_id": project_id,
            "region": region,
            "topic_name": topic,
            "service_account_id": account_id,
            "service_account_display_name": display_name,
        }
    )
    if dry_run:
        terraform(["plan", "-destroy", "-input=false", *vars_flags])
    else:
        terraform(["destroy", "-input=false", "-auto-approve", *vars_flags])


def create_service_account_key(email: str, project_id: str, output_path: pathlib.Path) -> pathlib.Path:
    if output_path.exists():
        raise RuntimeError(f"Refusing to overwrite existing key: {output_path}")
    run(
        [
            GCLOUD,
            "iam",
            "service-accounts",
            "keys",
            "create",
            str(output_path),
            "--iam-account",
            email,
            "--project",
            project_id,
            "--quiet",
        ]
    )
    return output_path


def configure_github_secrets(
    project_id: str,
    region: str,
    topic: str,
    key_path: Optional[pathlib.Path],
) -> None:
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
        run(
            [
                "powershell",
                "-NoProfile",
                "-ExecutionPolicy",
                "Bypass",
                "-File",
                str(RUN_GH_SCRIPT),
                "secret",
                "set",
                name,
                "--body",
                value,
            ]
        )

    for name, value in optional.items():
        if value.strip():
            run(
                [
                    "powershell",
                    "-NoProfile",
                    "-ExecutionPolicy",
                    "Bypass",
                    "-File",
                    str(RUN_GH_SCRIPT),
                    "secret",
                    "set",
                    name,
                    "--body",
                    value.strip(),
                ]
            )


def format_display_name(name: str) -> str:
    safe = re.sub(r"[^a-zA-Z0-9 -]", " ", name).strip()
    safe = re.sub(r"\s+", " ", safe)
    if not safe:
        safe = "Oak Disperser"
    return safe[:30]


def parse_args(argv: List[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Bootstrap GCP resources for oak-disperser",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
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
    parser.add_argument("--destroy", action="store_true", help="Destroy Terraform-managed resources instead of provisioning")
    parser.add_argument("--recreate-project", action="store_true", help="Delete and recreate the project when it already exists")
    return parser.parse_args(argv)


def main(argv: List[str]) -> int:
    args = parse_args(argv)

    raw_base_name = args.base_name or repo_base_name()
    base_name = sanitize_base(raw_base_name)
    project_id = args.project_id or generate_project_id(base_name)

    if args.destroy:
        if args.configure_github:
            raise RuntimeError("--destroy cannot be combined with --configure-github")
        if args.recreate_project:
            raise RuntimeError("--destroy cannot be combined with --recreate-project")
        if project_exists(project_id):
            terraform_destroy(
                project_id,
                args.region,
                args.topic,
                args.service_account_id,
                args.service_account_name,
                dry_run=args.dry_run,
            )
        else:
            print(f"Project {project_id} not found; nothing to destroy.")
        print("GCP teardown complete.")
        return 0

    if args.recreate_project:
        delete_project(project_id)
    create_project(project_id, format_display_name(raw_base_name))
    print(f"Project ID: {project_id}")

    billing_id = select_billing_account(args.billing_account)
    if billing_id:
        link_billing(project_id, billing_id)

    terraform_provision(
        project_id,
        args.region,
        args.topic,
        args.service_account_id,
        args.service_account_name,
        dry_run=args.dry_run,
    )

    key_path = None
    sa_email = service_account_email(project_id, args.service_account_id)
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

