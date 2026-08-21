# msi-terraform-cloudwatch-metrics

Derives CloudWatch metrics that don't exist natively (log-based metric filters, EventBridge-triggered
signals like ECS OOM kills) and streams metrics to long-term storage for analytics.

This module is one of several independently-versioned modules split out of MSI's CloudWatch
observability initiative, so that bumping one module's version doesn't force a version bump on the
others. It is a pure "derive metrics" module — it does not create alarms. Metrics it emits (namespace
+ name) are meant to be consumed by the sibling [`msi-terraform-cloudwatch-alarms`](https://github.com/MemberSolutionsInc/msi-terraform-cloudwatch-alarms)
module.

## Use cases

### 1. ECS OOM kill detection (no native CloudWatch metric)

ECS does not emit a CloudWatch metric when a task is killed by the OOM killer — the only signal is the
`stoppedReason` field on an `ECS Task State Change` event, e.g. `"OutOfMemoryError: Container killed
due to memory usage"`. This module reconstructs a real, alarmable metric from that event:

```
ECS Task State Change event (EventBridge, source = aws.ecs)
        │
        ▼
EventBridge Rule  ──filter: detail.stoppedReason contains "OutOfMemoryError"──▶  CloudWatch Log Group
                                                                                          │
                                                                                          ▼
                                                                          CloudWatch Logs Metric Filter
                                                                                          │
                                                                                          ▼
                                                                     Custom metric (default: MSI/ECS ▸
                                                                          ECSTaskOOMKilled)
```

Enable with `enable_ecs_oom_detection = true`. Optionally scope the EventBridge rule to specific
clusters with `ecs_cluster_arns`.

The same log-group → metric-filter mechanism is exposed generically via `custom_metric_filters`, so any
future "derive a metric from a log pattern" need (custom application error counts, specific log
messages, etc.) can reuse this module against any existing log group — not just the ECS OOM case.

### 2. Long-term metric storage for analytics

CloudWatch's own metric retention is capped (15 months max) and is awkward/expensive to query
historically. This module can stream selected metric namespaces out continuously via a
CloudWatch Metric Stream into a Kinesis Firehose delivery stream, landing them in S3 as JSON for
long-term storage and downstream analytics (Athena, QuickSight, etc.):

```
CloudWatch Metrics (namespaces in metric_stream_namespaces)
        │
        ▼
CloudWatch Metric Stream (output_format = json)
        │
        ▼
Kinesis Firehose (extended_s3 destination)
        │
        ▼
S3 bucket (metrics_storage_bucket_arn, or a fallback bucket created by this module)
```

Enable with `enable_metric_stream = true`. Pass `metrics_storage_bucket_arn` to land data in a bucket
owned by whatever module manages the org's S3/storage estate. If left empty, this module creates a
fallback bucket (`metrics_storage_bucket_name`) so it remains usable standalone.

## Usage

```hcl
module "cloudwatch_metrics" {
  source = "git::https://github.com/MemberSolutionsInc/msi-terraform-cloudwatch-metrics.git?ref=v0.1.0"

  name_prefix = "msi-prod"

  # ECS OOM kill detection
  enable_ecs_oom_detection = true
  ecs_cluster_arns = [
    "arn:aws:ecs:us-east-1:123456789012:cluster/prod-cluster",
  ]
  log_retention_in_days = 30

  # Additional custom log-derived metrics
  custom_metric_filters = {
    app-fatal-errors = {
      log_group_name   = "/ecs/my-app"
      pattern          = "\"FATAL\""
      metric_namespace = "MSI/MyApp"
      metric_name      = "FatalErrorCount"
    }
  }

  # Long-term metric storage
  enable_metric_stream = true
  metric_stream_namespaces = [
    "AWS/ECS",
    "ECS/ContainerInsights",
    "AWS/ApplicationELB",
  ]
  metrics_storage_bucket_arn = "arn:aws:s3:::msi-prod-metrics-storage"

  tags = {
    Environment = "prod"
    ManagedBy   = "terraform"
  }
}
```

## Inputs

| Name | Description | Type | Default |
|---|---|---|---|
| `name_prefix` | Prefix applied to resource names created by this module. | `string` | `"msi-cw-metrics"` |
| `tags` | Common tags applied to all resources created by this module. | `map(string)` | `{}` |
| `enable_ecs_oom_detection` | Whether to create the EventBridge rule, log group, and metric filter for ECS OOM kill detection. | `bool` | `false` |
| `ecs_cluster_arns` | Optional list of ECS cluster ARNs to filter OOM detection to. | `list(string)` | `[]` |
| `log_retention_in_days` | Retention period, in days, for CloudWatch Log Groups created by this module. | `number` | `30` |
| `oom_metric_namespace` | CloudWatch namespace for the derived ECS OOM kill metric. | `string` | `"MSI/ECS"` |
| `oom_metric_name` | Name of the derived ECS OOM kill metric. | `string` | `"ECSTaskOOMKilled"` |
| `custom_metric_filters` | Map of arbitrary CloudWatch Logs metric filters to create, keyed by filter name. | `map(object)` | `{}` |
| `enable_metric_stream` | Whether to create the CloudWatch Metric Stream and Firehose delivery stream. | `bool` | `false` |
| `metric_stream_namespaces` | List of CloudWatch namespaces to include in the metric stream. | `list(string)` | `[]` |
| `metrics_storage_bucket_arn` | ARN of an existing S3 bucket to use as the Firehose destination. | `string` | `""` |
| `metrics_storage_bucket_name` | Name of the fallback S3 bucket created when `metrics_storage_bucket_arn` is empty. | `string` | `"REPLACE_ME-msi-cloudwatch-metrics-storage"` |
| `firehose_buffer_size` | Firehose buffer size (MiB) before delivering to S3. | `number` | `5` |
| `firehose_buffer_interval` | Firehose buffer interval (seconds) before delivering to S3. | `number` | `300` |
| `firehose_s3_prefix` | S3 key prefix for objects delivered by Firehose. | `string` | `"cloudwatch-metrics/"` |
| `enable_firehose_logging` | Whether to enable CloudWatch Logs logging for the Firehose S3 destination. | `bool` | `true` |

`custom_metric_filters` object shape:

```hcl
map(object({
  log_group_name   = string
  pattern          = string
  metric_namespace = string
  metric_name      = string
  metric_value     = optional(string, "1")
  default_value    = optional(number)
}))
```

## Outputs

| Name | Description |
|---|---|
| `ecs_oom_metric_namespace` | Namespace of the derived ECS OOM kill metric (for the alarms module). |
| `ecs_oom_metric_name` | Name of the derived ECS OOM kill metric (for the alarms module). |
| `ecs_oom_log_group_name` | Name of the log group receiving ECS Task State Change events. |
| `custom_metric_filter_ids` | Map of `custom_metric_filters` key to metric filter resource ID. |
| `custom_metric_filter_names` | Map of `custom_metric_filters` key to metric filter name. |
| `metric_stream_arn` | ARN of the CloudWatch Metric Stream. |
| `firehose_delivery_stream_arn` | ARN of the Kinesis Firehose delivery stream. |
| `metrics_storage_bucket_arn` | ARN of the S3 bucket ultimately used for metric storage. |

## Requirements

| Name | Version |
|---|---|
| terraform | ~> 1.0 |
| aws | ~> 5.0 |
