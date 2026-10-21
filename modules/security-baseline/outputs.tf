output "guardduty_detector_id" {
  description = "ID do detector do GuardDuty (null se desabilitado)."
  value       = try(aws_guardduty_detector.this[0].id, null)
}

output "config_recorder_name" {
  description = "Nome do recorder do AWS Config (null se desabilitado)."
  value       = try(aws_config_configuration_recorder.this[0].name, null)
}
