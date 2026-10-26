# Data: one managed Postgres (RDS) in the private subnets, and its connection string
# in Secrets Manager. Pods never see a password in Git: External Secrets (addons.tf)
# copies the secret into Kubernetes at runtime.

# Letters and digits only, so the password can sit inside a URL without escaping.
# Note: the value is stored in Terraform state, which is why the state bucket is private and encrypted.
resource "random_password" "db" {
  length  = 32
  special = false
}

# Which subnets RDS may place the database in: the private ones (no route from the internet).
resource "aws_db_subnet_group" "db" {
  name       = var.name
  subnet_ids = module.vpc.private_subnets
}

# Firewall for the database: only the EKS nodes (and therefore their pods) may connect, only on 5432.
resource "aws_security_group" "db" {
  name        = "${var.name}-db"
  description = "Postgres, reachable only from EKS nodes"
  vpc_id      = module.vpc.vpc_id
}

resource "aws_vpc_security_group_ingress_rule" "db_from_nodes" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = module.eks.node_security_group_id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_db_instance" "db" {
  identifier     = var.name
  engine         = "postgres"
  engine_version = "17"          # major only: AWS picks its default 17.x minor
  instance_class = "db.t3.micro" # free-tier eligible, x86

  allocated_storage = 20
  storage_type      = "gp3"
  storage_encrypted = true # AWS-managed key; nothing left behind on destroy

  db_name  = "snapshotdb" # "snapshot" is a reserved word in RDS Postgres
  username = "app"
  password = random_password.db.result

  db_subnet_group_name   = aws_db_subnet_group.db.name
  vpc_security_group_ids = [aws_security_group.db.id]
  publicly_accessible    = false
  multi_az               = false # production: true (a standby copy in the second AZ)

  # Throwaway data: no backups, no final snapshot, deletable. Production flips all three.
  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false
  apply_immediately       = true
}

# The secret post-service will read. recovery_window_in_days = 0 deletes it immediately on destroy,
# so the next `apply` can reuse the same name (the default 7-day recovery window would block it).
resource "aws_secretsmanager_secret" "post_service_db" {
  name                    = "${var.name}/post-service/db"
  recovery_window_in_days = 0
}

resource "aws_secretsmanager_secret_version" "post_service_db" {
  secret_id = aws_secretsmanager_secret.post_service_db.id
  secret_string = jsonencode({
    DATABASE_URL = "postgres://app:${random_password.db.result}@${aws_db_instance.db.address}:5432/${aws_db_instance.db.db_name}?sslmode=require"
  })
}
