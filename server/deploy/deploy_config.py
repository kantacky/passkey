#!/usr/bin/env python3
"""Read the small subset of HCL used by infra/terraform.tfvars for Cloud Build."""

from __future__ import annotations

import argparse
import json
import re
import shlex
import sys
from pathlib import Path

REQUIRED_KEYS = (
    "project_id",
    "region",
    "artifact_repository",
    "image_name",
    "vpc_network_name",
    "vpc_subnet_name",
    "cloud_sql_instance_name",
    "database_name",
    "mailgun_secret_name",
    "cloud_run_service_name",
    "migrate_job_name",
    "cleanup_job_name",
    "server_service_account_name",
    "migrator_service_account_name",
    "cloudbuild_service_account_name",
    "rp_id",
    "origin",
    "mailgun_domain",
    "mailgun_api_base_url",
    "mail_from",
)

MANIFESTS = (
    "cloudrun-migrate-job.yaml",
    "cloudrun-service.yaml",
    "cloudrun-cleanup-job.yaml",
)

ASSIGNMENT = re.compile(
    r'^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*'
    r'("(?:\\.|[^"\\])*"|-?[0-9]+(?:\.[0-9]+)?|true|false)\s*(?:#.*)?$'
)
LEFTOVER_PLACEHOLDER = re.compile(r"__[A-Z0-9_]+__")


class ConfigError(Exception):
    pass


def load_tfvars(path: Path) -> dict[str, object]:
    values: dict[str, object] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as error:
        raise ConfigError(f"cannot read {path}: {error}") from error

    for line_number, line in enumerate(lines, start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("#") or stripped.startswith("//"):
            continue
        match = ASSIGNMENT.match(line)
        if match is None:
            raise ConfigError(
                f"{path}:{line_number}: unsupported terraform.tfvars syntax; "
                "use a single string, number, or boolean assignment per line"
            )
        key, raw_value = match.groups()
        try:
            values[key] = json.loads(raw_value)
        except json.JSONDecodeError as error:
            raise ConfigError(f"{path}:{line_number}: invalid scalar value") from error

    missing = [key for key in REQUIRED_KEYS if key not in values]
    if missing:
        raise ConfigError(f"{path}: missing required keys: {', '.join(missing)}")
    if values["project_id"] == "__GCP_PROJECT_ID__":
        raise ConfigError(f"{path}: edit project_id before deploying")
    return values


def export_env(values: dict[str, object], output: Path) -> None:
    lines = [
        f"TF_{key.upper()}={shlex.quote(str(values[key]))}"
        for key in REQUIRED_KEYS
    ]
    output.write_text("\n".join(lines) + "\n", encoding="utf-8")


def render_manifests(values: dict[str, object], image_tag: str, output_dir: Path) -> None:
    replacements = {
        "__GCP_PROJECT_ID__": values["project_id"],
        "__REGION__": values["region"],
        "__ARTIFACT_REPOSITORY__": values["artifact_repository"],
        "__IMAGE_NAME__": values["image_name"],
        "__IMAGE_TAG__": image_tag,
        "__VPC_NETWORK__": values["vpc_network_name"],
        "__VPC_SUBNET__": values["vpc_subnet_name"],
        "__CLOUD_SQL_INSTANCE__": values["cloud_sql_instance_name"],
        "__DATABASE_NAME__": values["database_name"],
        "__CLOUD_RUN_SERVICE_NAME__": values["cloud_run_service_name"],
        "__MIGRATE_JOB_NAME__": values["migrate_job_name"],
        "__CLEANUP_JOB_NAME__": values["cleanup_job_name"],
        "__SERVER_SA_NAME__": values["server_service_account_name"],
        "__MIGRATOR_SA_NAME__": values["migrator_service_account_name"],
        "__RP_ID__": values["rp_id"],
        "__ORIGIN__": values["origin"],
        "__MAILGUN_SECRET_NAME__": values["mailgun_secret_name"],
        "__MAILGUN_DOMAIN__": values["mailgun_domain"],
        "__MAILGUN_API_BASE_URL__": values["mailgun_api_base_url"],
        "__MAIL_FROM__": values["mail_from"],
    }

    source_dir = Path(__file__).resolve().parent
    output_dir.mkdir(parents=True, exist_ok=True)
    for filename in MANIFESTS:
        text = (source_dir / filename).read_text(encoding="utf-8")
        for placeholder, value in replacements.items():
            text = text.replace(placeholder, str(value))
        leftover = sorted(set(LEFTOVER_PLACEHOLDER.findall(text)))
        if leftover:
            raise ConfigError(f"{filename}: unresolved placeholders: {', '.join(leftover)}")
        (output_dir / filename).write_text(text, encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser()
    subparsers = parser.add_subparsers(dest="command", required=True)

    export_parser = subparsers.add_parser("export")
    export_parser.add_argument("tfvars", type=Path)
    export_parser.add_argument("output", type=Path)

    render_parser = subparsers.add_parser("render")
    render_parser.add_argument("tfvars", type=Path)
    render_parser.add_argument("image_tag")
    render_parser.add_argument("output_dir", type=Path)

    args = parser.parse_args()
    try:
        values = load_tfvars(args.tfvars)
        if args.command == "export":
            export_env(values, args.output)
        elif args.command == "render":
            if not args.image_tag:
                raise ConfigError("image tag must not be empty")
            render_manifests(values, args.image_tag, args.output_dir)
    except ConfigError as error:
        print(f"deploy_config.py: error: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
