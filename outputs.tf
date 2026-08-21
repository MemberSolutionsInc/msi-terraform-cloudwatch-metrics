output "ecs_oom_metric_namespace" {
  description = "CloudWatch namespace of the derived ECS OOM kill metric (null if enable_ecs_oom_detection = false). Consumed by the sibling msi-terraform-cloudwatch-alarms module."
  value       = local.create_ecs_oom_detection ? var.oom_metric_namespace : null
}

output "ecs_oom_metric_name" {
  description = "Name of the derived ECS OOM kill metric (null if enable_ecs_oom_detection = false). Consumed by the sibling msi-terraform-cloudwatch-alarms module."
  value       = local.create_ecs_oom_detection ? var.oom_metric_name : null
}

output "ecs_oom_log_group_name" {
  description = "Name of the CloudWatch Log Group receiving ECS Task State Change events (null if enable_ecs_oom_detection = false)."
  value       = local.create_ecs_oom_detection ? aws_cloudwatch_log_group.ecs_oom[0].name : null
}

output "custom_metric_filter_ids" {
  description = "Map of custom_metric_filters key to the resulting aws_cloudwatch_log_metric_filter resource ID."
  value       = { for k, v in aws_cloudwatch_log_metric_filter.custom : k => v.id }
}

output "custom_metric_filter_names" {
  description = "Map of custom_metric_filters key to the resulting metric filter name."
  value       = { for k, v in aws_cloudwatch_log_metric_filter.custom : k => v.name }
}

output "metric_stream_arn" {
  description = "ARN of the CloudWatch Metric Stream (null if enable_metric_stream = false)."
  value       = local.create_metric_stream ? aws_cloudwatch_metric_stream.this[0].arn : null
}

output "firehose_delivery_stream_arn" {
  description = "ARN of the Kinesis Firehose delivery stream used for long-term metric storage (null if enable_metric_stream = false)."
  value       = local.create_metric_stream ? aws_kinesis_firehose_delivery_stream.metrics[0].arn : null
}

output "metrics_storage_bucket_arn" {
  description = "ARN of the S3 bucket ultimately used for metric storage — either the supplied metrics_storage_bucket_arn or the fallback bucket created by this module (null if enable_metric_stream = false)."
  value       = local.create_metric_stream ? local.metrics_bucket_arn : null
}
