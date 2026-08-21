locals {
  create_ecs_oom_detection  = var.enable_ecs_oom_detection
  create_metric_stream      = var.enable_metric_stream
  create_fallback_s3_bucket = local.create_metric_stream && var.metrics_storage_bucket_arn == ""

  metrics_bucket_arn = local.create_metric_stream ? (
    var.metrics_storage_bucket_arn != "" ? var.metrics_storage_bucket_arn : aws_s3_bucket.metrics_storage[0].arn
  ) : ""
}

# ---------------------------------------------------------------------------
# ECS OOM kill detection: EventBridge -> CloudWatch Log Group -> Metric Filter
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_group" "ecs_oom" {
  count = local.create_ecs_oom_detection ? 1 : 0

  name              = "/aws/events/${var.name_prefix}-ecs-oom"
  retention_in_days = var.log_retention_in_days

  tags = var.tags
}

# Allows EventBridge to deliver matched events into the log group above.
resource "aws_cloudwatch_log_resource_policy" "ecs_oom_eventbridge" {
  count = local.create_ecs_oom_detection ? 1 : 0

  policy_name = "${var.name_prefix}-ecs-oom-eventbridge"

  policy_document = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EventBridgeToCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "events.amazonaws.com"
        }
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.ecs_oom[0].arn}:*"
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_cloudwatch_event_rule.ecs_oom[0].arn
          }
        }
      }
    ]
  })
}

resource "aws_cloudwatch_event_rule" "ecs_oom" {
  count = local.create_ecs_oom_detection ? 1 : 0

  name        = "${var.name_prefix}-ecs-oom"
  description = "Matches ECS Task State Change events where the task was stopped due to an OutOfMemoryError."

  event_pattern = jsonencode({
    source      = ["aws.ecs"]
    detail-type = ["ECS Task State Change"]
    detail = merge(
      {
        stoppedReason = [{ wildcard = "*OutOfMemoryError*" }]
      },
      length(var.ecs_cluster_arns) > 0 ? {
        clusterArn = var.ecs_cluster_arns
      } : {}
    )
  })

  tags = var.tags
}

resource "aws_cloudwatch_event_target" "ecs_oom_to_log_group" {
  count = local.create_ecs_oom_detection ? 1 : 0

  rule = aws_cloudwatch_event_rule.ecs_oom[0].name
  arn  = aws_cloudwatch_log_group.ecs_oom[0].arn
}

resource "aws_cloudwatch_log_metric_filter" "ecs_oom" {
  count = local.create_ecs_oom_detection ? 1 : 0

  name           = "${var.name_prefix}-ecs-oom"
  log_group_name = aws_cloudwatch_log_group.ecs_oom[0].name
  pattern        = "{ $.detail.stoppedReason = \"*OutOfMemoryError*\" }"

  metric_transformation {
    namespace     = var.oom_metric_namespace
    name          = var.oom_metric_name
    value         = "1"
    default_value = "0"
  }

  depends_on = [aws_cloudwatch_log_resource_policy.ecs_oom_eventbridge]
}

# ---------------------------------------------------------------------------
# Generic log-derived metric filters (bring-your-own log group)
# ---------------------------------------------------------------------------

resource "aws_cloudwatch_log_metric_filter" "custom" {
  for_each = var.custom_metric_filters

  name           = each.key
  log_group_name = each.value.log_group_name
  pattern        = each.value.pattern

  metric_transformation {
    namespace     = each.value.metric_namespace
    name          = each.value.metric_name
    value         = each.value.metric_value
    default_value = each.value.default_value
  }
}

# ---------------------------------------------------------------------------
# Long-term metric storage: CloudWatch Metric Stream -> Kinesis Firehose -> S3
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "metrics_storage" {
  count = local.create_fallback_s3_bucket ? 1 : 0

  bucket = var.metrics_storage_bucket_name

  tags = var.tags
}

data "aws_iam_policy_document" "metric_stream_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["streams.metrics.cloudwatch.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "metric_stream" {
  count = local.create_metric_stream ? 1 : 0

  name               = "${var.name_prefix}-metric-stream"
  assume_role_policy = data.aws_iam_policy_document.metric_stream_assume_role.json

  tags = var.tags
}

data "aws_iam_policy_document" "metric_stream_permissions" {
  count = local.create_metric_stream ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "firehose:PutRecord",
      "firehose:PutRecordBatch",
    ]
    resources = [aws_kinesis_firehose_delivery_stream.metrics[0].arn]
  }
}

resource "aws_iam_role_policy" "metric_stream" {
  count = local.create_metric_stream ? 1 : 0

  name   = "${var.name_prefix}-metric-stream"
  role   = aws_iam_role.metric_stream[0].id
  policy = data.aws_iam_policy_document.metric_stream_permissions[0].json
}

resource "aws_cloudwatch_metric_stream" "this" {
  count = local.create_metric_stream ? 1 : 0

  name          = "${var.name_prefix}-metric-stream"
  role_arn      = aws_iam_role.metric_stream[0].arn
  firehose_arn  = aws_kinesis_firehose_delivery_stream.metrics[0].arn
  output_format = "json"

  dynamic "include_filter" {
    for_each = var.metric_stream_namespaces
    content {
      namespace = include_filter.value
    }
  }

  tags = var.tags
}

data "aws_iam_policy_document" "firehose_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["firehose.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "firehose" {
  count = local.create_metric_stream ? 1 : 0

  name               = "${var.name_prefix}-firehose"
  assume_role_policy = data.aws_iam_policy_document.firehose_assume_role.json

  tags = var.tags
}

data "aws_iam_policy_document" "firehose_permissions" {
  count = local.create_metric_stream ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "s3:AbortMultipartUpload",
      "s3:GetBucketLocation",
      "s3:GetObject",
      "s3:ListBucket",
      "s3:ListBucketMultipartUploads",
      "s3:PutObject",
    ]
    resources = [
      local.metrics_bucket_arn,
      "${local.metrics_bucket_arn}/*",
    ]
  }

  dynamic "statement" {
    for_each = var.enable_firehose_logging ? [1] : []
    content {
      effect    = "Allow"
      actions   = ["logs:PutLogEvents"]
      resources = ["${aws_cloudwatch_log_group.firehose[0].arn}:*"]
    }
  }
}

resource "aws_iam_role_policy" "firehose" {
  count = local.create_metric_stream ? 1 : 0

  name   = "${var.name_prefix}-firehose"
  role   = aws_iam_role.firehose[0].id
  policy = data.aws_iam_policy_document.firehose_permissions[0].json
}

resource "aws_cloudwatch_log_group" "firehose" {
  count = local.create_metric_stream && var.enable_firehose_logging ? 1 : 0

  name              = "/aws/kinesisfirehose/${var.name_prefix}-metrics"
  retention_in_days = var.log_retention_in_days

  tags = var.tags
}

resource "aws_kinesis_firehose_delivery_stream" "metrics" {
  count = local.create_metric_stream ? 1 : 0

  name        = "${var.name_prefix}-metrics"
  destination = "extended_s3"

  extended_s3_configuration {
    role_arn           = aws_iam_role.firehose[0].arn
    bucket_arn         = local.metrics_bucket_arn
    prefix             = var.firehose_s3_prefix
    buffering_size     = var.firehose_buffer_size
    buffering_interval = var.firehose_buffer_interval

    dynamic "cloudwatch_logging_options" {
      for_each = var.enable_firehose_logging ? [1] : []
      content {
        enabled         = true
        log_group_name  = aws_cloudwatch_log_group.firehose[0].name
        log_stream_name = "S3Delivery"
      }
    }
  }

  tags = var.tags
}
