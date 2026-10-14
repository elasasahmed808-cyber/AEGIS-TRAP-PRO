"""Playbook #3 - Key Disable & Session Revoke.

Disables compromised IAM access keys and revokes active sessions by attaching
an inline "AWSRevokeOlderSessions" deny policy (aws:TokenIssueTime < now).

Expected EventBridge event (source: custom.security.automation):
  detail = {
    "risk_type": "COMPROMISED_CREDENTIALS" | "CREDENTIAL_EXFILTRATION",
    "access_key_id": "AKIA... (optional)",
    "user_name": "alice (optional)",
    "role_name": "app-role (optional, for assumed-role/ASIA sessions)",
    "description": "free text"
  }
Environment:
  SNS_TOPIC_ARN        - alert topic
  PROTECTED_PRINCIPALS - comma separated user/role names never touched (break-glass)
"""
import json
import os
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

iam = boto3.client("iam")
sns = boto3.client("sns")

SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN")
PROTECTED = {p.strip() for p in os.environ.get("PROTECTED_PRINCIPALS", "").split(",") if p.strip()}
POLICY_NAME = "AWSRevokeOlderSessions"


def _revoke_policy():
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    return json.dumps({
        "Version": "2012-10-17",
        "Statement": [{
            "Effect": "Deny",
            "Action": "*",
            "Resource": "*",
            "Condition": {"DateLessThan": {"aws:TokenIssueTime": now}},
        }],
    })


def _notify(subject, message):
    if SNS_TOPIC_ARN:
        sns.publish(TopicArn=SNS_TOPIC_ARN, Subject=subject[:100], Message=message)


def lambda_handler(event, context):
    print("Received event:", json.dumps(event))
    detail = event.get("detail", {})
    key_id = detail.get("access_key_id")
    user_name = detail.get("user_name")
    role_name = detail.get("role_name")
    description = detail.get("description", "No details provided.")

    actions, errors = [], []

    # Resolve the owning user of a long-term key (AKIA...). Temporary keys (ASIA...)
    # cannot be disabled; they are handled by revoking sessions on the role/user.
    if key_id and not user_name and key_id.startswith("AKIA"):
        try:
            user_name = iam.get_access_key_last_used(AccessKeyId=key_id)["UserName"]
        except ClientError as exc:
            errors.append(f"resolve owner of {key_id}: {exc}")

    if user_name and user_name in PROTECTED:
        errors.append(f"user {user_name} is protected; skipped")
        user_name = None
    if role_name and role_name in PROTECTED:
        errors.append(f"role {role_name} is protected; skipped")
        role_name = None

    if user_name:
        try:
            if key_id and key_id.startswith("AKIA"):
                targets = [key_id]
            else:
                targets = [k["AccessKeyId"] for k in iam.list_access_keys(UserName=user_name)["AccessKeyMetadata"]]
            for kid in targets:
                iam.update_access_key(UserName=user_name, AccessKeyId=kid, Status="Inactive")
                actions.append(f"KEY_DISABLED:{user_name}:{kid}")
            iam.put_user_policy(UserName=user_name, PolicyName=POLICY_NAME, PolicyDocument=_revoke_policy())
            actions.append(f"SESSIONS_REVOKED:user/{user_name}")
        except ClientError as exc:
            errors.append(f"user {user_name}: {exc}")

    if role_name:
        try:
            iam.put_role_policy(RoleName=role_name, PolicyName=POLICY_NAME, PolicyDocument=_revoke_policy())
            actions.append(f"SESSIONS_REVOKED:role/{role_name}")
        except ClientError as exc:
            errors.append(f"role {role_name}: {exc}")

    if not user_name and not role_name and not errors:
        errors.append("no user_name, role_name or resolvable AKIA access_key_id in event")

    status = "SUCCESS" if actions and not errors else ("PARTIAL" if actions else "FAILED")
    _notify(
        f"[URGENT] Credential response: {status}",
        f"Actions: {actions}\nErrors: {errors}\nReason: {description}",
    )
    if errors:
        print("Errors:", errors)
    if status == "FAILED":
        raise RuntimeError("; ".join(errors))
    return {"status": status, "actions": actions, "errors": errors}
