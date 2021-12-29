#   Monitoring for multiple Cloud Composer environments
#   
#   Usage:
#       1. Create a new project that you will use for monitoring of Cloud Composer environments in other projects
#       2. Store the name of this project in "monitoring_project" variable below, in the locals block
#       3. Save the list of projects with Cloud Composer environments to be monitored in "monitored_projects", set in the locals block
#       4. Run "terraform apply"
#
#   The script creates:
#       In monitored projects:
#           1. Custom metrics for Composer monitoring (log-based)
#       In the monitoring project:
#           1. Adds monitored projects to Cloud Monitoring
#           2. Creates Alert Policies
#           3. Creates Monitoring Dashboard
#


#######################################################
#  
# Overall settings
#
########################################################


locals {
    monitoring_project = "ihub-sample"
    monitored_projects = toset(["filipsdirtytests4", "filipstest5"])
}

#######################################################
#  
# Provider
#
########################################################

provider "google-beta" {
  region = "us-central1"
  project = local.monitoring_project
}

#######################################################
#  
# Add Monitored Projects to the Monitoring project
#
########################################################

resource "google_monitoring_monitored_project" "project1monitoring" {
  for_each = local.monitored_projects
  metrics_scope = join("",["locations/global/metricsScopes/",local.monitoring_project])
  name          = "${each.value}"
  provider      = google-beta
}

#######################################################
#  
# Create custom metrics in Monitored Projects
#
########################################################

resource "google_logging_metric" "tasks_for_retry" {
  for_each = local.monitored_projects
  project = "${each.value}"
  name   = "Composer_Airflow_new_tasks_for_RETRY"
  filter = "resource.type=\"cloud_composer_environment\" log_name:\"airflow-scheduler\" \"Marking task as UP_FOR_RETRY\""
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    labels {
      key         = "environment_name"
      value_type  = "STRING"
      description = "Composer environment"
    }
    labels {
      key         = "project_id"
      value_type  = "STRING"
      description = "Composer project"
    }
    display_name = "Composer Airflow tasks for RETRY"
  }

  label_extractors = {
    "environment_name" = "EXTRACT(resource.labels.environment_name)"
    "project_id"  = "EXTRACT(resource.labels.project_id)"
  }
}

resource "google_logging_metric" "tasks_failed" {
  for_each = local.monitored_projects
  project = "${each.value}"
  name   = "Composer_Airflow_new_FAILED_tasks"
  filter = "resource.type=\"cloud_composer_environment\" log_name:\"airflow-scheduler\" \"Marking task as FAILED\""
  metric_descriptor {
    metric_kind = "DELTA"
    value_type  = "INT64"
    labels {
      key         = "environment_name"
      value_type  = "STRING"
      description = "Composer environment"
    }
    labels {
      key         = "project_id"
      value_type  = "STRING"
      description = "Composer project"
    }
    display_name = "Composer Airflow FAILED tasks"
  }

  label_extractors = {
    "environment_name" = "EXTRACT(resource.labels.environment_name)"
    "project_id"  = "EXTRACT(resource.labels.project_id)"
  }
}

resource "time_sleep" "tasks_for_retry" {
  depends_on = [google_logging_metric.tasks_for_retry]

  create_duration = "60s"
}

resource "time_sleep" "tasks_failed" {
  depends_on = [google_logging_metric.tasks_failed]

  create_duration = "60s"
}

#######################################################
#  
# Create alert policies in Monitoring project
#
########################################################

resource "google_monitoring_alert_policy" "environment_health" {
  display_name = "Environment Health"
  combiner     = "OR"
  conditions {
    display_name = "Environmnet Health"
    condition_monitoring_query_language {
        query = join("", [
            "fetch cloud_composer_environment",
            "| {metric 'composer.googleapis.com/environment/dagbag_size'",
            "| group_by 5m, [value_dagbag_size_mean: if(mean(value.dagbag_size) > 0, 1, 0)]",
            "| align mean_aligner(5m)",
            "| group_by [resource.project_id, resource.environment_name],    [value_dagbag_size_mean_aggregate: aggregate(value_dagbag_size_mean)];  ",
            "metric 'composer.googleapis.com/environment/healthy'",
            "| group_by 5m,    [value_sum_signals: aggregate(if(value.healthy,1,0))]",
            "| align mean_aligner(5m)| absent_for 5m }",
            "| outer_join 0",
            "| group_by [resource.project_id, resource.environment_name]",
            "| value val(2)",
            "| align mean_aligner(5m)",
            "| window(5m)",
            "| condition val(0) < 0.9"
            ])
        duration = "120s"
        trigger {
            count = "1"
        }
    }
  }
}

resource "google_monitoring_alert_policy" "database_health" {
  display_name = "Database Health"
  combiner     = "OR"
  conditions {
    display_name = "Database Health"
    condition_monitoring_query_language {
        query = join("", [
            "fetch cloud_composer_environment",
            "| metric 'composer.googleapis.com/environment/database_health'",
            "| group_by 5m,",
            "    [value_database_health_fraction_true: fraction_true(value.database_health)]",
            "| every 5m",
            "| group_by 5m,",
            "    [value_database_health_fraction_true_aggregate:",
            "       aggregate(value_database_health_fraction_true)]",
            "| every 5m",
            "| group_by [resource.project_id, resource.environment_name],",
            "    [value_database_health_fraction_true_aggregate_aggregate:",
            "       aggregate(value_database_health_fraction_true_aggregate)]",
            "| condition val() < 0.95"])
        duration = "120s"
        trigger {
            count = "1"
        }
    }
  }
}

resource "google_monitoring_alert_policy" "webserver_health" {
  display_name = "Web Server Health"
  combiner     = "OR"
  conditions {
    display_name = "Web Server Health"
    condition_monitoring_query_language {
        query = join("", [
            "fetch cloud_composer_environment",
            "| metric 'composer.googleapis.com/environment/web_server/health'",
            "| group_by 5m, [value_health_fraction_true: fraction_true(value.health)]",
            "| every 5m",
            "| group_by 5m,",
            "    [value_health_fraction_true_aggregate:",
            "       aggregate(value_health_fraction_true)]",
            "| every 5m",
            "| group_by [resource.project_id, resource.environment_name],",
            "    [value_health_fraction_true_aggregate_aggregate:",
            "       aggregate(value_health_fraction_true_aggregate)]",
            "| condition val() < 0.95"])
        duration = "120s"
        trigger {
            count = "1"
        }
    }
  }
}

resource "google_monitoring_alert_policy" "scheduler_heartbeat" {
  display_name = "Scheduler Heartbeat"
  combiner     = "OR"
  conditions {
    display_name = "Scheduler Heartbeat"
    condition_monitoring_query_language {
        query = join("", [
            "fetch cloud_composer_environment",
            "| metric 'composer.googleapis.com/environment/scheduler_heartbeat_count'",
            "| group_by 10m,",
            "    [value_scheduler_heartbeat_count_aggregate:",
            "      aggregate(value.scheduler_heartbeat_count)]",
            "| every 10m",
            "| group_by 10m,",
            "    [value_scheduler_heartbeat_count_aggregate_mean:",
            "       mean(value_scheduler_heartbeat_count_aggregate)]",
            "| every 10m",
            "| group_by [resource.project_id, resource.environment_name],",
            "    [value_scheduler_heartbeat_count_aggregate_mean_aggregate:",
            "       aggregate(value_scheduler_heartbeat_count_aggregate_mean)]",
            "| condition val() < 80"])
        duration = "120s"
        trigger {
            count = "1"
        }
    }
  }
}

resource "google_monitoring_alert_policy" "database_cpu" {
  display_name = "Database CPU"
  combiner     = "OR"
  conditions {
    display_name = "Database CPU"
    condition_monitoring_query_language {
        query = join("", [
            "fetch cloud_composer_environment",
            "| metric 'composer.googleapis.com/environment/database/cpu/utilization'",
            "| group_by 10m, [value_utilization_mean: mean(value.utilization)]",
            "| every 10m",
            "| group_by [resource.project_id, resource.environment_name]",
            "| condition val() > 0.8"])
        duration = "120s"
        trigger {
            count = "1"
        }
    }
  }
}

resource "google_monitoring_alert_policy" "scheduler_cpu" {
  display_name = "Scheduler CPU"
  combiner     = "OR"
  conditions {
    display_name = "Scheduler CPU"
    condition_monitoring_query_language {
        query = join("", [
            "fetch k8s_container",
            "| metric 'kubernetes.io/container/cpu/limit_utilization'",
            "| filter (resource.pod_name =~ 'airflow-scheduler-.*')",
            "| group_by 10m, [value_limit_utilization_mean: mean(value.limit_utilization)]",
            "| every 10m",
            "| group_by [resource.cluster_name],",
            "    [value_limit_utilization_mean_mean: mean(value_limit_utilization_mean)]",
            "| condition val() > 0.8"])
        duration = "120s"
        trigger {
            count = "1"
        }
    }
  }
}

resource "google_monitoring_alert_policy" "worker_cpu" {
  display_name = "Worker CPU"
  combiner     = "OR"
  conditions {
    display_name = "Worker CPU"
    condition_monitoring_query_language {
        query = join("", [
            "fetch k8s_container",
            "| metric 'kubernetes.io/container/cpu/limit_utilization'",
            "| filter (resource.pod_name =~ 'airflow-worker.*')",
            "| group_by 10m, [value_limit_utilization_mean: mean(value.limit_utilization)]",
            "| every 10m",
            "| group_by [resource.cluster_name],",
            "    [value_limit_utilization_mean_mean: mean(value_limit_utilization_mean)]",
            "| condition val() > 0.8"])
        duration = "120s"
        trigger {
            count = "1"
        }
    }
  }
}

resource "google_monitoring_alert_policy" "webserver_cpu" {
  display_name = "Web Server CPU"
  combiner     = "OR"
  conditions {
    display_name = "Web Server CPU"
    condition_monitoring_query_language {
        query = join("", [
            "fetch k8s_container",
            "| metric 'kubernetes.io/container/cpu/limit_utilization'",
            "| filter (resource.pod_name =~ 'airflow-webserver.*')",
            "| group_by 10m, [value_limit_utilization_mean: mean(value.limit_utilization)]",
            "| every 10m",
            "| group_by [resource.cluster_name],",
            "    [value_limit_utilization_mean_mean: mean(value_limit_utilization_mean)]",
            "| condition val() > 0.8"])
        duration = "120s"
        trigger {
            count = "1"
        }
    }
  }
}

resource "google_monitoring_alert_policy" "database_memory" {
  display_name = "Database Memory"
  combiner     = "OR"
  conditions {
    display_name = "Database Memory"
    condition_monitoring_query_language {
        query = join("", [
            "fetch cloud_composer_environment",
            "| metric 'composer.googleapis.com/environment/database/memory/utilization'",
            "| group_by 10m, [value_utilization_mean: mean(value.utilization)]",
            "| every 10m",
            "| group_by [resource.project_id, resource.environment_name]",
            "| condition val() > 0.8"])
        duration = "0s"
        trigger {
            count = "1"
        }
    }
  }
}

resource "google_monitoring_alert_policy" "scheduler_memory" {
  display_name = "Scheduler Memory"
  combiner     = "OR"
  conditions {
    display_name = "Scheduler Memory"
    condition_monitoring_query_language {
        query = join("", [
            "fetch k8s_container",
            "| metric 'kubernetes.io/container/memory/limit_utilization'",
            "| filter (resource.pod_name =~ 'airflow-scheduler-.*')",
            "| group_by 10m, [value_limit_utilization_mean: mean(value.limit_utilization)]",
            "| every 10m",
            "| group_by [resource.cluster_name],",
            "    [value_limit_utilization_mean_mean: mean(value_limit_utilization_mean)]",
            "| condition val() > 0.8"])
        duration = "0s"
        trigger {
            count = "1"
        }
    }
  }
}

resource "google_monitoring_alert_policy" "worker_memory" {
  display_name = "Worker Memory"
  combiner     = "OR"
  conditions {
    display_name = "Worker Memory"
    condition_monitoring_query_language {
        query = join("", [
            "fetch k8s_container",
            "| metric 'kubernetes.io/container/memory/limit_utilization'",
            "| filter (resource.pod_name =~ 'airflow-worker.*')",
            "| group_by 10m, [value_limit_utilization_mean: mean(value.limit_utilization)]",
            "| every 10m",
            "| group_by [resource.cluster_name],",
            "    [value_limit_utilization_mean_mean: mean(value_limit_utilization_mean)]",
            "| condition val() > 0.8"])
        duration = "0s"
        trigger {
            count = "1"
        }
    }
  }
}

resource "google_monitoring_alert_policy" "webserver_memory" {
  display_name = "Web Server Memory"
  combiner     = "OR"
  conditions {
    display_name = "Web Server Memory"
    condition_monitoring_query_language {
        query = join("", [
            "fetch k8s_container",
            "| metric 'kubernetes.io/container/memory/limit_utilization'",
            "| filter (resource.pod_name =~ 'airflow-webserver.*')",
            "| group_by 10m, [value_limit_utilization_mean: mean(value.limit_utilization)]",
            "| every 10m",
            "| group_by [resource.cluster_name],",
            "    [value_limit_utilization_mean_mean: mean(value_limit_utilization_mean)]",
            "| condition val() > 0.8"])
        duration = "0s"
        trigger {
            count = "1"
        }
    }
  }
}

resource "google_monitoring_alert_policy" "scheduled_tasks_percentage" {
  display_name = "Scheduled Tasks Percentage"
  combiner     = "OR"
  conditions {
    display_name = "Scheduled Tasks Percentage"
    condition_monitoring_query_language {
        query = join("", [
            "fetch cloud_composer_environment",
            "| metric 'composer.googleapis.com/environment/unfinished_task_instances'",
            "| align mean_aligner(10m)",
            "| every(10m)",
            "| window(10m)",
            "| filter_ratio_by [resource.project_id, resource.environment_name], metric.state = 'scheduled'",
            "| condition val() > 0.80"])
        duration = "120s"
        trigger {
            count = "1"
        }
    }
  }
}

resource "google_monitoring_alert_policy" "queued_tasks_percentage" {
  display_name = "Queued Tasks Percentage"
  combiner     = "OR"
  conditions {
    display_name = "Queued Tasks Percentage"
    condition_monitoring_query_language {
        query = join("", [
            "fetch cloud_composer_environment",
            "| metric 'composer.googleapis.com/environment/unfinished_task_instances'",
            "| align mean_aligner(10m)",
            "| every(10m)",
            "| window(10m)",
            "| filter_ratio_by [resource.project_id, resource.environment_name], metric.state = 'queued'",
            "| group_by [resource.project_id, resource.environment_name]",
            "| condition val() > 0.95"])
        duration = "120s"
        trigger {
            count = "1"
        }
    }
  }
}

resource "google_monitoring_alert_policy" "workers_above_minimum" {
  display_name = "Current vs min number of workers (negative = missing workers)"
  combiner     = "OR"
  conditions {
    display_name = "Current vs min number of workers"
    condition_monitoring_query_language {
        query = join("", [
            "fetch cloud_composer_environment",
            "| { metric 'composer.googleapis.com/environment/num_celery_workers'",
            "| group_by 5m, [value_num_celery_workers_mean: mean(value.num_celery_workers)]",
            "| every 5m",
            "; metric 'composer.googleapis.com/environment/worker/min_workers'",
            "| group_by 5m, [value_min_workers_mean: mean(value.min_workers)]",
            "| every 5m }",
            "| outer_join 0",
            "| sub",
            "| group_by [resource.project_id, resource.environment_name]",
            "| condition val() < 0"])
        duration = "0s"
        trigger {
            count = "1"
        }
    }
  }
}

resource "google_monitoring_alert_policy" "pod_evictions" {
  display_name = "Worker pod evictions"
  combiner     = "OR"
  conditions {
    display_name = "Worker pod evictions"
    condition_monitoring_query_language {
        query = join("", [
            "fetch cloud_composer_environment",
            "| metric 'composer.googleapis.com/environment/worker/pod_eviction_count'",
            "| align delta(1m)",
            "| every 1m",
            "| group_by [resource.project_id, resource.environment_name]",
            "| condition val() > 0"])
        duration = "0s"
        trigger {
            count = "1"
        }
    }
  }
}

resource "google_monitoring_alert_policy" "scheduler_errors" {
  display_name = "Scheduler Errors"
  combiner     = "OR"
  conditions {
    display_name = "Scheduler Errors"
    condition_monitoring_query_language {
        query = join("", [
            "fetch cloud_composer_environment",
            "| metric 'logging.googleapis.com/log_entry_count'",
            "| filter (metric.log == 'airflow-scheduler' && metric.severity == 'ERROR')",
            "| group_by 1m,",
            "    [value_log_entry_count_aggregate: aggregate(value.log_entry_count)]",
            "| every 1m",
            "| group_by [resource.project_id, resource.environment_name],",
            "    [value_log_entry_count_aggregate_max: max(value_log_entry_count_aggregate)]",
            "| condition val() > 50"])
        duration = "60s"
        trigger {
            count = "1"
        }
    }
  }
}

resource "google_monitoring_alert_policy" "worker_errors" {
  display_name = "Worker Errors"
  combiner     = "OR"
  conditions {
    display_name = "Worker Errors"
    condition_monitoring_query_language {
        query = join("", [
            "fetch cloud_composer_environment",
            "| metric 'logging.googleapis.com/log_entry_count'",
            "| filter (metric.log == 'airflow-worker' && metric.severity == 'ERROR')",
            "| group_by 1m,",
            "    [value_log_entry_count_aggregate: aggregate(value.log_entry_count)]",
            "| every 1m",
            "| group_by [resource.project_id, resource.environment_name],",
            "    [value_log_entry_count_aggregate_max: max(value_log_entry_count_aggregate)]",
            "| condition val() > 50"])
        duration = "60s"
        trigger {
            count = "1"
        }
    }
  }
}

resource "google_monitoring_alert_policy" "webserver_errors" {
  display_name = "Web Server Errors"
  combiner     = "OR"
  conditions {
    display_name = "Web Server Errors"
    condition_monitoring_query_language {
        query = join("", [
            "fetch cloud_composer_environment",
            "| metric 'logging.googleapis.com/log_entry_count'",
            "| filter (metric.log == 'airflow-webserver' && metric.severity == 'ERROR')",
            "| group_by 1m,",
            "    [value_log_entry_count_aggregate: aggregate(value.log_entry_count)]",
            "| every 1m",
            "| group_by [resource.project_id, resource.environment_name],",
            "    [value_log_entry_count_aggregate_max: max(value_log_entry_count_aggregate)]",
            "| condition val() > 50"])
        duration = "60s"
        trigger {
            count = "1"
        }
    }
  }
}

resource "google_monitoring_alert_policy" "other_errors" {
  display_name = "Other Errors"
  combiner     = "OR"
  conditions {
    display_name = "Other Errors"
    condition_monitoring_query_language {
        query = join("", [
            "fetch cloud_composer_environment",
            "| metric 'logging.googleapis.com/log_entry_count'",
            "| filter",
            "    (metric.log !~ 'airflow-scheduler|airflow-worker|airflow-webserver'",
            "     && metric.severity == 'ERROR')",
            "| group_by 1m, [value_log_entry_count_max: max(value.log_entry_count)]",
            "| every 1m",
            "| group_by [resource.project_id, resource.environment_name],",
            "    [value_log_entry_count_max_aggregate: aggregate(value_log_entry_count_max)]",
            "| condition val() > 10"])
        duration = "60s"
        trigger {
            count = "1"
        }
    }
  }
}

resource "google_monitoring_alert_policy" "new_tasks_for_retry" {
  display_name = "New tasks for retry"

  depends_on = [time_sleep.tasks_for_retry]

  combiner     = "OR"
  conditions {
    display_name = "New tasks for retry"
    condition_monitoring_query_language {
        query = join("", [
            "fetch cloud_composer_environment",
            "| metric 'logging.googleapis.com/user/Composer_Airflow_new_tasks_for_RETRY'",
            "| align delta(5m)",
            "| every 5m",
            "| group_by [metric.environment_name, metric.project_id],",
            "   [value_Composer_Airflow_new_tasks_for_RETRY_aggregate: aggregate(value.Composer_Airflow_new_tasks_for_RETRY)]",
            "| condition val() > 10"
            ])
        duration = "60s"
        trigger {
            count = "1"
        }
    }
  }
}

resource "google_monitoring_alert_policy" "new_tasks_failed" {
  display_name = "New tasks failed"

  depends_on = [time_sleep.tasks_failed]

  combiner     = "OR"
  conditions {
    display_name = "New tasks failed"
    condition_monitoring_query_language {
        query = join("", [
            "fetch cloud_composer_environment",
            "| metric 'logging.googleapis.com/user/Composer_Airflow_new_FAILED_tasks'",
            "| align delta(5m)",
            "| every 5m",
            "| group_by [metric.environment_name, metric.project_id],",
            "   [value_Composer_Airflow_new_FAILED_tasks: aggregate(value.Composer_Airflow_new_FAILED_tasks)]",
            "| condition val() > 10"
            ])
        duration = "60s"
        trigger {
            count = "1"
        }
    }
  }
}


#######################################################
#  
# Create Monitoring Dashboard
#
########################################################


resource "google_monitoring_dashboard" "Composer_Dashboard" {
  dashboard_json = <<EOF
{
  "category": "CUSTOM",
  "displayName": "Cloud Composer - Monitoring Platform",
  "mosaicLayout": {
    "columns": 12,
    "tiles": [
      {
        "height": 1,
        "widget": {
          "text": {
            "content": "",
            "format": "MARKDOWN"
          },
          "title": "Health"
        },
        "width": 12,
        "xPos": 0,
        "yPos": 0
      },
      {
        "height": 4,
        "widget": {
          "alertChart": {
            "name": "${google_monitoring_alert_policy.environment_health.name}"
          }
        },
        "width": 6,
        "xPos": 0,
        "yPos": 1
      },
      {
        "height": 4,
        "widget": {
          "alertChart": {
            "name": "${google_monitoring_alert_policy.database_health.name}"
          }
        },
        "width": 6,
        "xPos": 6,
        "yPos": 1
      },
      {
        "height": 4,
        "widget": {
          "alertChart": {
            "name": "${google_monitoring_alert_policy.webserver_health.name}"
          }
        },
        "width": 6,
        "xPos": 0,
        "yPos": 5
      },
      {
        "height": 4,
        "widget": {
          "alertChart": {
            "name": "${google_monitoring_alert_policy.scheduler_heartbeat.name}"
          }
        },
        "width": 6,
        "xPos": 6,
        "yPos": 5
      },
      {
        "height": 1,
        "widget": {
          "text": {
            "content": "",
            "format": "RAW"
          },
          "title": "CPU Utilization"
        },
        "width": 12,
        "xPos": 0,
        "yPos": 9
      },
      {
        "height": 4,
        "widget": {
          "alertChart": {
            "name": "${google_monitoring_alert_policy.database_cpu.name}"
          }
        },
        "width": 6,
        "xPos": 0,
        "yPos": 10
      },
      {
        "height": 4,
        "widget": {
          "alertChart": {
            "name": "${google_monitoring_alert_policy.scheduler_cpu.name}"
          }
        },
        "width": 6,
        "xPos": 6,
        "yPos": 10
      },
      {
        "height": 4,
        "widget": {
          "alertChart": {
            "name": "${google_monitoring_alert_policy.worker_cpu.name}"
          }
        },
        "width": 6,
        "xPos": 0,
        "yPos": 14
      },
      {
        "height": 4,
        "widget": {
          "alertChart": {
            "name": "${google_monitoring_alert_policy.webserver_cpu.name}"
          }
        },
        "width": 6,
        "xPos": 6,
        "yPos": 14
      },
      {
        "height": 1,
        "widget": {
          "text": {
            "content": "",
            "format": "RAW"
          },
          "title": "Task execution bottleneck"
        },
        "width": 12,
        "xPos": 0,
        "yPos": 18
      },
      {
        "height": 4,
        "widget": {
          "alertChart": {
            "name": "${google_monitoring_alert_policy.scheduled_tasks_percentage.name}"
          }
        },
        "width": 6,
        "xPos": 0,
        "yPos": 19
      },
      {
        "height": 4,
        "widget": {
          "alertChart": {
            "name": "${google_monitoring_alert_policy.queued_tasks_percentage.name}"
          }
        },
        "width": 6,
        "xPos": 6,
        "yPos": 19
      },
      {
        "height": 1,
        "widget": {
          "text": {
            "content": "",
            "format": "RAW"
          },
          "title": "Workers presence"
        },
        "width": 12,
        "xPos": 0,
        "yPos": 23
      },
      {
        "height": 4,
        "widget": {
          "alertChart": {
            "name": "${google_monitoring_alert_policy.workers_above_minimum.name}"
          }
        },
        "width": 6,
        "xPos": 0,
        "yPos": 24
      },
      {
        "height": 4,
        "widget": {
          "alertChart": {
            "name": "${google_monitoring_alert_policy.pod_evictions.name}"
          }
        },
        "width": 6,
        "xPos": 6,
        "yPos": 24
      },
      {
        "height": 1,
        "widget": {
          "text": {
            "content": "",
            "format": "RAW"
          },
          "title": "Memory Utilization"
        },
        "width": 12,
        "xPos": 0,
        "yPos": 28
      },
      {
        "height": 4,
        "widget": {
          "alertChart": {
            "name": "${google_monitoring_alert_policy.database_memory.name}"
          }
        },
        "width": 6,
        "xPos": 0,
        "yPos": 29
      },
      {
        "height": 4,
        "widget": {
          "alertChart": {
            "name": "${google_monitoring_alert_policy.scheduler_memory.name}"
          }
        },
        "width": 6,
        "xPos": 6,
        "yPos": 29
      },
      {
        "height": 4,
        "widget": {
          "alertChart": {
            "name": "${google_monitoring_alert_policy.worker_memory.name}"
          }
        },
        "width": 6,
        "xPos": 0,
        "yPos": 33
      },
      {
        "height": 4,
        "widget": {
          "alertChart": {
            "name": "${google_monitoring_alert_policy.webserver_memory.name}"
          }
        },
        "width": 6,
        "xPos": 6,
        "yPos": 33
      },
      {
        "height": 1,
        "widget": {
          "text": {
            "content": "",
            "format": "RAW"
          },
          "title": "Errors"
        },
        "width": 12,
        "xPos": 0,
        "yPos": 37
      },
      {
        "height": 4,
        "widget": {
          "alertChart": {
            "name": "${google_monitoring_alert_policy.scheduler_errors.name}"
          }
        },
        "width": 6,
        "xPos": 0,
        "yPos": 38
      },
      {
        "height": 4,
        "widget": {
          "alertChart": {
            "name": "${google_monitoring_alert_policy.worker_errors.name}"
          }
        },
        "width": 6,
        "xPos": 6,
        "yPos": 38
      },
            {
        "height": 4,
        "widget": {
          "alertChart": {
            "name": "${google_monitoring_alert_policy.webserver_errors.name}"
          }
        },
        "width": 6,
        "xPos": 0,
        "yPos": 44
      },
      {
        "height": 4,
        "widget": {
          "alertChart": {
            "name": "${google_monitoring_alert_policy.other_errors.name}"
          }
        },
        "width": 6,
        "xPos": 6,
        "yPos": 44
      },
      {
        "height": 1,
        "widget": {
          "text": {
            "content": "",
            "format": "RAW"
          },
          "title": "Task errors"
        },
        "width": 12,
        "xPos": 0,
        "yPos": 48
      },
      {
        "height": 4,
        "widget": {
          "alertChart": {
            "name": "${google_monitoring_alert_policy.new_tasks_for_retry.name}"
          }
        },
        "width": 6,
        "xPos": 0,
        "yPos": 49
      },   
      {
        "height": 4,
        "widget": {
          "alertChart": {
            "name": "${google_monitoring_alert_policy.new_tasks_failed.name}"
          }
        },
        "width": 6,
        "xPos": 6,
        "yPos": 49
      }     
    ]
  }
}
EOF
}
