# This module is customised only for roboshop project, cannot be used for remaining projects

resource "aws_lb_target_group" "component" {
  name     = "${local.name}-${var.tags.Component}"
  port     = 8080
  protocol = "HTTP"
  vpc_id   = var.vpc_id
  deregistration_delay = 60
  health_check {
      healthy_threshold   = 2
      interval            = 10
      unhealthy_threshold = 3
      timeout             = 5
      path                = "/health"
      port                = 8080
      matcher = "200-299"
  }
}

module "component" {
  source                 = "terraform-aws-modules/ec2-instance/aws"
  ami = data.aws_ami.centos8.id
  name                   = "${local.name}-${var.tags.Component}-ami"
  instance_type          = "t2.micro"
  vpc_security_group_ids = [var.component_sg_id]
  subnet_id = element(var.private_subnet_ids, 0)
  iam_instance_profile = var.iam_instance_profile
  tags = merge(
    var.common_tags,
    var.tags
  )
}

resource "null_resource" "component" {
  triggers = {
    instance_id = module.component.id
  }

  connection {
    host = module.component.private_ip
    type = "ssh"
    user = "centos"
    password = "DevOps321"
  }

  provisioner "file" {
    source      = "bootstrap.sh"
    destination = "/tmp/bootstrap.sh"
  }

  provisioner "remote-exec" {
    inline = [
      "chmod +x /tmp/bootstrap.sh",
      "sudo sh /tmp/bootstrap.sh ${var.tags.Component} ${var.environment} ${var.app_version}"
    ]
  }
}

resource "aws_ec2_instance_state" "component" {
  instance_id = module.component.id
  state       = "stopped"
  depends_on = [ null_resource.component ]
}

resource "aws_ami_from_instance" "component" {
  name               = "${local.name}-${var.tags.Component}-${local.current_time}"
  source_instance_id = module.component.id
  depends_on = [ aws_ec2_instance_state.component ]
}

resource "null_resource" "component_delete" {
  triggers = {
    instance_id = module.component.id
  }

  provisioner "local-exec" {
    command = "aws ec2 terminate-instances --instance-ids ${module.component.id}"
  }

  depends_on = [ aws_ami_from_instance.component]
}

resource "aws_launch_template" "component" {
  name = "${local.name}-${var.tags.Component}"
  image_id = aws_ami_from_instance.component.id
  instance_initiated_shutdown_behavior = "terminate"
  instance_type = "t2.micro"
  update_default_version = true
  vpc_security_group_ids = [var.component_sg_id]

  tag_specifications {
    resource_type = "instance"

    tags = {
      Name = "${local.name}-${var.tags.Component}"
    }
  }

}

resource "aws_autoscaling_group" "component" {
  name                      = "${local.name}-${var.tags.Component}"
  max_size                  = 10
  min_size                  = 1
  health_check_grace_period = 60
  health_check_type         = "ELB"
  desired_capacity          = 2
  vpc_zone_identifier       = var.private_subnet_ids
  target_group_arns = [ aws_lb_target_group.component.arn ]
  
  launch_template {
    id      = aws_launch_template.component.id
    version = aws_launch_template.component.latest_version
  }

  instance_refresh {
    strategy = "Rolling"
    preferences {
      min_healthy_percentage = 50
    }
    triggers = ["launch_template"]
  }

  tag {
    key                 = "Name"
    value               = "${local.name}-${var.tags.Component}"
    propagate_at_launch = true
  }

  timeouts {
    delete = "15m"
  }
}

resource "aws_lb_listener_rule" "component" {
  listener_arn = var.app_alb_listener_arn
  priority     = var.rule_priority

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.component.arn
  }


  condition {
    host_header {
      values = ["${var.tags.Component}.app-${var.environment}.${var.zone_name}"]
    }
  }
}

resource "aws_autoscaling_policy" "component" {
  autoscaling_group_name = aws_autoscaling_group.component.name
  name                   = "${local.name}-${var.tags.Component}"
  policy_type            = "TargetTrackingScaling"

  target_tracking_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ASGAverageCPUUtilization"
    }

    target_value = 5.0
  }
}