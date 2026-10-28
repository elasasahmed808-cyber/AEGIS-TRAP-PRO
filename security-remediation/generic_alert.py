"""Generic alert - notify-only responder.

Handles security events that have NO automated playbook (risk_type
GUARDDUTY_FINDING, SECURITY_HUB_FINDING, GENERAL_ALERT). It changes nothing in
the account; it only publishes the details to SNS.

Environment:
  SNS_TOPIC_ARN - alert topic
"""
import json
import os

import boto3

sns = boto3.client("sns")
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN")


def lambda_handler(event, context):
    print("Received event:", json.dumps(event))
    detail = event.get("detail", {})
    risk_type = detail.get("risk_type", "GENERAL_ALERT")

    lines = [
        f"Type: {risk_type}",
        f"Source service: {detail.get('source_service', 'n/a')}",
        f"Finding type: {detail.get('finding_type', 'n/a')}",
        f"Severity: {detail.get('severity', 'n/a')}",
        f"Finding ID: {detail.get('finding_id', 'n/a')}",
        f"Details: {detail.get('description', 'No details provided.')}",
    ]
    sns.publish(
        TopicArn=SNS_TOPIC_ARN,
        Subject=f"[SECURITY ALERT] {risk_type}"[:100],
        Message="Security risk detected:\n" + "\n".join(lines),
    )
    return {"status": "SUCCESS", "action": "ALERT_SENT"}
