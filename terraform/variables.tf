variable "alert_email" {
  type        = string
  description = "Email address for incident notifications"
  default     = "rodriguerwi@gmail.com"
}

variable "app_service_name" {
  type        = string
  description = "systemd service name to restart via SSM"
  default     = "techstream-app"
}

variable "cw_namespace" {
  type        = string
  description = "CloudWatch custom metrics namespace"
  default     = "TechStream/App"
}

variable "error_rate_threshold" {
  type        = number
  description = "Error rate % that triggers remediation"
  default     = 5
}

variable "latency_threshold_ms" {
  type        = number
  description = "P99 latency (ms) that triggers alert"
  default     = 2000
}

variable "cpu_threshold" {
  type        = number
  description = "CPU % that triggers saturation alert"
  default     = 80
}

variable "instance_type" {
  type        = string
  description = "EC2 instance type — t2.micro is free tier eligible"
  default     = "t3.micro"
}

variable "key_name" {
  type        = string
  description = "EC2 key pair name for SSH access. Set to null to use SSM Session Manager instead."
  default     = null
}
