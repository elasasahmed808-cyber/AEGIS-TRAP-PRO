{
  "agent": { "run_as_user": "root" },
  "metrics": {
    "append_dimensions": { "InstanceId": "$${aws:InstanceId}" },
    "metrics_collected": {
      "mem":  { "measurement": ["mem_used_percent"] },
      "disk": { "measurement": ["used_percent"], "resources": ["/"] }
    }
  },
  "logs": {
    "logs_collected": {
      "files": {
        "collect_list": [
          { "file_path": "${app_log_path}", "log_group_name": "${app_log_group}", "log_stream_name": "{instance_id}" },
          { "file_path": "/var/log/messages", "log_group_name": "${os_log_group}", "log_stream_name": "{instance_id}/messages" },
          { "file_path": "/var/log/secure",   "log_group_name": "${os_log_group}", "log_stream_name": "{instance_id}/secure" },
          { "file_path": "/var/log/audit/audit.log", "log_group_name": "${os_log_group}", "log_stream_name": "{instance_id}/audit" }
        ]
      }
    }
  }
}
