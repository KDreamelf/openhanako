# PH01 认证中心正式配置。
# 部署前按实际 PostgreSQL / Redis / SMTP / 域名修改。

database "auth" {
  driver = "postgres"
  dsn    = "host=postgres.example.internal port=5432 user=ph01_auth password=CHANGE_ME_AUTH_DB_PASSWORD dbname=ph01_auth sslmode=require"
}

redis "auth" {
  url = "redis://:CHANGE_ME_AUTH_REDIS_PASSWORD@redis.example.internal:6379/0"
}

smtp "recovery" {
  enabled  = false
  host     = "smtp.example.com"
  port     = 587
  username = "noreply@example.com"
  password = "CHANGE_ME_SMTP_PASSWORD"
  from     = "PH01 <noreply@example.com>"
  tls_mode = "require_starttls"
}

ai_gateway_sync "default" {
  enabled        = true
  base_url       = "http://ph01-ai-gateway:3000"
  internal_token = "04e12202af9b65fe416a81ace6ed0f7eab2a40d52e0aa4a03eb70591ad019769"
  timeout_ms     = 5000
}

server "auth_gateway" {
  listen       = ":8080"
  admin_token  = "148e8975201d395fa417e4846847de6f458410ed86415065094002631a81b0ab"
  cors_origins = ["https://auth.xn--lbtx0e.cn", "https://ai.xn--lbtx0e.cn"]
}

server "auth_gateway_mtls" {
  listen       = ":8443"
  admin_token  = "148e8975201d395fa417e4846847de6f458410ed86415065094002631a81b0ab"
  cors_origins = ["https://ai.xn--lbtx0e.cn"]

  tls {
    enabled             = true
    cert_file           = "/etc/ph01/certs/mtls/auth-center.pem"
    key_file            = "/etc/ph01/certs/mtls/auth-center-key.pem"
    client_ca_file      = "/etc/ph01/certs/mtls/root-ca.pem"
    require_client_cert = true
  }
}
