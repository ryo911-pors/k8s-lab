# state 置き場の S3 バケットだけを管理する。
# 最初に1回作ったら、ほぼ触らない。
# このディレクトリ自身の state はローカル（terraform.tfstate）に置く。消さないこと。

terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

resource "aws_s3_bucket" "tfstate" {
  bucket = "ryo-tfstate-321604617840"

  # 誤って destroy しようとしたら Terraform 側で止める
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

# 既に存在するバケットを、この state に取り込む。
# 取り込みが済めば消してもよいが、記録として残しておく。
import {
  to = aws_s3_bucket.tfstate
  id = "ryo-tfstate-321604617840"
}

import {
  to = aws_s3_bucket_versioning.tfstate
  id = "ryo-tfstate-321604617840"
}
