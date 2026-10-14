"""Playbook #2 - ASG Detach / Standby.

Pulls a compromised or unhealthy instance out of its Auto Scaling Group so the
ASG launches a clean replacement (ShouldDecrementDesiredCapacity=False).

Expected EventBridge event (source: custom.security.automation):
  detail = {
    "risk_type": "COMPROMISED_INSTANCE" | "UNHEALTHY_INSTANCE",
    "instance_id": "i-0123456789abcdef0",
    "description": "free text"
  }
Environment:
  SNS_TOPIC_ARN - alert topic
  ASG_ACTION    - "detach" (default) or "standby"
"""
import json
import os

import boto3

autoscaling = boto3.client("autoscaling")
ec2 = boto3.client("ec2")
sns = boto3.client("sns")

SNS_TOPIC_ARN = os.environ.get("SNS_TOPIC_ARN")
ASG_ACTION = os.environ.get("ASG_ACTION", "detach").lower()


def _notify(subject, message):
    if SNS_TOPIC_ARN:
        sns.publish(TopicArn=SNS_TOPIC_ARN, Subject=subject[:100], Message=message)


def lambda_handler(event, context):
    print("Received event:", json.dumps(event))
    detail = event.get("detail", {})
    instance_id = detail.get("instance_id")
    description = detail.get("description", "No details provided.")

    if not instance_id:
        print("No instance_id in event; nothing to do.")
        return {"status": "SKIPPED", "reason": "NO_INSTANCE_ID"}

    resp = autoscaling.describe_auto_scaling_instances(InstanceIds=[instance_id])
    members = resp.get("AutoScalingInstances", [])
    if not members:
        print(f"{instance_id} is not in an Auto Scaling Group.")
        return {"status": "SKIPPED", "reason": "NOT_IN_ASG", "instance_id": instance_id}

    asg_name = members[0]["AutoScalingGroupName"]
    state = members[0]["LifecycleState"]
    if state in ("Detached", "Detaching", "Standby", "EnteringStandby"):
        return {"status": "SKIPPED", "reason": f"ALREADY_{state.upper()}", "instance_id": instance_id}

    try:
        if ASG_ACTION == "standby":
            autoscaling.enter_standby(
                InstanceIds=[instance_id],
                AutoScalingGroupName=asg_name,
                ShouldDecrementDesiredCapacity=False,
            )
            action, tag_value = "ENTERED_STANDBY", "AsgStandby"
        else:
            autoscaling.detach_instances(
                InstanceIds=[instance_id],
                AutoScalingGroupName=asg_name,
                ShouldDecrementDesiredCapacity=False,
            )
            action, tag_value = "DETACHED_FROM_ASG", "AsgDetached"

        ec2.create_tags(
            Resources=[instance_id],
            Tags=[
                {"Key": "AsgPlaybook", "Value": tag_value},
                {"Key": "AsgOriginalGroup", "Value": asg_name},
            ],
        )
        _notify(
            "[URGENT] Instance removed from ASG",
            f"Instance {instance_id} {action} from ASG {asg_name}. "
            f"A replacement will be launched.\nReason: {description}",
        )
        return {"status": "SUCCESS", "action": action, "instance_id": instance_id, "asg": asg_name}
    except Exception as exc:
        print(f"Error handling {instance_id}: {exc}")
        _notify("[ERROR] ASG detach playbook failed", f"Instance {instance_id}: {exc}")
        raise
