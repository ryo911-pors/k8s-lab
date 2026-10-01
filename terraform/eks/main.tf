terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
      version = "~> 6.0"
    }

    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.0"
    }

  }
  backend "s3" {
    bucket       = "ryo-tfstate-321604617840"
    key          = "eks/terraform.tfstate"
    region       = "us-east-1"
    use_lockfile = true
  }
}

provider "aws" {
  region = "us-east-1"
}

provider "helm" {
  kubernetes = {
    host                   = aws_eks_cluster.main.endpoint
    cluster_ca_certificate = base64decode(aws_eks_cluster.main.certificate_authority[0].data)
    exec = {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      args        = ["eks", "get-token", "--cluster-name", aws_eks_cluster.main.name, "--region", "us-east-1"]
    }
  }
}

# state 置き場の S3 バケット（ryo-tfstate-321604617840）は ../bootstrap で管理する。
# ここで destroy しても巻き込まれないよう、ディレクトリごと分けてある。

resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_hostnames = true
  enable_dns_support   = true

  tags = {
    Name = "vllm-lab"
  }
}

resource "aws_subnet" "a" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.1.0/24"
  availability_zone       = "us-east-1a"
  map_public_ip_on_launch = true
}

resource "aws_subnet" "b" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.0.2.0/24"
  availability_zone       = "us-east-1b"
  map_public_ip_on_launch = true
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "a" {
  subnet_id      = aws_subnet.a.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "b" {
  subnet_id      = aws_subnet.b.id
  route_table_id = aws_route_table.public.id
}

resource "aws_iam_role" "cluster" {
  name = "vllm-lab-cluster"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "eks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "cluster" {
  role       = aws_iam_role.cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_eks_cluster" "main" {
  name     = "vllm-lab"
  version  = "1.36"
  role_arn = aws_iam_role.cluster.arn

  vpc_config {
    subnet_ids = [aws_subnet.a.id, aws_subnet.b.id]
  }

  access_config {
    authentication_mode                         = "API"
    bootstrap_cluster_creator_admin_permissions = true
  }

  upgrade_policy {
    support_type = "STANDARD"
  }
  
  depends_on = [aws_iam_role_policy_attachment.cluster]
}


resource "aws_iam_role" "node" {
  name = "vllm-lab-node"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
  ])

  role       = aws_iam_role.node.name
  policy_arn = each.value
}

resource "aws_eks_node_group" "cpu" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "cpu"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = [aws_subnet.a.id, aws_subnet.b.id]
  instance_types  = ["t3.medium"]
  disk_size       = 50 # 負荷用 Pod で vLLM イメージ（8.7GB）を使うため。20GB だと Evicted になった

  scaling_config {
    desired_size = 2
    min_size     = 1
    max_size     = 3
  }

    depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_route_table_association.a,
    aws_route_table_association.b,
  ]

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

# イメージ pull はディスク書込が gp3 標準の 125MiB/s に張り付いて遅かった。
# g5.xlarge の EBS 帯域の上限は 437.5MB/s なので、それに近い 400MiB/s まで上げる。
resource "aws_launch_template" "gpu" {
  name = "vllm-lab-gpu"

  user_data = base64encode(<<-EOT
    MIME-Version: 1.0
    Content-Type: multipart/mixed; boundary="BOUNDARY"

    --BOUNDARY
    Content-Type: application/node.eks.aws

    apiVersion: node.eks.aws/v1alpha1
    kind: NodeConfig
    spec:
      containerd:
        config: |
          [plugins.'io.containerd.transfer.v1.local']
          max_concurrent_downloads = 4
          concurrent_layer_fetch_buffer = 67108864

          # 上の transfer 側の設定だけでは、大きいレイヤーが分割されなかった（pull 時間が変わらず）。
          # CRI の pull を古い窓口（ローカル pull）に切り替え、そこに分割の設定を渡す
          [plugins.'io.containerd.cri.v1.images']
          use_local_image_pull = true
          max_concurrent_downloads = 4
          concurrent_layer_fetch_buffer = 67108864

    --BOUNDARY--
  EOT
  )

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 100
      volume_type           = "gp3"
      iops                  = 3000
      throughput            = 400
      delete_on_termination = true
    }
  }
}

resource "aws_eks_node_group" "gpu" {
  cluster_name    = aws_eks_cluster.main.name
  node_group_name = "gpu"
  node_role_arn   = aws_iam_role.node.arn
  subnet_ids      = [aws_subnet.a.id, aws_subnet.b.id]
  instance_types  = ["g5.xlarge"]
  ami_type        = "AL2023_x86_64_NVIDIA"

  launch_template {
    id      = aws_launch_template.gpu.id
    version = aws_launch_template.gpu.latest_version
  }

  scaling_config {
    desired_size = 0 # 最初は0台。vLLM を置くと CA が 0→1 に増やす
    min_size     = 0
    max_size     = 2
  }

  labels = {  #this node has GPU
    "nvidia.com/gpu" = "true"
    "k8s.amazonaws.com/accelerator" = "nvidia-a10g"
  }

  taint {  #pods which doesn't use GPU cannot enter the node
    key    = "nvidia.com/gpu"
    value  = "true"
    effect = "NO_SCHEDULE"
  }

  depends_on = [
    aws_iam_role_policy_attachment.node,
    aws_route_table_association.a,
    aws_route_table_association.b,
  ]

  lifecycle {
    ignore_changes = [scaling_config[0].desired_size]
  }
}

   


resource "helm_release" "nvdp" {
  name             = "nvdp"
  repository       = "https://nvidia.github.io/k8s-device-plugin"
  chart            = "nvidia-device-plugin"
  version          = "0.20.1"
  namespace        = "gpu-operator"
  create_namespace = true

  depends_on       = [aws_eks_node_group.gpu]
}

resource "aws_eks_addon" "pod_identity" {
  cluster_name = aws_eks_cluster.main.name
  addon_name   = "eks-pod-identity-agent"
}

resource "aws_iam_role" "cluster_autoscaler" {
  name = "vllm-lab-cluster-autoscaler"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "pods.eks.amazonaws.com" }
      Action    = ["sts:AssumeRole", "sts:TagSession"]
    }]
  })
}

resource "aws_iam_role_policy" "cluster_autoscaler" {
  name = "cluster-autoscaler"
  role = aws_iam_role.cluster_autoscaler.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeScalingActivities",
        "autoscaling:DescribeTags",
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup",
        "ec2:DescribeImages",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplateVersions",
        "ec2:GetInstanceTypesFromInstanceRequirements",
        "eks:DescribeNodegroup",
      ]
      Resource = "*"
    }]
  })
}

resource "aws_eks_pod_identity_association" "cluster_autoscaler" {
  cluster_name    = aws_eks_cluster.main.name
  namespace       = "kube-system"
  service_account = "cluster-autoscaler"
  role_arn        = aws_iam_role.cluster_autoscaler.arn
}


resource "helm_release" "cluster_autoscaler" {
  name       = "cluster-autoscaler"
  repository = "https://kubernetes.github.io/autoscaler"
  chart      = "cluster-autoscaler"
  version    = "9.59.0"
  namespace  = "kube-system"

  values = [yamlencode({
    autoDiscovery = { clusterName = aws_eks_cluster.main.name }
    awsRegion     = "us-east-1"
    image         = { tag = "v1.36.1" }
    rbac = {
      serviceAccount = { name = "cluster-autoscaler" }
    }
  })]

  depends_on = [
    aws_eks_pod_identity_association.cluster_autoscaler,
    aws_eks_addon.pod_identity,
    aws_eks_node_group.cpu,
  ]
}



