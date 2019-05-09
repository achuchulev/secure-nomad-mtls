// Generates random name for instances
module "random_name" {
  source = "../random_pet"
}

// Generates AWS key pairs for instances
resource "aws_key_pair" "my_key" {
  key_name   = "key-${module.random_name.name}"
  public_key = "${var.public_key}"
}

// Generates an IAM policy document in JSON format
data "aws_iam_policy_document" "assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

// Creates an IAM Role and Instance Profile with a necessary permission required for Nomad Cloud-Join
resource "aws_iam_role" "nomad" {
  name               = "${var.nomad_region}-${var.dc}-${var.role_name}-${var.instance_role}"
  assume_role_policy = "${data.aws_iam_policy_document.assume_role.json}"
}

data "aws_iam_policy_document" "nomad" {
  statement {
    sid       = "AllowSelfAssembly"
    effect    = "Allow"
    resources = ["*"]

    actions = [
      "ec2:DescribeInstances",
    ]
  }
}

// Generates an IAM policy document in JSON format
resource "aws_iam_role_policy" "nomad" {
  name   = "${var.nomad_region}-${var.dc}-${var.role_name}-${var.instance_role}"
  role   = "${aws_iam_role.nomad.id}"
  policy = "${data.aws_iam_policy_document.nomad.json}"
}

// This will provides an IAM instance profile.
resource "aws_iam_instance_profile" "nomad" {
  name = "${var.nomad_region}-${var.dc}-${var.role_name}-${var.instance_role}"
  role = "${aws_iam_role.nomad.name}"
}

// Creates AWS EC2 instances for nomad server/client
resource "aws_instance" "new_instance" {
  count         = "${var.nomad_instance_count}"
  ami           = "${var.ami}"
  instance_type = "${var.instance_type}"

  availability_zone = "${var.availability_zone}"

  subnet_id              = "${var.subnet_id}"
  vpc_security_group_ids = ["${var.vpc_security_group_ids}"]
  iam_instance_profile   = "${aws_iam_instance_profile.nomad.id}"
  key_name               = "${aws_key_pair.my_key.id}"

  tags {
    Name       = "${var.dc}-${module.random_name.name}-${var.instance_role}-0${count.index + 1}"
    nomad-node = "${var.instance_role}"
  }

  provisioner "file" {
    source      = "${path.root}/config/nomad.service"
    destination = "/tmp/nomad.service"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = "${file("~/.ssh/id_rsa")}"
    }
  }

  provisioner "file" {
    source      = "${path.root}/scripts/provision-${var.instance_role}.sh"
    destination = "/tmp/provision.sh"

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = "${file("~/.ssh/id_rsa")}"
    }
  }

  provisioner "remote-exec" {
    inline = [
      "sudo chmod +x /tmp/provision.sh",
      "sudo /tmp/provision.sh ${var.nomad_region} ${var.dc} ${var.authoritative_region} '${var.retry_join}'",
      "sudo cp /tmp/nomad.service /etc/systemd/system",
      "sudo systemctl enable nomad.service",
      "sudo systemctl start nomad.service",
      "sudo rm -rf /tmp/*",
    ]

    connection {
      type        = "ssh"
      user        = "ubuntu"
      private_key = "${file("~/.ssh/id_rsa")}"
    }
  }
}
