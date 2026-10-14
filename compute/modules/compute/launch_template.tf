data "aws_ssm_parameter" "al2023" {
  count = var.ami_id == "" ? 1 : 0
  name  = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

locals {
  ami_id       = var.ami_id != "" ? var.ami_id : data.aws_ssm_parameter.al2023[0].value
  artifact_key = "${var.artifact_prefix}latest.tar.gz"

  app_log_group     = "/${var.name_prefix}/documind/app"
  jenkins_log_group = "/${var.name_prefix}/documind/jenkins"
  os_log_group      = "/${var.name_prefix}/documind/os"

  user_data = {
    app = templatefile("${path.module}/files/user_data_app.sh.tpl", {
      region               = var.region
      artifact_bucket      = var.build_artifacts_bucket_name
      artifact_key         = local.artifact_key
      summaries_bucket     = var.documents_bucket_name
      summaries_prefix     = var.summaries_prefix
      apmix_api_key_param  = aws_ssm_parameter.apmix_api_key.name
      canary_key_id        = aws_iam_access_key.canary["2"].id
      canary_secret        = aws_iam_access_key.canary["2"].secret
      deploy_b64           = base64encode(file("${path.module}/files/documind-deploy.sh"))
      cw_b64 = base64encode(templatefile("${path.module}/files/cw-agent.json.tpl", {
        app_log_path  = "/var/log/documind/*.log"
        app_log_group = local.app_log_group
        os_log_group  = local.os_log_group
      }))
    })
    jenkins = templatefile("${path.module}/files/user_data_jenkins.sh.tpl", {
      region            = var.region
      artifact_bucket   = var.build_artifacts_bucket_name
      artifact_key      = local.artifact_key
      canary_key_id     = aws_iam_access_key.canary["2"].id
      canary_secret     = aws_iam_access_key.canary["2"].secret
      cw_b64 = base64encode(templatefile("${path.module}/files/cw-agent.json.tpl", {
        app_log_path  = "/var/log/jenkins/jenkins.log"
        app_log_group = local.jenkins_log_group
        os_log_group  = local.os_log_group
      }))
    })
  }

  instances = {
    app = {
      instance_type = var.app_instance_type
      profile       = aws_iam_instance_profile.app.name
      sg_id         = aws_security_group.app.id
      role_tag      = "documind-app"
    }
    jenkins = {
      instance_type = var.jenkins_instance_type
      profile       = aws_iam_instance_profile.jenkins.name
      sg_id         = aws_security_group.jenkins.id
      role_tag      = "documind-jenkins"
    }
  }
}

resource "aws_cloudwatch_log_group" "this" {
  for_each          = toset([local.app_log_group, local.jenkins_log_group, local.os_log_group])
  name              = each.value
  retention_in_days = var.log_retention_days
}

resource "aws_launch_template" "this" {
  for_each = local.instances

  name_prefix            = "${var.name_prefix}-${each.key}-"
  image_id               = local.ami_id
  instance_type          = each.value.instance_type
  vpc_security_group_ids = [each.value.sg_id]
  update_default_version = true
  user_data              = base64encode(local.user_data[each.key])

  iam_instance_profile { name = each.value.profile }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2
    http_put_response_hop_limit = 1
  }

  monitoring { enabled = true }

  block_device_mappings {
    device_name = var.root_device_name
    ebs {
      volume_size           = var.root_volume_size
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  # Merged instance tag specifications
  tag_specifications {
    resource_type = "instance"
    tags = {
      Name = "${var.name_prefix}-${each.key}"
      Role = each.value.role_tag
      Env  = "prod"
    }
  }

  # Merged volume tag specifications
  tag_specifications {
    resource_type = "volume"
    tags = {
      Name = "${var.name_prefix}-${each.key}"
      Env  = "prod"
    }
  }

  lifecycle { create_before_destroy = true }
}

# Seed artifact so the very first boot can deploy before Jenkins has ever run.
# Jenkins overwrites this object afterwards (changes are ignored by Terraform).
data "archive_file" "seed" {
  type        = "tar.gz"
  source_dir  = var.app_source_dir
  output_path = "${path.module}/.build/documind-seed.tar.gz"
}

resource "aws_s3_object" "seed" {
  bucket                 = var.build_artifacts_bucket_name
  key                    = local.artifact_key
  source                 = data.archive_file.seed.output_path
  source_hash            = data.archive_file.seed.output_md5
  server_side_encryption = "aws:kms"

  lifecycle {
    ignore_changes = [source, source_hash, etag, version_id, tags_all]
  }
}

# Jenkins: ONE server, same private subnet as the app instances
resource "aws_instance" "jenkins" {
  subnet_id = var.private_subnet_ids[0]

  launch_template {
    id      = aws_launch_template.this["jenkins"].id
    version = aws_launch_template.this["jenkins"].latest_version
  }

  tags = { Name = "${var.name_prefix}-jenkins", Role = "documind-jenkins", Env = "prod" }
}