terraform {
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 5.70" }
  }
}

# ---------- Glue Catalog ----------

resource "aws_glue_catalog_database" "main" {
  name = "callcenter_${var.env}"
}

resource "aws_glue_catalog_table" "consult_results" {
  name          = "consult_results"
  database_name = aws_glue_catalog_database.main.name
  table_type    = "EXTERNAL_TABLE"

  parameters = {
    "classification"      = "parquet"
    "parquet.compression" = "SNAPPY"
    "EXTERNAL"            = "TRUE"
  }

  partition_keys {
    name = "year"
    type = "int"
  }
  partition_keys {
    name = "month"
    type = "int"
  }
  partition_keys {
    name = "day"
    type = "int"
  }

  storage_descriptor {
    location      = "s3://${var.bucket_analytics_id}/consult-results/"
    input_format  = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetInputFormat"
    output_format = "org.apache.hadoop.hive.ql.io.parquet.MapredParquetOutputFormat"

    ser_de_info {
      serialization_library = "org.apache.hadoop.hive.ql.io.parquet.serde.ParquetHiveSerDe"
    }

    columns {
      name = "callId"
      type = "string"
    }
    columns {
      name = "agentId"
      type = "string"
    }
    columns {
      name = "startedAt"
      type = "string"
    }
    columns {
      name = "durationSec"
      type = "int"
    }
    columns {
      name = "category_대code"
      type = "string"
    }
    columns {
      name = "category_대name"
      type = "string"
    }
    columns {
      name = "category_중code"
      type = "string"
    }
    columns {
      name = "category_중name"
      type = "string"
    }
    columns {
      name = "category_소code"
      type = "string"
    }
    columns {
      name = "category_소name"
      type = "string"
    }
    columns {
      name = "confidence"
      type = "double"
    }
    columns {
      name = "reason"
      type = "string"
    }
    columns {
      name = "verified"
      type = "string"
    }
    columns {
      name = "status"
      type = "string"
    }
    columns {
      name = "modelPath"
      type = "array<string>"
    }
    columns {
      name = "promptVersion"
      type = "string"
    }
    columns {
      name = "classifiedAt"
      type = "string"
    }
  }
}

# ---------- Athena Workgroup ----------

resource "aws_athena_workgroup" "main" {
  name = "callcenter-${var.env}"

  configuration {
    enforce_workgroup_configuration = true

    result_configuration {
      output_location = "s3://${var.bucket_analytics_id}/athena-results/"

      encryption_configuration {
        encryption_option = "SSE_KMS"
        kms_key_arn       = var.kms_analytics_arn
      }
    }
  }
}

# ---------- Firehose Delivery Stream (Parquet conversion) ----------

resource "aws_iam_role" "firehose" {
  name = "callcenter-${var.env}-firehose"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "firehose.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "firehose" {
  role = aws_iam_role.firehose.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetBucketLocation", "s3:AbortMultipartUpload", "s3:ListBucketMultipartUploads"]
        Resource = [
          var.bucket_analytics_arn,
          "${var.bucket_analytics_arn}/*"
        ]
      },
      {
        Effect   = "Allow"
        Action   = ["glue:GetTable", "glue:GetTableVersion", "glue:GetTableVersions"]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["kms:GenerateDataKey", "kms:Decrypt"]
        Resource = var.kms_analytics_arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:PutLogEvents", "logs:CreateLogStream"]
        Resource = "${aws_cloudwatch_log_group.firehose.arn}:*"
      },
    ]
  })
}

resource "aws_cloudwatch_log_group" "firehose" {
  name              = "/aws/kinesisfirehose/callcenter-${var.env}-consult"
  retention_in_days = 30
}

resource "aws_kinesis_firehose_delivery_stream" "consult" {
  name        = "callcenter-${var.env}-consult-fh"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn            = aws_iam_role.firehose.arn
    bucket_arn          = var.bucket_analytics_arn
    prefix              = "consult-results/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    error_output_prefix = "consult-results-errors/!{firehose:error-output-type}/year=!{timestamp:yyyy}/month=!{timestamp:MM}/day=!{timestamp:dd}/"
    buffering_size      = 64
    buffering_interval  = 60
    kms_key_arn         = var.kms_analytics_arn
    compression_format  = "UNCOMPRESSED" # Parquet writer handles internally

    cloudwatch_logging_options {
      enabled         = true
      log_group_name  = aws_cloudwatch_log_group.firehose.name
      log_stream_name = "S3Delivery"
    }

    data_format_conversion_configuration {
      enabled = true

      input_format_configuration {
        deserializer {
          open_x_json_ser_de {}
        }
      }

      output_format_configuration {
        serializer {
          parquet_ser_de {
            compression = "SNAPPY"
          }
        }
      }

      schema_configuration {
        database_name = aws_glue_catalog_database.main.name
        table_name    = aws_glue_catalog_table.consult_results.name
        role_arn      = aws_iam_role.firehose.arn
      }
    }
  }
}
