module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 19.17.2"

  cluster_name    = "${var.env_name}-cluster"
  cluster_version = var.cluster_version

  cluster_endpoint_public_access  = true
  enable_irsa = true

  cluster_addons = var.cluster_addons

  vpc_id = module.vpc.vpc_id
  subnet_ids = concat(sort(module.vpc.public_subnets), sort(module.vpc.private_subnets))

  eks_managed_node_group_defaults = {
    instance_types = var.default_instance_types
  }

  eks_managed_node_groups = {

    nodegroup1 = {
      desired_size   = 1
      max_size       = 4
      min_size       = 1
      instance_types = ["t3.medium"]
      capacity_type  = "ON_DEMAND"
      update_config = {
        max_unavailable_percentage = 50
      }
      labels = {
        asg-group = var.nodegroup1_label
      }

      tags = {
        "k8s.io/cluster-autoscaler/enabled"                       = "true"
        "k8s.io/cluster-autoscaler/${var.cluster_name}"           = "owned"
        "k8s.io/cluster-autoscaler/node-template/label/asg-group" = "${var.nodegroup1_label}"
      }
    }

    nodegroup2 = {
      desired_size   = 0
      max_size       = 10
      min_size       = 0
      instance_types = ["c5.xlarge", "c5a.xlarge", "m5.xlarge", "m5a.xlarge"]
      capacity_type  = "SPOT"
      update_config = {
        max_unavailable_percentage = 100
      }
      labels = {
        asg-group = var.nodegroup2_label
      }
      taints = [
        {
          key    = "dedicated"
          value  = var.nodegroup2_label
          effect = "NO_SCHEDULE"
        }
      ]
      tags = {
        "k8s.io/cluster-autoscaler/enabled"                       = "true"
        "k8s.io/cluster-autoscaler/${var.cluster_name}"           = "owned"
        "k8s.io/cluster-autoscaler/node-template/taint/dedicated" = "${var.nodegroup2_label}:NoSchedule"
        "k8s.io/cluster-autoscaler/node-template/label/asg-group" = "${var.nodegroup2_label}"
      }
    }
  }
  #  EKS K8s API cluster needs to be able to talk with the EKS worker nodes with port 15017/TCP and 15012/TCP which is used by Istio
  #  Istio in order to create sidecar needs to be able to communicate with webhook and for that network passage to EKS is needed.
  node_security_group_additional_rules = {
    ingress_15017 = {
      description                   = "Cluster API - Istio Webhook namespace.sidecar-injector.istio.io"
      protocol                      = "TCP"
      from_port                     = 15017
      to_port                       = 15017
      type                          = "ingress"
      source_cluster_security_group = true
    }
    ingress_15012 = {
      description                   = "Cluster API to nodes ports/protocols"
      protocol                      = "TCP"
      from_port                     = 15012
      to_port                       = 15012
      type                          = "ingress"
      source_cluster_security_group = true
    }
  }
}

##############################################################
# Cluster Autoscaler
##############################################################
locals {
  k8s_service_account_namespace = "kube-system"
  k8s_service_account_name      = "cluster-autoscaler"
  tags = {
    Owner = "terraform"
  }
}

resource "helm_release" "cluster-autoscaler" {
  name             = "cluster-autoscaler"
  namespace        = local.k8s_service_account_namespace
  repository       = "https://kubernetes.github.io/autoscaler"
  chart            = "cluster-autoscaler"
  version          = "9.29.3"
  create_namespace = false

  set {
    name  = "awsRegion"
    value = var.aws_region
  }
  set {
    name  = "rbac.serviceAccount.name"
    value = local.k8s_service_account_name
  }
  set {
    name  = "rbac.serviceAccount.annotations.eks\\.amazonaws\\.com/role-arn"
    value = module.iam_assumable_role_admin.iam_role_arn
    type  = "string"
  }
  set {
    name  = "autoDiscovery.clusterName"
    value = var.cluster_name
  }
  set {
    name  = "autoDiscovery.enabled"
    value = "true"
  }
  set {
    name  = "rbac.create"
    value = "true"
  }
}

module "iam_assumable_role_admin" {
  source                        = "terraform-aws-modules/iam/aws//modules/iam-assumable-role-with-oidc"
  version                       = "~> 4.0"
  create_role                   = true
  role_name                     = "cluster-autoscaler-${var.cluster_name}"
  provider_url                  = replace(module.eks.cluster_oidc_issuer_url, "https://", "")
  role_policy_arns              = [aws_iam_policy.cluster_autoscaler.arn]
  oidc_fully_qualified_subjects = ["system:serviceaccount:${local.k8s_service_account_namespace}:${local.k8s_service_account_name}"]
}

resource "aws_iam_policy" "cluster_autoscaler" {
  name_prefix = "cluster-autoscaler"
  description = "EKS cluster-autoscaler policy for cluster ${module.eks.cluster_name}"
  policy      = data.aws_iam_policy_document.cluster_autoscaler.json
}

data "aws_iam_policy_document" "cluster_autoscaler" {
  statement {
    sid    = "clusterAutoscalerAll"
    effect = "Allow"

    actions = [
      "autoscaling:DescribeAutoScalingGroups",
      "autoscaling:DescribeAutoScalingInstances",
      "autoscaling:DescribeLaunchConfigurations",
      "autoscaling:DescribeTags",
      "ec2:DescribeLaunchTemplateVersions",
    ]

    resources = ["*"]
  }

  statement {
    sid    = "clusterAutoscalerOwn"
    effect = "Allow"

    actions = [
      "autoscaling:SetDesiredCapacity",
      "autoscaling:TerminateInstanceInAutoScalingGroup",
      "autoscaling:UpdateAutoScalingGroup",
    ]

    resources = ["*"]

    condition {
      test     = "StringEquals"
      variable = "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/${module.eks.cluster_name}"
      values   = ["owned"]
    }

    condition {
      test     = "StringEquals"
      variable = "autoscaling:ResourceTag/k8s.io/cluster-autoscaler/enabled"
      values   = ["true"]
    }
  }
}

################################################################################
# Supporting Resources
################################################################################
resource "aws_iam_policy" "node_additional" {
  name        = "${var.cluster_name}-additional"
  description = "${var.cluster_name} node additional policy"

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = [
          "ec2:Describe*",
        ]
        Effect   = "Allow"
        Resource = "*"
      },
    ]
  })

  tags = local.tags
}

################################################################################
# Tags for the ASG to support cluster-autoscaler scale up from 0 for nodegroup2
################################################################################

locals {

  eks_asg_tag_list_nodegroup1 = {
    "k8s.io/cluster-autoscaler/enabled" : true
    "k8s.io/cluster-autoscaler/${var.cluster_name}" : "owned"
    "k8s.io/cluster-autoscaler/node-template/label/asg-group" : var.nodegroup1_label
  }

  eks_asg_tag_list_nodegroup2 = {
    "k8s.io/cluster-autoscaler/enabled" : true
    "k8s.io/cluster-autoscaler/${var.cluster_name}" : "owned"
    "k8s.io/cluster-autoscaler/node-template/label/asg-group" : var.nodegroup2_label
    "k8s.io/cluster-autoscaler/node-template/taint/dedicated" : "${var.nodegroup2_label}:NoSchedule"
  }

}

resource "aws_autoscaling_group_tag" "nodegroup1" {
  for_each               = local.eks_asg_tag_list_nodegroup1
  autoscaling_group_name = element(module.eks.eks_managed_node_groups_autoscaling_group_names, 0)

  tag {
    key                 = each.key
    value               = each.value
    propagate_at_launch = true
  }
}

resource "aws_autoscaling_group_tag" "nodegroup2" {
  for_each               = local.eks_asg_tag_list_nodegroup2
  autoscaling_group_name = element(module.eks.eks_managed_node_groups_autoscaling_group_names, 1)

  tag {
    key                 = each.key
    value               = each.value
    propagate_at_launch = true
  }
}