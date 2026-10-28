resource "aws_autoscaling_group" "app" {
  name                      = "${var.name_prefix}-documind-app"
  min_size                  = var.asg_min
  desired_capacity          = var.asg_desired
  max_size                  = var.asg_max
  vpc_zone_identifier       = var.private_subnet_ids
  target_group_arns         = [aws_lb_target_group.app.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 300

  launch_template {
    id      = aws_launch_template.this["app"].id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences { min_healthy_percentage = 50 }
  }

  tag {
    key                 = "Name"
    value               = "${var.name_prefix}-app"
    propagate_at_launch = true
  }

  tag {
    key                 = "Env"
    value               = "prod"
    propagate_at_launch = true
  }

  depends_on = [aws_s3_object.seed]
}

# Jenkins used to be a single aws_instance with nothing watching it: if it
# died, nothing noticed and nothing replaced it. Putting it in an ASG with
# min=max=desired=1 means EC2 health checks + the ALB target group health
# check now detect a dead Jenkins and launch a replacement automatically,
# the same way the app tier already works.
resource "aws_autoscaling_group" "jenkins" {
  name                      = "${var.name_prefix}-jenkins"
  min_size                  = 1
  desired_capacity          = 1
  max_size                  = 1
  vpc_zone_identifier       = var.private_subnet_ids
  target_group_arns         = [aws_lb_target_group.jenkins.arn]
  health_check_type         = "ELB"
  health_check_grace_period = 420 # Jenkins + plugin install takes longer than the app to come up

  launch_template {
    id      = aws_launch_template.this["jenkins"].id
    version = "$Latest"
  }

  instance_refresh {
    strategy = "Rolling"
    preferences { min_healthy_percentage = 0 } # only one instance to begin with, nothing to keep "healthy" during a refresh
  }

  tag {
    key                 = "Name"
    value               = "${var.name_prefix}-jenkins"
    propagate_at_launch = true
  }
  tag {
    key                 = "Role"
    value               = "documind-jenkins"
    propagate_at_launch = true
  }
  tag {
    key                 = "Env"
    value               = "prod"
    propagate_at_launch = true
  }

  # Wait for EFS to actually be mountable before the first Jenkins instance
  # tries to mount it.
  depends_on = [aws_efs_mount_target.jenkins_home]
}
