# Persistent JENKINS_HOME.
#
# Jenkins stores every job, every credential/API token, every installed
# plugin and every user account as plain files under /var/lib/jenkins. The
# EC2 root volume Jenkins used to run on is wiped on every replacement, so
# all of that disappeared every time the instance was replaced. Mounting
# this EFS filesystem at /var/lib/jenkins means that data now lives outside
# the instance: a brand-new EC2 instance that mounts the same filesystem
# sees the exact same Jenkins (same jobs, same users, same API tokens) that
# the old instance had.

resource "aws_efs_file_system" "jenkins_home" {
  creation_token  = "${var.name_prefix}-jenkins-home"
  encrypted       = true
  throughput_mode = "bursting"

  tags = {
    Name = "${var.name_prefix}-jenkins-home"
  }
}

# One mount target per private subnet, so whichever subnet the ASG launches
# the next Jenkins instance into, EFS is reachable from there too.
resource "aws_efs_mount_target" "jenkins_home" {
  for_each        = toset(var.private_subnet_ids)
  file_system_id  = aws_efs_file_system.jenkins_home.id
  subnet_id       = each.value
  security_groups = [aws_security_group.jenkins_efs.id]
}

resource "aws_security_group" "jenkins_efs" {
  name        = "${var.name_prefix}-jenkins-efs"
  description = "EFS for /var/lib/jenkins - NFS from Jenkins instances only"
  vpc_id      = var.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "efs_from_jenkins" {
  security_group_id            = aws_security_group.jenkins_efs.id
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049
  referenced_security_group_id = aws_security_group.jenkins.id
}

resource "aws_vpc_security_group_egress_rule" "jenkins_to_efs" {
  security_group_id            = aws_security_group.jenkins.id
  ip_protocol                  = "tcp"
  from_port                    = 2049
  to_port                      = 2049
  referenced_security_group_id = aws_security_group.jenkins_efs.id
}
