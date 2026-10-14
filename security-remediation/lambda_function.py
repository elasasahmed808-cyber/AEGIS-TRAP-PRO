import json
import boto3
import os

ec2 = boto3.client('ec2')
sns = boto3.client('sns')

ISOLATION_SG_ID = os.environ.get('ISOLATION_SECURITY_GROUP_ID')
SNS_TOPIC_ARN = os.environ.get('SNS_TOPIC_ARN')

def lambda_handler(event, context):
    print("Received event:", json.dumps(event))
    
    detail = event.get('detail', {})
    risk_type = detail.get('risk_type', 'GENERAL_ALERT')
    instance_id = detail.get('instance_id')
    description = detail.get('description', 'No details provided.')
    
    # سيناريو الخطر على سيرفر: عزل الـ EC2 فوراً
    if risk_type == 'COMPROMISED_INSTANCE' and instance_id:
        try:
            ec2.modify_instance_attribute(
                InstanceId=instance_id,
                Groups=[ISOLATION_SG_ID]
            )
            
            ec2.create_tags(
                Resources=[instance_id],
                Tags=[{'Key': 'SecurityStatus', 'Value': 'Quarantined'}]
            )
            
            msg = f"Security Action: Instance {instance_id} isolated successfully.\nReason: {description}"
            sns.publish(
                TopicArn=SNS_TOPIC_ARN,
                Subject="[URGENT] EC2 Instance Isolated",
                Message=msg
            )
            return {"status": "SUCCESS", "action": "INSTANCE_ISOLATED", "instance_id": instance_id}
            
        except Exception as e:
            print(f"Error isolating instance {instance_id}: {str(e)}")
            raise e
            
    # سيناريو الشك الأمني أو التنبيهات العامة
    else:
        sns.publish(
            TopicArn=SNS_TOPIC_ARN,
            Subject=f"[SECURITY ALERT] {risk_type}",
            Message=f"Security risk detected:\nType: {risk_type}\nDetails: {description}"
        )
        return {"status": "SUCCESS", "action": "ALERT_SENT"}