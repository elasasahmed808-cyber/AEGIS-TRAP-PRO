"""Playbook #1 - Quarantine swap.

Replaces ALL security groups on a compromised instance with the isolation SG
(no inbound, no outbound), tags it, and notifies via SNS.

Triggered ONLY by events with detail.risk_type == "COMPROMISED_INSTANCE"
(the EventBridge rule in main.tf filters on it).

Expected event (source: custom.security.automation):
  detail = {"risk_type": "COMPROMISED_INSTANCE", "instance_id": "i-0123...", "description": "..."}
Environment:
  ISOLATION_SECURITY_GROUP_ID - SG with no rules
  SNS_TOPIC_ARN               - alert topic
"""
import json
import os

import boto3

ec2 = boto3.client("ec2")
sns = boto3.client("sns")

ISOLATION_SG_ID = os.environ.get("ISOLATION_SECURITY_GROUP_ID")
SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN")


def lambda_handler(event, context):
    print("Received event:", json.dumps(event))

    detail = event.get("detail", {})
    instance_id = detail.get("instance_id")
    description = detail.get("description", "No details provided.")

    if not instance_id:
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject="[SECURITY ALERT] COMPROMISED_INSTANCE without instance_id",
            Message=f"Cannot isolate: event carried no instance_id.\nDetails: {description}",
        )
        return {"status": "SKIPPED", "reason": "missing instance_id"}

    try:
        # EC2 requires at least one SG, so we "swap" (replace the whole list)
        # instead of removing groups.
        ec2.modify_instance_attribute(InstanceId=instance_id, Groups=[ISOLATION_SG_ID])
        ec2.create_tags(
            Resources=[instance_id],
            Tags=[{"Key": "SecurityStatus", "Value": "Quarantined"}],
        )
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject="[URGENT] EC2 Instance Isolated",
            Message=f"Security Action: Instance {instance_id} isolated successfully.\nReason: {description}",
        )
        return {"status": "SUCCESS", "action": "INSTANCE_ISOLATED", "instance_id": instance_id}
    except Exception as e:
        print(f"Error isolating instance {instance_id}: {e}")
        raise