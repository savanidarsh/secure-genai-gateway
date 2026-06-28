# budgets.tf — Phase 8c: dollar-cost circuit-breaker for the whole account.

resource "aws_budgets_budget" "monthly_cost" {
  name         = "secure-genai-gateway-monthly-cost"
  budget_type  = "COST"
  limit_amount = "5" # your monthly ceiling in dollars
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  # Alert when ACTUAL spend passes 80% of the limit ($4 of $5).
  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = ["darsh@terpmail.umd.edu"]
  }
}