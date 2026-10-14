"""Finding translator - bridges native AWS security findings into the playbooks.

The playbook Lambdas only react to events with source "custom.security.automation"
(see playbooks.tf). AWS security services never use that source, so this Lambda
subscribes to their native EventBridge events and re-publishes each finding in
the playbook event contract:

    GuardDuty   (source aws.guardduty,   "GuardDuty Finding")
    Security Hub (source aws.securityhub, "Security Hub Findings - Imported")
        |
        v  this Lambda
    events.put_events(Source="custom.security.automation",
                      DetailType="Security Incident",
                      Detail={"risk_type": ..., ...})
        |
        v
    existing rules -> playbook Lambdas (unchanged)

Mapping (see the purpose sets / keyword lists below):
  Instance findings whose threat purpose indicates compromise
    -> risk_type=COMPROMISED_INSTANCE   (quarantine + asg-detach + ebs-snapshot)
  IAM findings whose threat purpose indicates credential misuse
    -> risk_type=CREDENTIAL_EXFILTRATION (for *Exfiltration* findings) or
       COMPROMISED_CREDENTIALS          (key-disable-revoke)
  Everything else
    -> risk_type=GUARDDUTY_FINDING / SECURITY_HUB_FINDING
       (only the quarantine Lambda's generic alert picks these up)

Assumed-role sessions (userType=AssumedRole, userName "Role/session") are sent
as role_name so the key-disable playbook revokes role sessions instead of
trying to disable a temporary ASIA key.

Environment:
  MIN_SEVERITY - minimum GuardDuty severity (0-9 scale) to forward. The
                 EventBridge rule already filters on this; it is checked again
                 here as a second line of defence. Security Hub findings are
                 normalised to the same scale (Severity.Normalized / 10).
"""
import json
import os
import re

import boto3

events = boto3.client("events")

FORWARD_SOURCE = "custom.security.automation"
FORWARD_DETAIL_TYPE = "Security Incident"
MIN_SEVERITY = float(os.environ.get("MIN_SEVERITY", "7"))

# Threat purpose = the token before the first ":" in a GuardDuty finding type,
# e.g. "Backdoor:EC2/CryptoMinerDomainRequest.B" -> "BACKDOOR".
INSTANCE_COMPROMISE_PURPOSES = {
    "BACKDOOR", "TROJAN", "CRYPTOMINING", "EXECUTION",
    "UNAUTHORIZEDACCESS", "PERSISTENCE", "IMPACT",
}
CREDENTIAL_MISUSE_PURPOSES = {
    "CREDENTIALACCESS", "UNAUTHORIZEDACCESS", "DISCOVERY",
    "STEALTH", "IMPACT", "PERSISTENCE",
}

# Fallback keywords for finding types that carry no "Purpose:" prefix
# (typical for Security Hub standards, e.g. "TTPs/Credential Access").
_COMPROMISE_KEYWORDS = ("CRYPTOMIN", "MINER", "BACKDOOR", "TROJAN", "MALWARE")
_CREDENTIAL_KEYWORDS = ("CREDENTIAL", "EXFILTRAT", "UNAUTHORIZED ACCESS",
                        "ANOMALOUS", "PASSWORD", "ACCESS KEY")

_INSTANCE_ID_RE = re.compile(r"\bi-[0-9a-f]{8,17}\b")
_ACCESS_KEY_RE = re.compile(r"\b(?:AKIA|ASIA|ASCA)[0-9A-Z]{16}\b")
_LABEL_SEVERITY = {"CRITICAL": 9.0, "HIGH": 7.5, "MEDIUM": 5.0, "LOW": 2.0, "INFORMATIONAL": 0.0}


def _purpose(finding_type):
    return str(finding_type).split(":", 1)[0].strip().upper()


def _looks_like(finding_type, keywords):
    upper = str(finding_type).upper()
    return any(k in upper for k in keywords)


def _classify(finding_type, has_instance, has_principal):
    """Decide the playbook risk_type for a finding; None = generic alert only."""
    purpose = _purpose(finding_type) if ":" in str(finding_type) else ""
    if has_instance and (purpose in INSTANCE_COMPROMISE_PURPOSES
                         or _looks_like(finding_type, _COMPROMISE_KEYWORDS)):
        return "COMPROMISED_INSTANCE"
    if has_principal and (purpose in CREDENTIAL_MISUSE_PURPOSES
                          or _looks_like(finding_type, _CREDENTIAL_KEYWORDS)):
        return "CREDENTIAL_EXFILTRATION" if "exfiltrat" in str(finding_type).lower() \
            else "COMPROMISED_CREDENTIALS"
    return None


def _entry(risk_type, description, service, finding_id, finding_type, severity, **detail):
    payload = {
        "risk_type": risk_type,
        "description": description,
        "source_service": service,
        "finding_id": finding_id,
        "finding_type": finding_type,
        "severity": severity,
        # Links forensic custody records back to the original detection.
        "incident_id": f"{service[:2].upper()}-{finding_id}",
    }
    payload.update(detail)
    return {"Source": FORWARD_SOURCE, "DetailType": FORWARD_DETAIL_TYPE,
            "Detail": json.dumps(payload)}


def translate_guardduty(detail):
    """Map one GuardDuty finding (EventBridge event["detail"]) to an entry."""
    finding_id = detail.get("id", "unknown")
    ftype = detail.get("type", "")
    severity = float(detail.get("severity", 0) or 0)
    if severity < MIN_SEVERITY:
        print(f"Skipping finding {finding_id}: severity {severity} < {MIN_SEVERITY}")
        return None

    resource = detail.get("resource") or {}
    instance_id = (resource.get("instanceDetails") or {}).get("instanceId")
    keys = resource.get("accessKeyDetails") or {}
    access_key_id = keys.get("accessKeyId")
    user_name = keys.get("userName")

    description = (f"[GuardDuty {severity:.1f}] {detail.get('title', ftype)}: "
                   f"{detail.get('description', '')}").strip()

    risk = _classify(ftype, has_instance=bool(instance_id),
                     has_principal=bool(access_key_id or user_name))

    if risk == "COMPROMISED_INSTANCE":
        return _entry(risk, description, "guardduty", finding_id, ftype, severity,
                      instance_id=instance_id, region=detail.get("region"))

    if risk in ("CREDENTIAL_EXFILTRATION", "COMPROMISED_CREDENTIALS"):
        if keys.get("userType") == "AssumedRole" or (user_name and "/" in user_name):
            # Temporary STS session: revoke on the role, never disable ASIA keys.
            return _entry(risk, description, "guardduty", finding_id, ftype, severity,
                          role_name=str(user_name).split("/")[0])
        return _entry(risk, description, "guardduty", finding_id, ftype, severity,
                      access_key_id=access_key_id, user_name=user_name)

    print(f"Finding {finding_id} ({ftype}) has no playbook mapping; forwarding as generic alert")
    return _entry("GUARDDUTY_FINDING", description, "guardduty", finding_id, ftype, severity)


def translate_securityhub(detail):
    """Map the findings array of one Security Hub event to entries."""
    entries = []
    for finding in detail.get("findings") or []:
        entry = _translate_securityhub_finding(finding)
        if entry:
            entries.append(entry)
    return entries


def _translate_securityhub_finding(finding):
    finding_id = finding.get("Id", "unknown")
    types = finding.get("Types") or []
    ftype = types[0] if types else "SecurityHubFinding"

    severity_info = finding.get("Severity") or {}
    normalized = severity_info.get("Normalized")
    severity = float(normalized) / 10.0 if normalized is not None else _LABEL_SEVERITY.get(
        str(severity_info.get("Label", "")).upper(), 0.0)
    if severity < MIN_SEVERITY:
        print(f"Skipping finding {finding_id}: severity {severity} < {MIN_SEVERITY}")
        return None

    instance_id = access_key_id = user_name = role_name = None
    for res in finding.get("Resources") or []:
        rid = res.get("Id") or ""
        details = res.get("Details") or {}
        m = _INSTANCE_ID_RE.search(rid)
        instance_id = instance_id or (m.group(0) if m else None)
        m = _ACCESS_KEY_RE.search(rid)
        access_key_id = access_key_id or (m.group(0) if m else None)
        user_name = user_name or (details.get("AwsIamAccessKey") or {}).get("UserName") \
                               or (details.get("AwsIamUser") or {}).get("UserName")
        if res.get("Type") == "AwsIamRole" and rid:
            role_name = role_name or rid.rstrip("/").split("/")[-1]

    description = (f"[SecurityHub {severity:.1f}] {finding.get('Title', ftype)}: "
                   f"{finding.get('Description', '')}")[:1500]

    risk = _classify(ftype, has_instance=bool(instance_id),
                     has_principal=bool(access_key_id or user_name or role_name))

    if risk == "COMPROMISED_INSTANCE":
        return _entry(risk, description, "securityhub", finding_id, ftype, severity,
                      instance_id=instance_id, region=finding.get("Region"))

    if risk in ("CREDENTIAL_EXFILTRATION", "COMPROMISED_CREDENTIALS"):
        if role_name and not user_name:
            return _entry(risk, description, "securityhub", finding_id, ftype, severity,
                          role_name=role_name)
        return _entry(risk, description, "securityhub", finding_id, ftype, severity,
                      access_key_id=access_key_id, user_name=user_name)

    print(f"Finding {finding_id} ({ftype}) has no playbook mapping; forwarding as generic alert")
    return _entry("SECURITY_HUB_FINDING", description, "securityhub", finding_id, ftype, severity)


def _dedupe_key(detail):
    # Generic alerts stay unique per finding; actionable ones collapse when
    # several findings point at the same principal (e.g. GuardDuty finding also
    # imported into Security Hub).
    if detail["risk_type"] in ("GUARDDUTY_FINDING", "SECURITY_HUB_FINDING"):
        return (detail["risk_type"], detail.get("finding_id"))
    return (detail["risk_type"], detail.get("instance_id"), detail.get("access_key_id"),
            detail.get("user_name"), detail.get("role_name"))


def lambda_handler(event, context):
    print("Received event:", json.dumps(event))

    source = event.get("source", "")
    if source == "aws.guardduty":
        entries = [translate_guardduty(event.get("detail") or {})]
    elif source == "aws.securityhub":
        entries = translate_securityhub(event.get("detail") or {})
    else:
        print(f"Ignoring unsupported source: {source}")
        return {"status": "SKIPPED", "reason": f"unsupported source {source}"}

    seen, unique = set(), []
    for entry in (e for e in entries if e):
        key = _dedupe_key(json.loads(entry["Detail"]))
        if key not in seen:
            seen.add(key)
            unique.append(entry)

    forwarded = 0
    for i in range(0, len(unique), 10):  # PutEvents accepts at most 10 entries per call
        resp = events.put_events(Entries=unique[i:i + 10])
        forwarded += sum(1 for r in resp.get("Entries", []) if "EventId" in r)
        failed = sum(1 for r in resp.get("Entries", []) if "ErrorCode" in r)
        if failed:
            raise RuntimeError(f"EventBridge rejected {failed} forwarded events")

    return {"status": "SUCCESS", "forwarded": forwarded}
