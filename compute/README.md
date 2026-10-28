# DocuMind Terraform (Compute + Bedrock)

## Layout
- `modules/bedrock`  – guardrail (optional), `proj-prod-bedrock-logs` bucket, CloudWatch log group, invocation logging config
- `modules/compute`  – IAM (app, Jenkins, canary users), SGs, launch templates (app + Jenkins), app ASG 2/2/4, Jenkins ASG 1/1/1, ALB + decoy rules, persistent Jenkins home on EFS
- `documind-app/`    – push this folder's content to your GitHub repo (Jenkinsfile + `app/`). Terraform also uploads `app/` as a seed `documind/latest.tar.gz` so first boot deploys without Jenkins.

## Prereqs (from other modules)
VPC, public/private subnets, NAT, S3 gateway endpoint, KMS key, buckets: documents, build-artifacts, logging.
The logging bucket policy must allow the regional ELB principal to write to `alb/*` (ALB access logs).
The KMS key policy must allow the app/Jenkins roles via IAM (or set `create_asg_kms_grant = true` once the ASG service-linked role exists).

## Use
    cp terraform.tfvars.example terraform.tfvars   # edit
    terraform init && terraform plan && terraform apply

## Already-existing roles/policies
If the Bedrock/Jenkins roles already exist in AWS, import before apply, e.g.:
    terraform import 'module.compute.aws_iam_role.jenkins' <existing-jenkins-role-name>
    terraform import 'module.compute.aws_iam_role.app' <existing-app-role-name>
(or rename them in `modules/compute/iam.tf`).

## Jenkins
Jenkins runs in its own ASG (min=max=desired=1), behind the same ALB as the app, at `/jenkins`.
If the instance dies, EC2/ALB health checks launch a replacement automatically - no manual step.

Reach the UI either at `https://<alb_dns_name>/jenkins` or, for console access, with SSM port
forwarding (target the current instance in `aws_autoscaling_group.jenkins`):
    aws ssm start-session --target <instance_id> --document-name AWS-StartPortForwardingSession --parameters portNumber=8080,localPortNumber=8080

**One-time setup:** create a Pipeline job named to match `jenkins_trigger_job_name`
(default `documind-deploy`) pointing at the GitHub repo (Jenkinsfile in repo root), and under
"Trigger builds remotely" enable the token field (any placeholder value - it gets overwritten).
After that, `/var/lib/jenkins` is persisted on EFS, so the job survives instance replacement, and
`init.groovy.d/sync-trigger-token.groovy` re-applies the token from SSM parameter
`jenkins_trigger_token_param` on every boot so it always matches what GitHub Actions has stored
as its secret - nothing to re-create by hand after the first time.

GitHub Actions triggers a build with:
    curl "https://<alb_dns_name>/jenkins/job/<job_name>/build?token=<secret>"
where `<secret>` is the current value of the `jenkins_trigger_token_param` SSM parameter
(fetch it once, store it as a GitHub Actions repo secret, done).

## Decoy/Canary
ALB decoy paths -> 404 (logged). `/opt/documind/.env.bak` (root, 600) holds canary key 2. Canary user 1 secret is in the sensitive output `canary_user_1_secret`.
