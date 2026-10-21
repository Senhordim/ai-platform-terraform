output "budget_names" {
  description = "Budgets por caso de uso."
  value       = { for k, b in aws_budgets_budget.use_case : k => b.name }
}

output "cur_bucket" {
  description = "Bucket do CUR 2.0."
  value       = module.cur_bucket.id
}
