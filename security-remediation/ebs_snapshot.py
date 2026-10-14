"""Playbook #4 - EBS Snapshot & Chain of Custody.

Stage 1 (trigger event, source custom.security.automation):
    detail = {"risk_type": "COMPROMISED_INSTANCE" | "FORENSIC_SNAPSHOT_REQUEST",
              "instance_id": "i-...", "volume_ids": ["vol-..."] (optional),
              "incident_id": "optional", "description": "free text"}
    -> snapshots the volumes, tags them SecurityStatus=Evidence and writes
       custody record #1 (SNAPSHOT_REQUESTED) to the evidence bucket.

Stage 2 (source aws.ec2, "EBS Snapshot Notification", result=succeeded):
    -> hashes the snapshot blocks (SHA-256 per block, then a SHA-256 manifest
       over all blocks) and writes custody record #2 (SNAPSHOT_HASHED).

Every custody record contains prev_record_sha256 and its own record_sha256, so
the records form a hash chain; the bucket is versioned with S3 Object Lock.

Environment:
  SNS_TOPIC_ARN   - alert topic
  EVIDENCE_BUCKET - S3 bucket for custody records
  MAX_HASH_BLOCKS - cap on 512 KiB blocks hashed (default 20000 ~ 10 GiB);
                    if exceeded the record is marked hash_scope=PARTIAL.
"""
import hashlib
import json
import os
from datetime import datetime, timezone

import boto3

ec2 = boto3.client("ec2")
ebs = boto3.client("ebs")
s3 = boto3.client("s3")
sns = boto3.client("sns")

SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN")
EVIDENCE_BUCKET = os.environ["EVIDENCE_BUCKET"]
MAX_HASH_BLOCKS = int(os.environ.get("MAX_HASH_BLOCKS", "20000"))
SAFETY_MS = 30000  # stop hashing when this little time is left


def _now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def _notify(subject, message):
    if SNS_TOPIC_ARN:
        sns.publish(TopicArn=SNS_TOPIC_ARN, Subject=subject[:100], Message=message)


def _canonical(obj):
    return json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()


def _key(snapshot_id, seq, action):
    return f"custody/{snapshot_id}/{seq:03d}-{action}.json"


def _read_record(snapshot_id, seq, action):
    try:
        obj = s3.get_object(Bucket=EVIDENCE_BUCKET, Key=_key(snapshot_id, seq, action))
        return json.loads(obj["Body"].read())
    except s3.exceptions.NoSuchKey:
        return None


def _write_record(snapshot_id, seq, action, context, base, details, prev_hash):
    record = {
        "schema": "custody-record/v1",
        "sequence": seq,
        "action": action,
        "timestamp_utc": _now(),
        "snapshot_id": snapshot_id,
        "actor": {
            "function": context.function_name,
            "function_arn": context.invoked_function_arn,
            "request_id": context.aws_request_id,
        },
        **base,
        "details": details,
        "prev_record_sha256": prev_hash,
    }
    record["record_sha256"] = hashlib.sha256(_canonical(record)).hexdigest()
    s3.put_object(
        Bucket=EVIDENCE_BUCKET,
        Key=_key(snapshot_id, seq, action),
        Body=json.dumps(record, indent=2, sort_keys=True).encode(),
        ContentType="application/json",
        ServerSideEncryption="AES256",
    )
    return record


def _volumes_of(instance_id):
    resp = ec2.describe_instances(InstanceIds=[instance_id])
    vols = []
    for r in resp["Reservations"]:
        for i in r["Instances"]:
            for m in i.get("BlockDeviceMappings", []):
                if "Ebs" in m:
                    vols.append(m["Ebs"]["VolumeId"])
    return vols


# ---------------------------------------------------------------- stage 1
def handle_trigger(event, context):
    detail = event.get("detail", {})
    instance_id = detail.get("instance_id")
    volume_ids = detail.get("volume_ids") or (_volumes_of(instance_id) if instance_id else [])
    incident_id = detail.get("incident_id") or event.get("id", context.aws_request_id)
    description = detail.get("description", "No details provided.")

    if not volume_ids:
        print("No volumes resolved; nothing to snapshot.")
        return {"status": "SKIPPED", "reason": "NO_VOLUMES"}

    created = []
    for vol in volume_ids:
        snap = ec2.create_snapshot(
            VolumeId=vol,
            Description=f"Forensic evidence incident={incident_id} volume={vol}",
            TagSpecifications=[{
                "ResourceType": "snapshot",
                "Tags": [
                    {"Key": "SecurityStatus", "Value": "Evidence"},
                    {"Key": "IncidentId", "Value": str(incident_id)[:256]},
                    {"Key": "SourceVolume", "Value": vol},
                    {"Key": "SourceInstance", "Value": instance_id or "unknown"},
                ],
            }],
        )
        sid = snap["SnapshotId"]
        base = {
            "incident_id": incident_id,
            "source_instance_id": instance_id,
            "source_volume_id": vol,
            "source_event_id": event.get("id"),
        }
        _write_record(
            sid, 1, "SNAPSHOT_REQUESTED", context, base,
            {"reason": description, "encrypted": snap.get("Encrypted"), "start_time": str(snap.get("StartTime"))},
            prev_hash=None,
        )
        created.append(sid)

    _notify(
        "[URGENT] Forensic EBS snapshots started",
        f"Incident {incident_id}: snapshots {created} created for instance {instance_id}.\n"
        f"Custody records: s3://{EVIDENCE_BUCKET}/custody/\nReason: {description}",
    )
    return {"status": "SUCCESS", "action": "SNAPSHOTS_STARTED", "snapshots": created}


# ---------------------------------------------------------------- stage 2
def _snapshot_ids_from_notification(detail):
    ids = []
    if detail.get("snapshot_id"):
        ids.append(detail["snapshot_id"])
    for s in detail.get("snapshots", []) or []:
        if s.get("snapshot_id"):
            ids.append(s["snapshot_id"])
    return [i.split("/")[-1] for i in ids]


def _hash_snapshot(snapshot_id, context):
    manifest = hashlib.sha256()
    blocks = 0
    scope = "FULL"
    token = None
    while True:
        kwargs = {"SnapshotId": snapshot_id, "MaxResults": 10000}
        if token:
            kwargs["NextToken"] = token
        page = ebs.list_snapshot_blocks(**kwargs)
        for b in page.get("Blocks", []):
            if blocks >= MAX_HASH_BLOCKS or context.get_remaining_time_in_millis() < SAFETY_MS:
                return manifest.hexdigest(), blocks, "PARTIAL"
            data = ebs.get_snapshot_block(
                SnapshotId=snapshot_id, BlockIndex=b["BlockIndex"], BlockToken=b["BlockToken"]
            )["BlockData"].read()
            manifest.update(f"{b['BlockIndex']}:{hashlib.sha256(data).hexdigest()}\n".encode())
            blocks += 1
        token = page.get("NextToken")
        if not token:
            break
    return manifest.hexdigest(), blocks, scope


def handle_snapshot_completed(event, context):
    detail = event.get("detail", {})
    if detail.get("result") != "succeeded":
        return {"status": "SKIPPED", "reason": "SNAPSHOT_NOT_SUCCEEDED"}

    results = []
    for sid in _snapshot_ids_from_notification(detail):
        snaps = ec2.describe_snapshots(SnapshotIds=[sid])["Snapshots"]
        tags = {t["Key"]: t["Value"] for t in snaps[0].get("Tags", [])} if snaps else {}
        if tags.get("SecurityStatus") != "Evidence":
            continue  # not one of ours
        if _read_record(sid, 2, "SNAPSHOT_HASHED"):
            results.append({"snapshot_id": sid, "status": "ALREADY_HASHED"})
            continue
        first = _read_record(sid, 1, "SNAPSHOT_REQUESTED")
        if not first:
            results.append({"snapshot_id": sid, "status": "NO_PRIOR_RECORD"})
            continue

        digest, blocks, scope = _hash_snapshot(sid, context)
        base = {
            "incident_id": first.get("incident_id"),
            "source_instance_id": first.get("source_instance_id"),
            "source_volume_id": first.get("source_volume_id"),
            "source_event_id": event.get("id"),
        }
        rec = _write_record(
            sid, 2, "SNAPSHOT_HASHED", context, base,
            {
                "hash_algorithm": "SHA-256 manifest over 'index:sha256(block)' lines",
                "manifest_sha256": digest,
                "blocks_hashed": blocks,
                "hash_scope": scope,
                "volume_size_gib": snaps[0].get("VolumeSize"),
            },
            prev_hash=first["record_sha256"],
        )
        _notify(
            "[EVIDENCE] Snapshot hashed" + ("" if scope == "FULL" else " (PARTIAL)"),
            f"Snapshot {sid} manifest sha256={digest} blocks={blocks} scope={scope}\n"
            f"Record: s3://{EVIDENCE_BUCKET}/{_key(sid, 2, 'SNAPSHOT_HASHED')}",
        )
        results.append({"snapshot_id": sid, "status": "HASHED", "scope": scope, "record_sha256": rec["record_sha256"]})
    return {"status": "SUCCESS", "action": "SNAPSHOTS_HASHED", "results": results}


def lambda_handler(event, context):
    print("Received event:", json.dumps(event))
    if event.get("source") == "aws.ec2" and event.get("detail-type") == "EBS Snapshot Notification":
        return handle_snapshot_completed(event, context)
    return handle_trigger(event, context)
