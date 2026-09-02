variable "name_prefix" {
  description = "Prefix applied to resource names created by this module (log groups, rules, roles, streams)."
  type        = string
  default     = "msi-cw-metrics"
}

variable "tags" {
  description = "Common tags applied to all resources created by this module."
  type        = map(string)
  default     = {}
}

# ---------------------------------------------------------------------------
# ECS OOM kill detection (EventBridge -> Log Group -> Metric Filter)
# ---------------------------------------------------------------------------

variable "enable_ecs_oom_detection" {
  description = "Whether to create the EventBridge rule, log group, and metric filter that derive an ECSTaskOOMKilled metric from ECS Task State Change events."
  type        = bool
  default     = false
}

variable "ecs_cluster_arns" {
  description = "Optional list of ECS cluster ARNs to filter OOM detection to. If empty, the EventBridge rule matches ECS Task State Change events across all clusters in the account/region."
  type        = list(string)
  default     = []
}

variable "log_retention_in_days" {
  description = "Retention period, in days, for the CloudWatch Log Group that receives ECS Task State Change events."
  type        = number
  default     = 30
}

variable "oom_metric_namespace" {
  description = "CloudWatch namespace for the derived ECS OOM kill metric."
  type        = string
  default     = "MSI/ECS"
}

variable "oom_metric_name" {
  description = "Name of the derived CloudWatch metric emitted when an ECS task is stopped due to an OutOfMemoryError."
  type        = string
  default     = "ECSTaskOOMKilled"
}

# ---------------------------------------------------------------------------
# ECS per-service restart/churn detection (EventBridge -> Log Group -> Metric
# Filter). ECS has no native per-service "restart count" the way EKS pods
# do - ECS/ContainerInsights RestartCount is dimensioned by {TaskId,
# ContainerName, ClusterName, TaskDefinitionFamily}, not {ClusterName,
# ServiceName}, and TaskId is a new random value every deployment/restart,
# so it can never be usefully alarmed on per-service. This derives a real
# per-service metric the same way OOM detection above does: every task
# belonging to an ECS-service-managed task group that stops gets counted,
# dimensioned by the values an alarm can actually hold constant
# (ClusterArn + the literal "service:<name>" group string, both taken
# verbatim from the event - not string-manipulated, since CloudWatch Logs
# metric filter dimensions can only reference raw JSON field values).
# ---------------------------------------------------------------------------

variable "enable_ecs_service_restarts" {
  description = "Whether to create the EventBridge rule, log group, and metric filter that derive a per-service ECS task-stop metric from ECS Task State Change events."
  type        = bool
  default     = false
}

variable "ecs_service_restarts_cluster_arns" {
  description = "Optional list of ECS cluster ARNs to filter service-restart detection to. If empty, the EventBridge rule matches ECS Task State Change events across all clusters in the account/region."
  type        = list(string)
  default     = []
}

variable "ecs_service_restarts_metric_namespace" {
  description = "CloudWatch namespace for the derived ECS per-service task-stop metric."
  type        = string
  default     = "MSI/ECS"
}

variable "ecs_service_restarts_metric_name" {
  description = "Name of the derived CloudWatch metric emitted when a service-managed ECS task stops - dimensioned by ClusterArn and ServiceGroup (the literal \"service:<name>\" value from the event, not just the service name)."
  type        = string
  default     = "ServiceTaskStopped"
}

# ---------------------------------------------------------------------------
# Generic log-derived metric filters
# ---------------------------------------------------------------------------

variable "custom_metric_filters" {
  description = <<-EOT
    Map of arbitrary CloudWatch Logs metric filters to create, keyed by a unique filter name.
    Use this to derive additional custom metrics (e.g. application error counts) from any
    existing log group, beyond the built-in ECS OOM use case.
  EOT
  type = map(object({
    log_group_name   = string
    pattern          = string
    metric_namespace = string
    metric_name      = string
    metric_value     = optional(string, "1")
    default_value    = optional(number)
  }))
  default = {}
}

# ---------------------------------------------------------------------------
# Metric streaming to long-term storage (CloudWatch Metric Streams -> Firehose -> S3)
# ---------------------------------------------------------------------------

variable "enable_metric_stream" {
  description = "Whether to create a CloudWatch Metric Stream and its backing Kinesis Firehose delivery stream for long-term metric storage/analytics."
  type        = bool
  default     = false
}

variable "metric_stream_namespaces" {
  description = "List of CloudWatch namespaces to include in the metric stream (e.g. [\"AWS/ECS\", \"ECS/ContainerInsights\", \"AWS/ApplicationELB\"]). Ignored if empty (no include_filter is applied and all namespaces are streamed)."
  type        = list(string)
  default     = []
}

variable "metrics_storage_bucket_arn" {
  description = "ARN of an existing S3 bucket to use as the Firehose delivery destination for long-term metric storage. Takes precedence over metrics_storage_bucket_name. Leave empty to have this module create a fallback bucket."
  type        = string
  default     = ""
}

variable "metrics_storage_bucket_name" {
  description = "Name of the S3 bucket to create as a fallback destination for metric storage when metrics_storage_bucket_arn is not supplied. Must be globally unique."
  type        = string
  default     = "REPLACE_ME-msi-cloudwatch-metrics-storage"
}

variable "firehose_buffer_size" {
  description = "Buffer size (in MiB) before Firehose delivers data to S3. AWS default is 5."
  type        = number
  default     = 5
}

variable "firehose_buffer_interval" {
  description = "Buffer interval (in seconds) before Firehose delivers data to S3. AWS default is 300."
  type        = number
  default     = 300
}

variable "firehose_s3_prefix" {
  description = "Optional S3 key prefix for objects delivered by the Firehose delivery stream."
  type        = string
  default     = "cloudwatch-metrics/"
}

variable "enable_firehose_logging" {
  description = "Whether to enable CloudWatch Logs logging for the Firehose delivery stream's S3 destination."
  type        = bool
  default     = true
}
